#!/bin/bash
# run_disagg_test.sh - Disagg 模式测试脚本（cluster 端执行）
# 
# 功能：
# 1. 从 TestList 或配置文件名提取配置
# 2. 调用 calculate_hardware_nodes.py 计算节点数
# 3. 生成并提交 sbatch 脚本
# 4. 等待作业完成
#
# 注意：此脚本在 cluster 上运行，不是在中转机上运行

set -euo pipefail

# ============================================
# 参数解析
# ============================================
TRTLLM_DIR=""
TESTLIST=""
CONFIG_FILE=""
WORKSPACE=""
DRY_RUN=false

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --trtllm-dir DIR        TensorRT-LLM 目录路径 (必需)
    --testlist NAME         TestList 名称 (与 --config-file 二选一)
    --config-file NAME      配置文件名 (与 --testlist 二选一)
    --workspace DIR         工作目录 (必需)
    --dry-run               试运行模式
    -h, --help              显示帮助信息

注意：disagg 模式不支持 pytest -k 过滤（使用专用的 submit.py）

示例:
    $0 --trtllm-dir /path/to/TensorRT-LLM \\
       --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \\
       --workspace /tmp/disagg_test

    $0 --trtllm-dir /path/to/TensorRT-LLM \\
       --config-file deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX \\
       --workspace /tmp/disagg_test
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --trtllm-dir)
            TRTLLM_DIR="$2"
            shift 2
            ;;
        --testlist)
            TESTLIST="$2"
            shift 2
            ;;
        --config-file)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "错误：未知参数 $1"
            usage
            ;;
    esac
done

# 验证必需参数
if [[ -z "$TRTLLM_DIR" ]]; then
    echo "错误：必须指定 --trtllm-dir"
    exit 1
fi

if [[ -z "$TESTLIST" && -z "$CONFIG_FILE" ]]; then
    echo "错误：必须指定 --testlist 或 --config-file"
    exit 1
fi

if [[ -z "$WORKSPACE" ]]; then
    echo "错误：必须指定 --workspace"
    exit 1
fi

# 创建工作目录
mkdir -p "$WORKSPACE"

echo "========================================"
echo "Disagg 模式性能测试"
echo "========================================"
echo "TensorRT-LLM 目录: $TRTLLM_DIR"
echo "TestList: ${TESTLIST:-未指定}"
echo "配置文件: ${CONFIG_FILE:-未指定}"
echo "工作目录: $WORKSPACE"
echo "试运行: $DRY_RUN"
echo "========================================"

# ============================================
# 步骤 1: 提取配置文件名
# ============================================
CONFIG_NAME="$CONFIG_FILE"

if [[ -z "$CONFIG_NAME" && -n "$TESTLIST" ]]; then
    echo ""
    echo "[步骤 1] 从 TestList 提取配置文件名..."
    
    # 查找 TestList 文件
    TESTLIST_FILE=""
    for path in \
        "$TRTLLM_DIR/tests/integration/test_lists/test-db/${TESTLIST}.yml" \
        "$TRTLLM_DIR/tests/integration/test_lists/qa/${TESTLIST}.yml"; do
        if [[ -f "$path" ]]; then
            TESTLIST_FILE="$path"
            break
        fi
    done
    
    if [[ -z "$TESTLIST_FILE" ]]; then
        echo "错误：找不到 TestList 文件: $TESTLIST"
        exit 1
    fi
    
    echo "找到 TestList: $TESTLIST_FILE"
    
    # 提取配置名
    CONFIG_NAME=$(python3 << 'EOF'
import yaml
import re
import sys

testlist_file = sys.argv[1]

try:
    with open(testlist_file) as f:
        data = yaml.safe_load(f)
    
    testlist_name = [k for k in data.keys() if k != 'version'][0]
    
    for item in data[testlist_name]:
        if 'tests' in item:
            for test in item['tests']:
                if 'disagg_upload-' in test or 'disagg-' in test:
                    match = re.search(r'\[disagg_upload-(.+?)\]|\[disagg-(.+?)\]', test)
                    if match:
                        config_base = match.group(1) or match.group(2)
                        config_base = config_base.split()[0]
                        print(config_base)
                        sys.exit(0)
    
    print("错误：TestList 中没有找到 disagg 测试", file=sys.stderr)
    sys.exit(1)
    
except Exception as e:
    print(f"错误：{e}", file=sys.stderr)
    sys.exit(1)
EOF
"$TESTLIST_FILE"
)
    
    if [[ -z "$CONFIG_NAME" ]]; then
        echo "错误：无法从 TestList 提取配置名"
        exit 1
    fi
    
    echo "提取的配置名: $CONFIG_NAME"
