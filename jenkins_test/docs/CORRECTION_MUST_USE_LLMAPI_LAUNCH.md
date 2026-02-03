# 重大更正：Disaggregated 模式必须使用 trtllm-llmapi-launch

> **严重错误更正：我之前的分析完全错误！Disaggregated 模式的 CTX/GEN servers 确实需要 trtllm-llmapi-launch！**

---

## 🚨 我的严重错误

### 错误的结论（之前）❌

我之前在多个文档中错误地声称：
- ❌ "test_perf_sanity.py 不使用 trtllm-llmapi-launch"
- ❌ "直接用 subprocess.Popen 启动 trtllm-serve"
- ❌ "不需要 trtllm-llmapi-launch 来管理多进程"

### 实际情况（正确）✅

**Disaggregated 模式的 CTX/GEN servers 必须使用 trtllm-llmapi-launch！**

---

## 🔍 铁证如山

### 证据 1: L0_Test.groovy 确实传递了 trtllm-llmapi-launch

**代码（jenkins/L0_Test.groovy:1051-1064）：**

```groovy
// Generate Pytest command
String pytestUtil = ""
if (nodeCount > 1) {
    pytestUtil = "$llmSrcNode/tensorrt_llm/llmapi/trtllm-llmapi-launch"
}

def pytestCommand = getPytestBaseCommandLine(
    llmSrcNode,
    stageName,
    waivesListPathNode,
    perfMode,
    jobWorkspace,
    "__PLACEHOLDER_TRTLLM_WHL_PATH__",
    "$jobWorkspace/.coveragerc",
    pytestUtil,  // ← 传递 trtllm-llmapi-launch！
    [
      "--test-list=$testListPathNode",
      "--splitting-algorithm least_duration",
      "--splits $splits",
      "--group $splitId"
    ]
).join(" ")
```

**关键：**
- ✅ 当 `nodeCount > 1` 时，pytestUtil 被设置为 trtllm-llmapi-launch 的路径
- ✅ 这个参数被传递给 `getPytestBaseCommandLine`
- ✅ 最终出现在 `export pytestCommand="..."` 中

---

### 证据 2: examples 中明确使用 trtllm-llmapi-launch

**代码（examples/disaggregated/slurm/benchmark/start_worker.sh:55-58）：**

```bash
${nsys_prefix} trtllm-llmapi-launch ${numa_bind_cmd} \
    trtllm-serve ${model_path} \
        --host $(hostname) --port ${port} \
        --config ${config_file}
```

**关键：**
- ✅ **明确使用 `trtllm-llmapi-launch`**
- ✅ 它在 `trtllm-serve` 之前
- ✅ 这是启动 disaggregated worker（CTX/GEN）的标准方式

---

### 证据 3: L0_Test.groovy 的完整命令结构

**getPytestBaseCommandLine 函数（jenkins/L0_Test.groovy:800-850）：**

```groovy
def testCmdLine = [
    "LLM_ROOT=${llmSrc}",
    "LLM_BACKEND_ROOT=${llmSrc}/triton_backend",
    "LLM_MODELS_ROOT=${MODEL_CACHE_DIR}",
    "MODEL_CACHE_DIR=${MODEL_CACHE_DIR}",
    "COLUMNS=300",
    extraInternalEnv,
    portEnvVars,
    pytestUtil,  // ← trtllm-llmapi-launch 插入到这里
    "pytest",
    "-vv",
    "--timeout-method=thread",
    "--apply-test-list-correction",
    "--timeout=${pytestTestTimeout}",
    "--rootdir ${llmSrc}/tests/integration/defs",
    "--test-prefix=${stageName}",
    "--waives-file=${waivesFilePath}",
    "--output-dir=${outputPath}/",
    "--csv=${outputPath}/report.csv",
    "-o junit_logging=out-err",
    "--junit-xml=${outputPath}/results.xml",
    *extraArgs,
]
```

**生成的完整命令：**

```bash
export pytestCommand="LLM_ROOT=/path/to/TensorRT-LLM \
LLM_MODELS_ROOT=/lustre/fsw/... \
NCCL_DEBUG=INFO \
/path/to/TensorRT-LLM/tensorrt_llm/llmapi/trtllm-llmapi-launch \
pytest -vv \
--test-prefix=L0_disagg \
--junit-xml=/workspace/results.xml \
--test-list=/workspace/test_list.txt"
```

