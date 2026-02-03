# slurm_launch_prefix.sh 参数传递机制详解

> 深入理解 slurm_launch_prefix.sh 如何获取 pytest 模块和函数参数

---

## 🔍 关键发现

### **slurm_launch_prefix.sh 不是预先存在的文件！**

它是由 `run_disagg_test.sh` **动态生成**的临时文件。

---

## 📝 完整的参数传递链路

### 调用链概览

```
Jenkins Pipeline (Perf_Test.groovy)
  ↓ 设置环境变量
  ↓ PERF_TEST_MODULE, PERF_TEST_FUNCTION, PERF_TEST_PREFIX
  ↓
sync_and_run.sh
  ↓ 传递环境变量到远程集群
  ↓
run_disagg_test.sh (在集群上运行)
  ↓ 读取环境变量
  ↓ 生成 slurm_launch_prefix.sh 文件（cat > ... << EOF）
  ↓ 将 pytest 命令写入 slurm_launch_prefix.sh
  ↓
submit.py
  ↓ 读取 slurm_launch_prefix.sh
  ↓ 组合生成最终的 slurm_launch_generated.sh
  ↓
sbatch slurm_launch_generated.sh
  ↓ 执行 Slurm 作业
  ↓
slurm_launch_draft.sh (模板)
  ↓ 读取环境变量（来自 slurm_launch_generated.sh）
  ↓ export pytestCommand="$pytestCommand"
  ↓
slurm_run.sh
  ↓ 执行 pytest
  ↓
eval $pytestCommand
  → pytest perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek...]
```

---

## 🎯 核心机制：动态生成

### 步骤 1: run_disagg_test.sh 读取环境变量

**文件：** `jenkins_test/scripts/run_disagg_test.sh`  
**位置：** 需要在步骤 4.2 之前添加（约 250 行之前）

```bash
# ============================================
# 步骤 0: 读取自定义测试模块配置
# ============================================

# 从环境变量读取（如果未设置则使用默认值）
PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"

echo ""
echo "[步骤 0] 测试模块配置:"
echo "  测试模块: $PERF_TEST_MODULE"
echo "  测试函数: $PERF_TEST_FUNCTION"
echo "  测试前缀: $PERF_TEST_PREFIX"
```

**环境变量来源：**
- Jenkins Pipeline 设置
- sync_and_run.sh 传递到远程集群
- 在远程集群的 shell 环境中可用

---

### 步骤 2: run_disagg_test.sh 生成 slurm_launch_prefix.sh

**当前代码（262-289 行）：**

```bash
# 4.2 创建 script prefix 文件（包含 SBATCH 指令和环境变量）
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
export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test_${CONFIG_NAME}"
export perfMode=true
export resourcePathNode=$TRTLLM_DIR
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
#                            ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
#                            这一行是硬编码的，需要改为使用变量
export coverageConfigFile=$WORKSPACE/coverage_config.json
export NVIDIA_IMEX_CHANNELS=\\\${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=\\\${NVIDIA_VISIBLE_DEVICES:-\\\$(seq -s, 0 \\\$((\\\$(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
EOFPREFIX
echo "✓ 生成 script prefix: $SCRIPT_PREFIX_FILE"
```

**需要修改为（使用变量）：**

```bash
# 4.2 创建 script prefix 文件（包含 SBATCH 指令和环境变量）
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
export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test_${CONFIG_NAME}"
export perfMode=true
export resourcePathNode=$TRTLLM_DIR

# ✅ 关键修改：使用变量构造 pytestCommand
export pytestCommand="pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"

export coverageConfigFile=$WORKSPACE/coverage_config.json
export NVIDIA_IMEX_CHANNELS=\\\${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=\\\${NVIDIA_VISIBLE_DEVICES:-\\\$(seq -s, 0 \\\$((\\\$(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
EOFPREFIX
echo "✓ 生成 script prefix: $SCRIPT_PREFIX_FILE"
```

**关键点：**
- `cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX` 是一个 Here Document
- `${PERF_TEST_MODULE}` 等变量在 `run_disagg_test.sh` 执行时被展开
- 生成的文件包含展开后的实际值

---

### 步骤 3: 同样需要修改 test list 文件生成

**当前代码（254-259 行）：**

```bash
# 4.1 创建 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}]
#↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑
# 这一行也是硬编码的，需要改为使用变量
EOF
echo "✓ 生成 test list: $TEST_LIST_FILE"
```

**需要修改为：**

```bash
# 4.1 创建 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]
EOF
echo "✓ 生成 test list: $TEST_LIST_FILE"
```

---

## 📊 完整的文件生成和传递流程

### 流程图

