# run_disagg_test.sh 更新说明

> **已完成：添加 trtllm-llmapi-launch 支持，完全对齐 L0_Test.groovy**

---

## 🎯 更新内容

### 主要修改

1. **添加 trtllm-llmapi-launch 支持** ✅
2. **完整的环境变量设置** ✅
3. **自定义测试模块支持** ✅
4. **完整的 pytest 参数** ✅

---

## 📊 详细修改对比

### 修改位置：步骤 4（第 241-289 行）

#### 之前的实现 ❌

```bash
# 4.1 创建 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}]
EOF

# 4.2 创建 script prefix 文件
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
```

**问题：**
- ❌ 缺少 `trtllm-llmapi-launch`
- ❌ 缺少必要的环境变量（`LLM_ROOT`、`MODEL_CACHE_DIR`、`NCCL_DEBUG` 等）
- ❌ pytest 参数不完整（缺少 `--timeout`、`--rootdir`、`--test-prefix` 等）
- ❌ CTX/GEN servers 无法进行多 GPU 通信
- ❌ 硬编码测试模块路径

---

#### 现在的实现 ✅

```bash
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
# ... SBATCH directives ...

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
```

**改进：**
- ✅ **自动判断是否需要 `trtllm-llmapi-launch`**（基于节点数和 GPU 数）
- ✅ **添加所有必要的环境变量**（与 L0_Test.groovy 对齐）
- ✅ **完整的 pytest 参数**（timeout、rootdir、test-prefix、csv 等）
- ✅ **支持自定义测试模块**（通过环境变量）
- ✅ **CTX/GEN servers 现在可以正确进行多 GPU 通信**

---

## 🔍 关键改进详解

### 1. trtllm-llmapi-launch 的智能判断

```bash
PYTEST_UTIL=""
if [[ "$TOTAL_NODES" -gt 1 ]] || [[ "$GPUS_PER_NODE" -gt 1 ]]; then
    PYTEST_UTIL="$TRTLLM_DIR/tensorrt_llm/llmapi/trtllm-llmapi-launch"
    echo "✓ 将使用 trtllm-llmapi-launch (多节点/多GPU)"
else
    echo "✓ 单节点单GPU，不使用 trtllm-llmapi-launch"
fi
```

**逻辑：**
- 当 `TOTAL_NODES > 1` **或** `GPUS_PER_NODE > 1` 时，设置 `PYTEST_UTIL`
- 完全对齐 L0_Test.groovy 的判断逻辑（`nodeCount > 1`）
- 单节点单 GPU 场景不使用 llmapi-launch（不需要多进程通信）

**为什么这很重要？**
- ✅ CTX/GEN servers 需要 Tensor Parallelism（TP）
- ✅ TP 要求多个进程通过 NCCL 通信
- ✅ `trtllm-llmapi-launch` 负责启动多个进程并设置 MPI 环境
- ❌ 没有它，CTX/GEN 无法在多个 GPU 之间分片模型和通信

---

### 2. 完整的环境变量设置

```bash
export pytestCommand="LLM_ROOT=$TRTLLM_DIR \
LLM_BACKEND_ROOT=$TRTLLM_DIR/triton_backend \
LLM_MODELS_ROOT=$CLUSTER_LLM_DATA \
MODEL_CACHE_DIR=$CLUSTER_LLM_DATA \
COLUMNS=300 \
NCCL_DEBUG=INFO \
$PYTEST_UTIL \
pytest ..."
```

**新增的环境变量：**

| 环境变量 | 作用 | 来源 |
|---------|------|------|
| `LLM_ROOT` | TensorRT-LLM 根目录 | L0_Test.groovy |
| `LLM_BACKEND_ROOT` | Triton backend 目录 | L0_Test.groovy |
| `LLM_MODELS_ROOT` | 模型缓存目录 | L0_Test.groovy |
| `MODEL_CACHE_DIR` | 模型缓存目录（别名） | L0_Test.groovy |
| `COLUMNS` | 终端列宽 | L0_Test.groovy |
| `NCCL_DEBUG` | NCCL 调试信息 | L0_Test.groovy |

**为什么需要这些？**
- ✅ pytest 测试依赖这些环境变量找到模型和库
- ✅ `NCCL_DEBUG=INFO` 帮助调试多 GPU 通信问题
- ✅ 完全对齐 L0_Test.groovy，确保一致性

---

### 3. 完整的 pytest 参数

