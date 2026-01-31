# Shell 脚本使用说明

## 📁 脚本列表

所有脚本位于 `jenkins_test/scripts/` 目录下：

1. **`run_disagg_test.sh`** - Disagg 模式测试
2. **`run_single_agg_test.sh`** - Single Node Agg 模式测试  
3. **`run_multi_agg_test.sh`** - Multi Node Agg 模式测试
4. **`calculate_hardware_nodes.py`** - 节点数计算工具（被 disagg 脚本调用）

## 🚀 快速开始

### 1. Disagg 模式测试

```bash
cd jenkins_test/scripts

# 使用 TestList
./run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --workspace /tmp/disagg_test

# 或直接指定配置文件名
./run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX \
    --workspace /tmp/disagg_test

# 试运行（不实际提交）
./run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --workspace /tmp/disagg_test \
    --dry-run
```

**执行流程**:
1. 从 TestList 提取配置文件名（或直接使用提供的配置名）
2. 查找配置文件完整路径
3. 调用 `calculate_hardware_nodes.py` 计算节点数
4. 生成 sbatch 脚本（包含 `--nodes=N` 等参数）
5. 提交 sbatch 作业
6. 等待作业完成

### 2. Single Agg 模式测试

```bash
cd jenkins_test/scripts

# 运行测试
./run_single_agg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_blackwell

# 试运行
./run_single_agg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_blackwell \
    --dry-run
```

**执行流程**:
1. 查找配置文件
2. 直接运行 pytest（单节点，不需要 Slurm）

### 3. Multi Agg 模式测试

```bash
cd jenkins_test/scripts

# 运行测试
./run_multi_agg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --workspace /tmp/multi_agg_test

# 试运行
./run_multi_agg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --workspace /tmp/multi_agg_test \
    --dry-run
```

**执行流程**:
1. 查找配置文件
2. 从配置文件计算节点数（从 `world_size` / `gpus_per_node`）
3. 生成 sbatch 脚本
4. 提交 sbatch 作业
5. 等待作业完成

## 📋 详细参数说明

### run_disagg_test.sh

| 参数 | 必需 | 说明 | 示例 |
|------|------|------|------|
| `--trtllm-dir` | ✅ | TensorRT-LLM 目录路径 | `/path/to/TensorRT-LLM` |
| `--testlist` | ⚠️ | TestList 名称（与 config-file 二选一） | `l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes` |
| `--config-file` | ⚠️ | 配置文件名（与 testlist 二选一） | `deepseek-r1-fp4_1k1k_ctx1_gen1...` |
| `--workspace` | ✅ | 工作目录（存放日志和中间文件） | `/tmp/disagg_test` |
| `--dry-run` | ❌ | 试运行模式（不实际提交） | - |

### run_single_agg_test.sh

| 参数 | 必需 | 说明 | 示例 |
|------|------|------|------|
| `--trtllm-dir` | ✅ | TensorRT-LLM 目录路径 | `/path/to/TensorRT-LLM` |
| `--config-file` | ✅ | 配置文件名 | `deepseek_r1_fp4_v2_blackwell` |
| `--dry-run` | ❌ | 试运行模式 | - |

### run_multi_agg_test.sh

| 参数 | 必需 | 说明 | 示例 |
|------|------|------|------|
| `--trtllm-dir` | ✅ | TensorRT-LLM 目录路径 | `/path/to/TensorRT-LLM` |
| `--config-file` | ✅ | 配置文件名 | `deepseek_r1_fp4_v2_grace_blackwell` |
| `--workspace` | ✅ | 工作目录 | `/tmp/multi_agg_test` |
| `--dry-run` | ❌ | 试运行模式 | - |

## 🔧 调试技巧

### 1. 使用 --dry-run 检查生成的脚本

```bash
./run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --testlist xxx \
    --workspace /tmp/test \
    --dry-run
```

输出会显示：
- 提取的配置文件
- 计算的节点数
- 生成的 sbatch 脚本内容
- 但不会实际提交作业

### 2. 手动提交生成的 sbatch 脚本

运行 dry-run 后，sbatch 脚本会保存在 workspace 目录：

```bash
# 查看生成的脚本
cat /tmp/disagg_test/sbatch_disagg.sh

# 手动提交
sbatch /tmp/disagg_test/sbatch_disagg.sh

# 查看作业状态
squeue | grep disagg_perf_test

# 查看日志
tail -f /tmp/disagg_test/slurm_<JOB_ID>.log
```