```
1. Jenkins 设置环境变量
   PERF_TEST_MODULE=perf/test_perf_enhanced.py
   PERF_TEST_FUNCTION=test_e2e
   PERF_TEST_PREFIX=custom_test
   ↓
   
2. run_disagg_test.sh 读取环境变量
   PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
   PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
   PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"
   ↓
   
3. 生成 test_list_disagg.txt
   内容: perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek...]
   ↓
   
4. 生成 slurm_launch_prefix.sh
   内容: export pytestCommand="pytest perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek...] ..."
   ↓
   
5. submit.py 读取这两个文件
   - 读取 test_list_disagg.txt
   - 读取 slurm_launch_prefix.sh
   - 提取 pytestCommand
   ↓
   
6. submit.py 生成 slurm_launch_generated.sh
   将 slurm_launch_prefix.sh 的内容复制到最终脚本
   ↓
   
7. sbatch 执行 slurm_launch_generated.sh
   所有 export 的环境变量在 Slurm 作业中可用
   ↓
   
8. slurm_launch_draft.sh 读取环境变量
   使用 $pytestCommand (从 slurm_launch_generated.sh 继承)
   ↓
   
9. slurm_run.sh 执行
   eval $pytestCommand
   → 实际执行: pytest perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek...]
```

---

## 🔧 需要修改的具体位置

### 文件 1: run_disagg_test.sh

**需要修改的地方：**

#### 位置 1: 步骤 0（新增，约 240 行之后）

```bash
echo ""
echo "============================================"
echo "步骤 0: 确定测试模块路径"
echo "============================================"

# 从环境变量读取自定义测试模块（默认使用 test_perf_sanity.py）
PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"

echo "测试模块配置:"
echo "  测试模块: $PERF_TEST_MODULE"
echo "  测试函数: $PERF_TEST_FUNCTION"
echo "  测试前缀: $PERF_TEST_PREFIX"
echo ""
```

#### 位置 2: 步骤 2.1（约 254-259 行）

```bash
# 4.1 创建 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]
EOF
echo "✓ 生成 test list: $TEST_LIST_FILE"
echo "  内容: ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]"
```

#### 位置 3: 步骤 4.2（约 284 行）

```bash
# 在 slurm_launch_prefix.sh 的 pytestCommand 行修改为：
export pytestCommand="pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
```

---

## ✅ submit.py 不需要修改！

**原因：**

`submit.py` 只是读取 `slurm_launch_prefix.sh` 文件的内容，然后组合到最终的脚本中。

```python
# submit.py (220-222 行)
with open(args.script_prefix, "r") as f:
    script_prefix_content = f.read()
script_prefix_lines = script_prefix_content.split("\n")
```

**submit.py 做的事情：**
1. 读取 `slurm_launch_prefix.sh` 的内容（包括 `export pytestCommand="..."` 这一行）
2. 添加额外的环境变量（`pytestCommandWorker`、`pytestCommandDisaggServer`、`pytestCommandBenchmark`）
3. 组合生成最终的 `slurm_launch_generated.sh`

**因为 `pytestCommand` 已经在 `slurm_launch_prefix.sh` 中正确设置，`submit.py` 不需要任何修改！**

---

## 🎯 slurm_launch_draft.sh 也不需要修改！

**原因：**

`slurm_launch_draft.sh` 是一个模板文件，它使用环境变量：

```bash
# slurm_launch_draft.sh (约 24 行)
export DISAGG_SERVING_TYPE="GEN_$i"
export pytestCommand="$pytestCommandWorker"
```

它只是**使用**环境变量 `$pytestCommand`，而不是定义它。

**环境变量的来源：**
- `slurm_launch_generated.sh` 中的 `export pytestCommand="..."`
- 由 `submit.py` 从 `slurm_launch_prefix.sh` 复制过来

---

## 📝 完整的修改清单

### 需要修改的文件（只有 3 个脚本 + 1 个 Groovy）

| 文件 | 修改位置 | 修改内容 |
|------|---------|---------|
| **run_disagg_test.sh** | 新增步骤 0（约 240 行） | 添加环境变量读取 |
| **run_disagg_test.sh** | 步骤 2.1（约 257 行） | 修改 test list 生成使用变量 |
| **run_disagg_test.sh** | 步骤 4.2（约 284 行） | 修改 pytestCommand 使用变量 |
| **run_single_agg_test.sh** | 约 131 行 | 使用 PERF_TEST_MODULE 变量 |
| **run_multi_agg_test.sh** | 约 201 行 | 使用 PERF_TEST_MODULE 变量 |
| **Perf_Test.groovy** | 参数定义 | 添加 PERF_TEST_MODULE 等参数 |
| **Perf_Test.groovy** | environment | 添加环境变量 |
| **Perf_Test.groovy** | 执行阶段 | 导出环境变量 |
| **sync_and_run.sh** | SSH 命令 | 传递环境变量 |

