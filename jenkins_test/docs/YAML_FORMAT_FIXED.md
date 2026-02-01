# YAML Testlist 格式完整指南

## ✅ 修复完成

已成功修复 `parse_unified_testlist.py` 中 YAML 格式的解析问题！

---

## 🎯 YAML 格式如何工作

### 文件结构

```yaml
# testlists/multi_agg/gb200_2nodes_perf.yml
version: 0.0.1  # ← 可选的版本字段

gb200_multi_agg_2nodes_perf:  # ← Suite 名称
- condition:  # ← 测试组 1
    ranges:
      system_gpu_count:
        gte: 8
        lte: 8
    wildcards:
      gpu:
      - '*gb200*'
    terms:
      stage: post_merge
      backend: pytorch
      # nodes: 2  # ← 如果有这个字段，直接识别为 multi-agg
  
  tests:  # ← 这个测试组的所有测试
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_8k1k]
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_tep8_mtp3]
```

---

## 🔄 解析流程

### 步骤 1: 识别文件格式

```python
# 根据扩展名
if file.endswith('.yml') or file.endswith('.yaml'):
    parse_yaml_testlist()  # ← YAML 解析器
else:
    parse_txt_testlist()   # ← TXT 解析器
```

### 步骤 2: 读取 YAML 并找到 Suite

```python
with open(testlist_file, 'r') as f:
    data = yaml.safe_load(f)

# data = {
#   "version": "0.0.1",
#   "gb200_multi_agg_2nodes_perf": [...]
# }

# 跳过 "version" 字段，找到 suite 名称
suite_name = None
for key in data.keys():
    if key != 'version':
        suite_name = key  # "gb200_multi_agg_2nodes_perf"
        break

suite_data = data[suite_name]  # 列表或字典
```

### 步骤 3: 处理两种 YAML 结构

#### 结构 A: 列表格式（常用）

```yaml
suite_name:
- condition:
    terms:
      nodes: 2  # ← 从这里识别 multi-agg
  tests:
  - "test1"
  - "test2"
```

**解析逻辑：**

```python
if isinstance(suite_data, list):
    for test_group in suite_data:
        # 从 condition.terms.nodes 判断
        terms = test_group['condition']['terms']
        
        if 'nodes' in terms and int(terms['nodes']) > 1:
            group_mode = 'multi-agg'
        else:
            # 从第一个测试的 test_id 推断
            first_test = test_group['tests'][0]
            test_id = extract_test_id(first_test)
            group_mode = infer_test_mode_from_config(test_id)
        
        # 这个组的所有测试都是同一模式
        for test_path in test_group['tests']:
            tests_by_mode[group_mode].append(test_path)
```

#### 结构 B: 字典格式（少见）

```yaml
suite_name:
  condition:
    terms:
      nodes: 2
  tests:
  - "test1"
  - "test2"
```

**解析逻辑：**

```python
elif isinstance(suite_data, dict):
    # 从 condition.terms.nodes 判断
    terms = suite_data['condition']['terms']
    
    if 'nodes' in terms and int(terms['nodes']) > 1:
        suite_mode = 'multi-agg'
    else:
        suite_mode = 'single-agg'
    
    # 所有测试都是同一模式
    for test_path in suite_data['tests']:
        tests_by_mode[suite_mode].append(test_path)
```

### 步骤 4: 模式识别逻辑

```
优先级 1: condition.terms.nodes 字段
  ├─ nodes > 1 → multi-agg
  └─ nodes == 1 → single-agg

优先级 2: test_type 字段
  └─ test_type == 'disagg' → disagg

优先级 3: 从 test_path 推断
  ├─ 提取 test_id（[aggr_upload-config-server_name]）
  ├─ 读取配置文件
  ├─ 计算 GPU 需求
  └─ total_gpus > gpus_per_node → multi-agg

优先级 4: 默认
  └─ single-agg
```

---

## 📊 测试结果

```bash
cd jenkins_test

# 测试 Multi-Agg YAML
python3 scripts/parse_unified_testlist.py testlists/multi_agg/gb200_2nodes_perf.yml --summary
```

**输出：**

