# Disagg 测试三个关键问题解答

> 详细解答 pytestCommand 差异、性能检查跳过、日志收集方案

---

## 📌 问题 1: pytestCommand 的差异和分流机制

### 1.1 三种 pytestCommand 的差异

在 `submit.py` (248-250 行) 中生成了三个不同的 pytestCommand：

```bash
# 在 submit.py 中生成
export pytestCommandWorker="unset UCX_TLS && ${worker_env_vars} $pytestCommand"
export pytestCommandDisaggServer="${server_env_vars} $pytestCommandNoLLMAPILaunch"
export pytestCommandBenchmark="${env_config["benchmark_env_var"]} $pytestCommandNoLLMAPILaunch"
```

#### 差异对比表

| pytestCommand | 使用场景 | 环境变量前缀 | 是否使用 llmapi-launch | DISAGG_SERVING_TYPE |
|---------------|----------|--------------|----------------------|---------------------|
| **pytestCommandWorker** | GEN/CTX Server | `unset UCX_TLS && worker_env_var` | ✅ 是 (`$pytestCommand`) | `GEN_0`, `GEN_1`, `CTX_0`, `CTX_1` |
| **pytestCommandDisaggServer** | DISAGG Server | `server_env_var` | ❌ 否 (`$pytestCommandNoLLMAPILaunch`) | `DISAGG_SERVER` |
| **pytestCommandBenchmark** | Benchmark Client | `benchmark_env_var` | ❌ 否 (`$pytestCommandNoLLMAPILaunch`) | `BENCHMARK` |

#### 具体展开示例

**基础命令 (pytestCommand):**
```bash
pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_...] -vv --junit-xml=/workspace/results.xml"
```

**pytestCommandNoLLMAPILaunch:**
```bash
# submit.py 通过 get_pytest_command_no_llmapilaunch() 生成
pytestCommandNoLLMAPILaunch="TRTLLM_SERVER_DISABLE_GC=1 pytest perf/test_perf_sanity.py..."
```

**展开后的三个命令:**

1. **pytestCommandWorker** (GEN/CTX 使用):
   ```bash
   unset UCX_TLS && \
   TLLM_LOG_LEVEL=INFO \
   TRTLLM_WORKER_DISABLE_GC=1 \
   trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...]
   ```
   - `unset UCX_TLS`: 清除 UCX 传输层配置，避免冲突
   - `worker_env_var`: 来自 YAML 的 `environment.worker_env_var`
   - **关键**: 使用 `trtllm-llmapi-launch` wrapper 启动

2. **pytestCommandDisaggServer** (DISAGG_SERVER 使用):
   ```bash
   TRTLLM_SERVER_DISABLE_GC=1 \
   pytest perf/test_perf_sanity.py::test_e2e[...]
   ```
   - `server_env_var`: 来自 YAML 的 `environment.server_env_var`
   - **关键**: 直接运行 pytest，不使用 llmapi-launch

3. **pytestCommandBenchmark** (BENCHMARK 使用):
   ```bash
   pytest perf/test_perf_sanity.py::test_e2e[...]
   ```
   - `benchmark_env_var`: 来自 YAML 的 `environment.benchmark_env_var`（通常为空）
   - **关键**: 最简单的 pytest 调用

---

### 1.2 YAML 配置中的环境变量来源

**示例 YAML 配置:**

```yaml
environment:
  worker_env_var: "TLLM_LOG_LEVEL=INFO TRTLLM_WORKER_DISABLE_GC=1"
  server_env_var: "TRTLLM_SERVER_DISABLE_GC=1"
  benchmark_env_var: ""
```

**这些环境变量会被 submit.py 读取并添加到对应的 pytestCommand 中。**

---

### 1.3 test_perf_sanity.py 中的分流逻辑

#### 入口函数: `test_e2e()` (1491-1520 行)