### 不需要修改的文件

| 文件 | 原因 |
|------|------|
| **submit.py** | ✅ 只读取 slurm_launch_prefix.sh，不关心内容 |
| **slurm_launch_draft.sh** | ✅ 只使用环境变量，不定义 |
| **slurm_run.sh** | ✅ 只执行 `eval $pytestCommand` |
| **slurm_install.sh** | ✅ 不涉及 pytest |

---

## 🔍 验证方法

### 步骤 1: 检查环境变量是否传递

```bash
# 在 run_disagg_test.sh 的步骤 0 添加调试输出
echo "DEBUG: PERF_TEST_MODULE=$PERF_TEST_MODULE"
echo "DEBUG: PERF_TEST_FUNCTION=$PERF_TEST_FUNCTION"
echo "DEBUG: PERF_TEST_PREFIX=$PERF_TEST_PREFIX"
```

### 步骤 2: 检查生成的文件内容

```bash
# 查看生成的 test list
cat $WORKSPACE/test_list_disagg.txt

# 查看生成的 script prefix
cat $WORKSPACE/slurm_launch_prefix.sh | grep pytestCommand

# 查看最终生成的 launch 脚本
cat $WORKSPACE/slurm_launch_generated.sh | grep pytestCommand
```

**预期输出：**

```bash
# test_list_disagg.txt
perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek-r1-fp4_...]

# slurm_launch_prefix.sh
export pytestCommand="pytest perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek-r1-fp4_...] -vv --junit-xml=/workspace/results.xml"

# slurm_launch_generated.sh (包含从 slurm_launch_prefix.sh 复制的内容)
export pytestCommand="pytest perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek-r1-fp4_...] -vv --junit-xml=/workspace/results.xml"
export pytestCommandWorker="unset UCX_TLS && TLLM_LOG_LEVEL=INFO ... $pytestCommand"
export pytestCommandDisaggServer="... $pytestCommandNoLLMAPILaunch"
export pytestCommandBenchmark="... $pytestCommandNoLLMAPILaunch"
```

---

## 📊 变量展开时机对比

### Here Document 中的变量展开

```bash
# 情况 1: 不带引号的 EOF（变量会展开）
cat > file.sh << EOF
export VAR="$MY_VAR"
EOF
# 结果: export VAR="actual_value"

# 情况 2: 带引号的 EOF（变量不展开）
cat > file.sh << 'EOF'
export VAR="$MY_VAR"
EOF
# 结果: export VAR="$MY_VAR"

# 情况 3: 混合（部分展开，部分不展开）
cat > file.sh << EOFPREFIX
export VAR1="$MY_VAR1"           # 展开
export VAR2="\\\$SLURM_VAR"      # 不展开，保留 $SLURM_VAR
EOFPREFIX
```

**在 run_disagg_test.sh 中：**

```bash
cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX
# 这些变量在 run_disagg_test.sh 执行时展开
export pytestCommand="pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}] ..."

# 这些变量在 Slurm 作业执行时展开（使用 \\\$ 转义）
export NVIDIA_VISIBLE_DEVICES=\\\${NVIDIA_VISIBLE_DEVICES:-\\\$(seq ...)}
EOFPREFIX
```

---

## ✅ 总结

### 核心要点

1. **slurm_launch_prefix.sh 是动态生成的**
   - 不是预先存在的文件
   - 由 `run_disagg_test.sh` 通过 `cat > ... << EOF` 生成

2. **参数传递是通过变量展开实现的**
   - Jenkins 设置环境变量
   - `run_disagg_test.sh` 读取环境变量
   - 在生成 `slurm_launch_prefix.sh` 时使用这些变量
   - 变量在 Here Document 中被展开为实际值

3. **只需修改 run_disagg_test.sh**
   - 添加步骤 0 读取环境变量
   - 修改步骤 2.1 使用变量生成 test list
   - 修改步骤 4.2 使用变量生成 pytestCommand

4. **submit.py 和 slurm_launch_draft.sh 不需要修改**
   - `submit.py` 只读取文件内容，不关心内容
   - `slurm_launch_draft.sh` 只使用环境变量，不定义

5. **完全向后兼容**
   - 默认值使用原始的 `test_perf_sanity.py`
   - 只有明确设置环境变量时才使用自定义模块

---

**现在你完全明白参数传递机制了吗？slurm_launch_prefix.sh 是动态生成的，只需修改 run_disagg_test.sh 的生成逻辑即可！** 🚀