### 3. 调试配置文件查找

如果脚本找不到配置文件，可以手动检查：

```bash
# Disagg 配置文件
ls $TRTLLM_DIR/tests/integration/defs/perf/disagg/test_configs/disagg/perf/
ls $TRTLLM_DIR/tests/integration/defs/perf/disagg/test_configs/wideep/perf/

# Agg 配置文件
ls $TRTLLM_DIR/tests/scripts/perf-sanity/
ls $TRTLLM_DIR/tests/integration/defs/perf/agg/
```

### 4. 测试节点计算逻辑

```bash
# 手动运行节点计算脚本
python3 jenkins_test/scripts/calculate_hardware_nodes.py \
    --config /path/to/config.yaml \
    --json

# 输出示例:
# {
#   "num_ctx_servers": 1,
#   "num_gen_servers": 1,
#   "ctx_nodes": 2,
#   "gen_nodes": 2,
#   "total_nodes": 4,
#   "total_gpus": 32,
#   "gpus_per_node": 8
# }
```

## 📝 Jenkins Pipeline 集成

在 `Perf_Test.groovy` 中，这些脚本的调用非常简单：

```groovy
// Disagg 模式
def cmd = """
${WORKSPACE_ROOT}/scripts/run_disagg_test.sh \\
    --trtllm-dir ${TRTLLM_DIR} \\
    --testlist ${TESTLIST} \\
    --workspace ${WORKSPACE_ROOT}/disagg_workspace
"""
sh(script: cmd)

// Single Agg 模式
def cmd = """
${WORKSPACE_ROOT}/scripts/run_single_agg_test.sh \\
    --trtllm-dir ${TRTLLM_DIR} \\
    --config-file ${CONFIG_FILE}
"""
sh(script: cmd)

// Multi Agg 模式
def cmd = """
${WORKSPACE_ROOT}/scripts/run_multi_agg_test.sh \\
    --trtllm-dir ${TRTLLM_DIR} \\
    --config-file ${CONFIG_FILE} \\
    --workspace ${WORKSPACE_ROOT}/multi_agg_workspace
"""
sh(script: cmd)
```

## 🎯 优势

### 1. 可调试性
- ✅ Shell 脚本可以直接在命令行运行
- ✅ 不需要 Jenkins 环境
- ✅ 可以单步调试每个步骤

### 2. 可维护性
- ✅ 逻辑集中在脚本中，易于理解和修改
- ✅ Groovy 文件保持简洁，只负责调用
- ✅ 每种测试类型独立一个脚本

### 3. 可重用性
- ✅ 可以在 CI/CD 之外使用
- ✅ 方便本地测试和开发
- ✅ 其他工具也可以调用这些脚本

## ⚠️ 注意事项

### 1. Slurm 环境要求

这些脚本需要在 Slurm 环境中运行（除了 single-agg 模式）：
- `sbatch` 命令可用
- `sacct` 命令可用
- 有可用的计算节点

### 2. 权限要求

脚本需要：
- 读取 TensorRT-LLM 目录的权限
- 创建 workspace 目录的权限
- 提交 Slurm 作业的权限

### 3. 依赖要求

- Python 3 + PyYAML
- Git（用于拉取 TensorRT-LLM）
- Slurm 工具（sbatch, sacct, srun）

## 🔗 相关文档

- `README.md` - 项目总览
- `FIX_SUMMARY.md` - NODE_LIST 问题修复总结
- `TEST_PROCESS.md` - 测试执行流程详解
- `NODE_LIST_ISSUE.md` - 原始问题分析

## 💡 示例：完整的测试流程

### Disagg 测试

```bash
# 1. 克隆 TensorRT-LLM（如果还没有）
git clone https://github.com/NVIDIA/TensorRT-LLM.git /path/to/TensorRT-LLM

# 2. 运行 dry-run 检查
cd jenkins_test/scripts
./run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --workspace /tmp/disagg_test \
    --dry-run

# 3. 检查输出，确认配置正确

# 4. 实际运行
./run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --workspace /tmp/disagg_test

# 5. 查看结果
ls -la /tmp/disagg_test/
cat /tmp/disagg_test/slurm_*.log
```

### Agg 测试

```bash
# Single node
./run_single_agg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_blackwell

# Multi node
./run_multi_agg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --workspace /tmp/multi_agg_test
```