```python
def test_e2e(output_dir, perf_sanity_test_case):
    # 1. 创建配置并解析测试用例名
    config = PerfSanityTestConfig(perf_sanity_test_case, output_dir)
    
    # 2. 解析配置文件 (会读取 DISAGG_SERVING_TYPE 环境变量)
    config.parse_config_file()
    
    # 3. 获取命令
    commands = config.get_commands()
    
    # 4. 运行命令并收集输出
    outputs = config.run_ex(commands)
    
    # 5. 分流：只有 BENCHMARK 节点处理结果
    if config.runtime == "multi_node_disagg_server":
        disagg_config = config.server_configs[0][2]
        if disagg_config.disagg_serving_type != "BENCHMARK":
            print_info(
                f"Disagg serving type is {disagg_config.disagg_serving_type}, "
                f"skipping perf result parsing and upload."
            )
            return  # ← GEN/CTX/DISAGG_SERVER 在这里直接返回
    
    # 6. 只有 BENCHMARK 继续执行以下步骤
    config.get_perf_result(outputs)
    config.check_test_failure()
    config.upload_test_results_to_database()
```

#### 关键分流点 1: 解析配置文件 (936 行)

```python
def _parse_disagg_config_file(self, config_file_path: str, config_file: str):
    """Parse YAML config file for disaggregated server."""
    # 从环境变量获取当前角色
    disagg_serving_type = os.environ.get("DISAGG_SERVING_TYPE", "BENCHMARK")
    
    # 读取 YAML 配置
    with open(config_file_path, "r") as f:
        config = yaml.safe_load(f)
    
    # 根据 disagg_serving_type 决定行为
    # ...
```

#### 关键分流点 2: 获取命令 (1035-1043 行)

```python
def get_commands(self):
    """Get commands based on runtime."""
    if self.runtime == "aggr_server":
        return self._get_aggr_commands(self.perf_sanity_output_dir)
    elif self.runtime == "multi_node_disagg_server":
        return self._get_disagg_commands(self.perf_sanity_output_dir)
        # ↓ 返回 DisaggTestCmds 对象
```

#### 关键分流点 3: 运行命令 (682-783 行)

**DisaggTestCmds.run_cmd() 方法根据 DISAGG_SERVING_TYPE 执行不同逻辑:**

```python
def run_cmd(self, server_idx: int) -> List[str]:
    """Run commands for a server and return outputs."""
    outputs = []
    benchmark_status_file = os.path.join(self.output_dir, f"benchmark_status.{server_idx}.txt")
    port = get_free_port()
    
    ctx_cmd, gen_cmd, disagg_cmd = self.server_cmds[server_idx]
    
    # 分支 1: CTX/GEN Server
    if "CTX" in self.disagg_serving_type or "GEN" in self.disagg_serving_type:
        # 1. 生成 hostname 文件 (让 DISAGG_SERVER 知道地址)
        self._generate_hostname_file(server_idx, port)
        
        # 2. 决定启动哪个 server
        is_ctx = "CTX" in self.disagg_serving_type
        server_cmd = ctx_cmd if is_ctx else gen_cmd
        server_cmd = add_host_port_to_cmd(server_cmd, self.hostname, port)
        
        # 3. 启动 server 进程
        print_info(f"Starting server. disagg_serving_type: {self.disagg_serving_type}")
        server_proc = subprocess.Popen(server_cmd, ...)
        
        # 4. 等待 benchmark_status 文件 (阻塞，直到 BENCHMARK 完成)
        self.wait_for_benchmark_ready(benchmark_status_file)
        
        # 5. 收到信号后终止 server
        server_proc.terminate()
        server_proc.wait()
    
    # 分支 2: DISAGG_SERVER
    elif self.disagg_serving_type == "DISAGG_SERVER":
        # 1. 生成 server_config.yaml (从 hostname 文件读取 GEN/CTX 地址)
        self._generate_disagg_server_config(server_idx, port)
        
        # 2. 启动协调服务器
        print_info(f"Starting disagg server. cmd is {disagg_cmd}")
        disagg_server_proc = subprocess.Popen(disagg_cmd, ...)
        
        # 3. 等待 benchmark_status 文件
        self.wait_for_benchmark_ready(benchmark_status_file)
        
        # 4. 终止 server
        disagg_server_proc.terminate()
    
    # 分支 3: BENCHMARK
    elif self.disagg_serving_type == "BENCHMARK":
        # 1. 读取 server_config.yaml (获取 DISAGG_SERVER 地址)
        disagg_server_hostname, disagg_server_port = \
            self._get_disagg_server_hostname_and_port(server_idx)
        
        # 2. 等待 /health 端点就绪
        wait_for_endpoint_ready(
            f"http://{disagg_server_hostname}:{disagg_server_port}/health",
            timeout=self.timeout,
            check_files=server_files,
        )
        
        # 3. 运行所有 benchmark clients
        for client_idx, client_cmd in enumerate(self.client_cmds[server_idx]):
            client_cmd_with_port = add_host_port_to_cmd(
                client_cmd, disagg_server_hostname, disagg_server_port
            )
            
            # 运行 benchmark 并收集输出
            output = subprocess.check_output(
                client_cmd_with_port,
                env=copy.deepcopy(os.environ),
                stderr=subprocess.STDOUT,
            ).decode()
            
            # 保存到文件
            with open(benchmark_file_path, "w") as benchmark_ctx:
                benchmark_ctx.write(output)
            
            outputs.append(output)  # ← 只有 BENCHMARK 有输出
        
        # 4. 创建 benchmark_status 文件 (通知其他组件退出)
        with open(benchmark_status_file, "w") as status_file:
            status_file.write("completed")
    
    return outputs  # GEN/CTX/DISAGG_SERVER 返回空列表，BENCHMARK 返回性能数据
```