fi

# ============================================
# 步骤 2: 查找配置文件完整路径
# ============================================
echo ""
echo "[步骤 2] 查找配置文件..."

CONFIG_FULL_PATH=""
for path in \
    "$TRTLLM_DIR/tests/integration/defs/perf/disagg/test_configs/disagg/perf/${CONFIG_NAME}.yaml" \
    "$TRTLLM_DIR/tests/integration/defs/perf/disagg/test_configs/wideep/perf/${CONFIG_NAME}.yaml"; do
    if [[ -f "$path" ]]; then
        CONFIG_FULL_PATH="$path"
        break
    fi
done

if [[ -z "$CONFIG_FULL_PATH" ]]; then
    echo "错误：找不到配置文件: ${CONFIG_NAME}.yaml"
    echo "查找路径:"
    echo "  - $TRTLLM_DIR/tests/integration/defs/perf/disagg/test_configs/disagg/perf/"
    echo "  - $TRTLLM_DIR/tests/integration/defs/perf/disagg/test_configs/wideep/perf/"
    exit 1
fi

echo "找到配置文件: $CONFIG_FULL_PATH"

# ============================================
# 步骤 3: 计算硬件节点数
# ============================================
echo ""
echo "[步骤 3] 计算硬件节点数..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CALC_SCRIPT="$SCRIPT_DIR/calculate_hardware_nodes.py"

if [[ ! -f "$CALC_SCRIPT" ]]; then
    echo "错误：找不到 calculate_hardware_nodes.py"
    exit 1
fi

NODE_INFO_JSON="$WORKSPACE/node_info.json"
python3 "$CALC_SCRIPT" --config "$CONFIG_FULL_PATH" --json > "$NODE_INFO_JSON"

# 读取节点信息
TOTAL_NODES=$(python3 -c "import json; print(json.load(open('$NODE_INFO_JSON'))['total_nodes'])")
TOTAL_GPUS=$(python3 -c "import json; print(json.load(open('$NODE_INFO_JSON'))['total_gpus'])")
GPUS_PER_NODE=$(python3 -c "import json; print(json.load(open('$NODE_INFO_JSON'))['gpus_per_node'])")
NUM_CTX_SERVERS=$(python3 -c "import json; print(json.load(open('$NODE_INFO_JSON')).get('num_ctx_servers', 0))")
NUM_GEN_SERVERS=$(python3 -c "import json; print(json.load(open('$NODE_INFO_JSON'))['num_gen_servers'])")
CTX_NODES=$(python3 -c "import json; print(json.load(open('$NODE_INFO_JSON')).get('ctx_nodes', 0))")
GEN_NODES=$(python3 -c "import json; print(json.load(open('$NODE_INFO_JSON'))['gen_nodes'])")

echo "节点计算结果:"
echo "  逻辑 CTX servers: $NUM_CTX_SERVERS"
echo "  逻辑 GEN servers: $NUM_GEN_SERVERS"
echo "  硬件 CTX nodes: $CTX_NODES"
echo "  硬件 GEN nodes: $GEN_NODES"
echo "  总硬件节点: $TOTAL_NODES"
echo "  总 GPU 数: $TOTAL_GPUS"
echo "  每节点 GPU 数: $GPUS_PER_NODE"

# ============================================
# 步骤 4: 准备 submit.py 所需的输入文件
# ============================================
echo ""
echo "[步骤 4] 准备 submit.py 输入文件..."

# 从环境变量获取 cluster 配置（由 Jenkins 设置）
CLUSTER_ACCOUNT="${CLUSTER_ACCOUNT:-coreai_comparch_trtllm}"
CLUSTER_PARTITION="${CLUSTER_PARTITION:-batch}"
MPI_TYPE="${MPI_TYPE:-pmix}"
DOCKER_IMAGE="${DOCKER_IMAGE:-nvcr.io/nvidia/tensorrt-llm:latest}"
CLUSTER_LLM_DATA="${CLUSTER_LLM_DATA:-/lustre/fsw/coreai_comparch_trtllm/common}"

