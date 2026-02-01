# TensorRT-LLM 性能测试 TestList 格式说明

## 🎯 核心理解

### test_perf_sanity.py::test_e2e 的工作原理

```python
# tests/integration/defs/perf/test_perf_sanity.py

@pytest.mark.parametrize("perf_sanity_test_case", PERF_SANITY_TEST_CASES)
def test_e2e(output_dir, perf_sanity_test_case):
    """
    性能测试的入口函数
    
    perf_sanity_test_case 格式:
    - Agg 模式: {test_type}-{config_yml}[-{server_config_name}]
    - Disagg 模式: {test_type}-{config_yml}
    
    示例:
    - "profiling-deepseek_r1_fp4_v2_blackwell"
    - "profiling-deepseek_r1_fp4_v2_blackwell-default_config"
    - "benchmark-llama3_70b_disagg"
    """
    config = PerfSanityTestConfig(perf_sanity_test_case, output_dir)
    ...
```

### 测试用例生成逻辑

```python
# Agg 测试类型
AGG_TEST_TYPES = ["profiling", "benchmark"]

# Disagg 测试类型
DISAGG_TEST_TYPES = ["benchmark"]

# 自动生成测试用例
def get_aggr_test_cases():
    """
    扫描 tests/scripts/perf-sanity/*.yaml
    为每个 YAML 和每个 test_type 生成测试用例
    
    如果 YAML 中定义了多个 server_configs，还会生成每个 server_config 的测试用例
    """
    test_cases = []
    for config_yml in yaml_files:
        for test_type in AGG_TEST_TYPES:
            # 运行所有 server configs
            test_cases.append(f"{test_type}-{config_yml}")
            
            # 运行单个 server config
            for server_name in server_names:
                test_cases.append(f"{test_type}-{config_yml}-{server_name}")
    return test_cases

def get_disagg_test_cases():
    """
    扫描 tests/integration/defs/perf/disagg/test_configs/disagg/perf/*.yaml
    为每个 YAML 和每个 test_type 生成测试用例
    """
    test_cases = []
    for config_yml in yaml_files:
        for test_type in DISAGG_TEST_TYPES:
            test_cases.append(f"{test_type}-{config_yml}")
    return test_cases
```

---

## 📝 TestList 格式

### 方式 1: pytest 路径格式（推荐 TXT）

```txt
# 完整的 pytest 路径（Jenkins L0_Test.groovy 使用的格式）
tests/integration/defs/perf/test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
tests/integration/defs/perf/test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_blackwell-default_config]
tests/integration/defs/perf/test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]
```

### 方式 2: 简化格式（可选）

```txt
# 只写参数部分（推荐用于快速 debug）
profiling-deepseek_r1_fp4_v2_blackwell
benchmark-deepseek_r1_fp4_v2_blackwell-default_config
benchmark-llama3_70b_disagg
```

### 方式 3: pytest -k 格式（推荐用于过滤）

```bash
# 使用 pytest -k 过滤
pytest tests/integration/defs/perf/test_perf_sanity.py -k "deepseek"
pytest tests/integration/defs/perf/test_perf_sanity.py -k "profiling and deepseek"
pytest tests/integration/defs/perf/test_perf_sanity.py -k "benchmark and not disagg"
```

---

## 🔍 测试用例命名规则

### Agg 模式（单节点或多节点聚合）

格式: `{test_type}-{config_yml}[-{server_config_name}]`

| 部分 | 说明 | 示例 |
|------|------|------|
| `test_type` | 测试类型 | `profiling`, `benchmark` |
| `config_yml` | YAML 配置文件名（不含扩展名） | `deepseek_r1_fp4_v2_blackwell` |
| `server_config_name` | 可选：server_config 名称 | `default_config`, `high_throughput` |

**配置文件位置**: `tests/scripts/perf-sanity/`

**示例**:
```txt
# 运行所有 server configs
profiling-deepseek_r1_fp4_v2_blackwell
benchmark-deepseek_r1_fp4_v2_blackwell

# 运行特定 server config
profiling-deepseek_r1_fp4_v2_blackwell-default_config
benchmark-deepseek_r1_fp4_v2_blackwell-high_throughput_config
```

### Disagg 模式（分离式）

格式: `{test_type}-{config_yml}`

| 部分 | 说明 | 示例 |
|------|------|------|
| `test_type` | 测试类型 | `benchmark` (disagg 只支持 benchmark) |
| `config_yml` | YAML 配置文件名（不含扩展名） | `llama3_70b_disagg` |

**配置文件位置**: `tests/integration/defs/perf/disagg/test_configs/disagg/perf/`

**示例**:
```txt
benchmark-llama3_70b_disagg
benchmark-llama3_405b_disagg
```

---

## 📂 配置文件结构

### Agg 配置文件示例

