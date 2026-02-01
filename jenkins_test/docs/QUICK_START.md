# 🚀 TensorRT-LLM 性能测试快速指南

## 两种使用方式

### 1. TestList 模式（🌟 推荐）

**适用场景**：从 YAML 文件运行测试套件

```groovy
// Jenkins 参数
TESTLIST: gb200_unified_suite    // 选择测试套件
FILTER_MODE: all                 // 运行所有类型（或过滤：single-agg/multi-agg/disagg）
PYTEST_K: "deepseek"             // pytest -k 过滤（可选，仅 single-agg/multi-agg）
CLUSTER: gb200
```

**本地调试**：
```bash
# 运行整个套件
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM

# 只运行 single-agg（通过 --mode 过滤）
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --mode single-agg

# 使用 pytest -k 过滤（仅支持 single-agg 和 multi-agg）
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    -k "deepseek and not fp8"
```

---

### 2. 手动调试模式

**适用场景**：调试单个配置文件

```groovy
// Jenkins 参数
TESTLIST: manual
MANUAL_TEST_MODE: single-agg
CONFIG_FILE: deepseek_r1_fp4_v2_grace_blackwell
CLUSTER: gb200
```

**本地调试**：
```bash
./scripts/run_single_agg_test.sh \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --trtllm-dir /path/to/TensorRT-LLM \
    -k "deepseek"  # 可选，额外过滤
```

---

## 参数说明

### Jenkins Pipeline 参数

| 参数 | 说明 | 示例 |
|------|------|------|
| **TESTLIST** | 测试套件名称 | `gb200_unified_suite`<br>`gb300_unified_suite`<br>`manual` |
| **FILTER_MODE** | 测试类型过滤 | `all` / `single-agg` / `multi-agg` / `disagg` |
| **CLUSTER** | 目标集群 | `gb200` / `gb300` / `gb200_lyris` |
| **PYTEST_K** | pytest -k 过滤表达式 | `"deepseek"` / `"deepseek and not fp8"`<br>**注意：仅支持 single-agg 和 multi-agg** |
| **CONFIG_FILE** | 配置文件（手动模式） | `deepseek_r1_fp4_v2_grace_blackwell` |
| **MANUAL_TEST_MODE** | 测试类型（手动模式） | `single-agg` / `multi-agg` / `disagg` |
| **DRY_RUN** | 试运行（不实际执行） | `true` / `false` |

---

## 查看 TestList 内容

```bash
# 查看统计信息
python3 scripts/parse_unified_testlist.py \
    testlists/gb200_unified_suite.yml \
    --summary

# 输出:
# ============================================================
# TestList: gb200_unified_perf_suite
# ============================================================
# 总测试数: 10
#   - Single-Agg: 6
#   - Multi-Agg:  3
#   - Disagg:     1
# ============================================================

# 查看详细内容（美化输出）
python3 scripts/parse_unified_testlist.py \
    testlists/gb200_unified_suite.yml \
    --pretty

# 只查看 single-agg 测试
python3 scripts/parse_unified_testlist.py \
    testlists/gb200_unified_suite.yml \
    --mode single-agg \
    --pretty
```

---

## 试运行（Dry Run）

在实际执行前查看将要运行的命令：

```bash
# TestList 模式
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run

# 手动调试模式
./scripts/run_single_agg_test.sh \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run
```

---

## 文件结构

```
jenkins_test/
├── testlists/
│   ├── gb200_unified_suite.yml          # 🌟 GB200 测试套件（包含所有类型）
│   └── gb300_unified_suite.yml          # 🌟 GB300 测试套件（包含所有类型）
│
├── configs/                              # 配置文件（手动调试用）
│   ├── single_agg/                      # 单节点配置
│   ├── multi_agg/                       # 多节点配置
│   └── disagg/                          # 分离式配置
│
└── scripts/
    ├── run_perf_tests.sh                # 🌟 统一执行入口
    ├── parse_unified_testlist.py        # TestList 解析器
    ├── run_single_agg_test.sh           # 单节点执行（被调用）
    ├── run_multi_agg_test.sh            # 多节点执行（被调用）
    └── run_disagg_test.sh               # 分离式执行（被调用）
```

**核心思路**：
- **TestList 模式**：`run_perf_tests.sh` 解析 YAML → 自动调用对应脚本
- **手动模式**：直接调用 `run_single_agg_test.sh` 等脚本

---

## 核心优势

1. **简洁明了**：只有两种模式 - TestList 和手动调试
2. **灵活过滤**：
   - 用 `--mode` 参数按测试类型过滤
   - 用 `-k` 参数按测试名过滤（single-agg 和 multi-agg）
3. **统一入口**：`run_perf_tests.sh` 自动分发到对应脚本
4. **易于扩展**：新增测试只需编辑一个 YAML 文件

**⚠️ 重要提示**：
- pytest `-k` 过滤**仅支持 single-agg 和 multi-agg** 模式
- disagg 模式使用专用的 `submit.py`，**不支持 `-k` 过滤**

---

## 常见场景

### 场景 1: 运行完整测试套件
```groovy
TESTLIST: gb200_unified_suite
FILTER_MODE: all
CLUSTER: gb200
```

### 场景 2: 只运行单节点测试（通过过滤）
```groovy
TESTLIST: gb200_unified_suite
FILTER_MODE: single-agg          # ← 过滤参数
CLUSTER: gb200
```

### 场景 3: 过滤特定模型（pytest -k）
```groovy
TESTLIST: gb200_unified_suite
FILTER_MODE: single-agg          # 或 multi-agg
PYTEST_K: "deepseek and not fp8" # ← pytest -k 过滤
CLUSTER: gb200
```

### 场景 4: 调试单个配置
```groovy
TESTLIST: manual
MANUAL_TEST_MODE: single-agg
CONFIG_FILE: deepseek_r1_fp4_v2_grace_blackwell
CLUSTER: gb200
```

### 场景 5: 本地运行（脱离 Jenkins）
```bash
# 设置集群环境变量
export CLUSTER_ACCOUNT="coreai_comparch_trtllm"
export CLUSTER_PARTITION="batch"
export CLUSTER_LLM_DATA="/lustre/fs1/..."
export DOCKER_IMAGE="nvcr.io/nvidia/tensorrt-llm:latest"
export MPI_TYPE="pmix"

# 运行测试
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --mode single-agg \
    -k "deepseek"
```

---

## pytest -k 使用示例

```bash
# 只运行包含 "deepseek" 的测试
-k "deepseek"

# 运行 deepseek 但排除 fp8
-k "deepseek and not fp8"

# 运行 llama 或 qwen
-k "llama or qwen"

# 复杂表达式
-k "(deepseek or llama) and not (fp8 or fp16)"
```

**提示**：pytest `-k` 表达式匹配的是测试名称，例如：
- `aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k`
- 使用 `-k "deepseek"` 会匹配这个测试
- 使用 `-k "fp8"` 会排除这个测试（因为名称中有 fp4 不是 fp8）

---

## 详细文档

- **[TEST_PROCESS.md](../TEST_PROCESS.md)** - 完整执行流程和调试指南
- **[README.md](../README.md)** - 项目概述和架构说明

---

## 获取帮助

```bash
# 查看脚本帮助
./scripts/run_perf_tests.sh --help
./scripts/run_single_agg_test.sh --help
python3 scripts/parse_unified_testlist.py --help
```
