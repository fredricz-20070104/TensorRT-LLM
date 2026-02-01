# TestList 格式详解

## 📚 概述

Jenkins 性能测试框架支持**两种 TestList 格式**，满足不同的使用场景：

1. **YAML 格式**（test-db 兼容）- 结构化配置，适合管理复杂测试套件
2. **TXT 格式**（pytest 格式）- 简单文本列表，适合快速 debug 和手动测试

---

## 🎯 使用场景对比

| 场景 | 推荐格式 | 原因 |
|------|---------|------|
| **生产环境测试** | YAML | 结构化，易于管理和审计 |
| **CI/CD 集成** | YAML | 支持元数据和条件 |
| **快速 Debug（任何类型）** | TXT | 直接从 pytest 输出复制粘贴 |
| **单个 Case 重跑（任何类型）** | TXT | 快速指定具体测试 |
| **混合类型 Debug** | TXT | 一个文件支持所有类型 |
| **大规模测试套件** | YAML | 支持分组和过滤 |

**重要**: TXT 格式支持所有三种测试类型（single-agg, multi-agg, disagg），通过模式标记区分。

---

## 1️⃣ YAML 格式（test-db 兼容）

### 文件结构

```yaml
gb200_unified_perf_suite:   # Suite 名称
  tests:                     # 测试列表
    - name: "测试名称"       # 可读的测试名称
      config_file: "配置文件" # 配置文件名（不含扩展名）
      condition:             # 可选：执行条件
        terms:
          nodes: 1           # 节点数（1=single-agg, >1=multi-agg）
      test_type: disagg      # 可选：明确指定测试类型
```

### 完整示例

```yaml
gb200_unified_perf_suite:
  tests:
    # ==========================================
    # Single-Agg 测试（单节点）
    # ==========================================
    - name: "DeepSeek-R1 FP4 V2 Blackwell"
      config_file: "deepseek_r1_fp4_v2_blackwell"
      condition:
        terms:
          nodes: 1           # 单节点 = single-agg
    
    - name: "Llama3.1-8B FP16"
      config_file: "llama3.1_8b_fp16"
      # 没有 condition.terms.nodes，默认为 single-agg
    
    # ==========================================
    # Multi-Agg 测试（多节点聚合）
    # ==========================================
    - name: "Llama3.1-70B TP4 Multi-Node"
      config_file: "llama3.1_70b_tp4"
      condition:
        terms:
          nodes: 2           # 多节点 = multi-agg
    
    # ==========================================
    # Disagg 测试（分离式）
    # ==========================================
    - name: "Llama3.1-70B Disaggregated"
      config_file: "llama3.1_70b_disagg"
      test_type: disagg      # 明确标记为 disagg
      condition:
        terms:
          nodes: 3
```

### 测试类型识别规则

```python
if test.test_type == 'disagg':
    mode = 'disagg'
elif test.condition.terms.nodes > 1:
    mode = 'multi-agg'
else:
    mode = 'single-agg'  # 默认
```

### 文件位置

```
jenkins_test/testlists/
├── gb200_unified_suite.yml      # GB200 完整测试套件
├── gb300_unified_suite.yml      # GB300 完整测试套件
└── custom_suite.yml             # 自定义套件
```

---

## 2️⃣ TXT 格式（pytest 格式）

### 文件结构

```txt
# 注释行（以 # 开头）

# ✨ 无需手动标记！自动识别测试类型
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]

# 可选：手动标记覆盖自动识别
test_perf_sanity.py::test_e2e[benchmark-custom_config]  # mode:multi-agg
```

### 🎯 自动识别机制

**新特性**：parse_unified_testlist.py 现在会自动读取配置文件来推断测试类型！

#### 识别逻辑（按优先级）：

1. **手动标记**（优先级最高）
   ```txt
   test_case  # mode:multi-agg  ← 手动标记优先
   ```

2. **配置文件分析**
   - 读取 `tests/scripts/perf-sanity/{config_yml}.yaml`
   - 检查 `gpus` vs `gpus_per_node` 判断是否多节点
   - 检查 `disagg_run_type` 字段
   - 检查 `hardware.num_ctx_servers` 和 `num_gen_servers`

3. **命名规则推断**
   - 包含 `_disagg` 或 `-disagg` → disagg
   - 包含 `ctx` + `gen` → disagg
   - 包含 `_2_nodes`, `_3_nodes`, `multi_node` → multi-agg

4. **默认规则**
   - 默认为 single-agg

### 完整示例