---

## 🎯 为什么 CTX/GEN 必须使用 trtllm-llmapi-launch？

### 原因 1: 多 GPU 进程间通信（MPI/NCCL）

**CTX/GEN servers 需要 Tensor Parallelism（TP）：**

```
trtllm-llmapi-launch (MPI 启动器)
  ↓
启动多个进程（每个 GPU 一个）
  ├── Rank 0 (GPU 0): trtllm-serve --host xxx --port xxx
  ├── Rank 1 (GPU 1): trtllm-serve --host xxx --port xxx
  ├── Rank 2 (GPU 2): trtllm-serve --host xxx --port xxx
  └── Rank 3 (GPU 3): trtllm-serve --host xxx --port xxx
  ↓
所有进程通过 NCCL 通信（AllReduce 等操作）
  ↓
对外提供一个统一的服务端点
```

**如果不使用 trtllm-llmapi-launch：**
- ❌ 只有一个进程
- ❌ 无法在多个 GPU 之间分配 Tensor Parallel
- ❌ 无法进行 AllReduce 等 NCCL 集合通信
- ❌ CTX/GEN servers 根本无法正常工作！

---

### 原因 2: 每个 GPU 需要独立的 Rank 和通信上下文

**TP=4 的示例：**

```bash
# 错误的方式（不使用 llmapi-launch）
trtllm-serve /model --host localhost --port 8000
# ↑ 只启动一个进程，无法使用 4 个 GPU

# 正确的方式（使用 llmapi-launch）
trtllm-llmapi-launch trtllm-serve /model --host localhost --port 8000
# ↑ 启动 4 个进程（根据 CUDA_VISIBLE_DEVICES）
#   Rank 0: GPU 0
#   Rank 1: GPU 1
#   Rank 2: GPU 2
#   Rank 3: GPU 3
```

---

### 原因 3: 模型权重分片和通信

**Tensor Parallelism 要求：**
1. **模型权重分片**：每个 GPU 只加载部分权重
2. **激活值分片**：输入数据在多个 GPU 上分片计算
3. **AllReduce 通信**：需要在多个进程之间同步梯度/激活值

**trtllm-llmapi-launch 的作用：**
- 设置 MPI 环境（RANK、LOCAL_RANK、WORLD_SIZE 等）
- 初始化 NCCL 通信组
- 确保所有进程正确启动和同步

---

## 📊 正确的 Disaggregated 启动流程

### 完整的执行链

```
sbatch slurm_launch_generated.sh
  ↓
slurm_launch_draft.sh
  ↓
├── GEN_0: srun -N 1 -n 4 slurm_run.sh
│   ↓ DISAGG_SERVING_TYPE=GEN_0
│   ↓ eval $pytestCommand
│   ↓ trtllm-llmapi-launch pytest test_perf_sanity.py
│   ↓
│   ├── trtllm-llmapi-launch 启动 4 个 pytest 进程
│   │   ├── Rank 0: pytest → test_perf_sanity.py → subprocess.Popen(["trtllm-serve", ...])
│   │   ├── Rank 1: pytest → test_perf_sanity.py → subprocess.Popen(["trtllm-serve", ...])
│   │   ├── Rank 2: pytest → test_perf_sanity.py → subprocess.Popen(["trtllm-serve", ...])
│   │   └── Rank 3: pytest → test_perf_sanity.py → subprocess.Popen(["trtllm-serve", ...])
│   ↓
│   所有 4 个 trtllm-serve 进程通过 NCCL 组成一个 TP=4 的 GEN server
│
├── CTX_0: srun -N 1 -n 4 slurm_run.sh
│   ↓ DISAGG_SERVING_TYPE=CTX_0
│   ↓ trtllm-llmapi-launch pytest test_perf_sanity.py
│   ↓ （同样的多进程启动）
│
├── DISAGG_SERVER: srun -N 1 slurm_run.sh
│   ↓ DISAGG_SERVING_TYPE=DISAGG_SERVER
│   ↓ pytest test_perf_sanity.py （单进程，不需要 llmapi-launch）
│   ↓ subprocess.Popen(["trtllm-serve-coordinator", ...])
│
└── BENCHMARK: srun -N 1 slurm_run.sh
    ↓ DISAGG_SERVING_TYPE=BENCHMARK
    ↓ pytest test_perf_sanity.py （单进程，不需要 llmapi-launch）
    ↓ subprocess.check_output(["benchmark_serving", ...])
```

