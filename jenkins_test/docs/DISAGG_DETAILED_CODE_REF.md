# Disagg 调用链条详细代码参考

> 本文档提供完整的代码路径、行号和关键代码片段，方便追踪和验证调用链条

---

## 📋 完整调用链条（带代码位置）

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Jenkins Pipeline                                               │
│    文件: jenkins_test/Perf_Test.groovy                           │
│    行号: ~300-350                                                 │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 2. run_perf_tests.sh                                              │
│    文件: jenkins_test/scripts/run_perf_tests.sh                  │
│    行号: 324-371 (run_disagg_tests 函数)                         │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 3. run_disagg_test.sh                                             │
│    文件: jenkins_test/scripts/run_disagg_test.sh                 │
│    行号: 全文 (关键行在下方详述)                                 │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 4. submit.py (环境变量生成器)                                     │
│    文件: jenkins/scripts/perf/disaggregated/submit.py            │
│    行号: 292行完整文件 (关键函数在下方详述)                       │
│    功能: 生成 slurm_launch_draft.sh 需要的环境变量和 launch.sh   │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 5. slurm_launch_draft.sh (真正的启动器)                           │
│    文件: jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh│
│    行号: 77行完整文件                                             │
│    功能: 使用 srun 启动所有 CTX/GEN servers 和 benchmark          │
└────────────────────────┬─────────────────────────────────────────┘
                         │
                         ▼
┌──────────────────────────────────────────────────────────────────┐
│ 6. test_perf_sanity.py                                            │
│    文件: tests/integration/defs/perf/test_perf_sanity.py         │
│    行号: 1490-1521 (test_e2e 函数)                               │
└──────────────────────────────────────────────────────────────────┘
```

---

## ⚠️ 重要更新说明

在之前的分析中，我错误地描述了 `jenkins/scripts/perf/disaggregated/submit.py` 的功能。该文件是一个**环境变量生成器**（292行），而不是完整的 SLURM job 提交器（594行）。以下是修正后的分析。

---

## 🔍 详细代码追踪

### 1. Jenkins Pipeline 入口

**文件：** `jenkins_test/Perf_Test.groovy`

**关键代码段（第274行附近）：**

```groovy
stage('Run Disagg Tests') {
    steps {
        script {
            sh """
                cd ${WORKSPACE}
                ${SCRIPTS_DIR}/run_perf_tests.sh \\
                    --testlist ${TESTLIST_PATH} \\
                    --trtllm-dir ${TRTLLM_DIR} \\
                    --mode disagg
            """
        }
    }
}
```

**验证点：**
- [ ] 检查 `SCRIPTS_DIR` 变量是否正确指向 `jenkins_test/scripts`
- [ ] 检查 `run_perf_tests.sh` 文件是否存在
- [ ] 检查传递的参数是否完整

---

### 2. run_perf_tests.sh - 测试分发器

**文件：** `jenkins_test/scripts/run_perf_tests.sh`

#### 2.1 Disagg 测试分发函数

**代码位置：** 第 324-371 行

```bash
# 函数：执行 Disagg 测试
run_disagg_tests() {
    if [[ $DISAGG_COUNT -eq 0 ]]; then
        echo "⊘ 没有 Disagg 测试"
        return 0
    fi
    
    echo ""
    echo "========================================"
    echo "运行 Disagg 测试 ($DISAGG_COUNT 个)"
    echo "========================================"
    
    for i in $(seq 0 $((DISAGG_COUNT - 1))); do
        local test_info=$(echo "$DISAGG_TESTS" | python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin)[$i]))")
        local config_file=$(echo "$test_info" | python3 -c "import sys, json; print(json.load(sys.stdin)['config_file'])")
        
        echo ""
        echo "----------------------------------------"
        echo "[Disagg $((i + 1))/$DISAGG_COUNT] $config_file"
        echo "----------------------------------------"
        
        local script_args=()
        script_args+=("--trtllm-dir" "$TRTLLM_DIR")
        script_args+=("--config-file" "$config_file")
        script_args+=("--workspace" "${WORKSPACE:-$(pwd)}/disagg_workspace")
        
        # 注意：disagg 模式不支持 pytest -k 过滤
        
        if [[ "$DRY_RUN" == "true" ]]; then
            script_args+=("--dry-run")
        fi
        
        if "$SCRIPT_DIR/run_disagg_test.sh" "${script_args[@]}"; then  # ← 第355行：调用 run_disagg_test.sh
            ((PASSED_TESTS++))
            echo "✓ 测试通过"
        else
            ((FAILED_TESTS++))
            FAILED_LIST+=("Disagg: $config_file")
            echo "✗ 测试失败"
            
            if [[ "$STOP_ON_ERROR" == "true" ]]; then
                echo "遇到错误，停止执行"
                return 1
            fi
        fi
    done
    
    return 0
}
```

**关键调用：** 第 355 行
```bash
"$SCRIPT_DIR/run_disagg_test.sh" "${script_args[@]}"
```

**验证点：**
- [ ] 检查 `DISAGG_TESTS` JSON 格式是否正确
- [ ] 检查 `config_file` 是否是有效的配置文件名
- [ ] 检查 `WORKSPACE` 变量是否设置

---

### 3. run_disagg_test.sh - SLURM 作业提交器

**文件：** `jenkins_test/scripts/run_disagg_test.sh`

#### 3.1 提取配置文件完整路径

**代码位置：** 第 180-204 行

```bash
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
```

**验证点：**
- [ ] 检查配置文件路径是否存在
- [ ] 检查 `CONFIG_NAME` 是否正确解析

#### 3.2 计算硬件节点数

**代码位置：** 第 206-240 行

```bash
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
```

**验证点：**
- [ ] 检查 `calculate_hardware_nodes.py` 是否存在
- [ ] 检查计算结果是否合理（节点数、GPU数）

#### 3.3 生成 sbatch 脚本

**代码位置：** 第 242-310 行

```bash
# ============================================
# 步骤 4: 生成 sbatch 脚本
# ============================================
echo ""
echo "[步骤 4] 生成 sbatch 脚本..."

