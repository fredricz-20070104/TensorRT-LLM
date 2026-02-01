# TXT 格式支持所有测试类型

## 🎯 核心改进

**之前的误导性设计**：
```
testlists/
├── debug_single_agg.txt    # ❌ 暗示只能用于 single-agg
├── debug_multi_agg.txt     # ❌ 需要多个文件
└── debug_disagg.txt        # ❌ 管理复杂
```

**现在的统一设计**：
```
testlists/
└── debug_cases.txt         # ✅ 一个文件支持所有类型
```

---

## ✅ 设计理念

### 核心原则

> **"只要能找到对应的配置文件就行"**

TXT 格式不应该按测试类型分文件，而应该：
- ✅ 支持所有三种测试类型
- ✅ 通过模式标记区分
- ✅ 一个文件管理所有 debug 测试

---

## 📝 完整示例

### `testlists/debug_cases.txt` - 统一的 Debug 文件

```txt
# Debug Test Cases - 支持所有测试类型
# 从 pytest 输出或 CI 日志直接复制粘贴

# ============================================
# Single-Agg 测试（默认，不需要标记）
# ============================================
perf/test_perf.py::test_perf[gpt_next_2b-float16-input_output_len:128,8]
perf/test_perf.py::test_perf[llama3_8b-float16-tp1-input_len:512]
accuracy/test_llm_api_pytorch.py::TestLlama3_1_8B::test_nvfp4

# ============================================
# Multi-Agg 测试（多节点，需要标记）
# ============================================
perf/test_perf.py::test_perf[llama3_70b-tp4-input_len:2048]  # mode:multi-agg
perf/test_perf.py::test_perf[llama3_70b-tp4-input_len:4096]  # mode:multi-agg

# ============================================
# Disagg 测试（分离式，需要标记）
# ============================================
perf/test_perf.py::test_perf[llama3_70b_disagg-input_len:1024]  # mode:disagg
perf/test_perf.py::test_perf[llama3_70b_disagg-input_len:2048]  # mode:disagg

# ============================================
# 混合场景：一个文件支持所有类型
# ============================================
perf/test_perf.py::test_perf[model_a-single_node]
perf/test_perf.py::test_perf[model_b-multi_node]  # mode:multi-agg
perf/test_perf.py::test_perf[model_c-disagg]  # mode:disagg
```

---

## 🔍 测试类型识别

### 规则

```python
# 解析每一行
for line in txt_file:
    if '# mode:multi-agg' in line:
        test_type = 'multi-agg'
    elif '# mode:disagg' in line:
        test_type = 'disagg'
    else:
        test_type = 'single-agg'  # 默认
```

### 示例

```txt
# 默认 single-agg（80% 的测试）
perf/test_perf.py::test_case1

# 明确 multi-agg（15% 的测试）
perf/test_perf.py::test_case2  # mode:multi-agg

# 明确 disagg（5% 的测试）
perf/test_perf.py::test_case3  # mode:disagg
```

---

## 🚀 使用场景

### 场景 1: 混合类型 Debug

```txt
# 从 CI 失败日志收集的各种类型测试
perf/test_perf.py::test_perf[gpt_2b]              # single-agg
perf/test_perf.py::test_perf[llama_70b_tp4]       # mode:multi-agg
perf/test_perf.py::test_perf[llama_70b_disagg]    # mode:disagg
```

**Jenkins 参数**：
```
TESTLIST = 'debug_cases'
FILTER_MODE = 'all'  # 运行所有类型
```

### 场景 2: 只运行特定类型

```txt
# 文件中有多种类型
perf/test_perf.py::test_case1
perf/test_perf.py::test_case2  # mode:multi-agg
perf/test_perf.py::test_case3  # mode:disagg
```

**Jenkins 参数**：
```
TESTLIST = 'debug_cases'
FILTER_MODE = 'multi-agg'  # 只运行 multi-agg（忽略其他类型）
```

### 场景 3: 快速重跑失败测试

从 CI 日志直接复制：
```bash
# 失败日志
FAILED tests/perf/test_perf.py::test_perf[gpt_2b] - single-agg
FAILED tests/perf/test_perf.py::test_perf[llama_70b] - multi-agg
FAILED tests/perf/test_perf.py::test_perf[llama_disagg] - disagg
```