---

## 🔧 run_disagg_test.sh 必须添加 trtllm-llmapi-launch

### 当前代码（错误）❌

```bash
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
```

**问题：**
- ❌ 缺少 trtllm-llmapi-launch
- ❌ CTX/GEN servers 无法正确启动多进程
- ❌ 无法进行 NCCL 通信
- ❌ 测试会失败！

---

### 正确的实现（必须修改）✅

```bash
# 步骤 0: 判断是否需要 llmapi-launch
if [ "$TOTAL_NODES" -gt 1 ] || [ "$GPUS_PER_NODE" -gt 1 ]; then
    PYTEST_UTIL="$TRTLLM_DIR/tensorrt_llm/llmapi/trtllm-llmapi-launch"
else
    PYTEST_UTIL=""
fi

# 步骤 4.2: 生成 slurm_launch_prefix.sh（完整版）
cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX
#!/bin/bash
# ... SBATCH directives ...

export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test_${CONFIG_NAME}"
export perfMode=true
export resourcePathNode=$TRTLLM_DIR

# ✅ 关键：添加环境变量和 llmapi-launch
export pytestCommand="LLM_ROOT=$TRTLLM_DIR \\
LLM_MODELS_ROOT=$CLUSTER_LLM_DATA \\
MODEL_CACHE_DIR=$CLUSTER_LLM_DATA \\
NCCL_DEBUG=INFO \\
$PYTEST_UTIL \\
pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}] \\
-vv \\
--junit-xml=$WORKSPACE/results.xml"

export coverageConfigFile=$WORKSPACE/coverage_config.json
export NVIDIA_IMEX_CHANNELS=\\\${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=\\\${NVIDIA_VISIBLE_DEVICES:-\\\$(seq -s, 0 \\\$((\\\$(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
EOFPREFIX
```

---

## 📊 submit.py 的智能处理

**submit.py 会自动处理 trtllm-llmapi-launch：**

```python
# submit.py 读取 slurm_launch_prefix.sh
pytest_command_line = "export pytestCommand=\"... trtllm-llmapi-launch pytest ...\""

# 生成两个版本
pytestCommand = "... trtllm-llmapi-launch pytest ..."  # 带 llmapi-launch
pytestCommandNoLLMAPILaunch = "... pytest ..."  # 不带 llmapi-launch

# 派生命令
pytestCommandWorker = "unset UCX_TLS && ... $pytestCommand"  # ← GEN/CTX 使用，带 llmapi-launch
pytestCommandDisaggServer = "... $pytestCommandNoLLMAPILaunch"  # ← DISAGG_SERVER 使用，不带
pytestCommandBenchmark = "$pytestCommandNoLLMAPILaunch"  # ← BENCHMARK 使用，不带
```

**最终执行：**

| 组件 | 使用的命令 | 是否有 llmapi-launch | 原因 |
|------|-----------|---------------------|------|
| **GEN servers** | `pytestCommandWorker` | ✅ 有 | 需要多 GPU TP 通信 |
| **CTX servers** | `pytestCommandWorker` | ✅ 有 | 需要多 GPU TP 通信 |
| **DISAGG_SERVER** | `pytestCommandDisaggServer` | ❌ 无 | 单进程协调器 |
| **BENCHMARK** | `pytestCommandBenchmark` | ❌ 无 | 单进程客户端 |

---

## 🎯 test_perf_sanity.py 的实际执行流程

### GEN/CTX 组件（多进程）