SBATCH_SCRIPT="$WORKSPACE/sbatch_disagg.sh"
SUBMIT_PY="$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/submit.py"

if [[ ! -f "$SUBMIT_PY" ]]; then
    echo "错误：找不到 submit.py: $SUBMIT_PY"
    exit 1
fi

# 从环境变量获取 cluster 配置（由 Jenkins 设置）
CLUSTER_ACCOUNT="${CLUSTER_ACCOUNT:-coreai_comparch_trtllm}"
CLUSTER_PARTITION="${CLUSTER_PARTITION:-batch}"
MPI_TYPE="${MPI_TYPE:-pmix}"
DOCKER_IMAGE="${DOCKER_IMAGE:-nvcr.io/nvidia/tensorrt-llm:latest}"

cat > "$SBATCH_SCRIPT" << EOFSBATCH
#!/bin/bash
#SBATCH --nodes=$TOTAL_NODES
#SBATCH --ntasks=$TOTAL_GPUS
#SBATCH --ntasks-per-node=$GPUS_PER_NODE
#SBATCH --gpus-per-node=$GPUS_PER_NODE
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT
#SBATCH --output=$WORKSPACE/slurm_%j.log
#SBATCH --error=$WORKSPACE/slurm_%j.log
#SBATCH --job-name=disagg_perf_test

set -xEeuo pipefail

echo "=========================================="
echo "Slurm Job ID: \$SLURM_JOB_ID"
echo "Slurm Nodelist: \$SLURM_NODELIST"
echo "Total Nodes: $TOTAL_NODES"
echo "Total GPUs: $TOTAL_GPUS"
echo "GPUs per Node: $GPUS_PER_NODE"
echo "Partition: $CLUSTER_PARTITION"
echo "Account: $CLUSTER_ACCOUNT"
echo "=========================================="

cd $TRTLLM_DIR

# 调用 submit.py 执行 disagg 测试
# 注意：submit.py 会处理所有的 disagg 逻辑
python3 $SUBMIT_PY \\
    --run-ci \\
    --llm-src $TRTLLM_DIR \\
    --config $CONFIG_FULL_PATH

exit_code=\$?

echo "=========================================="
echo "Test completed with exit code: \$exit_code"
echo "=========================================="

exit \$exit_code
EOFSBATCH

chmod +x "$SBATCH_SCRIPT"
```

**关键调用：** 第 289-292 行
```bash
python3 $SUBMIT_PY \
    --run-ci \
    --llm-src $TRTLLM_DIR \
    --config $CONFIG_FULL_PATH
