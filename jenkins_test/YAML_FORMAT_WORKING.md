# YAML Testlist 格式工作原理详解

## 📋 概览

当你指定 YAML 格式的 testlist（如 `gb200_2nodes_perf.yml`）时，`parse_unified_testlist.py` 会使用**完全不同**的解析逻辑。

---

## 🔄 两种格式对比

### TXT 格式 vs YAML 格式

| 特性 | TXT 格式 | YAML 格式 |
|------|---------|----------|
| **文件内容** | pytest 路径列表 | 结构化配置 + pytest 路径 |
| **模式识别** | 从 test_id 推断 | 从 YAML 结构推断 |
| **配置文件读取** | ✅ 需要读取 | ❌ 不需要 |
| **适用场景** | Debug、手动测试 | CI、自动化测试 |

---

## 📊 YAML 格式结构

### 完整示例

```yaml
# gb200_2nodes_perf.yml
version: 0.0.1
gb200_multi_agg_2nodes_perf:  # ← suite 名称
- condition:  # ← 测试条件（可选）
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
      # nodes: 2  # ← 如果有这个字段，会被识别为 multi-agg
  
  tests:  # ← 测试列表
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_8k1k]
```

---

## 🔍 YAML 解析流程详解

### 步骤 1: 文件格式识别

```python
# parse_unified_testlist.py (第 404-420 行)

def parse_testlist(testlist_file, mode_filter=None):
    """自动识别格式并解析"""
    
    # 根据扩展名选择解析器
    ext = os.path.splitext(testlist_file)[1].lower()
    
    if ext in ['.yml', '.yaml']:
        return parse_yaml_testlist(testlist_file, mode_filter)  # ← YAML 解析器
    elif ext == '.txt':
        return parse_txt_testlist(testlist_file, mode_filter)   # ← TXT 解析器
```

### 步骤 2: 解析 YAML 结构

```python
# parse_unified_testlist.py (第 193-240 行)

def parse_yaml_testlist(testlist_file, mode_filter=None):
    """解析 YAML 格式的 testlist 文件"""
    
    # 读取 YAML 文件
    with open(testlist_file, 'r') as f:
        data = yaml.safe_load(f)
    
    # YAML 结构：
    # {
    #   "gb200_multi_agg_2nodes_perf": [
    #     {
    #       "condition": {...},
    #       "tests": [...]
    #     }
    #   ]
    # }
    
    # 获取 suite 名称（第一个 key）
    suite_name = list(data.keys())[0]  # "gb200_multi_agg_2nodes_perf"
    suite_data = data[suite_name]       # [{"condition": ..., "tests": ...}]
    
    # suite_data 可能是：
    # 1. 列表（包含多个测试组）
    # 2. 字典（单个测试组）
    
    # 如果是列表，遍历每个测试组
    if isinstance(suite_data, list):
        for test_group in suite_data:
            tests = test_group.get('tests', [])
            # 处理每个测试
    else:
        tests = suite_data.get('tests', [])
```

### 步骤 3: 识别测试模式

```python
# parse_unified_testlist.py (第 162-190 行)

def identify_test_mode(test):
    """
    从 YAML 结构识别测试模式
    
    ⚠️ 关键：这里不读取配置文件！
    只看 YAML 中的字段
    """
    
    # 规则 1: 检查 test_type 字段
    if test.get('test_type') == 'disagg':
        return 'disagg'
    
    # 规则 2: 检查 condition.terms.nodes 字段
    condition = test.get('condition', {})
    terms = condition.get('terms', {})
    
    if 'nodes' in terms:
        nodes_count = int(terms['nodes'])
        if nodes_count > 1:
            return 'multi-agg'  # ← 多节点
    
    # 规则 3: 默认为 single-agg
    return 'single-agg'
```

---

## 🎯 关键区别：YAML vs TXT

### YAML 格式的模式识别

```yaml
# gb200_2nodes_perf.yml
- condition:
    terms:
      nodes: 2  # ← 直接从这里读取！
  tests:
  - perf/test_perf_sanity.py::test_e2e[...]
```

**识别逻辑：**
```python
# 不需要解析 test_id！
# 不需要读取配置文件！
# 直接从 YAML 的 condition.terms.nodes 判断

if condition['terms']['nodes'] == 2:
    return 'multi-agg'  # ✅ 快速识别
```

### TXT 格式的模式识别

```txt
# debug_cases.txt
test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]
```