---

### 1.4 完整执行流程对比

| 步骤 | GEN/CTX Server | DISAGG_SERVER | BENCHMARK |
|------|----------------|---------------|-----------|
| 1. 读取 DISAGG_SERVING_TYPE | ✅ `GEN_0` / `CTX_0` | ✅ `DISAGG_SERVER` | ✅ `BENCHMARK` |
| 2. 解析 YAML 配置 | ✅ 读取 worker 配置 | ✅ 读取 server 配置 | ✅ 读取 benchmark 配置 |
| 3. 生成命令 | ✅ ctx_cmd / gen_cmd | ✅ disagg_cmd | ✅ client_cmd |
| 4. 执行操作 | 🔹 生成 hostname 文件<br>🔹 启动 server<br>🔹 等待 benchmark_status | 🔹 等待 hostname 文件<br>🔹 生成 server_config<br>🔹 启动协调服务器<br>🔹 等待 benchmark_status | 🔹 等待 server_config<br>🔹 等待 /health<br>🔹 运行 benchmark<br>🔹 创建 benchmark_status |
| 5. 返回输出 | ❌ 空列表 | ❌ 空列表 | ✅ 性能数据 |
| 6. 解析结果 | ❌ 跳过 (提前 return) | ❌ 跳过 (提前 return) | ✅ 解析并上传 |

---

### 1.5 为什么需要三种不同的 pytestCommand？

**原因总结:**

1. **Worker 需要 llmapi-launch**
   - GEN/CTX 是真正的推理服务器，需要 TensorRT-LLM 的完整初始化
   - `trtllm-llmapi-launch` 会设置 GPU、MPI、环境等

2. **DISAGG_SERVER 是轻量协调器**
   - 只负责请求路由，不需要加载模型
   - 直接运行 `trtllm-serve disaggregated`

3. **BENCHMARK 是纯客户端**
   - 只发送请求和收集指标
   - 不需要任何服务器初始化

---

## 📌 问题 2: 跳过性能检查 (perf check)

### 2.1 当前逻辑分析

**slurm_run.sh (129-154 行):**

