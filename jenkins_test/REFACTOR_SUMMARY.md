# 重构总结：使用 Shell 脚本简化测试流程

## ✅ 完成的工作

### 1. 创建了三个独立的 Shell 脚本

**位置**: `jenkins_test/scripts/`

| 脚本 | 功能 | 用途 |
|------|------|------|
| `run_disagg_test.sh` | Disagg 模式测试 | 自动计算节点数、生成 sbatch 脚本、提交作业 |
| `run_single_agg_test.sh` | Single Agg 测试 | 直接运行 pytest（单节点） |
| `run_multi_agg_test.sh` | Multi Agg 测试 | 从配置计算节点数、生成 sbatch 脚本、提交作业 |

### 2. 简化了 Perf_Test.groovy

**之前**: 
- 500+ 行 Groovy 代码
- 复杂的配置提取逻辑
- 内嵌 Python 脚本
- 节点计算和验证逻辑在 Groovy 中

**现在**:
- 200+ 行 Groovy 代码（简化了一半以上）
- 只负责参数验证和脚本调用
- 所有复杂逻辑都在 Shell 脚本中

**核心代码**:
```groovy
// 只需调用对应的脚本
if (TEST_MODE == 'disagg') {
    testScript = "${WORKSPACE_ROOT}/scripts/run_disagg_test.sh"
    scriptArgs = ["--trtllm-dir", TRTLLM_DIR, "--testlist", TESTLIST, "--workspace", workspace]
} else if (TEST_MODE == 'single-agg') {
    testScript = "${WORKSPACE_ROOT}/scripts/run_single_agg_test.sh"
    scriptArgs = ["--trtllm-dir", TRTLLM_DIR, "--config-file", CONFIG_FILE]
} else if (TEST_MODE == 'multi-agg') {
    testScript = "${WORKSPACE_ROOT}/scripts/run_multi_agg_test.sh"
    scriptArgs = ["--trtllm-dir", TRTLLM_DIR, "--config-file", CONFIG_FILE, "--workspace", workspace]
}

sh "${testScript} ${scriptArgs.join(' ')}"
```

### 3. 删除了不必要的文件

- ❌ 删除 `submit_disagg.py`（功能集成到 `run_disagg_test.sh`）
- ✅ 保留 `calculate_hardware_nodes.py`（被 disagg 脚本调用）

## 🎯 优势

### 1. 可调试性 ⭐⭐⭐⭐⭐

**之前**:
```groovy
// 必须在 Jenkins 中才能运行
// 无法单独调试
// 逻辑分散在 Groovy 和 Python 中
```

**现在**:
```bash
# 直接在命令行运行
./run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --testlist xxx \
    --workspace /tmp/test \
    --dry-run  # 查看将要执行的命令

# 单步调试
set -x  # 在脚本开头启用调试
```

### 2. 可维护性 ⭐⭐⭐⭐⭐

**之前**:
- 逻辑分散：Groovy + Python + inline shell
- 难以理解：需要懂 Groovy 语法
- 难以测试：依赖 Jenkins 环境

**现在**:
- 逻辑集中：每个脚本一个测试类型
- 易于理解：标准 Bash 脚本
- 易于测试：可以独立运行

### 3. 可重用性 ⭐⭐⭐⭐⭐

**之前**:
- 只能在 Jenkins Pipeline 中使用
- 无法在本地开发环境使用
- 无法被其他工具调用

**现在**:
```bash
# 本地开发
./run_single_agg_test.sh --trtllm-dir ~/TensorRT-LLM --config-file xxx

# 其他 CI/CD 工具
gitlab-ci.yml:
  script:
    - jenkins_test/scripts/run_disagg_test.sh --testlist xxx --workspace $CI_PROJECT_DIR/workspace

# Cron 定时任务
0 2 * * * /path/to/run_multi_agg_test.sh --trtllm-dir /data/TensorRT-LLM --config-file xxx --workspace /tmp/nightly
```

## 📁 文件结构

```
jenkins_test/
├── scripts/
│   ├── calculate_hardware_nodes.py     # 节点计算工具
│   ├── run_disagg_test.sh              # Disagg 测试脚本
│   ├── run_single_agg_test.sh          # Single Agg 测试脚本
│   └── run_multi_agg_test.sh           # Multi Agg 测试脚本
├── Perf_Test.groovy                     # Jenkins Pipeline（简化版）
├── README.md                            # 项目总览
├── SHELL_SCRIPTS_USAGE.md               # Shell 脚本使用说明 ⭐ NEW
├── FIX_SUMMARY.md                       # NODE_LIST 修复总结
├── TEST_PROCESS.md                      # 测试执行流程详解
└── NODE_LIST_ISSUE.md                   # 原始问题分析
```

## 🚀 使用示例

### 本地手动调试

```bash
cd jenkins_test/scripts

# 1. Disagg 测试
./run_disagg_test.sh \
    --trtllm-dir ~/TensorRT-LLM \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --workspace /tmp/disagg_test \
    --dry-run  # 先看看会执行什么

# 2. Single Agg 测试
./run_single_agg_test.sh \
    --trtllm-dir ~/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_blackwell

# 3. Multi Agg 测试
./run_multi_agg_test.sh \
    --trtllm-dir ~/TensorRT-LLM \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --workspace /tmp/multi_agg_test
```