```

**验证点：**
- [ ] 检查 `SUBMIT_PY` 路径是否正确
- [ ] 检查 SLURM 参数是否合理
- [ ] 检查传递给 submit.py 的参数

#### 3.4 提交到 SLURM

**代码位置：** 第 314-377 行

```bash
# ============================================
# 步骤 5: 提交作业
# ============================================
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[试运行模式] 跳过实际提交"
    echo "要手动提交，请运行:"
    echo "  sbatch $SBATCH_SCRIPT"
    exit 0
fi

echo ""
echo "[步骤 5] 提交 Slurm 作业..."

SUBMIT_OUTPUT=$(sbatch "$SBATCH_SCRIPT")
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
```

**验证点：**
- [ ] 检查 `sbatch` 命令是否成功
- [ ] 检查能否正确获取 JOB_ID
- [ ] 检查 `sacct` 命令是否可用

---

### 4. submit.py - 环境变量生成器 ⚠️ 重要纠正

**文件：** `jenkins/scripts/perf/disaggregated/submit.py` (292行)

**⚠️ 注意：** 这个文件**不是** `examples/disaggregated/slurm/benchmark/submit.py` (594行)！
- Jenkins 使用的是 292 行的简化版本
- 它只负责生成环境变量和 launch.sh 脚本
- **不负责启动 servers**（那是 slurm_launch_draft.sh 的工作）

#### 4.1 主函数

**代码位置：** 第 164-292 行（`main` 函数）

```python
def main():
    parser = argparse.ArgumentParser(
        description="Generate SLURM launch script for both CI and local modes"
    )
    parser.add_argument("--run-ci", action="store_true", default=False)
    parser.add_argument("--draft-launch-sh", required=True)  # ← slurm_launch_draft.sh 模板
    parser.add_argument("--launch-sh", required=True)        # ← 输出的 launch.sh
    parser.add_argument("--run-sh", required=True)           # ← slurm_run.sh
    parser.add_argument("--install-sh", required=True)       # ← slurm_install.sh
    parser.add_argument("--llm-src", default="")
    parser.add_argument("--test-list", default="")
    parser.add_argument("--script-prefix", default="")
    parser.add_argument("--srun-args", default="")

    args = parser.parse_args()

    # 1. 从 test_list 提取配置文件路径
    config_yaml = get_config_yaml(args.test_list, args.llm_src)  # ← 第199行
    
    # 2. 加载配置
    with open(config_yaml, "r") as f:
        config = yaml.safe_load(f)  # ← 第202行
    
    # 3. 提取各种配置
    env_config = get_env_config(config)           # ← 第207行
    benchmark_config = get_benchmark_config(config)  # ← 第210行
    hardware_config = get_hardware_config(config, benchmark_mode)  # ← 第214行
    
    # 4. 生成 pytest 命令环境变量
    script_prefix_lines.extend([
        pytest_command_no_llmapi_launch,
        f'export pytestCommandWorker="unset UCX_TLS && {worker_env_vars} $pytestCommand"',  # ← 第248行
        f'export pytestCommandDisaggServer="{server_env_vars} $pytestCommandNoLLMAPILaunch"',  # ← 第249行
        f'export pytestCommandBenchmark="{env_config["benchmark_env_var"]} $pytestCommandNoLLMAPILaunch"',  # ← 第250行
        f"export runScript={args.run_sh}",
        f"export installScript={install_script}",
        f"export numCtxServers={hardware_config['num_ctx_servers']}",  # ← 第253行
        f"export numGenServers={hardware_config['num_gen_servers']}",
        f"export gpusPerNode={hardware_config['gpus_per_node']}",
        # ... 更多环境变量 ...
    ])  # ← 第245-262行：关键的环境变量设置
    
    # 5. 生成 srun 参数
    srun_args_lines.extend([
        "--container-env=DISAGG_SERVING_TYPE",  # ← 第271行：关键！传递环境变量
        "--container-env=pytestCommand",
    ])
    
    # 6. 合并生成最终的 launch.sh
    with open(args.launch_sh, "w") as f:
        f.write(f"{script_prefix}\n{srun_args}\n{draft_launch_content}")  # ← 第285行