```bash
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ]; then
    if [[ "$stageName" == *PyTorch* ]]; then
        basePerfFilename="base_perf_pytorch.csv"
    else
        basePerfFilename="base_perf.csv"
    fi
    basePerfPath="$llmSrcNode/tests/integration/defs/perf/$basePerfFilename"
    
    # 性能检查
    echo "Check Perf Result"
    python3 $llmSrcNode/tests/integration/defs/perf/sanity_perf_check.py \
        $stageName/perf_script_test_results.csv \
        $basePerfPath
    perf_check_exit_code=$?
    
    # 生成性能报告
    echo "Create Perf Report"
    python3 $llmSrcNode/tests/integration/defs/perf/create_perf_comparison_report.py \
        --output_path $stageName/report.pdf \
        --files $stageName/perf_script_test_results.csv \
        $basePerfPath
    perf_report_exit_code=$?
    
    # 合并退出码
    if [ "$perf_check_exit_code" -eq 0 ] && [ "$perf_report_exit_code" -ne 0 ]; then
        perf_check_exit_code=$perf_report_exit_code
    fi
fi
```

**执行条件:**
1. `SLURM_PROCID -eq 0`: 只有第一个进程执行
2. `perfMode = "true"`: 性能模式开启

**问题:**
- L0 性能测试需要这个检查（确保性能不回退）
- 功能测试不需要（只关心功能正确性，不关心性能）

---

### 2.2 解决方案（三种方案）

#### 方案 1: 通过环境变量控制（推荐）⭐

**优点:**
- ✅ 不修改脚本代码
- ✅ 灵活控制
- ✅ 保持向后兼容

**实现:**

**在 run_disagg_test.sh 的 slurm_launch_prefix.sh 中添加:**

```bash
# 在步骤 4.2 中修改 (jenkins_test/scripts/run_disagg_test.sh)
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
trap 'rc=\$? ; echo "Error in file \${BASH_SOURCE[0]} on line \$LINENO: \$BASH_COMMAND (exit \$rc)"; exit \$rc' ERR

echo "Starting Slurm job \$SLURM_JOB_ID on \$SLURM_NODELIST"
export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test_${CONFIG_NAME}"
export perfMode=true

# ✅ 新增：控制性能检查的开关
export SKIP_PERF_CHECK=${SKIP_PERF_CHECK:-false}  # ← 添加这一行

export resourcePathNode=$TRTLLM_DIR
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
export coverageConfigFile=$WORKSPACE/coverage_config.json
export NVIDIA_IMEX_CHANNELS=\${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=\${NVIDIA_VISIBLE_DEVICES:-\$(seq -s, 0 \$((\$(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
EOFPREFIX
```

**在 slurm_run.sh 中修改 (129 行):**

```bash
# 修改前
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ]; then

# 修改后
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ] && [ "$SKIP_PERF_CHECK" != "true" ]; then
```

**使用方式:**

```bash
# L0 性能测试（默认，执行性能检查）
export SKIP_PERF_CHECK=false
bash run_disagg_test.sh

# 功能测试（跳过性能检查）
export SKIP_PERF_CHECK=true
bash run_disagg_test.sh
```

---

#### 方案 2: 通过 stageName 判断（适合区分测试类型）

**优点:**
- ✅ 自动判断
- ✅ 根据测试名称自动决策

**实现:**

**在 slurm_run.sh 中修改 (129 行):**

```bash
# 修改前
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ]; then

# 修改后
# 只有 stageName 包含 "Perf" 或 "Performance" 才执行性能检查
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ] && [[ "$stageName" == *Perf* ]]; then
```

**效果:**

```bash
# 执行性能检查
stageName="disagg_perf_test_deepseek"     → 执行
stageName="L0_Performance_Test"           → 执行

# 跳过性能检查
stageName="disagg_functional_test"        → 跳过
stageName="disagg_sanity_test"            → 跳过
```

---

#### 方案 3: 独立的性能检查脚本（最彻底的分离）

**优点:**
- ✅ 完全解耦
- ✅ 可以在测试后单独运行

**实现:**

**创建独立脚本: `jenkins/scripts/perf/run_perf_check.sh`**