# 从环境变量读取自定义测试模块配置（可选）
PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"

echo "测试模块配置:"
echo "  测试模块: $PERF_TEST_MODULE"
echo "  测试函数: $PERF_TEST_FUNCTION"
echo "  测试前缀: $PERF_TEST_PREFIX"

# 判断是否需要 trtllm-llmapi-launch（对齐 L0_Test.groovy）
# 当节点数 > 1 或每节点 GPU 数 > 1 时，需要 llmapi-launch 来管理多进程通信
PYTEST_UTIL=""
if [[ "$TOTAL_NODES" -gt 1 ]] || [[ "$GPUS_PER_NODE" -gt 1 ]]; then
    PYTEST_UTIL="$TRTLLM_DIR/tensorrt_llm/llmapi/trtllm-llmapi-launch"
    echo "✓ 将使用 trtllm-llmapi-launch (多节点/多GPU)"
else
    echo "✓ 单节点单GPU，不使用 trtllm-llmapi-launch"
fi

# 4.1 创建 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]
EOF
echo "✓ 生成 test list: $TEST_LIST_FILE"
echo "  内容: ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]"

# 4.2 创建 script prefix 文件（包含 SBATCH 指令和环境变量）
# 完全对齐 L0_Test.groovy 的实现
SCRIPT_PREFIX_FILE="$WORKSPACE/slurm_launch_prefix.sh"
cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX
#!/bin/bash
#SBATCH --output=$WORKSPACE/slurm_%j.log
#SBATCH --nodes=$TOTAL_NODES
#SBATCH --ntasks=$TOTAL_GPUS
#SBATCH --ntasks-per-node=$GPUS_PER_NODE
#SBATCH --gpus-per-node=$GPUS_PER_NODE
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT
#SBATCH --job-name=disagg_perf_test
#SBATCH --time=04:00:00

set -xEeuo pipefail
trap 'rc=\\\$?; echo "Error in file \\\${BASH_SOURCE[0]} on line \\\$LINENO: \\\$BASH_COMMAND (exit \\\$rc)"; exit \\\$rc' ERR

echo "Starting Slurm job \\\$SLURM_JOB_ID on \\\$SLURM_NODELIST"

# 导出基础环境变量
export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test_${CONFIG_NAME}"
export perfMode=true
export resourcePathNode=$TRTLLM_DIR

# 构造完整的 pytestCommand（对齐 L0_Test.groovy）
# 包含必要的环境变量、llmapi-launch（如果需要）和完整的 pytest 参数
export pytestCommand="LLM_ROOT=$TRTLLM_DIR LLM_BACKEND_ROOT=$TRTLLM_DIR/triton_backend LLM_MODELS_ROOT=$CLUSTER_LLM_DATA MODEL_CACHE_DIR=$CLUSTER_LLM_DATA COLUMNS=300 NCCL_DEBUG=INFO $PYTEST_UTIL pytest -vv --timeout-method=thread --timeout=3600 --rootdir $TRTLLM_DIR/tests/integration/defs --test-prefix=${PERF_TEST_PREFIX} --output-dir=$WORKSPACE/ --csv=$WORKSPACE/report.csv -o junit_logging=out-err --junit-xml=$WORKSPACE/results.xml ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]"

