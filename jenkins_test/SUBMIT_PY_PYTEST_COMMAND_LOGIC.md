# submit.py 中 pytestCommand 的处理逻辑详解

> 深入理解 `export pytestCommand` 的两个版本及 `trtllm-llmapi-launch` 的作用

---

## 🎯 核心问题解答

### ❓ script_prefix_lines 是怎么传过来的？

**答案：从 `slurm_launch_prefix.sh` 文件读取！**

```python
# submit.py (220-222 行)
with open(args.script_prefix, "r") as f:
    script_prefix_content = f.read()
script_prefix_lines = script_prefix_content.split("\n")
```

- `args.script_prefix` = `$WORKSPACE/slurm_launch_prefix.sh`（由 `run_disagg_test.sh` 生成）
- 读取整个文件内容，按换行符分割成行列表

---

### ❓ export pytestCommand 默认要在前面加上 trtllm-llmapi-launch 吗？

**答案：不是必须的！这取决于你的使用场景。**

submit.py 的设计是：
1. **如果你的 `pytestCommand` 包含 `trtllm-llmapi-launch`**：它会创建两个版本
   - `pytestCommand`（带 llmapi-launch）→ 用于 **GEN/CTX Worker**
   - `pytestCommandNoLLMAPILaunch`（不带 llmapi-launch）→ 用于 **DISAGG_SERVER 和 BENCHMARK**

2. **如果你的 `pytestCommand` 不包含 `trtllm-llmapi-launch`**：两个版本是一样的
   - `pytestCommand` → 用于所有组件
   - `pytestCommandNoLLMAPILaunch` → 与 `pytestCommand` 内容相同

---

## 📊 完整的处理流程

### 流程图

```
1. run_disagg_test.sh 生成 slurm_launch_prefix.sh
   ↓
   内容: export pytestCommand="pytest ..."
         (可能带或不带 trtllm-llmapi-launch)
   ↓

2. submit.py 读取 slurm_launch_prefix.sh
   ↓
   script_prefix_lines = file.read().split("\n")
   ↓

3. submit.py 提取 pytestCommand 行
   ↓
   for line in script_prefix_lines:
       if "export pytestCommand=" in line:
           pytest_command_line = line
   ↓

4. submit.py 生成 pytestCommandNoLLMAPILaunch
   ↓
   - 替换变量名: pytestCommand → pytestCommandNoLLMAPILaunch
   - 移除 trtllm-llmapi-launch 部分
   ↓

5. submit.py 创建三个派生命令
   ↓
   - pytestCommandWorker (使用 $pytestCommand，带 llmapi-launch)
   - pytestCommandDisaggServer (使用 $pytestCommandNoLLMAPILaunch，不带 llmapi-launch)
   - pytestCommandBenchmark (使用 $pytestCommandNoLLMAPILaunch，不带 llmapi-launch)
   ↓

6. slurm_launch_draft.sh 根据组件类型使用不同的命令
   ↓
   - GEN/CTX servers → pytestCommandWorker
   - DISAGG_SERVER → pytestCommandDisaggServer
   - BENCHMARK → pytestCommandBenchmark
```

---

## 🔍 代码详细分析

### 步骤 1: run_disagg_test.sh 生成 pytestCommand

**当前代码（284 行）：**

```bash
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
```

**特点：**
- ❌ **不包含** `trtllm-llmapi-launch`
- ✅ 直接调用 `pytest`

**这意味着什么？**
- `pytestCommand` 和 `pytestCommandNoLLMAPILaunch` 将会是**完全相同**的内容

---

### 步骤 2: submit.py 读取文件

**代码（220-222 行）：**

```python
with open(args.script_prefix, "r") as f:
    script_prefix_content = f.read()
script_prefix_lines = script_prefix_content.split("\n")
```

**`args.script_prefix` 来源：**

在 `run_disagg_test.sh` 中：

```bash
SCRIPT_PREFIX_FILE="$WORKSPACE/slurm_launch_prefix.sh"
# ... 生成文件内容 ...

python3 "$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/submit.py" \
    --script-prefix "$SCRIPT_PREFIX_FILE" \
    ...
```