粘贴到 `debug_cases.txt`：
```txt
tests/perf/test_perf.py::test_perf[gpt_2b]
tests/perf/test_perf.py::test_perf[llama_70b]  # mode:multi-agg
tests/perf/test_perf.py::test_perf[llama_disagg]  # mode:disagg
```

---

## 📊 优势对比

| 特性 | 旧设计（分文件） | 新设计（统一文件） |
|------|----------------|------------------|
| **文件数量** | 3 个 | 1 个 ✅ |
| **管理复杂度** | 高（需要分别编辑） | 低（一个文件） ✅ |
| **类型识别** | 文件名 | 模式标记 ✅ |
| **混合类型支持** | ❌ 不支持 | ✅ 支持 |
| **灵活性** | 低 | 高 ✅ |
| **易用性** | 中 | 高 ✅ |

---

## 🔧 实现细节

### 1. Jenkins Pipeline 参数

```groovy
choice(
    name: 'TESTLIST',
    choices: [
        'gb200_unified_suite',  // YAML
        'gb300_unified_suite',  // YAML
        'debug_cases',          // TXT（支持所有类型）⭐
        'manual'
    ],
    description: '''
🔧 TXT 格式 (.txt) - Debug 快速测试（支持所有类型）:
  • debug_cases: 统一的 Debug 文件
  • 支持所有测试类型（single-agg/multi-agg/disagg）
  • 通过模式标记区分
    '''
)
```

### 2. 解析脚本逻辑

```python
def parse_txt_testlist(testlist_file, mode_filter=None):
    """解析 TXT 格式，支持所有测试类型"""
    
    tests_by_mode = {
        'single-agg': [],
        'multi-agg': [],
        'disagg': []
    }
    
    for line in lines:
        # 跳过注释和空行
        if not line or line.startswith('#'):
            continue
        
        # 解析模式标记
        test_path = line
        test_mode = 'single-agg'  # 默认
        
        if '# mode:multi-agg' in line:
            test_mode = 'multi-agg'
            test_path = line.split('#')[0].strip()
        elif '# mode:disagg' in line:
            test_mode = 'disagg'
            test_path = line.split('#')[0].strip()
        
        # 应用过滤器
        if mode_filter and test_mode != mode_filter:
            continue
        
        tests_by_mode[test_mode].append({
            'pytest_path': test_path,
            'test_type': test_mode
        })
    
    return tests_by_mode
```

### 3. 过滤支持

```bash
# FILTER_MODE 参数仍然有效
TESTLIST = 'debug_cases'

# 运行所有类型
FILTER_MODE = 'all'

# 只运行 single-agg
FILTER_MODE = 'single-agg'

# 只运行 multi-agg
FILTER_MODE = 'multi-agg'

# 只运行 disagg
FILTER_MODE = 'disagg'
```

---

## 🎓 最佳实践

### DO ✅

- ✅ 使用一个 `debug_cases.txt` 管理所有 debug 测试
- ✅ 为 multi-agg 和 disagg 添加模式标记
- ✅ 从 CI 日志直接复制粘贴
- ✅ 使用注释组织不同类型的测试
- ✅ 验证通过后删除或注释掉测试

### DON'T ❌

- ❌ 不要创建多个 TXT 文件（`debug_single_agg.txt`, `debug_multi_agg.txt` 等）
- ❌ 不要忘记为 multi-agg 和 disagg 添加模式标记
- ❌ 不要将 debug TXT 文件提交到 Git（个人使用）
- ❌ 不要在 TXT 中使用 YAML 格式

---

## 📚 相关文档

- [TESTLIST_FORMAT_GUIDE.md](./TESTLIST_FORMAT_GUIDE.md) - 完整格式说明
- [TESTLIST_QUICK_REF.md](./TESTLIST_QUICK_REF.md) - 快速参考
- [QUICK_START.md](./QUICK_START.md) - 快速开始

---

**总结**: TXT 格式现在是真正统一的 debug 工具，支持所有三种测试类型，无需按类型分文件！🎉