```

**关键输出：**
- `launch.sh` = `环境变量定义` + `srun参数` + `slurm_launch_draft.sh 内容`

#### 4.2 关键函数 - get_hardware_config

**代码位置：** 第 8-54 行

```python
def get_hardware_config(config, benchmark_mode):
    hardware = config.get("hardware", {})
    worker_config = config.get("worker_config", {})

    num_ctx_servers = 0 if "gen_only" in benchmark_mode else hardware.get("num_ctx_servers")
    num_gen_servers = hardware.get("num_gen_servers")
    gpus_per_node = hardware.get("gpus_per_node")

    # 从 worker_config 计算每个 server 需要的 GPU 数
    ctx_tp = ctx_config.get("tensor_parallel_size", 1)
    ctx_pp = ctx_config.get("pipeline_parallel_size", 1)
    ctx_cp = ctx_config.get("context_parallel_size", 1)
    gpus_per_ctx_server = ctx_tp * ctx_pp * ctx_cp

    gen_tp = gen_config.get("tensor_parallel_size", 1)
    gen_pp = gen_config.get("pipeline_parallel_size", 1)
    gen_cp = gen_config.get("context_parallel_size", 1)
    gpus_per_gen_server = gen_tp * gen_pp * gen_cp

    # 计算节点数
    nodes_per_ctx_server = (gpus_per_ctx_server + gpus_per_node - 1) // gpus_per_node
    nodes_per_gen_server = (gpus_per_gen_server + gpus_per_node - 1) // gpus_per_node

    total_nodes = num_ctx_servers * nodes_per_ctx_server + num_gen_servers * nodes_per_gen_server
    total_gpus = total_nodes * gpus_per_node

    return {
        "num_ctx_servers": num_ctx_servers,
        "num_gen_servers": num_gen_servers,
        "gpus_per_node": gpus_per_node,
        # ... 其他配置 ...
        "total_nodes": total_nodes,
        "total_gpus": total_gpus,
    }
```

**验证点：**
- [ ] 检查配置 YAML 中的 `hardware` 和 `worker_config` 部分
- [ ] 检查节点数计算是否正确（向上取整）
- [ ] 检查 gen_only 模式是否正确处理

**验证点：**
- [ ] 检查 `get_config_yaml()` 是否正确解析 test_list
- [ ] 检查生成的环境变量是否完整
- [ ] 检查 `--container-env=DISAGG_SERVING_TYPE` 是否传递给 srun

---

### 5. slurm_launch_draft.sh - Server 启动器（真正的工作者）

**文件：** `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`

**完整文件：** 77 行

**⚠️ 重要说明：** 这个脚本才是真正启动所有 servers 的地方！它使用 `submit.py` 生成的环境变量。

#### 5.1 安装阶段

**代码位置：** 第 8-17 行

```bash
mkdir -p $jobWorkspace
chmod +x $runScript
chmod +x $installScript

# Run installation on all nodes
echo "Running installation on all nodes..."
if ! srun "${srunArgs[@]}" $installScript &> $jobWorkspace/install.log; then
    cleanup_on_failure "Failed to run installation. Check $jobWorkspace/install.log"
fi
echo "Installation completed on all nodes"
```

**验证点：**
- [ ] 检查 `$runScript` 和 `$installScript` 变量是否设置
- [ ] 检查 `$jobWorkspace` 目录是否可写
- [ ] 检查 `srunArgs` 数组是否正确

#### 5.2 启动 GEN Servers

**代码位置：** 第 19-31 行

```bash
# Start gen servers
echo "Starting gen servers..."
for i in $(seq 0 $((numGenServers - 1))); do
    gen_world_size=$((nodesPerGenServer * gpusPerNode))
    export DISAGG_SERVING_TYPE="GEN_$i"  # ← 关键：设置环境变量
    export pytestCommand="$pytestCommandWorker"
    srun "${srunArgs[@]}" --kill-on-bad-exit=1 \
        -N $nodesPerGenServer \
        --ntasks=$gen_world_size \
        --ntasks-per-node=$gpusPerNode \
        $runScript &> $jobWorkspace/gen_server_$i.log &  # ← 后台运行，日志重定向
    echo "Started gen server $i"