```txt
# ============================================
# 自动识别示例（无需手动标记）
# ============================================

# Single-Agg（自动识别）
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[benchmark-llama3_8b]

# Multi-Agg（自动识别 - 通过配置文件中的 gpus > gpus_per_node）
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]

# Disagg（自动识别 - 通过命名规则或配置文件）
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]
test_perf_sanity.py::test_e2e[disagg-deepseek-r1-fp4_8k1k_ctx1_gen1]

# ============================================
# 手动标记覆盖（可选）
# ============================================

# 如果自动识别不准确，可以手动标记
test_perf_sanity.py::test_e2e[benchmark-custom_config]  # mode:multi-agg
test_perf_sanity.py::test_e2e[profiling-special_case]  # mode:disagg
```

### 模式标记语法

```txt
# ✨ 新特性：大多数情况下无需手动标记！

# 自动识别为 single-agg（配置文件分析）
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]

# 自动识别为 multi-agg（配置文件显示 gpus > gpus_per_node）
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]

# 自动识别为 disagg（命名包含 _disagg）
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]

# 可选：手动标记覆盖自动识别
test_perf_sanity.py::test_e2e[custom_case]  # mode:multi-agg
```

### 文件位置

```
jenkins_test/testlists/
├── debug_cases.txt              # ⭐ 统一的 Debug 文件（支持所有类型）
├── custom_debug.txt             # 可选：自定义 debug 文件
└── failed_tests.txt             # 可选：从 CI 收集的失败测试
```

**推荐做法**：
- ✅ 使用一个 `debug_cases.txt` 文件即可
- ✅ 通过模式标记区分测试类型
- ✅ 不需要按类型分文件（`debug_single_agg.txt`, `debug_multi_agg.txt` 等）

---

## 🔄 格式对比

| 特性 | YAML 格式 | TXT 格式 |
|------|----------|---------|
| **可读性** | 高（结构化） | 中（简单列表） |
| **元数据支持** | ✅ 丰富 | ❌ 有限 |
| **快速编辑** | ❌ 需要遵循格式 | ✅ 直接复制粘贴 |
| **自动识别模式** | ✅ 是 | ✅ 是（新特性！） |
| **配置文件分析** | ✅ 是 | ✅ 是（新特性！） |
| **手动标记** | ❌ 不需要 | ⚠️ 可选覆盖 |
| **大规模管理** | ✅ 适合 | ❌ 不适合 |
| **Debug 调试** | ⚠️ 需要转换 | ✅ 直接使用 |
| **CI/CD 集成** | ✅ 推荐 | ⚠️ 简单场景 |

---

## 🚀 Jenkins Pipeline 使用

### 方式 1：使用预定义 YAML 套件

```groovy
// 在 Jenkins UI 中选择
TESTLIST = 'gb200_unified_suite'  // 自动加载 testlists/gb200_unified_suite.yml
FILTER_MODE = 'single-agg'        // 只运行 single-agg 测试
```

### 方式 2：使用 TXT Debug 列表

```groovy
// 在 Jenkins UI 中选择
TESTLIST = 'debug_single_agg'     // 自动加载 testlists/debug_single_agg.txt
FILTER_MODE = 'all'               // TXT 格式通常不需要过滤
```

### 方式 3：手动模式（单个配置）

```groovy
// 在 Jenkins UI 中选择
TESTLIST = 'manual'
CONFIG_FILE = 'deepseek_r1_fp4_v2_blackwell'
MANUAL_TEST_MODE = 'single-agg'
```

---

## 📝 快速 Debug 工作流

### 场景：某个测试失败，需要单独重跑

#### 步骤 1：从 CI 日志中复制 pytest 路径

```bash
# 从失败日志中找到类似这样的行：
FAILED perf/test_perf.py::test_perf[gpt_next_2b-float16-input_output_len:128,8]
```

#### 步骤 2：创建或编辑 TXT 文件

```bash
# 编辑 jenkins_test/testlists/debug_single_agg.txt
vim jenkins_test/testlists/debug_single_agg.txt

# 添加失败的测试路径
perf/test_perf.py::test_perf[gpt_next_2b-float16-input_output_len:128,8]
```

#### 步骤 3：在 Jenkins 中重跑

```groovy
TESTLIST = 'debug_single_agg'
CLUSTER = 'gb200'
FILTER_MODE = 'all'
```

#### 步骤 4：验证修复后删除

```bash
# 验证通过后，从 TXT 文件中删除该行
# 或注释掉：
# perf/test_perf.py::test_perf[gpt_next_2b-float16-input_output_len:128,8]  # 已修复
```

---

## 🔧 高级用法

### 1. 混合使用 YAML 和 TXT

```bash
# 生产环境：使用 YAML
jenkins_job --testlist gb200_unified_suite --mode single-agg

# Debug：使用 TXT
jenkins_job --testlist debug_single_agg
```

### 2. 从 pytest 批量收集失败测试

```bash
# 运行测试并收集失败的 case
pytest --collect-only -q | grep "test_perf" > failed_tests.txt

# 编辑 failed_tests.txt，添加到 jenkins_test/testlists/
mv failed_tests.txt jenkins_test/testlists/debug_failed.txt
```