export coverageConfigFile=$WORKSPACE/coverage_config.json
export NVIDIA_IMEX_CHANNELS=\\\${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=\\\${NVIDIA_VISIBLE_DEVICES:-\\\$(seq -s, 0 \\\$((\\\$(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
EOFPREFIX
echo "✓ 生成 script prefix: $SCRIPT_PREFIX_FILE"

# 4.3 创建 srun args 文件
SRUN_ARGS_FILE="$WORKSPACE/slurm_srun_args.txt"
cat > "$SRUN_ARGS_FILE" << EOFSRUN
--container-name=disagg_test_\${SLURM_JOB_ID}
--container-image=${DOCKER_IMAGE}
--container-workdir=$WORKSPACE/disagg_workspace
--container-mounts=${CLUSTER_LLM_DATA}:/data,${TRTLLM_DIR}:${TRTLLM_DIR}
--mpi=${MPI_TYPE}
EOFSRUN
echo "✓ 生成 srun args: $SRUN_ARGS_FILE"

# 4.4 准备其他文件路径
DRAFT_LAUNCH_SH="$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh"
LAUNCH_SH="$WORKSPACE/slurm_launch_generated.sh"
RUN_SH="$TRTLLM_DIR/jenkins/scripts/slurm_run.sh"
INSTALL_SH="$TRTLLM_DIR/jenkins/scripts/slurm_install.sh"
SUBMIT_PY="$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/submit.py"

# 验证文件存在
for file in "$DRAFT_LAUNCH_SH" "$RUN_SH" "$INSTALL_SH" "$SUBMIT_PY"; do
    if [[ ! -f "$file" ]]; then
        echo "错误：找不到文件: $file"
        exit 1
    fi
done

echo "✓ 所有输入文件准备完成"

# ============================================
# 步骤 5: 调用 submit.py 生成 launch 脚本
# ============================================
echo ""
echo "[步骤 5] 调用 submit.py 生成 launch 脚本..."

python3 "$SUBMIT_PY" \
    --run-ci \
    --llm-src "$TRTLLM_DIR" \
    --test-list "$TEST_LIST_FILE" \
    --draft-launch-sh "$DRAFT_LAUNCH_SH" \
    --launch-sh "$LAUNCH_SH" \
    --run-sh "$RUN_SH" \
    --install-sh "$INSTALL_SH" \
    --script-prefix "$SCRIPT_PREFIX_FILE" \
    --srun-args "$SRUN_ARGS_FILE"

if [[ ! -f "$LAUNCH_SH" ]]; then
    echo "错误：submit.py 未生成 launch 脚本: $LAUNCH_SH"
    exit 1
fi

echo "✓ Launch 脚本已生成: $LAUNCH_SH"
echo ""
echo "生成的脚本内容:"
echo "----------------------------------------"
cat "$LAUNCH_SH"
echo "----------------------------------------"

# ============================================
# 步骤 6: 提交作业
# ============================================
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[试运行模式] 跳过实际提交"
    echo "要手动提交，请运行:"
    echo "  sbatch $LAUNCH_SH"
    exit 0
fi

echo ""
echo "[步骤 6] 提交 Slurm 作业..."

SUBMIT_OUTPUT=$(sbatch "$LAUNCH_SH")
echo "$SUBMIT_OUTPUT"

JOB_ID=$(echo "$SUBMIT_OUTPUT" | awk '{print $NF}')

if [[ -z "$JOB_ID" ]]; then
    echo "错误：无法获取作业 ID"
    exit 1
fi

echo "Slurm Job ID: $JOB_ID"
LOG_FILE="$WORKSPACE/slurm_${JOB_ID}.log"
echo "日志文件: $LOG_FILE"

# ============================================
# 步骤 6: 等待作业完成
# ============================================
echo ""
echo "[步骤 6] 等待作业完成..."

while true; do
    STATUS=$(sacct -j "$JOB_ID" --format=State -Pn --allocations 2>/dev/null || echo "")
    
    if [[ -z "$STATUS" || "$STATUS" == "RUNNING" || "$STATUS" == "PENDING" || "$STATUS" == "CONFIGURING" ]]; then
        echo "作业状态: ${STATUS:-PENDING} (等待 30s...)"
        sleep 30
    else
        echo "作业状态: $STATUS"
        break
    fi
done

# 获取退出码
EXIT_CODE=$(sacct -j "$JOB_ID" --format=ExitCode -Pn --allocations | awk -F: '{print $1}')

echo ""
echo "========================================"
echo "作业完成"
echo "========================================"
echo "Job ID: $JOB_ID"
echo "状态: $STATUS"
echo "退出码: $EXIT_CODE"
echo "日志: $LOG_FILE"
echo "========================================"

if [[ "$STATUS" == "COMPLETED" && "$EXIT_CODE" -eq 0 ]]; then
    echo "✓ 测试成功"
    exit 0
else
    echo "✗ 测试失败"
    exit 1
fi
