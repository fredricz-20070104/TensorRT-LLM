# TestList 快速参考

## 📝 两种格式对比

| 格式 | 文件扩展名 | 使用场景 | 示例 |
|------|----------|---------|------|
| **YAML** | `.yml`, `.yaml` | 生产环境、CI/CD | `gb200_unified_suite.yml` |
| **TXT** | `.txt` | Debug、快速测试 | `debug_single_agg.txt` |

---

## 🚀 快速使用

### YAML 格式（结构化）

```yaml
# testlists/gb200_unified_suite.yml
gb200_unified_perf_suite:
  tests:
    - name: "DeepSeek-R1 FP4"
      config_file: "deepseek_r1_fp4_v2_blackwell"
      condition:
        terms:
          nodes: 1  # single-agg
    
    - name: "Llama3.1-70B Multi-Node"
      config_file: "llama3.1_70b_tp4"
      condition:
        terms:
          nodes: 2  # multi-agg
    
    - name: "Disagg Test"
      config_file: "llama3.1_70b_disagg"
      test_type: disagg
```

**在 Jenkins 中使用**:
```
TESTLIST = 'gb200_unified_suite'
FILTER_MODE = 'single-agg'  # 或 'all', 'multi-agg', 'disagg'
```

---

### TXT 格式（快速 Debug）

```txt
# testlists/debug_cases.txt
# 支持所有测试类型，通过模式标记区分

# ============================================
# Single-Agg（默认，不需要标记）
# ============================================
perf/test_perf.py::test_perf[gpt_next_2b-float16-input_output_len:128,8]
perf/test_perf.py::test_perf[llama3_8b-float16-tp1-input_len:512]
accuracy/test_llm_api_pytorch.py::TestLlama3_1_8B::test_nvfp4

# ============================================
# Multi-Agg（多节点，需要标记）
# ============================================
perf/test_perf.py::test_perf[llama3_70b-tp4-input_len:2048]  # mode:multi-agg

# ============================================
# Disagg（分离式，需要标记）
# ============================================
perf/test_perf.py::test_perf[llama3_70b_disagg-input_len:1024]  # mode:disagg
```

**在 Jenkins 中使用**:
```
TESTLIST = 'debug_cases'    # 一个文件支持所有类型
FILTER_MODE = 'all'         # 或过滤特定类型（single-agg/multi-agg/disagg）
```

---

## 🎯 常见场景

### 场景 1: 运行完整测试套件

```yaml
# Jenkins 参数
TESTLIST: gb200_unified_suite
FILTER_MODE: all
PYTEST_K: (留空)
```

### 场景 2: 只运行 single-agg 测试

```yaml
# Jenkins 参数
TESTLIST: gb200_unified_suite
FILTER_MODE: single-agg
PYTEST_K: (留空)
```

### 场景 3: Debug 单个失败的测试（任何类型）

**步骤 1**: 从失败日志复制 pytest 路径
```
FAILED perf/test_perf.py::test_perf[gpt_next_2b-float16-input_len:128]        # single-agg
FAILED perf/test_perf.py::test_perf[llama3_70b-tp4-input_len:2048]            # multi-agg
FAILED perf/test_perf.py::test_perf[llama3_70b_disagg-input_len:1024]         # disagg
```

**步骤 2**: 编辑 `testlists/debug_cases.txt`
```txt
# Single-Agg（默认，不需要标记）
perf/test_perf.py::test_perf[gpt_next_2b-float16-input_len:128]

# Multi-Agg（需要标记）
perf/test_perf.py::test_perf[llama3_70b-tp4-input_len:2048]  # mode:multi-agg

# Disagg（需要标记）
perf/test_perf.py::test_perf[llama3_70b_disagg-input_len:1024]  # mode:disagg
```

**步骤 3**: 在 Jenkins 中运行
```yaml
TESTLIST: debug_cases
FILTER_MODE: all  # 或指定类型过滤
```

### 场景 4: 使用 pytest -k 过滤

```yaml
# Jenkins 参数
TESTLIST: gb200_unified_suite
FILTER_MODE: single-agg
PYTEST_K: deepseek  # 只运行包含 "deepseek" 的测试
```

### 场景 5: 手动指定配置

```yaml
# Jenkins 参数
TESTLIST: manual
CONFIG_FILE: deepseek_r1_fp4_v2_blackwell
MANUAL_TEST_MODE: single-agg
```

---

## 🔍 测试类型识别

### YAML 格式自动识别

```yaml
# Single-Agg: nodes=1 或无 nodes
- name: "Test"
  config_file: "config"
  condition:
    terms:
      nodes: 1

# Multi-Agg: nodes>1 且无 test_type
- name: "Test"
  config_file: "config"
  condition:
    terms:
      nodes: 2

# Disagg: test_type=disagg
- name: "Test"
  config_file: "config"
  test_type: disagg
  condition:
    terms:
      nodes: 3
```

### TXT 格式手动标记

```txt
# 默认 single-agg（不需要标记）
perf/test_perf.py::test_case1

# Multi-Agg（需要标记）
perf/test_perf.py::test_case2  # mode:multi-agg

# Disagg（需要标记）
perf/test_perf.py::test_case3  # mode:disagg
```

---

## 🧪 验证命令

```bash
# 解析 YAML 并显示统计
python3 scripts/parse_unified_testlist.py testlists/gb200_unified_suite.yml --summary

# 解析 TXT 并显示统计
python3 scripts/parse_unified_testlist.py testlists/debug_single_agg.txt --summary

# 只解析 single-agg 测试
python3 scripts/parse_unified_testlist.py testlists/gb200_unified_suite.yml --mode single-agg --summary

# 查看 JSON 输出
python3 scripts/parse_unified_testlist.py testlists/gb200_unified_suite.yml | jq .
```

---

## 💡 最佳实践

### DO ✅

- ✅ 生产环境使用 YAML 格式
- ✅ Debug 时使用 TXT 格式
- ✅ YAML 文件提交到 Git
- ✅ 为测试添加有意义的名称
- ✅ 使用 `--summary` 验证解析结果

### DON'T ❌

- ❌ TXT 文件不要提交到 Git（个人 debug 用）
- ❌ 不要在 YAML 中使用 pytest 路径作为 config_file
- ❌ 不要混淆测试类型（TXT 中忘记标记 mode）
- ❌ 不要在 TXT 中使用复杂的测试套件管理

---

## 📚 详细文档

完整文档请参考: [TESTLIST_FORMAT_GUIDE.md](./TESTLIST_FORMAT_GUIDE.md)