```bash
#!/bin/bash
# 独立的性能检查脚本

set -xEeuo pipefail

STAGE_NAME="$1"
LLM_SRC_NODE="$2"
OUTPUT_DIR="${3:-$(pwd)}"

if [[ "$STAGE_NAME" == *PyTorch* ]]; then
    basePerfFilename="base_perf_pytorch.csv"
else
    basePerfFilename="base_perf.csv"
fi
basePerfPath="$LLM_SRC_NODE/tests/integration/defs/perf/$basePerfFilename"

echo "Check Perf Result"
python3 $LLM_SRC_NODE/tests/integration/defs/perf/sanity_perf_check.py \
    $OUTPUT_DIR/$STAGE_NAME/perf_script_test_results.csv \
    $basePerfPath

echo "Create Perf Report"
python3 $LLM_SRC_NODE/tests/integration/defs/perf/create_perf_comparison_report.py \
    --output_path $OUTPUT_DIR/$STAGE_NAME/report.pdf \
    --files $OUTPUT_DIR/$STAGE_NAME/perf_script_test_results.csv \
    $basePerfPath
```

**在 slurm_run.sh 中移除性能检查部分 (129-154 行)**

**在 Jenkins 中按需调用:**

```groovy
// Perf_Test.groovy

// 运行测试
sh "bash jenkins_test/scripts/run_disagg_test.sh"

// L0 需要性能检查
if (env.JOB_NAME.contains("L0")) {
    sh """
        bash jenkins/scripts/perf/run_perf_check.sh \
            "disagg_perf_test_${CONFIG_NAME}" \
            "${WORKSPACE}/TensorRT-LLM" \
            "${WORKSPACE}"
    """
}
```

---

### 2.3 方案对比

| 方案 | 优点 | 缺点 | 适用场景 |
|------|------|------|----------|
| **方案 1: 环境变量** | 灵活、不改代码、向后兼容 | 需要手动设置环境变量 | ⭐ **推荐，通用** |
| **方案 2: stageName** | 自动判断、简单 | 依赖命名约定 | 测试名称规范的场景 |
| **方案 3: 独立脚本** | 完全解耦、可复用 | 需要在 Jenkins 中额外调用 | 复杂的 CI/CD 流程 |

---

### 2.4 推荐实施步骤（方案 1）

**步骤 1: 修改 run_disagg_test.sh**

```bash
# 在步骤 4.2 的 slurm_launch_prefix.sh 中添加
export SKIP_PERF_CHECK=${SKIP_PERF_CHECK:-false}
```

**步骤 2: 修改 slurm_run.sh**

```bash
# 第 129 行改为
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ] && [ "$SKIP_PERF_CHECK" != "true" ]; then
```

**步骤 3: 在 Jenkins 中设置**

```groovy
// Perf_Test.groovy

stage('Disagg Functional Test') {
    environment {
        SKIP_PERF_CHECK = 'true'  // ← 功能测试跳过
    }
    steps {
        sh "bash jenkins_test/scripts/run_disagg_test.sh"
    }
}

stage('Disagg Performance Test') {
    environment {
        SKIP_PERF_CHECK = 'false'  // ← L0 性能测试执行
    }
    steps {
        sh "bash jenkins_test/scripts/run_disagg_test.sh"
    }
}
```

---

## 📌 问题 3: 日志收集方案

### 3.1 当前日志收集方式

**在 slurm_launch_draft.sh 中:**

```bash
# 安装日志
srun "${srunArgs[@]}" $installScript &> $jobWorkspace/install.log

# GEN server 日志
for i in $(seq 0 $((numGenServers - 1))); do
    srun ... $runScript &> $jobWorkspace/gen_server_$i.log &
done

# CTX server 日志
for i in $(seq 0 $((numCtxServers - 1))); do
    srun ... $runScript &> $jobWorkspace/ctx_server_$i.log &
done

# DISAGG server 日志
srun ... $runScript &> $jobWorkspace/disagg_server.log &

# Benchmark 日志（没有单独的文件，输出到 stdout）
srun ... $runScript  # 没有 &> 重定向
```

**当前问题:**
1. ❌ 所有测试的日志都混在 `$jobWorkspace` 下
2. ❌ 多个测试会互相覆盖
3. ❌ 不方便归档和查找
4. ❌ benchmark 日志没有单独保存