```
============================================================
测试统计信息 (格式: YAML)
============================================================
总测试数:       5
  single-agg:   0
  multi-agg:    5  ✅ 正确识别为 multi-agg
  disagg:       0
============================================================
```

**测试用例：**

```
✅ aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k
✅ aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_8k1k
✅ aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_tep8_mtp3
✅ aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_tep8_32k8k
✅ aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_dep8_32k8k
```

---

## 🔧 修复的问题

### 问题 1: 未跳过 "version" 字段

**错误：**

```python
# 获取第一个 key
suite_name = list(data.keys())[0]  # ❌ 可能是 "version"
```

**修复：**

```python
# 跳过 "version" 字段
suite_name = None
for key in data.keys():
    if key != 'version':
        suite_name = key
        break
```

### 问题 2: 未处理列表格式

**错误：**

```python
if not isinstance(suite_data, dict) or 'tests' not in suite_data:
    print("错误: 未找到 tests 列表")
    sys.exit(1)

tests = suite_data['tests']  # ❌ suite_data 是列表
```

**修复：**

```python
if isinstance(suite_data, list):
    # 处理列表格式
    for test_group in suite_data:
        tests = test_group.get('tests', [])
        ...
elif isinstance(suite_data, dict):
    # 处理字典格式
    tests = suite_data.get('tests', [])
    ...
```

### 问题 3: identify_test_mode() 收到字符串

**错误：**

```python
for test in tests:
    test_mode = identify_test_mode(test)  # ❌ test 是字符串

def identify_test_mode(test):
    condition = test.get('condition', {})  # AttributeError: 'str' has no get
```

**修复：**

```python
# 在测试组级别判断模式，而不是单个测试级别
for test_group in suite_data:
    condition = test_group.get('condition', {})  # ✅ test_group 是字典
    group_mode = determine_mode(condition)
    
    for test_path in test_group.get('tests', []):
        # test_path 是字符串，直接使用 group_mode
        tests_by_mode[group_mode].append(test_path)
```

---

## 🆚 YAML vs TXT 对比总结

| 特性 | YAML 格式 | TXT 格式 |
|------|----------|---------|
| **结构** | 结构化（condition + tests） | 纯文本列表 |
| **模式识别** | 从 condition.terms.nodes | 读取配置文件计算 |
| **配置文件读取** | ❌ 不需要（大部分情况） | ✅ 总是需要 |
| **性能** | ⚡ 快（不读取配置文件） | 🐢 慢（读取多个配置文件） |
| **适用场景** | CI、test-db | Debug、手动测试 |
| **推荐度** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |

---

## 💡 最佳实践

### 推荐使用 YAML 格式

**原因：**

1. ✅ **明确的模式标记**：通过 `condition.terms.nodes` 直接指定
2. ✅ **性能更好**：不需要读取配置文件
3. ✅ **结构化**：包含条件、超时等元数据
4. ✅ **test-db 兼容**：与测试数据库系统集成

**示例：**

```yaml
version: 0.0.1
my_test_suite:
- condition:
    ranges:
      system_gpu_count:
        gte: 8  # 需要 8 个 GPU
        lte: 8
    wildcards:
      gpu:
      - '*gb200*'  # 只在 GB200 上运行
    terms:
      stage: post_merge  # 只在 post-merge 运行
      backend: pytorch
      nodes: 2  # ← 明确指定 2 个节点
  
  tests:
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k] TIMEOUT (90)
```

### TXT 格式的使用场景

适合：
- ✅ 快速 debug
- ✅ 手动测试
- ✅ 临时测试列表

不适合：
- ❌ 大规模 CI
- ❌ 需要条件筛选
- ❌ 需要元数据（超时、阶段等）

---

## 🎯 结论

✅ **YAML 格式的解析已经完全正常工作！**

- 正确跳过 `version` 字段
- 正确处理列表格式
- 正确从 `condition.terms.nodes` 识别模式
- 备用方案：从 test_id 推断（当 nodes 未指定时）

**测试验证：✅ 通过**

```
总测试数: 5
  multi-agg: 5  ← 全部正确识别
```