### 3. 动态生成 TXT 列表

```python
# 从 CI 结果生成 debug 列表
import json

with open('test_results.json') as f:
    results = json.load(f)

failed_tests = [t['nodeid'] for t in results if t['outcome'] == 'failed']

with open('jenkins_test/testlists/auto_debug.txt', 'w') as f:
    f.write("# Auto-generated from CI failures\n")
    for test in failed_tests:
        f.write(f"{test}\n")
```

---

## 🧪 测试和验证

### 1. 验证 YAML 格式

```bash
# 解析并显示统计
python3 scripts/parse_unified_testlist.py testlists/gb200_unified_suite.yml --summary

# 输出：
# ============================================================
# 测试统计信息 (格式: YAML)
# ============================================================
# 总测试数:       15
#   single-agg:   10
#   multi-agg:    3
#   disagg:       2
# ============================================================
```

### 2. 验证 TXT 格式

```bash
# 解析并显示统计
python3 scripts/parse_unified_testlist.py testlists/debug_single_agg.txt --summary

# 输出：
# ============================================================
# 测试统计信息 (格式: TXT)
# ============================================================
# 总测试数:       8
#   single-agg:   8
#   multi-agg:    0
#   disagg:       0
# ============================================================
```

### 3. 查看解析结果（JSON）

```bash
# YAML 格式
python3 scripts/parse_unified_testlist.py testlists/gb200_unified_suite.yml

# TXT 格式
python3 scripts/parse_unified_testlist.py testlists/debug_single_agg.txt
```

---

## ⚠️ 注意事项

### YAML 格式注意事项

1. **必须是有效的 YAML 语法**
   ```yaml
   # ❌ 错误：缩进不一致
   tests:
     - name: "test1"
    config_file: "config1"  # 缩进错误
   
   # ✅ 正确
   tests:
     - name: "test1"
       config_file: "config1"
   ```

2. **config_file 必须存在**
   - YAML 中的 `config_file` 必须在以下路径存在：
     - `tests/integration/defs/perf/agg/`
     - `tests/scripts/perf-sanity/`

### TXT 格式注意事项

1. **自动识别机制（新特性）**
   - ✅ 大多数情况下无需手动标记
   - ✅ 自动读取配置文件分析测试类型
   - ✅ 支持手动标记覆盖自动识别
   
   ```txt
   # ✅ 自动识别（推荐）
   test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
   
   # ⚠️ 手动标记（仅在自动识别不准确时使用）
   test_perf_sanity.py::test_e2e[custom_case]  # mode:multi-agg
   ```

2. **pytest 路径必须有效**
   ```txt
   # ✅ 正确
   test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
   
   # ❌ 错误：缺少 ::
   test_perf_sanity.py test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
   ```

3. **注释和空行会被忽略**
   ```txt
   # 这是注释
   
   test_perf_sanity.py::test_e2e[test_case1]  # 这也是注释
   ```

4. **配置文件必须存在**
   - 自动识别需要读取 `tests/scripts/perf-sanity/{config_yml}.yaml`
   - 如果配置文件不存在，会回退到命名规则推断

---

## 🎓 最佳实践

### 1. 测试套件组织

```
jenkins_test/testlists/
├── production/
│   ├── gb200_full_suite.yml          # 完整测试套件
│   ├── gb200_smoke_suite.yml         # 冒烟测试
│   └── gb200_regression_suite.yml    # 回归测试
├── debug/
│   ├── debug_single_agg.txt          # Debug single-agg
│   ├── debug_multi_agg.txt           # Debug multi-agg
│   └── debug_disagg.txt              # Debug disagg
└── experiments/
    └── new_features.txt              # 实验性测试
```

### 2. 命名规范

**YAML 文件**：
- `{platform}_{suite_type}_suite.yml`
- 例如：`gb200_unified_suite.yml`, `gb300_smoke_suite.yml`

**TXT 文件**：
- `debug_{mode}.txt`
- 例如：`debug_single_agg.txt`, `debug_failed_tests.txt`

### 3. 版本控制

```bash
# YAML 文件：提交到 Git
git add jenkins_test/testlists/gb200_unified_suite.yml
git commit -m "Add GB200 unified test suite"

# TXT 文件：通常不提交（个人 debug 用）
echo "testlists/debug_*.txt" >> .gitignore
```

---

## 📚 相关文档

- [QUICK_START.md](./QUICK_START.md) - 快速开始
- [TEST_PROCESS.md](./TEST_PROCESS.md) - 测试流程
- [ARCHITECTURE_CHANGES.md](./docs/ARCHITECTURE_CHANGES.md) - 架构说明

---

**最后更新**: 2026-01-31  
**维护者**: TensorRT-LLM Performance Team