---

### 3.2 理想的日志结构

```
$WORKSPACE/
└── disagg_logs/
    ├── deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX/
    │   ├── slurm_12345.log                  ← Slurm 作业日志
    │   ├── install.log                      ← 安装日志
    │   ├── gen_server_0.log                 ← GEN server 0 日志
    │   ├── gen_server_1.log                 ← GEN server 1 日志（如果有）
    │   ├── ctx_server_0.log                 ← CTX server 0 日志
    │   ├── ctx_server_1.log                 ← CTX server 1 日志（如果有）
    │   ├── disagg_server.log                ← DISAGG server 日志
    │   ├── benchmark.log                    ← Benchmark 客户端日志
    │   ├── results.xml                      ← pytest JUnit 报告
    │   ├── perf_script_test_results.csv     ← 性能结果
    │   └── report.pdf                       ← 性能报告（如果生成）
    │
    └── llama3_8b_tp4_pp2/
        ├── slurm_12346.log
        ├── install.log
        └── ...
```

---

### 3.3 解决方案（三种方案）

#### 方案 1: 修改 jobWorkspace 路径（推荐）⭐

**优点:**
- ✅ 改动最小
- ✅ 保持现有结构
- ✅ 自动按 case 分类

**实现:**

**修改 run_disagg_test.sh 的步骤 4.2:**

```bash
# 当前
export jobWorkspace=$WORKSPACE/disagg_workspace

# 修改为
export jobWorkspace=$WORKSPACE/disagg_logs/${CONFIG_NAME}
```

**完整示例:**

```bash
# 在 slurm_launch_prefix.sh 中（run_disagg_test.sh 步骤 4.2）
SCRIPT_PREFIX_FILE="$WORKSPACE/slurm_launch_prefix.sh"
cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX
#!/bin/bash
#SBATCH --output=$WORKSPACE/disagg_logs/${CONFIG_NAME}/slurm_%j.log  # ← 修改
#SBATCH --nodes=$TOTAL_NODES
#SBATCH --ntasks=$TOTAL_GPUS
#SBATCH --ntasks-per-node=$GPUS_PER_NODE
#SBATCH --gpus-per-node=$GPUS_PER_NODE
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT
#SBATCH --job-name=disagg_${CONFIG_NAME}  # ← 修改
#SBATCH --time=04:00:00

set -xEeuo pipefail
trap 'rc=\$? ; echo "Error in file \${BASH_SOURCE[0]} on line \$LINENO: \$BASH_COMMAND (exit \$rc)"; exit \$rc' ERR

echo "Starting Slurm job \$SLURM_JOB_ID on \$SLURM_NODELIST"

# ✅ 修改：按 case 名称创建日志目录
export jobWorkspace=$WORKSPACE/disagg_logs/${CONFIG_NAME}  # ← 关键修改
mkdir -p \$jobWorkspace  # ← 确保目录存在

export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test_${CONFIG_NAME}"
export perfMode=true
export resourcePathNode=$TRTLLM_DIR
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=\$jobWorkspace/results.xml"  # ← 修改输出路径
export coverageConfigFile=\$jobWorkspace/coverage_config.json  # ← 修改
export NVIDIA_IMEX_CHANNELS=\${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=\${NVIDIA_VISIBLE_DEVICES:-\$(seq -s, 0 \$((\$(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
EOFPREFIX
```

**效果:**

```
运行: run_disagg_test.sh deepseek-r1-fp4_...
日志位置: /workspace/disagg_logs/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX/

运行: run_disagg_test.sh llama3_8b_tp4_pp2
日志位置: /workspace/disagg_logs/llama3_8b_tp4_pp2/
```

---

#### 方案 2: 修改 slurm_launch_draft.sh 重定向（完整控制）

**优点:**
- ✅ 完整控制所有日志
- ✅ 包括 benchmark 日志

**实现:**

**修改 slurm_launch_draft.sh:**