### Jenkins Pipeline

```groovy
// 参数超级简单
TEST_MODE: disagg
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes

// Pipeline 自动调用对应的脚本
// 用户不需要关心任何细节
```

## 📊 代码行数对比

| 文件 | 之前 | 现在 | 变化 |
|------|------|------|------|
| Perf_Test.groovy | 569 行 | ~250 行 | ⬇️ -56% |
| submit_disagg.py | 274 行 | 0（删除） | ⬇️ -100% |
| run_disagg_test.sh | 0 | ~300 行 | ⬆️ 新增 |
| run_single_agg_test.sh | 0 | ~120 行 | ⬆️ 新增 |
| run_multi_agg_test.sh | 0 | ~230 行 | ⬆️ 新增 |
| **总计** | **843 行** | **~900 行** | **+7%** |

**分析**:
- 虽然总行数略有增加（+7%）
- 但代码质量大幅提升：
  - ✅ Shell 脚本比 Groovy 更易读易调试
  - ✅ 每个脚本独立，职责清晰
  - ✅ 可以在命令行直接运行
  - ✅ Jenkins Pipeline 大幅简化

## 🔍 执行流程对比

### 之前：Disagg 模式

```
用户输入 → Jenkins Pipeline
           ├── 验证参数
           ├── 拉取 TensorRT-LLM
           ├── [Stage: 处理配置 - Disagg]
           │   ├── 从 TestList 提取配置（Groovy + Python）
           │   ├── 查找配置文件（Groovy）
           │   ├── 计算节点数（Groovy 调用 Python）
           │   └── 验证节点数（Groovy）
           ├── [Stage: 运行测试]
           │   ├── 调用 submit_disagg.py（Python）
           │   ├── 生成 sbatch 脚本（Python）
           │   ├── 提交作业（Python）
           │   └── 等待完成（Python）
           └── 结束

❌ 问题：
- 逻辑分散在 Groovy 和 Python 中
- 无法直接调试
- 依赖 Jenkins 环境
```

### 现在：Disagg 模式

```
用户输入 → Jenkins Pipeline
           ├── 验证参数
           ├── 拉取 TensorRT-LLM
           └── 调用 run_disagg_test.sh
               ↓
           run_disagg_test.sh
               ├── 从 TestList 提取配置
               ├── 查找配置文件
               ├── 计算节点数（调用 calculate_hardware_nodes.py）
               ├── 生成 sbatch 脚本
               ├── 提交作业
               └── 等待完成

✅ 优势：
- 所有逻辑在一个脚本中
- 可以直接在命令行运行
- 不依赖 Jenkins
```

## 🎓 学到的经验

### 1. 保持 Jenkins Pipeline 简洁

**原则**: Jenkins Pipeline 应该只负责编排，不应该包含复杂的业务逻辑

**之前**: 
```groovy
// 在 Groovy 中写复杂逻辑
def extractCmd = """
python3 << 'EOF'
import yaml, re, sys
# ... 50 行 Python 代码 ...
EOF
"""
configName = sh(script: extractCmd, returnStdout: true).trim()
```

**现在**:
```groovy
// 只调用脚本
sh "run_disagg_test.sh --testlist ${TESTLIST} --workspace ${WORKSPACE}"
```

### 2. 优先使用 Shell 脚本

**优势**:
- ✅ 易于调试（set -x, echo, etc.）
- ✅ 易于测试（直接运行）
- ✅ 易于理解（标准 Unix 工具）
- ✅ 可移植性强（不依赖特定 CI/CD 工具）

**何时使用 Python**:
- 需要复杂的数据结构处理
- 需要 YAML/JSON 解析
- 需要复杂的数学计算

### 3. 每个脚本一个职责

**之前**: 一个大的 Groovy 文件处理所有测试类型

**现在**: 
- `run_disagg_test.sh` → 只处理 Disagg
- `run_single_agg_test.sh` → 只处理 Single Agg
- `run_multi_agg_test.sh` → 只处理 Multi Agg

## 📚 相关文档

- **SHELL_SCRIPTS_USAGE.md** ⭐ NEW - Shell 脚本详细使用说明
- **FIX_SUMMARY.md** - NODE_LIST 问题修复总结
- **TEST_PROCESS.md** - 测试执行流程详解
- **NODE_LIST_ISSUE.md** - 原始问题分析
- **README.md** - 项目总览

## ✅ 总结

这次重构实现了：

1. **✅ 移除多余的 NODE_COUNT/NODE_LIST 参数** - 系统自动计算
2. **✅ 简化 Jenkins Pipeline** - 从 569 行减少到 ~250 行
3. **✅ 所有逻辑放到 Shell 脚本** - 可以直接手动调试
4. **✅ 三个独立脚本** - 每个测试类型一个脚本
5. **✅ 完整的文档** - 使用说明和示例

**最大的收益**:
- 🎯 **用户可以直接在命令行调试**，不需要 Jenkins
- 🎯 **逻辑清晰**，每个脚本职责明确
- 🎯 **易于维护**，Shell 脚本比 Groovy 更容易理解
- 🎯 **可重用**，可以在任何环境使用这些脚本