**识别逻辑：**
```python
# 步骤 1: 解析 test_id
test_id = "aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k"
parts = test_id.split('-')
config_yml = parts[1]  # "deepseek_r1_fp4_v2_2_nodes_grace_blackwell"

# 步骤 2: 读取配置文件
config_file = f"tests/scripts/perf-sanity/{config_yml}.yaml"
config = yaml.safe_load(open(config_file))  # ← 需要读取！

# 步骤 3: 计算 GPU 需求
hardware = config['hardware']
gpus_per_node = hardware['gpus_per_node']  # 4

server_config = config['server_configs'][0]
total_gpus = tp * ep * pp * cp  # 64

# 步骤 4: 判断
if total_gpus > gpus_per_node:
    return 'multi-agg'  # 64 > 4 ✅
```

---

## 📊 实际运行示例

### 示例 1: 解析 YAML 文件

```bash
cd jenkins_test
python3 scripts/parse_unified_testlist.py testlists/multi_agg/gb200_2nodes_perf.yml --summary
```

**解析流程：**

```python
# 1. 识别文件格式
file = "testlists/multi_agg/gb200_2nodes_perf.yml"
ext = ".yml"  # → 使用 parse_yaml_testlist()

# 2. 读取 YAML
data = {
    "gb200_multi_agg_2nodes_perf": [
        {
            "condition": {
                "terms": {"stage": "post_merge", "backend": "pytorch"}
                # ⚠️ 注意：这里没有 "nodes" 字段！
            },
            "tests": [
                "perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]",
                ...
            ]
        }
    ]
}

# 3. 遍历测试
for test_group in data["gb200_multi_agg_2nodes_perf"]:
    for test_path in test_group["tests"]:
        # ⚠️ 问题：YAML 中没有 nodes 字段
        # 如何判断是 multi-agg？
        
        # 选项 1: 从文件名推断（"2nodes" in filename）
        # 选项 2: 从 suite 名称推断（"multi_agg" in suite_name）
        # 选项 3: 解析 test_path 中的 test_id（回到 TXT 格式的逻辑）
```

---

## ⚠️ 当前实现的问题

### 问题：YAML 中的测试如何识别模式？

**当前实现（第 162-190 行）：**

```python
def identify_test_mode(test):
    # test 是什么？
    # 在 YAML 格式中，test 可能是：
    # 1. 字符串：pytest 路径
    # 2. 字典：包含 condition 和其他字段
    
    if test.get('test_type') == 'disagg':
        return 'disagg'
    
    # ⚠️ 问题：如果 test 是字符串，get() 会报错！
    condition = test.get('condition', {})  # AttributeError: 'str' object has no attribute 'get'
```

### 实际的 YAML 结构

```yaml
gb200_multi_agg_2nodes_perf:
- condition:  # ← 这是测试组级别的
    terms:
      stage: post_merge
  tests:  # ← 这是字符串列表！
  - "perf/test_perf_sanity.py::test_e2e[...]"  # ← 字符串，不是字典
  - "perf/test_perf_sanity.py::test_e2e[...]"
```

**所以 `identify_test_mode(test)` 收到的是字符串！**

---

## 🔧 正确的解析逻辑

### 修正后的流程

```python
def parse_yaml_testlist(testlist_file, mode_filter=None):
    with open(testlist_file, 'r') as f:
        data = yaml.safe_load(f)
    
    suite_name = list(data.keys())[0]
    suite_data = data[suite_name]
    
    tests_by_mode = {
        'single-agg': [],
        'multi-agg': [],
        'disagg': []
    }
    
    # 遍历测试组
    for test_group in suite_data:
        # 从测试组级别获取 condition
        condition = test_group.get('condition', {})
        terms = condition.get('terms', {})
        
        # 判断整个测试组的模式
        if 'nodes' in terms and int(terms['nodes']) > 1:
            group_mode = 'multi-agg'
        elif 'test_type' in test_group and test_group['test_type'] == 'disagg':
            group_mode = 'disagg'
        else:
            group_mode = 'single-agg'
        
        # 这个测试组中的所有测试都是同一模式
        for test_path in test_group.get('tests', []):
            # test_path 是字符串，例如：
            # "perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]"
            
            tests_by_mode[group_mode].append({
                'name': test_path,
                'pytest_path': test_path,
                'test_type': group_mode
            })
```

---

## 🎯 实际行为（当前代码）

### 当前代码问题分析

看代码第 249-256 行：