```bash
# 在文件开头添加
LOG_DIR="${jobWorkspace}/logs"
mkdir -p "$LOG_DIR"

# 修改各个日志重定向
srun "${srunArgs[@]}" $installScript &> "$LOG_DIR/install.log"

for i in $(seq 0 $((numGenServers - 1))); do
    srun ... $runScript &> "$LOG_DIR/gen_server_$i.log" &
done

for i in $(seq 0 $((numCtxServers - 1))); do
    srun ... $runScript &> "$LOG_DIR/ctx_server_$i.log" &
done

srun ... $runScript &> "$LOG_DIR/disagg_server.log" &

# ✅ 新增：benchmark 日志也保存
srun ... $runScript &> "$LOG_DIR/benchmark.log"
```

**注意:** 这种方式需要修改 slurm_launch_draft.sh，但 submit.py 会覆盖这个文件的内容，需要在 submit.py 中生成时就包含这些修改。

---

#### 方案 3: 后处理脚本（事后收集）

**优点:**
- ✅ 不修改现有流程
- ✅ 灵活归档

**实现:**

**创建收集脚本: `jenkins_test/scripts/collect_disagg_logs.sh`**

```bash
#!/bin/bash
# 收集和归档 disagg 测试日志

set -xEeuo pipefail

WORKSPACE="$1"
CONFIG_NAME="$2"
JOB_WORKSPACE="${3:-$WORKSPACE/disagg_workspace}"

# 目标目录
TARGET_DIR="$WORKSPACE/disagg_logs/$CONFIG_NAME"
mkdir -p "$TARGET_DIR"

echo "Collecting logs for $CONFIG_NAME..."

# 复制所有日志文件
if [ -d "$JOB_WORKSPACE" ]; then
    cp -v "$JOB_WORKSPACE"/*.log "$TARGET_DIR/" 2>/dev/null || true
    cp -v "$JOB_WORKSPACE"/*.xml "$TARGET_DIR/" 2>/dev/null || true
    cp -v "$JOB_WORKSPACE"/*.csv "$TARGET_DIR/" 2>/dev/null || true
    cp -v "$JOB_WORKSPACE"/*.pdf "$TARGET_DIR/" 2>/dev/null || true
fi

# 复制 Slurm 作业日志（如果有）
if [ -n "${SLURM_JOB_ID:-}" ]; then
    cp -v "$WORKSPACE/slurm_${SLURM_JOB_ID}.log" "$TARGET_DIR/" 2>/dev/null || true
fi

# 创建归档
tar -czf "$TARGET_DIR.tar.gz" -C "$WORKSPACE/disagg_logs" "$CONFIG_NAME"

echo "Logs collected and archived to: $TARGET_DIR.tar.gz"
ls -lh "$TARGET_DIR"
```

**在 run_disagg_test.sh 末尾添加:**

```bash
# 步骤 7: 收集日志
echo ""
echo "[步骤 7] 收集日志..."
bash "$TRTLLM_DIR/jenkins_test/scripts/collect_disagg_logs.sh" \
    "$WORKSPACE" \
    "$CONFIG_NAME" \
    "$WORKSPACE/disagg_workspace"
```

---

### 3.4 方案对比

| 方案 | 优点 | 缺点 | 改动范围 |
|------|------|------|----------|
| **方案 1: 修改 jobWorkspace** | 简单、改动小、自动分类 | 需要确保目录提前创建 | ⭐ 只修改 run_disagg_test.sh |
| **方案 2: 修改重定向** | 完整控制、包括 benchmark | 需要修改生成逻辑 | submit.py 和 slurm_launch_draft.sh |
| **方案 3: 后处理脚本** | 不修改现有流程、灵活 | 事后处理、可能遗漏日志 | 新增脚本 + 调用点 |

---

### 3.5 推荐实施步骤（方案 1 + 增强）

**步骤 1: 修改 run_disagg_test.sh (步骤 4.2)**