done
```

**关键环境变量：**
- `DISAGG_SERVING_TYPE="GEN_$i"` - 告诉 pytest 这是 GEN server
- `pytestCommand="$pytestCommandWorker"` - pytest 命令

**验证点：**
- [ ] 检查 `numGenServers` 变量是否正确
- [ ] 检查 `$runScript` 是否调用 pytest
- [ ] 检查日志文件是否创建

#### 5.3 启动 CTX Servers

**代码位置：** 第 33-49 行

```bash
# Start ctx servers (skip if gen_only mode)
if [ "${TRTLLM_DISAGG_BENCHMARK_GEN_ONLY:-0}" != "1" ]; then
    echo "Starting ctx servers..."
    for i in $(seq 0 $((numCtxServers - 1))); do
        ctx_world_size=$((nodesPerCtxServer * gpusPerNode))
        export DISAGG_SERVING_TYPE="CTX_$i"  # ← 关键：设置环境变量
        export pytestCommand="$pytestCommandWorker"
        srun "${srunArgs[@]}" --kill-on-bad-exit=1 \
            -N $nodesPerCtxServer \
            --ntasks=$ctx_world_size \
            --ntasks-per-node=$gpusPerNode \
            $runScript &> $jobWorkspace/ctx_server_$i.log &  # ← 后台运行
        echo "Started ctx server $i"
    done
else
    echo "Skipping ctx servers (gen_only mode)"
fi
```

**验证点：**
- [ ] 检查 `numCtxServers` 变量
- [ ] 检查 gen_only 模式判断是否正确

#### 5.4 启动 Disagg Coordinator

**代码位置：** 第 52-61 行

```bash
# Start disagg server
echo "Starting disagg server..."
export DISAGG_SERVING_TYPE="DISAGG_SERVER"  # ← 关键
export pytestCommand="$pytestCommandDisaggServer"
srun "${srunArgs[@]}" --kill-on-bad-exit=1 --overlap \
    -N 1 \
    --ntasks=1 \
    --ntasks-per-node=1 \
    $runScript &> $jobWorkspace/disagg_server.log &  # ← 后台运行
echo "Started disagg server"
```

**验证点：**
- [ ] 检查 coordinator 是否只在单节点运行
- [ ] 检查 `pytestCommandDisaggServer` 变量

#### 5.5 运行 Benchmark

**代码位置：** 第 63-73 行

```bash
# Start benchmark
echo "Starting benchmark..."
export DISAGG_SERVING_TYPE="BENCHMARK"  # ← 关键：只有这个节点会上传数据
export pytestCommand="$pytestCommandBenchmark"
if ! srun "${srunArgs[@]}" --kill-on-bad-exit=1 --overlap \
    -N 1 \
    --ntasks=1 \
    --ntasks-per-node=1 \
    $runScript; then  # ← 前台运行，等待完成
    cleanup_on_failure "Benchmark failed. Check logs in ${jobWorkspace} for details"
fi

echo "Disagg server and benchmark completed successfully"
echo "Total runtime: $SECONDS seconds"
```

**验证点：**
- [ ] 检查 benchmark 是否前台运行（没有 `&`）
- [ ] 检查失败时是否调用 `cleanup_on_failure`

---

### 6. test_perf_sanity.py - 测试执行器

**文件：** `tests/integration/defs/perf/test_perf_sanity.py`

#### 6.1 test_e2e 函数

**代码位置：** 第 1490-1521 行

```python
@pytest.mark.parametrize("perf_sanity_test_case", PERF_SANITY_TEST_CASES)
def test_e2e(output_dir, perf_sanity_test_case):
    # Create config and parse test case name
    config = PerfSanityTestConfig(perf_sanity_test_case, output_dir)

    # Parse config file to get server_configs and server_client_configs
    config.parse_config_file()

    # Get commands
    commands = config.get_commands()

    # Run commands and collect outputs
    outputs = config.run_ex(commands)

    # For disagg mode, only BENCHMARK node parses results and uploads
    if config.runtime == "multi_node_disagg_server":
        disagg_config = config.server_configs[0][2]
        if disagg_config.disagg_serving_type != "BENCHMARK":  # ← 第1507行：关键判断
            print_info(
                f"Disagg serving type is {disagg_config.disagg_serving_type}, skipping perf result parsing and upload."
            )
            return  # ← GEN/CTX/DISAGG_SERVER 节点直接退出

    # Parse performance results
    config.get_perf_result(outputs)

    # Check for test failures
    config.check_test_failure()

    # Upload results to database
    config.upload_test_result()  # ← 第1519行：只有 BENCHMARK 节点执行