**读取的内容示例：**

```bash
#!/bin/bash
#SBATCH --output=/workspace/slurm_%j.log
#SBATCH --nodes=2
...
export jobWorkspace=/workspace/disagg_workspace
export llmSrcNode=/path/to/TensorRT-LLM
export stageName="disagg_perf_test_deepseek-r1-fp4"
export perfMode=true
export resourcePathNode=/path/to/TensorRT-LLM
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4] -vv --junit-xml=/workspace/results.xml"
export coverageConfigFile=/workspace/coverage_config.json
export NVIDIA_IMEX_CHANNELS=${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-$(seq -s, 0 $(($(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
```

---

### 步骤 3: submit.py 提取并处理 pytestCommand

**代码（105-123 行）：**

```python
def get_pytest_command_no_llmapilaunch(script_prefix_lines):
    pytest_command_line = None
    for line in script_prefix_lines:
        if "export pytestCommand=" in line:
            pytest_command_line = line
            break

    if not pytest_command_line:
        return ""

    # Replace pytestCommand with pytestCommandNoLLMAPILaunch
    replaced_line = pytest_command_line.replace("pytestCommand", "pytestCommandNoLLMAPILaunch")

    # Split by space, find and remove the substring with trtllm-llmapi-launch
    replaced_line_parts = replaced_line.split()
    replaced_line_parts_no_llmapi = [
        part for part in replaced_line_parts if "trtllm-llmapi-launch" not in part
    ]
    return " ".join(replaced_line_parts_no_llmapi)
```

**处理流程示例：**

#### 场景 A: 不包含 trtllm-llmapi-launch（当前情况）

**输入（来自 slurm_launch_prefix.sh）：**
```bash
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml"
```

**处理步骤：**
1. 找到这一行：`pytest_command_line = line`
2. 替换变量名：
   ```python
   replaced_line = "export pytestCommandNoLLMAPILaunch=\"pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml\""
   ```
3. 按空格分割：
   ```python
   replaced_line_parts = [
       "export",
       "pytestCommandNoLLMAPILaunch=\"pytest",
       "perf/test_perf_sanity.py::test_e2e[...]",
       "-vv",
       "--junit-xml=/workspace/results.xml\""
   ]
   ```
4. 过滤掉包含 `trtllm-llmapi-launch` 的部分（没有匹配）：
   ```python
   replaced_line_parts_no_llmapi = [...] # 所有元素都保留
   ```
5. 重新组合：
   ```python
   return "export pytestCommandNoLLMAPILaunch=\"pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml\""
   ```

**结果：`pytestCommand` 和 `pytestCommandNoLLMAPILaunch` 内容完全相同！**

---

#### 场景 B: 包含 trtllm-llmapi-launch（假设的情况）

**输入（假设）：**
```bash
export pytestCommand="trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml"
```

**处理步骤：**
1. 找到这一行：`pytest_command_line = line`
2. 替换变量名：
   ```python
   replaced_line = "export pytestCommandNoLLMAPILaunch=\"trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml\""
   ```
3. 按空格分割：
   ```python
   replaced_line_parts = [
       "export",
       "pytestCommandNoLLMAPILaunch=\"trtllm-llmapi-launch",
       "pytest",
       "perf/test_perf_sanity.py::test_e2e[...]",
       "-vv",
       "--junit-xml=/workspace/results.xml\""
   ]
   ```
4. 过滤掉包含 `trtllm-llmapi-launch` 的部分：
   ```python
   replaced_line_parts_no_llmapi = [
       "export",
       # "pytestCommandNoLLMAPILaunch=\"trtllm-llmapi-launch",  # ❌ 被移除
       "pytest",
       "perf/test_perf_sanity.py::test_e2e[...]",
       "-vv",
       "--junit-xml=/workspace/results.xml\""
   ]
   ```
5. 重新组合：
   ```python
   return "export pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml\""
   ```

**结果：`pytestCommandNoLLMAPILaunch` 移除了 `trtllm-llmapi-launch` 部分！**

---