```bash
# 修改 jobWorkspace 路径
export jobWorkspace=$WORKSPACE/disagg_logs/${CONFIG_NAME}

# 修改 pytest 输出路径
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=\$jobWorkspace/results.xml"

# 修改 coverage 配置路径
export coverageConfigFile=\$jobWorkspace/coverage_config.json
```

**步骤 2: 修改 SBATCH 输出路径**

```bash
#SBATCH --output=$WORKSPACE/disagg_logs/${CONFIG_NAME}/slurm_%j.log
```

**步骤 3: 在 slurm_launch_draft.sh 开头添加（可选）**

如果要修改 slurm_launch_draft.sh，需要在 submit.py 生成时注入：

**在 submit.py 的模板中添加 (可选，需要修改 submit.py):**

```python
# 在生成 launch.sh 时，在 draft_launch_content 前面插入
benchmark_log_redirect = f"&> $jobWorkspace/benchmark.log"
```

**步骤 4: 添加日志收集摘要（可选）**

**在 run_disagg_test.sh 末尾添加:**

```bash
# 步骤 7: 日志收集摘要
echo ""
echo "[步骤 7] 日志收集摘要"
echo "所有日志已保存到: $WORKSPACE/disagg_logs/${CONFIG_NAME}/"
echo "文件列表:"
ls -lh "$WORKSPACE/disagg_logs/${CONFIG_NAME}/" || true
```

---

### 3.6 日志文件说明

| 文件名 | 来源 | 内容 |
|--------|------|------|
| `slurm_<job_id>.log` | SBATCH stdout | 整个作业的标准输出 |
| `install.log` | slurm_install.sh | 安装 TensorRT-LLM 的日志 |
| `gen_server_<i>.log` | slurm_run.sh (GEN) | GEN server 启动和运行日志 |
| `ctx_server_<i>.log` | slurm_run.sh (CTX) | CTX server 启动和运行日志 |
| `disagg_server.log` | slurm_run.sh (DISAGG_SERVER) | 协调服务器日志 |
| `benchmark.log` | slurm_run.sh (BENCHMARK) | Benchmark 客户端日志（需要添加重定向） |
| `results.xml` | pytest | JUnit 测试报告 |
| `perf_script_test_results.csv` | test_perf_sanity.py | 性能指标数据 |
| `report.pdf` | create_perf_comparison_report.py | 性能对比报告（如果生成） |

---

## 🎯 总结

### 问题 1: pytestCommand 差异

**核心差异:**
- `pytestCommandWorker`: 使用 `trtllm-llmapi-launch`，包含 worker_env_var
- `pytestCommandDisaggServer`: 不使用 llmapi-launch，包含 server_env_var
- `pytestCommandBenchmark`: 最简单的 pytest 调用，包含 benchmark_env_var

**分流机制:**
- 通过 `DISAGG_SERVING_TYPE` 环境变量区分角色
- 在 `test_perf_sanity.py` 的 `DisaggTestCmds.run_cmd()` 中分支执行
- 只有 BENCHMARK 返回性能数据并解析结果

---

### 问题 2: 跳过性能检查

**推荐方案:** 环境变量控制（方案 1）

**实施:**
```bash
# run_disagg_test.sh
export SKIP_PERF_CHECK=${SKIP_PERF_CHECK:-false}

# slurm_run.sh (129 行)
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ] && [ "$SKIP_PERF_CHECK" != "true" ]; then
```

**使用:**
- L0 性能测试: `export SKIP_PERF_CHECK=false`
- 功能测试: `export SKIP_PERF_CHECK=true`

---

### 问题 3: 日志收集

**推荐方案:** 修改 jobWorkspace 路径（方案 1）

**实施:**
```bash
# run_disagg_test.sh (步骤 4.2)
export jobWorkspace=$WORKSPACE/disagg_logs/${CONFIG_NAME}

# SBATCH 输出
#SBATCH --output=$WORKSPACE/disagg_logs/${CONFIG_NAME}/slurm_%j.log
```

**效果:**
- 每个 case 独立目录
- 自动分类和归档
- 不会互相覆盖

---

**三个问题都有清晰的解决方案，可以按需实施！** 🚀
