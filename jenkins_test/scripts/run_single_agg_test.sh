#!/bin/bash
# run_single_agg_test.sh - Single Node Agg 模式测试脚本（cluster 端执行）
# 
# 功能：
# 1. 查找配置文件
# 2. 使用 srun + Docker 容器运行 pytest（单节点）
#
# 注意：此脚本在 cluster 上运行

set -euo pipefail

# ============================================
# 参数解析
# ============================================
TRTLLM_DIR=""
CONFIG_FILE=""
DRY_RUN=false

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
    --trtllm-dir DIR        TensorRT-LLM 目录路径 (必需)
    --config-file NAME      配置文件名 (必需)
    --dry-run               试运行模式
    -h, --help              显示帮助信息

示例:
    $0 --trtllm-dir /path/to/TensorRT-LLM \\
       --config-file deepseek_r1_fp4_v2_blackwell
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --trtllm-dir)
            TRTLLM_DIR="$2"
            shift 2
            ;;
        --config-file)
            CONFIG_FILE="$2"
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

if [[ -z "$CONFIG_FILE" ]]; then
    echo "错误：必须指定 --config-file"
    exit 1
fi

echo "========================================"
echo "Single Node Agg 模式性能测试"
echo "========================================"
echo "TensorRT-LLM 目录: $TRTLLM_DIR"
echo "配置文件: $CONFIG_FILE"
echo "试运行: $DRY_RUN"
echo "========================================"

# ============================================
# 步骤 1: 查找配置文件
# ============================================
echo ""
echo "[步骤 1] 查找配置文件..."

CONFIG_FULL_PATH=""
for path in \
    "$TRTLLM_DIR/tests/scripts/perf-sanity/${CONFIG_FILE}.yaml" \
    "$TRTLLM_DIR/tests/scripts/perf-sanity/${CONFIG_FILE}" \
    "$TRTLLM_DIR/tests/integration/defs/perf/agg/${CONFIG_FILE}.yaml" \
    "$TRTLLM_DIR/tests/integration/defs/perf/agg/${CONFIG_FILE}"; do
    if [[ -f "$path" ]]; then
        CONFIG_FULL_PATH="$path"
        break
    fi
done

if [[ -z "$CONFIG_FULL_PATH" ]]; then
    echo "错误：找不到配置文件: $CONFIG_FILE"
    echo "查找路径:"
    echo "  - $TRTLLM_DIR/tests/scripts/perf-sanity/"
    echo "  - $TRTLLM_DIR/tests/integration/defs/perf/agg/"
    exit 1
fi

echo "找到配置文件: $CONFIG_FULL_PATH"

# ============================================
# 步骤 2: 运行 pytest (使用 srun + Docker)
# ============================================
echo ""
echo "[步骤 2] 使用 srun 运行 pytest..."

# 从环境变量获取 cluster 配置
CLUSTER_ACCOUNT="${CLUSTER_ACCOUNT:-coreai_comparch_trtllm}"
CLUSTER_PARTITION="${CLUSTER_PARTITION:-batch}"
MPI_TYPE="${MPI_TYPE:-pmix}"
DOCKER_IMAGE="${DOCKER_IMAGE:-nvcr.io/nvidia/tensorrt-llm:latest}"
CLUSTER_LLM_DATA="${CLUSTER_LLM_DATA:-/lustre/fs1/portfolios/coreai/projects/coreai_comparch_trtllm/common}"

# 构造 srun 命令
SRUN_CMD="srun"
SRUN_CMD+=" --mpi=${MPI_TYPE}"
SRUN_CMD+=" -N 1"
SRUN_CMD+=" -A ${CLUSTER_ACCOUNT}"
SRUN_CMD+=" -p ${CLUSTER_PARTITION}"
SRUN_CMD+=" --container-image=${DOCKER_IMAGE}"
SRUN_CMD+=" --container-workdir=${TRTLLM_DIR}"
SRUN_CMD+=" --container-mounts=${TRTLLM_DIR}:${TRTLLM_DIR},${CLUSTER_LLM_DATA}:${CLUSTER_LLM_DATA}"

PYTEST_CMD="python3 -m pytest"
PYTEST_CMD+=" tests/integration/defs/perf/test_perf_sanity.py::test_e2e"
PYTEST_CMD+=" -k 'aggr_upload-${CONFIG_FILE}'"
PYTEST_CMD+=" -v"

echo "执行命令:"
echo "  cd ${TRTLLM_DIR}"
echo "  ${SRUN_CMD} \\"
echo "    ${PYTEST_CMD}"
echo ""

cd "$TRTLLM_DIR"

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[试运行模式] 跳过实际执行"
    echo "要手动运行，请执行:"
    echo "  cd ${TRTLLM_DIR} && ${SRUN_CMD} ${PYTEST_CMD}"
    exit 0
fi

echo ""
echo "========================================"
echo "开始测试"
echo "========================================"

$SRUN_CMD $PYTEST_CMD

EXIT_CODE=$?

echo ""
echo "========================================"
echo "测试完成"
echo "========================================"
echo "配置文件: $CONFIG_FULL_PATH"
echo "退出码: $EXIT_CODE"
echo "========================================"

if [[ $EXIT_CODE -eq 0 ]]; then
    echo "✓ 测试成功"
else
    echo "✗ 测试失败"
fi
exit $EXIT_CODE