```
slurm_run.sh 执行:
  trtllm-llmapi-launch pytest test_perf_sanity.py
  ↓
trtllm-llmapi-launch 启动 4 个 pytest 进程（TP=4）
  ↓
├── Rank 0 (GPU 0):
│   pytest test_perf_sanity.py
│   ↓ test_e2e() 函数
│   ↓ 读取 DISAGG_SERVING_TYPE=GEN_0
│   ↓ run_cmd() 中判断是 GEN
│   ↓ subprocess.Popen(["trtllm-serve", model, "--host", "xxx", "--port", "8000"])
│   ↓ trtllm-serve 启动（Rank 0，MASTER）
│
├── Rank 1 (GPU 1):
│   pytest test_perf_sanity.py
│   ↓ subprocess.Popen(["trtllm-serve", ...])
│   ↓ trtllm-serve 启动（Rank 1，WORKER）
│
├── Rank 2 (GPU 2):
│   pytest test_perf_sanity.py
│   ↓ subprocess.Popen(["trtllm-serve", ...])
│   ↓ trtllm-serve 启动（Rank 2，WORKER）
│
└── Rank 3 (GPU 3):
    pytest test_perf_sanity.py
    ↓ subprocess.Popen(["trtllm-serve", ...])
    ↓ trtllm-serve 启动（Rank 3，WORKER）
    ↓
所有 4 个 trtllm-serve 进程通过 NCCL 组成一个 TP=4 的服务
```

**关键点：**
- ✅ `trtllm-llmapi-launch` 启动多个 pytest 进程
- ✅ 每个 pytest 进程调用 `subprocess.Popen(["trtllm-serve", ...])`
- ✅ 每个 `trtllm-serve` 进程有自己的 RANK 和 GPU
- ✅ 所有进程通过 NCCL 通信

---

### DISAGG_SERVER 和 BENCHMARK（单进程）

```
slurm_run.sh 执行:
  pytest test_perf_sanity.py （不带 llmapi-launch）
  ↓
单个 pytest 进程
  ↓ test_e2e() 函数
  ↓ 读取 DISAGG_SERVING_TYPE=DISAGG_SERVER 或 BENCHMARK
  ↓ run_cmd() 中判断类型
  ↓ subprocess.Popen(["trtllm-serve-coordinator", ...]) 或
  ↓ subprocess.check_output(["benchmark_serving", ...])
```

**关键点：**
- ❌ 不需要 `trtllm-llmapi-launch`
- ✅ 单进程执行
- ✅ 不需要 NCCL 通信

---

## ✅ 最终结论

### 我之前的错误

1. ❌ 错误地认为 test_perf_sanity.py 不使用 trtllm-llmapi-launch
2. ❌ 错误地认为 trtllm-serve 可以自己管理多 GPU（只对单节点有限适用）
3. ❌ 错误地认为 run_disagg_test.sh 不需要添加 trtllm-llmapi-launch

### 正确的理解

1. ✅ **L0_Test.groovy 确实传递了 trtllm-llmapi-launch**
2. ✅ **examples/disaggregated 明确使用 trtllm-llmapi-launch**
3. ✅ **CTX/GEN servers 必须使用 trtllm-llmapi-launch 才能正常工作**
4. ✅ **run_disagg_test.sh 必须添加 trtllm-llmapi-launch**

---

## 🔧 必须的修改清单

### run_disagg_test.sh 需要完全重写 pytestCommand 生成部分

**必须包含：**
1. ✅ 判断 `nodeCount` 和 `gpusPerNode` 来决定是否需要 llmapi-launch
2. ✅ 添加环境变量（`LLM_ROOT`、`MODEL_CACHE_DIR`、`NCCL_DEBUG` 等）
3. ✅ 插入 `trtllm-llmapi-launch` 到 pytest 之前
4. ✅ 完整的 pytest 参数（timeout、rootdir 等）

---

## 📚 需要更正的文档

以下文档需要全面更正：
1. ❌ `jenkins_test/docs/CLARIFICATION_NO_LLMAPI_LAUNCH.md` - 完全错误
2. ❌ `jenkins_test/docs/L0_VS_DISAGG_PYTEST_COMMAND.md` - 部分错误
3. ⚠️ `jenkins_test/docs/CUSTOM_PERF_TEST_GUIDE.md` - 需要更新实现细节

---

## 🙏 深刻的道歉

**我为之前的错误分析深表歉意！**

你的观察完全正确：
- ✅ L0_Test.groovy 确实传递了 trtllm-llmapi-launch
- ✅ Disaggregated 模式的 CTX/GEN 必须使用 trtllm-llmapi-launch
- ✅ 没有 trtllm-llmapi-launch，CTX/GEN 根本无法进行多 GPU 通信

**感谢你的纠正！这是一个关键的发现！** 🙏