### 步骤 4: submit.py 生成派生命令

**代码（245-250 行）：**

```python
script_prefix_lines.extend(
    [
        pytest_command_no_llmapi_launch,  # 添加 pytestCommandNoLLMAPILaunch
        f'export pytestCommandWorker="unset UCX_TLS && {worker_env_vars} $pytestCommand"',
        f'export pytestCommandDisaggServer="{server_env_vars} $pytestCommandNoLLMAPILaunch"',
        f'export pytestCommandBenchmark="{env_config["benchmark_env_var"]} $pytestCommandNoLLMAPILaunch"',
        # ...
    ]
)
```

**生成的环境变量（当前场景，不带 llmapi-launch）：**

```bash
# 原始命令（从 slurm_launch_prefix.sh 继承）
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml"

# 新生成的命令（内容与 pytestCommand 相同）
export pytestCommandNoLLMAPILaunch="pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=/workspace/results.xml"

# Worker 命令（用于 GEN/CTX，使用 $pytestCommand）
export pytestCommandWorker="unset UCX_TLS && TLLM_LOG_LEVEL=INFO $pytestCommand"
#                                                                  ↑↑↑↑↑↑↑↑↑↑↑↑↑↑
#                                                                  引用原始的 pytestCommand

# DISAGG_SERVER 命令（使用 $pytestCommandNoLLMAPILaunch）
export pytestCommandDisaggServer="TLLM_LOG_LEVEL=INFO $pytestCommandNoLLMAPILaunch"
#                                                      ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
#                                                      引用不带 llmapi-launch 的版本

# BENCHMARK 命令（使用 $pytestCommandNoLLMAPILaunch）
export pytestCommandBenchmark="$pytestCommandNoLLMAPILaunch"
#                              ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
#                              引用不带 llmapi-launch 的版本
```

**关键点：**
- GEN/CTX Worker 使用 `$pytestCommand`（可能带 llmapi-launch）
- DISAGG_SERVER 和 BENCHMARK 使用 `$pytestCommandNoLLMAPILaunch`（保证不带 llmapi-launch）

---

### 步骤 5: slurm_launch_draft.sh 使用这些命令

**代码（slurm_launch_draft.sh 约 20-50 行）：**

```bash
# GEN servers
for ((i=0; i<$numGenServers; i++)); do
    export DISAGG_SERVING_TYPE="GEN_$i"
    export pytestCommand="$pytestCommandWorker"  # ← 使用 Worker 命令
    srun ... $runScript
done

# CTX servers
for ((i=0; i<$numCtxServers; i++)); do
    export DISAGG_SERVING_TYPE="CTX_$i"
    export pytestCommand="$pytestCommandWorker"  # ← 使用 Worker 命令
    srun ... $runScript
done

# DISAGG_SERVER
export DISAGG_SERVING_TYPE="DISAGG_SERVER"
export pytestCommand="$pytestCommandDisaggServer"  # ← 使用 DisaggServer 命令
srun ... $runScript

# BENCHMARK
export DISAGG_SERVING_TYPE="BENCHMARK"
export pytestCommand="$pytestCommandBenchmark"  # ← 使用 Benchmark 命令
srun ... $runScript
```

---

## 🎯 trtllm-llmapi-launch 的作用

### 什么是 trtllm-llmapi-launch？

`trtllm-llmapi-launch` 是一个包装器脚本，用于启动 TensorRT-LLM 的分布式服务。

**典型用法：**
```bash
trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...]
```

**功能：**
1. **多进程管理**：在多 GPU 环境中启动多个 worker 进程
2. **通信设置**：配置 MPI/UCX/NCCL 等通信后端
3. **资源分配**：为每个 worker 分配 GPU 和其他资源

---

### 为什么 GEN/CTX 需要 llmapi-launch？

**GEN/CTX 服务器：**
- 运行 TensorRT-LLM 引擎
- 需要多 GPU 并行（TP/PP）
- 需要进程间通信
- **需要 llmapi-launch 来管理多进程**

**DISAGG_SERVER：**
- 只是一个协调器（coordinator）
- 不运行推理引擎
- **不需要** llmapi-launch