```yaml
# tests/scripts/perf-sanity/deepseek_r1_fp4_v2_blackwell.yaml

server_configs:
  - name: "default_config"
    model_name: "deepseek_r1_0528_fp4_v2"
    tensor_parallel_size: 8
    max_batch_size: 512
    # ... 其他配置

  - name: "high_throughput_config"
    model_name: "deepseek_r1_0528_fp4_v2"
    tensor_parallel_size: 8
    max_batch_size: 1024
    # ... 其他配置

benchmark_configs:
  - name: "default_benchmark"
    # ... benchmark 配置
```

**生成的测试用例**:
```txt
profiling-deepseek_r1_fp4_v2_blackwell
profiling-deepseek_r1_fp4_v2_blackwell-default_config
profiling-deepseek_r1_fp4_v2_blackwell-high_throughput_config
benchmark-deepseek_r1_fp4_v2_blackwell
benchmark-deepseek_r1_fp4_v2_blackwell-default_config
benchmark-deepseek_r1_fp4_v2_blackwell-high_throughput_config
```

### Disagg 配置文件示例

```yaml
# tests/integration/defs/perf/disagg/test_configs/disagg/perf/llama3_70b_disagg.yaml

server_configs:
  - name: "prefill_server"
    model_name: "llama3_70b"
    disagg_run_type: "PREFILL"
    # ... 其他配置

  - name: "kv_server"
    model_name: "llama3_70b"
    disagg_run_type: "KV"
    # ... 其他配置

benchmark_configs:
  - name: "disagg_benchmark"
    # ... benchmark 配置
```

**生成的测试用例**:
```txt
benchmark-llama3_70b_disagg
```

---

## 🚀 实际使用示例

### 示例 1: debug_cases.txt (推荐格式)

```txt
# Debug Test Cases for Performance Testing
# Format: test_perf_sanity.py::test_e2e[test_case_id]

# ============================================
# Profiling 测试
# ============================================
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell-default_config]

# ============================================
# Benchmark 测试
# ============================================
test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_blackwell-high_throughput_config]

# ============================================
# Disagg 测试
# ============================================
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]
test_perf_sanity.py::test_e2e[benchmark-llama3_405b_disagg]
```

### 示例 2: 简化格式 (也支持)

```txt
# Simplified format - test case ID only
profiling-deepseek_r1_fp4_v2_blackwell
benchmark-deepseek_r1_fp4_v2_blackwell-default_config
benchmark-llama3_70b_disagg
```

### 示例 3: 使用 pytest -k 过滤

```bash
# 只运行 profiling 测试
pytest tests/integration/defs/perf/test_perf_sanity.py -k "profiling"

# 只运行 deepseek 相关测试
pytest tests/integration/defs/perf/test_perf_sanity.py -k "deepseek"

# 运行 benchmark 但排除 disagg
pytest tests/integration/defs/perf/test_perf_sanity.py -k "benchmark and not disagg"

# 运行特定配置
pytest tests/integration/defs/perf/test_perf_sanity.py -k "deepseek_r1_fp4_v2_blackwell and default_config"
```

---

## 🔧 Jenkins 集成

### 在 Jenkins Pipeline 中使用

```groovy
// 方式 1: 使用 testlist 文件
def testList = 'jenkins_test/testlists/debug_cases.txt'
sh """
    cd tests/integration/defs/perf && \
    pytest test_perf_sanity.py --test-list=${testList}
"""

// 方式 2: 使用 pytest -k 过滤
sh """
    cd tests/integration/defs/perf && \
    pytest test_perf_sanity.py -k "profiling and deepseek"
"""

// 方式 3: 直接指定测试用例
sh """
    cd tests/integration/defs/perf && \
    pytest test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
"""
```

---

## 📋 快速参考

### 从失败日志创建 debug testlist

```bash
# 1. 从 CI 日志复制失败测试
FAILED test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
FAILED test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]

# 2. 粘贴到 debug_cases.txt
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]

# 3. 在 Jenkins 中运行
TESTLIST = 'debug_cases'
```

### 查看所有可用测试用例

```bash
# 列出所有测试用例
cd tests/integration/defs/perf
pytest test_perf_sanity.py --collect-only

# 只看 pytest IDs
pytest test_perf_sanity.py --collect-only -q
```

---

## ⚠️ 注意事项

1. **配置文件必须存在**
   - Agg: `tests/scripts/perf-sanity/{config_yml}.yaml`
   - Disagg: `tests/integration/defs/perf/disagg/test_configs/disagg/perf/{config_yml}.yaml`

2. **测试类型限制**
   - Agg 支持: `profiling`, `benchmark`
   - Disagg 只支持: `benchmark`

3. **server_config_name 可选**
   - 不指定: 运行所有 server_configs
   - 指定: 只运行特定 server_config

4. **模式标记不再需要**
   - TXT 格式不需要 `# mode:single-agg` 等标记
   - 测试类型由配置文件自动识别

---

## 📚 相关文档

- [test_perf_sanity.py 源码](../tests/integration/defs/perf/test_perf_sanity.py)
- [Jenkins L0_Test.groovy](../jenkins/L0_Test.groovy)
- [配置文件示例](../tests/scripts/perf-sanity/)