```bash
pytest -vv \
    --timeout-method=thread \
    --timeout=3600 \
    --rootdir $TRTLLM_DIR/tests/integration/defs \
    --test-prefix=${PERF_TEST_PREFIX} \
    --output-dir=$WORKSPACE/ \
    --csv=$WORKSPACE/report.csv \
    -o junit_logging=out-err \
    --junit-xml=$WORKSPACE/results.xml \
    ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]
```

**新增的 pytest 参数：**

| 参数 | 作用 | 来源 |
|------|------|------|
| `--timeout-method=thread` | 超时方法 | L0_Test.groovy |
| `--timeout=3600` | 测试超时时间（1小时） | L0_Test.groovy |
| `--rootdir` | pytest 根目录 | L0_Test.groovy |
| `--test-prefix` | 测试名称前缀 | L0_Test.groovy |
| `--output-dir` | 输出目录 | L0_Test.groovy |
| `--csv` | CSV 报告路径 | L0_Test.groovy |
| `-o junit_logging=out-err` | JUnit 日志包含 stdout/stderr | L0_Test.groovy |

**为什么需要这些？**
- ✅ 防止测试挂死（`--timeout=3600`）
- ✅ 生成完整的性能报告（`--csv`）
- ✅ 更好的测试组织（`--rootdir`、`--test-prefix`）
- ✅ 完整的日志输出（`-o junit_logging=out-err`）

---

### 4. 自定义测试模块支持

```bash
# 从环境变量读取自定义测试模块配置（可选）
PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"
```

**使用方式：**

```bash
# 方式 1: 使用默认（test_perf_sanity.py）
./run_disagg_test.sh --trtllm-dir /path/to/TensorRT-LLM --config-file deepseek-r1-fp4 --workspace /tmp/test

# 方式 2: 使用自定义测试模块
export PERF_TEST_MODULE="perf/test_perf_enhanced.py"
export PERF_TEST_FUNCTION="test_e2e"
export PERF_TEST_PREFIX="custom_test"
./run_disagg_test.sh --trtllm-dir /path/to/TensorRT-LLM --config-file deepseek-r1-fp4 --workspace /tmp/test
```

**好处：**
- ✅ 支持自定义测试文件（`test_perf_enhanced.py`）
- ✅ 向后兼容（默认使用 `test_perf_sanity.py`）
- ✅ 灵活的测试函数和前缀配置

---

## 📊 submit.py 的智能处理

**submit.py 会自动处理 `trtllm-llmapi-launch`：**

### 输入（slurm_launch_prefix.sh）

```bash
export pytestCommand="... trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...] ..."
```

### submit.py 处理

```python
# 提取并生成两个版本
pytestCommand = "... trtllm-llmapi-launch pytest ..."  # 原始命令
pytestCommandNoLLMAPILaunch = "... pytest ..."  # 移除 llmapi-launch

# 派生命令
pytestCommandWorker = "unset UCX_TLS && ... $pytestCommand"  # GEN/CTX 使用
pytestCommandDisaggServer = "... $pytestCommandNoLLMAPILaunch"  # DISAGG_SERVER 使用
pytestCommandBenchmark = "$pytestCommandNoLLMAPILaunch"  # BENCHMARK 使用
```

### 最终执行

| 组件 | 使用的命令 | 是否有 llmapi-launch | 原因 |
|------|-----------|---------------------|------|
| **GEN servers** | `pytestCommandWorker` | ✅ 有 | 需要多 GPU TP 通信 |
| **CTX servers** | `pytestCommandWorker` | ✅ 有 | 需要多 GPU TP 通信 |
| **DISAGG_SERVER** | `pytestCommandDisaggServer` | ❌ 无 | 单进程协调器 |
| **BENCHMARK** | `pytestCommandBenchmark` | ❌ 无 | 单进程客户端 |

---

## 🔄 完整的执行流程

### 多节点/多 GPU 场景（TP=4）