```

**验证点：**
- [ ] 检查 `config.runtime` 是否正确识别 disagg 模式
- [ ] 检查 `disagg_config.disagg_serving_type` 是否从环境变量读取
- [ ] 检查非 BENCHMARK 节点是否正确跳过上传

#### 6.2 DisaggConfig 类 - 读取环境变量

**代码位置：** 第 331-376 行（DisaggConfig 类定义）

```python
class DisaggConfig:
    """Disagg configuration."""

    def __init__(
        self,
        name: str,
        hardware: dict,
        benchmark_mode: str = "e2e",
        # ... 其他参数 ...
    ):
        self.name = name
        self.num_ctx_servers = hardware.get("num_ctx_servers", 0)
        self.num_gen_servers = hardware.get("num_gen_servers", 1)
        # ... 其他初始化 ...
        
        # ⚠️ 关键：从环境变量读取 serving type
        self.disagg_serving_type = os.getenv("DISAGG_SERVING_TYPE", "BENCHMARK")  # ← 第353行左右
```

**验证点：**
- [ ] 确认 `DISAGG_SERVING_TYPE` 环境变量是否正确传递
- [ ] 确认默认值是否合理

#### 6.3 upload_test_result 函数

**代码位置：** 第 1380-1413 行

```python
def upload_test_result(self):
    """Upload test result to database."""
    # Get job info
    job_info = get_job_info()

    # Prepare new data
    new_data_dict = {}
    for test_case_index in range(len(self.server_configs)):
        # ... 准备数据 ...
        new_data_dict[test_case_index] = {
            "model": self.model_name,
            "precision": self.precision,
            # ... 其他字段 ...
        }

    # ... 准备 baseline 数据 ...

    if self.upload_to_db:
        # Upload the new perf data and baseline data to database
        post_new_perf_data(new_baseline_data_dict, new_data_dict)  # ← 第1407行：上传到 OpenSearch

    check_perf_regression(
        new_data_dict,
        fail_on_regression=is_scenario_mode,
        output_dir=self.perf_sanity_output_dir,
    )
```

**验证点：**
- [ ] 检查 `post_new_perf_data` 函数是否正确调用
- [ ] 检查 `self.upload_to_db` 标志是否正确设置
- [ ] 检查数据格式是否符合 OpenSearch 要求

---

## 🔍 关键验证点总结

### 环境变量传递链

```
slurm_launch_draft.sh (设置)
  ↓ export DISAGG_SERVING_TYPE="GEN_0"
  ↓ export pytestCommand="..."
  ↓
srun $runScript (调用 pytest)
  ↓
test_perf_sanity.py (读取)
  ↓ os.getenv("DISAGG_SERVING_TYPE")
  ↓
判断是否上传
```

**关键文件和行号：**
1. **设置环境变量：** `slurm_launch_draft.sh` 第23、38、54、65行
2. **读取环境变量：** `test_perf_sanity.py` 第353行（DisaggConfig.__init__）
3. **判断逻辑：** `test_perf_sanity.py` 第1507行（test_e2e函数）

---

### 日志文件路径

```
slurm_launch_draft.sh 中的日志重定向：

第29行: &> $jobWorkspace/gen_server_$i.log
第44行: &> $jobWorkspace/ctx_server_$i.log
第60行: &> $jobWorkspace/disagg_server.log
第70行: (benchmark 输出到 stdout，被 srun 捕获)
```

**验证点：**
- [ ] 检查 `$jobWorkspace` 变量是否正确设置
- [ ] 检查日志目录是否存在且可写
- [ ] 检查 benchmark 日志是否被正确捕获

---

### 数据上传路径

```
test_perf_sanity.py::test_e2e (第1490行)
  ↓
config.upload_test_result() (第1519行)
  ↓
post_new_perf_data() (第1407行)
  ↓
OpenSearch (在 open_search_db_utils.py 中实现)
```

**待实现：Perf DB 上传**
- 需要在第1407行之后添加
- 建议位置：`upload_test_result()` 函数中，`post_new_perf_data()` 调用之后

---

## 🐛 潜在 Bug 检查清单

### 1. 环境变量丢失

**检查点：** `slurm_launch_draft.sh` 第23-70行

```bash
# 是否所有 export 都在 srun 之前？
export DISAGG_SERVING_TYPE="GEN_0"
export pytestCommand="$pytestCommandWorker"
srun ... $runScript  # ← srun 会继承环境变量吗？
```

**验证方法：**
```bash
# 在 pytest 中打印环境变量
import os
print(f"DISAGG_SERVING_TYPE = {os.getenv('DISAGG_SERVING_TYPE')}")
```

### 2. 日志文件权限

**检查点：** `slurm_launch_draft.sh` 第8行

```bash
mkdir -p $jobWorkspace  # 是否需要检查权限？
```

**验证方法：**
```bash
# 检查目录是否可写
if [[ ! -w "$jobWorkspace" ]]; then
    echo "Error: $jobWorkspace is not writable"
    exit 1