**BENCHMARK 客户端：**
- 只发送请求和收集统计
- 不运行推理引擎
- **不需要** llmapi-launch

---

### 当前 run_disagg_test.sh 的行为

**当前代码（284 行）：**
```bash
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]"
```

**分析：**
- ❌ 不包含 `trtllm-llmapi-launch`
- ❓ 这意味着所有组件（GEN/CTX/DISAGG_SERVER/BENCHMARK）都使用相同的命令

**潜在问题：**
- GEN/CTX 服务器可能需要 `trtllm-llmapi-launch` 来正确启动多 GPU 推理
- 但是 `test_perf_sanity.py` 内部可能已经处理了这个问题

---

## 🔧 两种使用模式对比

### 模式 1: 不使用 trtllm-llmapi-launch（当前）

**slurm_launch_prefix.sh 中：**
```bash
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]"
```

**submit.py 生成的结果：**
```bash
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]"
export pytestCommandNoLLMAPILaunch="pytest perf/test_perf_sanity.py::test_e2e[...]"
export pytestCommandWorker="unset UCX_TLS && ... $pytestCommand"
export pytestCommandDisaggServer="... $pytestCommandNoLLMAPILaunch"
export pytestCommandBenchmark="$pytestCommandNoLLMAPILaunch"
```

**最终执行的命令（所有组件相同）：**
```bash
pytest perf/test_perf_sanity.py::test_e2e[...]
```

**适用场景：**
- ✅ pytest 测试脚本内部自己管理多进程启动
- ✅ 所有组件使用相同的入口点（test_perf_sanity.py）
- ✅ 简化的测试环境

---

### 模式 2: 使用 trtllm-llmapi-launch

**slurm_launch_prefix.sh 中：**
```bash
export pytestCommand="trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...]"
```

**submit.py 生成的结果：**
```bash
export pytestCommand="trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...]"
export pytestCommandNoLLMAPILaunch="pytest perf/test_perf_sanity.py::test_e2e[...]"
export pytestCommandWorker="unset UCX_TLS && ... $pytestCommand"
export pytestCommandDisaggServer="... $pytestCommandNoLLMAPILaunch"
export pytestCommandBenchmark="$pytestCommandNoLLMAPILaunch"
```

**最终执行的命令：**

GEN/CTX（有 llmapi-launch）：
```bash
trtllm-llmapi-launch pytest perf/test_perf_sanity.py::test_e2e[...]
```

DISAGG_SERVER/BENCHMARK（无 llmapi-launch）：
```bash
pytest perf/test_perf_sanity.py::test_e2e[...]
```

**适用场景：**
- ✅ GEN/CTX 需要外部多进程管理器
- ✅ 分离 worker 和 coordinator/client 的启动方式
- ✅ 更精细的控制

---

## 📊 完整的变量引用链

```
slurm_launch_prefix.sh (由 run_disagg_test.sh 生成)
├── export pytestCommand="pytest ..."
    ↓
submit.py 读取并处理
├── 提取 pytestCommand 行
├── 生成 pytestCommandNoLLMAPILaunch（移除 trtllm-llmapi-launch）
├── 生成 pytestCommandWorker（引用 $pytestCommand）
├── 生成 pytestCommandDisaggServer（引用 $pytestCommandNoLLMAPILaunch）
└── 生成 pytestCommandBenchmark（引用 $pytestCommandNoLLMAPILaunch）
    ↓
slurm_launch_generated.sh (包含所有 export 语句)
├── export pytestCommand="..."
├── export pytestCommandNoLLMAPILaunch="..."
├── export pytestCommandWorker="..."
├── export pytestCommandDisaggServer="..."
└── export pytestCommandBenchmark="..."
    ↓
slurm_launch_draft.sh (使用这些环境变量)
├── GEN_i: export pytestCommand="$pytestCommandWorker"
├── CTX_i: export pytestCommand="$pytestCommandWorker"
├── DISAGG_SERVER: export pytestCommand="$pytestCommandDisaggServer"
└── BENCHMARK: export pytestCommand="$pytestCommandBenchmark"
    ↓
slurm_run.sh (执行命令)
└── eval $pytestCommand
```