```python
for test in tests:
    test_mode = identify_test_mode(test)  # ← test 是什么？
    
    if mode_filter and test_mode != mode_filter:
        continue
    
    tests_by_mode[test_mode].append(test)
```

**问题：`tests` 是从哪里来的？**

看第 240 行：

```python
tests = suite_data['tests']
```

**但是 `suite_data` 不是字典，是列表！**

```yaml
gb200_multi_agg_2nodes_perf:  # ← suite_name
- condition:  # ← suite_data[0]
    ...
  tests:      # ← suite_data[0]['tests']
  - "..."     # ← 这才是测试
```

**所以当前代码有 Bug！应该是：**

```python
# 错误：
tests = suite_data['tests']  # ❌ suite_data 是列表，没有 'tests' key

# 正确：
for test_group in suite_data:
    tests = test_group.get('tests', [])
```

---

## 📝 完整的正确实现

### 建议的修复

```python
def parse_yaml_testlist(testlist_file, mode_filter=None):
    """解析 YAML 格式的 testlist 文件"""
    
    with open(testlist_file, 'r') as f:
        data = yaml.safe_load(f)
    
    suite_name = list(data.keys())[0]
    suite_data = data[suite_name]
    
    # 确保是列表
    if not isinstance(suite_data, list):
        suite_data = [suite_data]
    
    tests_by_mode = {
        'single-agg': [],
        'multi-agg': [],
        'disagg': []
    }
    
    # 遍历测试组
    for test_group in suite_data:
        # 从测试组获取条件
        condition = test_group.get('condition', {})
        terms = condition.get('terms', {})
        
        # 判断测试组的模式
        if test_group.get('test_type') == 'disagg':
            group_mode = 'disagg'
        elif 'nodes' in terms and int(terms.get('nodes', 1)) > 1:
            group_mode = 'multi-agg'
        else:
            # 如果 YAML 中没有明确指定，从 test_path 推断
            test_paths = test_group.get('tests', [])
            if test_paths:
                # 取第一个测试，从 test_id 推断
                first_test = test_paths[0]
                if '[' in first_test and ']' in first_test:
                    test_id = first_test.split('[')[1].split(']')[0]
                    group_mode = infer_test_mode_from_config(test_id)
                else:
                    group_mode = 'single-agg'
            else:
                group_mode = 'single-agg'
        
        # 应用过滤器
        if mode_filter and group_mode != mode_filter:
            continue
        
        # 添加所有测试到对应模式
        for test_path in test_group.get('tests', []):
            tests_by_mode[group_mode].append({
                'name': test_path,
                'pytest_path': test_path,
                'config_file': test_path,
                'source_file': testlist_file,
                'test_type': group_mode
            })
    
    # 统计信息
    statistics = {
        'total': sum(len(tests) for tests in tests_by_mode.values()),
        'single-agg': len(tests_by_mode['single-agg']),
        'multi-agg': len(tests_by_mode['multi-agg']),
        'disagg': len(tests_by_mode['disagg'])
    }
    
    return {
        'format': 'yaml',
        'tests_by_mode': tests_by_mode,
        'statistics': statistics
    }
```

---

## ✅ 总结

### YAML 格式的工作原理

1. **读取 YAML 文件**：解析整个结构
2. **遍历测试组**：每个测试组有自己的 `condition` 和 `tests`
3. **识别模式**：
   - 优先从 `condition.terms.nodes` 识别
   - 次选从 `test_type` 字段识别
   - 最后从 `test_path` 中的 `test_id` 推断（使用 TXT 格式的逻辑）
4. **分组输出**：按 single-agg/multi-agg/disagg 分组

### 当前代码的问题

❌ **第 236-240 行有 Bug**：
```python
if not isinstance(suite_data, dict) or 'tests' not in suite_data:
    print(f"错误: 未找到 tests 列表", file=sys.stderr)
    sys.exit(1)

tests = suite_data['tests']  # ← 错误！suite_data 是列表
```

应该是：
```python
if not isinstance(suite_data, list):
    suite_data = [suite_data]

for test_group in suite_data:
    tests = test_group.get('tests', [])
```

---

## 📚 相关文档

- **YAML 格式详解**：本文档
- **TXT 格式详解**：`EXECUTION_CHAIN_DETAILED.md`
- **配置文件结构**：`EXECUTION_CHAIN_QUICK_REF.md`

---

**建议：修复 `parse_yaml_testlist()` 函数以正确处理 YAML 格式！**