fi
```

### 3. 后台进程清理

**检查点：** `slurm_launch_draft.sh` 第29、44、60行

所有 server 都是后台运行（`&`），如果 benchmark 失败，这些后台进程是否会被清理？

**验证方法：**
检查 SLURM 的 `--kill-on-bad-exit` 参数是否会杀掉所有子进程。

### 4. config.runtime 判断

**检查点：** `test_perf_sanity.py` 第1505行

```python
if config.runtime == "multi_node_disagg_server":
```

**验证方法：**
```bash
# 搜索 runtime 在哪里设置
grep -n "self.runtime.*disagg" tests/integration/defs/perf/test_perf_sanity.py
```

### 5. disagg_config 索引

**检查点：** `test_perf_sanity.py` 第1506行

```python
disagg_config = config.server_configs[0][2]  # ← 为什么是 [0][2]？
```

**需要验证：**
- `server_configs` 的结构是什么？
- `[0]` 代表什么？
- `[2]` 代表什么？

---

## ⚠️ 关键纠正：两个不同的 submit.py

| submit.py | 行数 | 功能 | 使用场景 |
|-----------|------|------|---------|
| **`jenkins/scripts/perf/disaggregated/submit.py`** | **292行** | **环境变量生成器** | **Jenkins CI 使用** ✅ |
| `examples/disaggregated/slurm/benchmark/submit.py` | 594行 | 完整的 SLURM job 提交器 | 本地手动测试 |

**我之前的错误：**
- ❌ 我错误地分析了 594 行的 submit.py
- ❌ 描述了很多不存在的 `submit_job()` 函数
- ❌ 描述了 `allocations`、`srun` 命令生成等（这些在 292 行版本中不存在）

**正确的理解：**
- ✅ Jenkins 使用的是 292 行的简化版本
- ✅ 它只负责读取配置、生成环境变量、生成 launch.sh
- ✅ 真正启动 servers 的是 `slurm_launch_draft.sh`

---

## 📚 相关文件索引

### 核心文件

| 文件 | 行数 | 功能 |
|------|------|------|
| `jenkins_test/Perf_Test.groovy` | ~489 | Jenkins Pipeline |
| `jenkins_test/scripts/run_perf_tests.sh` | 409 | 测试分发器 |
| `jenkins_test/scripts/run_disagg_test.sh` | 378 | SLURM 作业提交 |
| `jenkins/scripts/perf/disaggregated/submit.py` | **292** | 环境变量生成器 ⚠️ |
| `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh` | 77 | Server 启动器（真正的工作者）|
| `tests/integration/defs/perf/test_perf_sanity.py` | 1521 | 测试执行器 |

### 辅助文件

| 文件 | 功能 |
|------|------|
| `jenkins_test/scripts/calculate_hardware_nodes.py` | 计算硬件节点数 |
| `jenkins_test/scripts/parse_unified_testlist.py` | 解析 testlist |
| `tests/integration/defs/perf/open_search_db_utils.py` | OpenSearch 上传 |

---

## 🎯 下一步行动

### 建议检查顺序

1. **验证环境变量传递**
   ```bash
   # 在 test_perf_sanity.py 第1492行之后添加
   print(f"DEBUG: DISAGG_SERVING_TYPE = {os.getenv('DISAGG_SERVING_TYPE')}")
   ```

2. **验证日志文件创建**
   ```bash
   # 检查 $jobWorkspace 是否存在
   ls -la $jobWorkspace/*.log
   ```

3. **验证数据上传**
   ```bash
   # 检查 OpenSearch 是否收到数据
   # 查看 post_new_perf_data 的实现
   ```

4. **验证 config.runtime 设置**
   ```python
   # 在 test_perf_sanity.py 第1505行之前添加
   print(f"DEBUG: config.runtime = {config.runtime}")
   ```

---

**所有关键代码位置已列出，请按此文档追踪代码流程并检查是否有bug！**