---

## ✅ 关键要点总结

### 1. script_prefix_lines 的来源

```python
# submit.py 从文件读取
with open(args.script_prefix, "r") as f:  # args.script_prefix = slurm_launch_prefix.sh
    script_prefix_content = f.read()
script_prefix_lines = script_prefix_content.split("\n")
```

**来源文件：** `$WORKSPACE/slurm_launch_prefix.sh`（由 `run_disagg_test.sh` 动态生成）

---

### 2. export pytestCommand 不需要强制包含 trtllm-llmapi-launch

**灵活设计：**
- ✅ 如果包含 → 自动生成两个版本（带/不带）
- ✅ 如果不包含 → 两个版本相同

**当前实现：**
- run_disagg_test.sh 不使用 trtllm-llmapi-launch
- 所有组件执行相同的 pytest 命令
- test_perf_sanity.py 内部处理多进程逻辑

---

### 3. submit.py 的智能处理

**核心逻辑：**
```python
def get_pytest_command_no_llmapilaunch(script_prefix_lines):
    # 1. 找到 export pytestCommand= 这一行
    # 2. 替换变量名为 pytestCommandNoLLMAPILaunch
    # 3. 移除所有包含 trtllm-llmapi-launch 的部分
    # 4. 返回清理后的命令
```

**好处：**
- 向后兼容（不强制要求 llmapi-launch）
- 自动分离 worker 和 coordinator 命令
- 灵活适配不同的测试场景

---

### 4. 三种派生命令的用途

| 命令变量 | 引用的基础命令 | 使用组件 | 是否带 llmapi-launch |
|---------|--------------|---------|---------------------|
| `pytestCommandWorker` | `$pytestCommand` | GEN, CTX | 可能带（取决于原始命令） |
| `pytestCommandDisaggServer` | `$pytestCommandNoLLMAPILaunch` | DISAGG_SERVER | 保证不带 |
| `pytestCommandBenchmark` | `$pytestCommandNoLLMAPILaunch` | BENCHMARK | 保证不带 |

---

## 🔧 修改建议

### 如果你想使用自定义测试模块

**只需修改 run_disagg_test.sh 生成 pytestCommand 的部分：**

```bash
# 当前（硬编码）
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"

# 修改为（使用变量）
export pytestCommand="pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
```

**submit.py 和其他脚本不需要任何修改！**

因为：
- submit.py 只读取文件内容，不关心具体的模块路径
- 变量展开在 run_disagg_test.sh 执行时完成
- 生成的 slurm_launch_prefix.sh 已经包含展开后的实际值

---

## 📝 验证方法

### 检查生成的文件内容

```bash
# 1. 查看 slurm_launch_prefix.sh
cat $WORKSPACE/slurm_launch_prefix.sh | grep pytestCommand
# 预期输出: export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]"

# 2. 查看 slurm_launch_generated.sh
cat $WORKSPACE/slurm_launch_generated.sh | grep pytestCommand
# 预期输出:
# export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]"
# export pytestCommandNoLLMAPILaunch="pytest perf/test_perf_sanity.py::test_e2e[...]"
# export pytestCommandWorker="unset UCX_TLS && ... $pytestCommand"
# export pytestCommandDisaggServer="... $pytestCommandNoLLMAPILaunch"
# export pytestCommandBenchmark="$pytestCommandNoLLMAPILaunch"

# 3. 在 Slurm 作业日志中检查实际执行的命令
grep "eval.*pytestCommand" slurm_*.log
```

---

**现在你完全理解 submit.py 的 pytestCommand 处理逻辑了吧？** 🚀

**关键点：**
1. ✅ script_prefix_lines 从 slurm_launch_prefix.sh 文件读取
2. ✅ trtllm-llmapi-launch 不是必须的，submit.py 会智能处理
3. ✅ 自动生成带/不带两个版本，分别用于不同组件
4. ✅ 修改 run_disagg_test.sh 即可，submit.py 不需要改