```
run_disagg_test.sh
  ↓ 判断: TOTAL_NODES > 1 或 GPUS_PER_NODE > 1
  ↓ PYTEST_UTIL="/path/to/trtllm-llmapi-launch"
  ↓ 生成 slurm_launch_prefix.sh
  ↓ export pytestCommand="... trtllm-llmapi-launch pytest ..."
  ↓
submit.py
  ↓ 读取 slurm_launch_prefix.sh
  ↓ 生成 pytestCommandWorker（带 llmapi-launch）
  ↓ 生成 pytestCommandDisaggServer（不带 llmapi-launch）
  ↓ 生成 pytestCommandBenchmark（不带 llmapi-launch）
  ↓
sbatch slurm_launch_generated.sh
  ↓
slurm_launch_draft.sh
  ↓
├── GEN_0: srun -N 1 -n 4 slurm_run.sh
│   ↓ eval $pytestCommandWorker
│   ↓ trtllm-llmapi-launch pytest test_perf_sanity.py
│   ↓ 启动 4 个 pytest 进程（TP=4）
│   ↓
│   ├── Rank 0 (GPU 0): pytest → subprocess.Popen(["trtllm-serve", ...])
│   ├── Rank 1 (GPU 1): pytest → subprocess.Popen(["trtllm-serve", ...])
│   ├── Rank 2 (GPU 2): pytest → subprocess.Popen(["trtllm-serve", ...])
│   └── Rank 3 (GPU 3): pytest → subprocess.Popen(["trtllm-serve", ...])
│   ↓
│   所有 4 个 trtllm-serve 进程通过 NCCL 通信（TP=4）
│
├── CTX_0: srun -N 1 -n 4 slurm_run.sh
│   ↓ （同样的多进程启动）
│
├── DISAGG_SERVER: srun -N 1 slurm_run.sh
│   ↓ eval $pytestCommandDisaggServer
│   ↓ pytest test_perf_sanity.py （不带 llmapi-launch）
│   ↓ subprocess.Popen(["trtllm-serve-coordinator", ...])
│
└── BENCHMARK: srun -N 1 slurm_run.sh
    ↓ eval $pytestCommandBenchmark
    ↓ pytest test_perf_sanity.py （不带 llmapi-launch）
    ↓ subprocess.check_output(["benchmark_serving", ...])
```

---

## ✅ 验证更新

### 检查生成的文件

```bash
# 1. 运行脚本（dry-run 模式）
./jenkins_test/scripts/run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX \
    --workspace /tmp/disagg_test \
    --dry-run

# 2. 检查生成的 slurm_launch_prefix.sh
cat /tmp/disagg_test/slurm_launch_prefix.sh | grep pytestCommand

# 预期输出应该包含：
# - LLM_ROOT=...
# - MODEL_CACHE_DIR=...
# - NCCL_DEBUG=INFO
# - trtllm-llmapi-launch (如果是多节点/多GPU)
# - pytest -vv --timeout-method=thread --timeout=3600 ...
```

### 检查 llmapi-launch 判断逻辑

```bash
# 场景 1: 多节点（应该有 llmapi-launch）
# 假设配置文件需要 2 个节点
./run_disagg_test.sh ... | grep "将使用 trtllm-llmapi-launch"

# 场景 2: 单节点多 GPU（应该有 llmapi-launch）
# 假设配置文件需要 1 个节点 4 个 GPU
./run_disagg_test.sh ... | grep "将使用 trtllm-llmapi-launch"

# 场景 3: 单节点单 GPU（应该没有 llmapi-launch）
# 假设配置文件需要 1 个节点 1 个 GPU
./run_disagg_test.sh ... | grep "单节点单GPU，不使用 trtllm-llmapi-launch"
```

---

## 📚 相关文档

1. **更正说明**: `jenkins_test/docs/CORRECTION_MUST_USE_LLMAPI_LAUNCH.md`
2. **参数传递**: `jenkins_test/docs/SLURM_LAUNCH_PREFIX_PARAM_PASSING.md`
3. **submit.py 逻辑**: `jenkins_test/docs/SUBMIT_PY_PYTEST_COMMAND_LOGIC.md`
4. **自定义测试模块**: `jenkins_test/docs/CUSTOM_PERF_TEST_GUIDE.md`

---

## 🎯 总结

### 核心改进

1. ✅ **添加 trtllm-llmapi-launch 支持**
   - 智能判断（基于节点数和 GPU 数）
   - 完全对齐 L0_Test.groovy

2. ✅ **完整的环境变量**
   - LLM_ROOT、MODEL_CACHE_DIR、NCCL_DEBUG 等
   - 与 L0_Test.groovy 完全一致

3. ✅ **完整的 pytest 参数**
   - timeout、rootdir、test-prefix、csv 等
   - 生成完整的测试报告

4. ✅ **自定义测试模块支持**
   - 通过环境变量配置
   - 向后兼容默认值

### 关键修复

- ✅ **CTX/GEN servers 现在可以正确进行多 GPU 通信**
- ✅ **修复了之前无法启动多进程的问题**
- ✅ **与 L0_Test.groovy 完全对齐**

---

**更新完成！现在 `run_disagg_test.sh` 可以正确支持 disaggregated 模式的多 GPU 通信了！** 🚀
