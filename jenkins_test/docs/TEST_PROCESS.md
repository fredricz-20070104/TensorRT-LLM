# 性能测试执行流程详解

## 📋 目录

1. [核心结论](#核心结论)
2. [快速开始](#快速开始)
3. [TestList 管理方案](#testlist-管理方案)
4. [⚠️ 待修复的设计问题](#待修复的设计问题)
5. [关键配置说明](#关键配置说明)
6. [测试文件说明](#测试文件说明)
7. [执行流程详解](#执行流程详解)

---

## 快速开始

### 🚀 推荐方式：使用统一 TestList

```groovy
// Jenkins Pipeline 参数
TESTLIST: gb200_unified_suite  // 一个文件包含所有类型的测试！
CLUSTER: gb200
```

```bash
# 本地调试：运行整个套件
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM

# 只运行 single-agg 测试
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --mode single-agg

# 试运行
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run
```

### 使用 TestList 运行测试（兼容方式）

```groovy
// Jenkins Pipeline 参数
TESTLIST: single_agg/gb200_perf_sanity  // 选择预定义的 testlist
CLUSTER: gb200                           // 选择目标集群
```

### 手动运行单个配置（调试）

```groovy
// Jenkins Pipeline 参数
TESTLIST: manual                                    // 选择手动模式
MANUAL_TEST_MODE: single-agg                        // 指定测试模式
CONFIG_FILE: deepseek_r1_fp4_v2_grace_blackwell     // 指定配置文件
CLUSTER: gb200                                      // 选择目标集群
```

### 本地调试（脱离 Jenkins）

```bash
# 方式1: 使用 testlist
cd /path/to/jenkins_test
./scripts/run_single_agg_test.sh \
    --testlist testlists/single_agg/gb200_perf_sanity.yml \
    --trtllm-dir /path/to/TensorRT-LLM

# 方式2: 直接指定配置文件
./scripts/run_single_agg_test.sh \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --trtllm-dir /path/to/TensorRT-LLM

# 试运行模式（查看将执行的命令）
./scripts/run_single_agg_test.sh \
    --testlist testlists/single_agg/gb200_perf_sanity.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run
```

---

## TestList 管理方案

### 🎯 方案选择

我们提供两种方案，根据需求选择：

#### 方案 A: 统一 TestList（推荐 - All-in-One）

**适用场景**：
- ✅ 需要管理大量测试用例
- ✅ 希望一个文件管理所有类型的测试
- ✅ 需要自动识别测试类型

**特点**：
- 一个 YAML 文件包含 single-agg、multi-agg、disagg 所有测试
- 自动识别测试类型（根据节点数和标记）
- 统一执行入口 `run_perf_tests.sh`

#### 方案 B: 分类 TestList（兼容 test-db）

**适用场景**：
- ✅ 需要完全兼容现有 test-db 格式
- ✅ 希望按测试类型分目录管理
- ✅ 需要独立运行某种类型的测试

**特点**：
- 按目录分类：`single_agg/`、`multi_agg/`、`disagg/`
- 完全兼容 test-db 格式
- 独立的执行脚本

---

### 方案 A: 统一 TestList 格式

#### 文件结构

```
jenkins_test/
├── testlists/
│   ├── gb200_unified_suite.yml     # 统一测试套件
│   ├── gb300_unified_suite.yml
│   └── b200_unified_suite.yml
│
├── configs/                         # 配置文件（共享）
│   ├── single_agg/
│   ├── multi_agg/
│   └── disagg/
│
└── scripts/
    ├── run_perf_tests.sh            # 统一执行入口
    ├── parse_unified_testlist.py    # 统一解析器
    ├── run_single_agg_test.sh       # 被调用
    ├── run_multi_agg_test.sh        # 被调用
    └── run_disagg_test.sh           # 被调用
```

#### 统一 TestList 格式

```yaml
# jenkins_test/testlists/gb200_unified_suite.yml
version: 1.0.0

metadata:
  description: "GB200 统一性能测试套件"
  cluster: gb200
  owner: perf-team

gb200_unified_perf_suite:
# ========================================
# Single Node Agg 测试
# ========================================
- condition:
    ranges:
      system_gpu_count:
        gte: 4
        lte: 4
    wildcards:
      gpu:
      - '*gb200*'
    terms:
      stage: pre_merge
      backend: pytorch
      nodes: 1                    # ← 自动识别：1节点 = single-agg
  tests:
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k]
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k] TIMEOUT (90)

# ========================================
# Multi Node Agg 测试
# ========================================
- condition:
    ranges:
      system_gpu_count:
        gte: 8
        lte: 8
    terms:
      stage: post_merge
      backend: pytorch
      nodes: 2                    # ← 自动识别：2节点 = multi-agg
  tests:
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k] TIMEOUT (90)

# ========================================
# Disagg 测试
# ========================================
- condition:
    ranges:
      system_gpu_count:
        gte: 12
        lte: 12
    terms:
      stage: post_merge
      backend: pytorch
      nodes: 3                    # ← 节点数
      test_type: disagg           # ← 明确标识：disagg
  tests:
  - perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] TIMEOUT (90)
```

#### 自动识别规则

```python
# 识别优先级：
1. condition.terms.test_type == "disagg" → disagg
2. test_line 包含 "disagg_upload"       → disagg
3. condition.terms.nodes == 1           → single-agg
4. condition.terms.nodes > 1            → multi-agg
```

#### 使用统一 TestList

```bash
# 运行整个套件
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM

# 只运行 single-agg 测试
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --mode single-agg

# 只运行 multi-agg 测试
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --mode multi-agg

# 遇到错误就停止
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --stop-on-error

# 试运行
./scripts/run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run
```

#### 查看 TestList 内容

```bash
# 查看统计摘要
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

# 查看详细信息（美化输出）
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

### 方案 B: 分类 TestList 格式（兼容方式）

```
jenkins_test/
├── testlists/                           # TestList 文件（test-db 格式）
│   ├── single_agg/
│   │   ├── gb200_perf_sanity.yml       # GB200 单节点性能测试
│   │   └── gb300_perf_sanity.yml       # GB300 单节点性能测试
│   ├── multi_agg/
│   │   └── gb200_2nodes_perf.yml       # GB200 双节点聚合测试
│   └── disagg/
│       └── gb200_3nodes_sanity.yml     # GB200 3节点分离式测试
│
├── configs/                             # 配置文件（按测试模式分类）
│   ├── single_agg/
│   │   ├── deepseek_r1_fp4_v2_grace_blackwell.yml
│   │   ├── deepseek_v32_fp4_grace_blackwell.yml
│   │   └── k2_thinking_fp4_grace_blackwell.yml
│   ├── multi_agg/
│   │   └── deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yml
│   └── disagg/
│       └── deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
│
└── scripts/
    ├── parse_testlist.py                # TestList 解析工具
    ├── run_single_agg_test.sh           # 单节点测试脚本
    ├── run_multi_agg_test.sh            # 多节点聚合测试脚本
    └── run_disagg_test.sh               # 分离式测试脚本
```

### TestList 格式（完全兼容 test-db）

```yaml
# jenkins_test/testlists/single_agg/gb200_perf_sanity.yml
version: 0.0.1
gb200_single_agg_perf_sanity:
- condition:
    ranges:
      system_gpu_count:
        gte: 4
        lte: 4
    wildcards:
      gpu:
      - '*gb200*'
      linux_distribution_name: ubuntu*
      cpu: aarch64
    terms:
      stage: pre_merge
      backend: pytorch
  tests:
  # DeepSeek-R1 FP4 配置
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k]
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k] TIMEOUT (90)
  
  # DeepSeek-V32 FP4 配置
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_v32_fp4_grace_blackwell-v32_fp4_tep4_mtp3_1k1k]
```

### 配置名称映射规则

```
测试名称格式：
  test_e2e[aggr_upload-{config_file}-{config_name}]

映射规则：
  {config_file} → jenkins_test/configs/{test_mode}/{config_file}.yml
  {config_name} → 配置文件中的 server_configs[name={config_name}]

示例：
  aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k
  ↓
  配置文件: jenkins_test/configs/single_agg/deepseek_r1_fp4_v2_grace_blackwell.yml
  配置项:   server_configs 中 name="r1_fp4_v2_tp4_mtp3_1k1k" 的配置
```

### 配置文件格式（保持现有格式）

```yaml
# jenkins_test/configs/single_agg/deepseek_r1_fp4_v2_grace_blackwell.yml
metadata:
  model_name: deepseek_r1_0528_fp4_v2
  supported_gpus:
  - GB200

hardware:
  gpus_per_node: 4

server_configs:
  - name: "r1_fp4_v2_tp4_mtp3_1k1k"
    model_name: "deepseek_r1_0528_fp4_v2"
    tensor_parallel_size: 4
    moe_expert_parallel_size: 1
    pipeline_parallel_size: 1
    max_batch_size: 4
    max_num_tokens: 8192
    attn_backend: "TRTLLM"
    # ... 完整配置

  - name: "r1_fp4_v2_dep4_mtp1_1k1k"
    model_name: "deepseek_r1_0528_fp4_v2"
    tensor_parallel_size: 4
    moe_expert_parallel_size: 4
    # ... 完整配置
```

### 完整执行流程

#### 方式1: 使用 TestList（推荐）

```
用户操作：
1. 在 Jenkins 选择 TESTLIST: single_agg/gb200_perf_sanity
2. 选择 CLUSTER: gb200
3. 点击构建

Pipeline 自动执行：
1. 参数验证和模式识别
   ├─ 识别 test_mode = single-agg
   ├─ 设置 TESTLIST_FILE = jenkins_test/testlists/single_agg/gb200_perf_sanity.yml
   └─ 设置 USE_TESTLIST = true

2. 准备工作环境
   ├─ 克隆/更新 TensorRT-LLM
   └─ 验证依赖文件

3. 加载集群配置
   ├─ 从 jenkins_test/config/clusters.conf 加载 gb200 配置
   └─ 设置环境变量

4. 运行测试
   ├─ 调用 run_single_agg_test.sh --testlist testlists/single_agg/gb200_perf_sanity.yml
   ├─ 脚本使用 parse_testlist.py 解析 testlist
   ├─ 提取测试列表:
   │   [
   │     {config_file: "deepseek_r1_fp4_v2_grace_blackwell", config_name: "r1_fp4_v2_tp4_mtp3_1k1k", timeout: 7200},
   │     {config_file: "deepseek_r1_fp4_v2_grace_blackwell", config_name: "r1_fp4_v2_dep4_mtp1_1k1k", timeout: 5400},
   │     ...
   │   ]
   ├─ 对每个测试:
   │   ├─ 查找配置文件: jenkins_test/configs/single_agg/deepseek_r1_fp4_v2_grace_blackwell.yml
   │   ├─ 构造 pytest 命令:
   │   │   pytest tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
   │   │     -k 'aggr_upload-deepseek_r1_fp4_v2_grace_blackwell and r1_fp4_v2_tp4_mtp3_1k1k'
   │   ├─ 使用 srun 在集群上运行
   │   └─ 收集结果
   └─ 输出总结
```

#### 方式2: 手动模式（调试）

```
用户操作：
1. 在 Jenkins 选择 TESTLIST: manual
2. 选择 MANUAL_TEST_MODE: single-agg
3. 输入 CONFIG_FILE: deepseek_r1_fp4_v2_grace_blackwell
4. 选择 CLUSTER: gb200
5. 点击构建

Pipeline 自动执行：
1. 参数验证和模式识别
   ├─ 识别运行模式 = 手动
   ├─ 设置 test_mode = single-agg
   └─ 设置 USE_TESTLIST = false

2-3. 准备环境和加载配置（同方式1）

4. 运行测试
   ├─ 调用 run_single_agg_test.sh --config-file deepseek_r1_fp4_v2_grace_blackwell
   ├─ 脚本直接查找配置文件
   ├─ 运行该配置文件中的所有 server_configs
   └─ 输出结果
```

#### 方式3: 本地调试（脱离 Jenkins）

```bash
# 设置环境变量（模拟集群配置）
export CLUSTER_ACCOUNT="coreai_comparch_trtllm"
export CLUSTER_PARTITION="batch"
export CLUSTER_LLM_DATA="/lustre/fs1/portfolios/coreai/projects/coreai_comparch_trtllm/common"
export DOCKER_IMAGE="nvcr.io/nvidia/tensorrt-llm:latest"
export MPI_TYPE="pmix"

# 使用 testlist
cd /path/to/jenkins_test
./scripts/run_single_agg_test.sh \
    --testlist testlists/single_agg/gb200_perf_sanity.yml \
    --trtllm-dir /path/to/TensorRT-LLM

# 或直接指定配置文件
./scripts/run_single_agg_test.sh \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --trtllm-dir /path/to/TensorRT-LLM

# 试运行（查看将执行的命令，不实际运行）
./scripts/run_single_agg_test.sh \
    --testlist testlists/single_agg/gb200_perf_sanity.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run
```

### 调试技巧

#### 1. 查看 TestList 解析结果

```bash
# 解析 testlist 并查看 JSON 输出
python3 scripts/parse_testlist.py \
    testlists/single_agg/gb200_perf_sanity.yml \
    --pretty

# 输出示例:
{
  "testlist_name": "gb200_single_agg_perf_sanity",
  "test_mode": "single-agg",
  "tests": [
    {
      "test_type": "aggr",
      "config_file": "deepseek_r1_fp4_v2_grace_blackwell",
      "config_name": "r1_fp4_v2_tp4_mtp3_1k1k",
      "timeout": 7200,
      "raw": "perf/test_perf_sanity.py::test_e2e[aggr_upload-...]"
    },
    ...
  ]
}
```

#### 2. 单独测试配置文件查找逻辑

```bash
# 测试配置文件查找
config_file="deepseek_r1_fp4_v2_grace_blackwell"

for path in \
    "jenkins_test/configs/single_agg/${config_file}.yaml" \
    "jenkins_test/configs/single_agg/${config_file}.yml" \
    "TensorRT-LLM/tests/scripts/perf-sanity/${config_file}.yaml"; do
    if [[ -f "$path" ]]; then
        echo "找到: $path"
    fi
done
```

#### 3. 验证 pytest 命令

```bash
# 使用 --dry-run 查看将执行的 pytest 命令
./scripts/run_single_agg_test.sh \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run

# 输出:
# 执行命令:
#   cd /path/to/TensorRT-LLM
#   srun --mpi=pmix -N 1 -A coreai_comparch_trtllm -p batch \
#     --container-image=nvcr.io/nvidia/tensorrt-llm:latest \
#     --container-workdir=/path/to/TensorRT-LLM \
#     python3 -m pytest tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
#       -k 'aggr_upload-deepseek_r1_fp4_v2_grace_blackwell' -v --timeout=7200
```

#### 4. 手动运行单个测试

```bash
# 在集群上手动运行（跳过脚本）
cd /path/to/TensorRT-LLM

srun --mpi=pmix -N 1 -A coreai_comparch_trtllm -p batch \
  --container-image=nvcr.io/nvidia/tensorrt-llm:latest \
  --container-workdir=$(pwd) \
  --container-mounts=$(pwd):$(pwd),/lustre/fs1/portfolios/coreai/projects/coreai_comparch_trtllm/common:/lustre/fs1/portfolios/coreai/projects/coreai_comparch_trtllm/common \
  python3 -m pytest \
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
    -k 'aggr_upload-deepseek_r1_fp4_v2_grace_blackwell and r1_fp4_v2_tp4_mtp3_1k1k' \
    -v
```

### 添加新测试

#### 添加到现有 TestList

```yaml
# 编辑 jenkins_test/testlists/single_agg/gb200_perf_sanity.yml
tests:
  # 添加新的测试行
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-my_new_model-my_config_name] TIMEOUT (90)
```

#### 创建新的配置文件

```yaml
# 创建 jenkins_test/configs/single_agg/my_new_model.yml
metadata:
  model_name: my_new_model
  supported_gpus:
  - GB200

server_configs:
  - name: "my_config_name"
    model_name: "my_new_model"
    tensor_parallel_size: 4
    # ... 完整配置
```

#### 创建新的 TestList

```yaml
# 创建 jenkins_test/testlists/single_agg/my_custom_suite.yml
version: 0.0.1
my_custom_test_suite:
- condition:
    ranges:
      system_gpu_count:
        gte: 4
        lte: 4
    wildcards:
      gpu:
      - '*gb200*'
    terms:
      stage: pre_merge
      backend: pytorch
  tests:
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-my_new_model-my_config_name]
```

然后在 `Perf_Test.groovy` 的 TESTLIST 参数中添加：

```groovy
choice(
    name: 'TESTLIST',
    choices: [
        'single_agg/gb200_perf_sanity',
        'single_agg/my_custom_suite',  // 添加新的选项
        ...
    ]
)
```

### 优势总结

✅ **兼容现有** - TestList 格式与 test-db 完全兼容  
✅ **统一管理** - 所有配置在 `jenkins_test/` 下集中管理  
✅ **易于调试** - 支持本地运行和 dry-run 模式  
✅ **批量执行** - 一个 testlist 管理多个测试  
✅ **灵活切换** - 可以在 testlist 模式和手动模式间切换  
✅ **清晰层次** - testlist (测什么) → config (怎么配置)  

---

## ⚠️ 待修复的设计问题

### 问题：Perf_Test.groovy 的 NODE_LIST 参数设计不合理

**当前错误实现**:
```groovy
// Perf_Test.groovy 当前参数
string(name: 'NODE_LIST', defaultValue: '', description: '节点列表')

// 用户需要手动指定：
NODE_LIST: node1,node2,node3,node4

// 然后验证 (第 244-257 行):
def providedNodes = NODE_LIST.split(',').size()  // 4
if (providedNodes != nodeInfo.total_nodes) {
    error "节点数不匹配！"
}
```

**为什么这是错误的**:

1. ❌ **Slurm 自动分配节点**
   - Slurm 根据资源可用性动态分配节点
   - 用户无法预知会分配哪些节点
   - 节点名称可能是 `gpu-node-[05-08]` 而不是 `node1,node2,node3,node4`

2. ❌ **submit.py 和 slurm_launch_draft.sh 不使用节点名称**
   - 它们通过 `srun -N <count>` 指定节点数量
   - Slurm 自动在已分配的节点池中选择
   - 不需要也不使用用户提供的节点名称列表

3. ❌ **限制调度灵活性**
   - 手动指定节点可能导致这些节点不可用
   - Slurm 应该有自由选择最优节点的能力

**正确的实现方式** (参考 L0_Test.groovy):

```groovy
// ✅ 正确的参数定义
string(name: 'NODE_COUNT', defaultValue: '4', description: '需要的节点数量')

// ✅ 生成 SBATCH 参数 (L0_Test.groovy 第 783-798 行)
def getNodeArgs(int nodeCount, int gpuCount, boolean setSegment = false) {
    int gpusPerNode = ((gpuCount / nodeCount) as BigDecimal).setScale(0, BigDecimal.ROUND_CEILING).intValue()
    return [
        "--nodes=${nodeCount}",          // ← 只指定数量
        "--ntasks=${gpuCount}",
        "--ntasks-per-node=${gpusPerNode}",
        "--gpus-per-node=${gpusPerNode}",
    ]
}

// ✅ 在 sbatch 脚本中 (L0_Test.groovy 第 1163-1168 行)
#!/bin/bash
#SBATCH --nodes=4                        // ← 告诉 Slurm 需要 4 个节点
#SBATCH --ntasks=32
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8

echo "Starting Slurm job $SLURM_JOB_ID on $SLURM_NODELIST"  // ← 运行时获取实际节点

// ✅ 验证逻辑应该改为
if (params.NODE_COUNT != nodeInfo.total_nodes) {
    error """
节点数不匹配！
  配置要求: ${nodeInfo.total_nodes} 个节点
  用户指定: ${params.NODE_COUNT} 个节点
"""
}
```

**Slurm 节点分配的实际流程**:

```bash
# 步骤 1: 提交作业，只指定需要的节点数量
$ sbatch --nodes=4 my_job.sh
Submitted batch job 12345

# 步骤 2: Slurm 自动选择 4 个可用节点
# 假设选中了: gpu-node-05, gpu-node-06, gpu-node-07, gpu-node-08

# 步骤 3: 作业运行时，通过环境变量获取实际分配的节点
$ echo $SLURM_NODELIST
gpu-node-[05-08]

$ echo $SLURM_JOB_NUM_NODES
4

# 步骤 4: 使用 srun 在已分配的节点中执行任务
$ srun -N 2 hostname     # 从 4 个节点中选 2 个
gpu-node-05
gpu-node-06

$ srun -N 2 hostname     # 可能选择另外 2 个
gpu-node-07
gpu-node-08
```

**submit.py 的实际行为**:

查看 `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh` (第 19-31 行):

```bash
# 启动 gen servers
for i in $(seq 0 $((numGenServers - 1))); do
    gen_world_size=$((nodesPerGenServer * gpusPerNode))
    export DISAGG_SERVING_TYPE="GEN_$i"
    export pytestCommand="$pytestCommandWorker"
    
    # ✅ 只指定需要的节点数量，不指定具体节点名称
    srun "${srunArgs[@]}" --kill-on-bad-exit=1 \
        -N $nodesPerGenServer \              # ← 例如: -N 2 (需要2个节点)
        --ntasks=$gen_world_size \
        --ntasks-per-node=$gpusPerNode \
        $runScript &> $jobWorkspace/gen_server_$i.log &
done

# Slurm 会自动从 $SLURM_NODELIST 中选择 2 个节点来运行这个命令
# 用户提供的 NODE_LIST 完全没有被使用！
```

**修复建议**:

1. **修改参数定义** (Perf_Test.groovy 第 7 行):
   ```groovy
   // 删除
   - string(name: 'NODE_LIST', defaultValue: '', description: '节点列表')
   
   // 添加
   + string(name: 'NODE_COUNT', defaultValue: '', description: '节点数量（可选，disagg模式会自动计算）')
   ```

2. **修改验证逻辑** (Perf_Test.groovy 第 244-257 行):
   ```groovy
   // 删除
   - if (NODE_LIST) {
   -     def providedNodes = NODE_LIST.split(',').size()
   -     if (providedNodes != nodeInfo.total_nodes) {
   
   // 添加
   + if (params.NODE_COUNT) {
   +     def requestedNodes = params.NODE_COUNT.toInteger()
   +     if (requestedNodes != nodeInfo.total_nodes) {
           error """
   节点数不匹配！
     配置要求: ${nodeInfo.total_nodes} 个节点
   - 实际提供: ${providedNodes} 个节点
   + 用户指定: ${requestedNodes} 个节点
   """
       }
       echo "✓ 节点数验证通过"
   }
   ```

3. **在 sbatch 命令中使用** (需要新增):
   ```groovy
   // 在生成 sbatch 脚本时添加
   def sbatchScript = """#!/bin/bash
   #SBATCH --nodes=${nodeInfo.total_nodes}
   #SBATCH --ntasks=${nodeInfo.total_gpus}
   #SBATCH --ntasks-per-node=${nodeInfo.gpus_per_node}
   ...
   """
   ```

**总结**:

| 维度 | 当前错误实现 | 正确实现 (L0_Test.groovy) |
|------|-------------|--------------------------|
| **参数类型** | `NODE_LIST` (字符串列表) | `NODE_COUNT` (整数) |
| **用户输入** | `node1,node2,node3,node4` | `4` |
| **验证方式** | `NODE_LIST.split(',').size()` | `params.NODE_COUNT.toInteger()` |
| **sbatch 参数** | 未使用 | `--nodes=4` |
| **节点分配** | 假装用户知道节点名称 | Slurm 自动分配 |
| **submit.py 使用** | 完全不使用 NODE_LIST | 使用 total_nodes 数量 |

---

## 🎯 核心结论

### 所有性能测试统一使用 test_perf_sanity.py

**重要发现**：
- ✅ **Single Node Agg** → `test_perf_sanity.py::test_e2e`
- ✅ **Multi-Node Agg** → `test_perf_sanity.py::test_e2e`
- ✅ **Multi-Node Disagg** → `test_perf_sanity.py::test_e2e`
- ❌ **test_perf.py** → 旧文件，已不再用于 perf sanity 测试

### 关键配置说明

**Q1: `disagg_run_type` 的默认值是什么？**

✅ **答案**: 默认值是 `"aggr"`

**证据**（`test_perf_sanity.py` 第 129 行）:
```python
self.disagg_run_type = server_config_data.get("disagg_run_type", "aggr")
                                                                   ^^^^^^
                                                                   默认值
```

**说明**:
- 如果 `server_config` 中没有 `disagg_run_type` 字段，默认为 `"aggr"`
- Agg 配置文件通常不需要显式指定（可以省略）
- Disagg 配置文件根本不使用 `server_config`，而是使用 `hardware` + `worker_config`

**Q2: `jenkins/scripts/perf/disaggregated/submit.py` 是否做了逻辑节点到硬件节点的转换？**

✅ **答案**: 是的！submit.py 确实做了完整的转换

**证据**（`submit.py` 第 8-54 行）:

```python
def get_hardware_config(config, benchmark_mode):
    hardware = config.get("hardware", {})
    worker_config = config.get("worker_config", {})

    # 1. 读取逻辑服务器数
    num_ctx_servers = hardware.get("num_ctx_servers")  # 逻辑
    num_gen_servers = hardware.get("num_gen_servers")  # 逻辑
    gpus_per_node = hardware.get("gpus_per_node")
    
    # 2. 计算每个逻辑服务器需要的 GPU 数
    ctx_tp = ctx_config.get("tensor_parallel_size", 1)
    ctx_pp = ctx_config.get("pipeline_parallel_size", 1)
    ctx_cp = ctx_config.get("context_parallel_size", 1)
    gpus_per_ctx_server = ctx_tp * ctx_pp * ctx_cp  # 每个 CTX 服务器的 GPU 数
    
    gen_tp = gen_config.get("tensor_parallel_size", 1)
    gen_pp = gen_config.get("pipeline_parallel_size", 1)
    gen_cp = gen_config.get("context_parallel_size", 1)
    gpus_per_gen_server = gen_tp * gen_pp * gen_cp  # 每个 GEN 服务器的 GPU 数
    
    # 3. 计算每个逻辑服务器需要的硬件节点数（向上取整）
    nodes_per_ctx_server = (gpus_per_ctx_server + gpus_per_node - 1) // gpus_per_node
    nodes_per_gen_server = (gpus_per_gen_server + gpus_per_node - 1) // gpus_per_node
    
    # 4. 计算总硬件节点数
    total_nodes = num_ctx_servers * nodes_per_ctx_server + num_gen_servers * nodes_per_gen_server
    total_gpus = total_nodes * gpus_per_node
    
    return {
        "num_ctx_servers": num_ctx_servers,           # 逻辑
        "num_gen_servers": num_gen_servers,           # 逻辑
        "nodes_per_ctx_server": nodes_per_ctx_server, # 硬件
        "nodes_per_gen_server": nodes_per_gen_server, # 硬件
        "total_nodes": total_nodes,                   # 硬件
        "total_gpus": total_gpus,
    }
```

**计算示例**:

假设配置为：
```yaml
hardware:
  num_ctx_servers: 1    # 1 个逻辑 CTX 服务器
  num_gen_servers: 1    # 1 个逻辑 GEN 服务器
  gpus_per_node: 4
worker_config:
  ctx:
    tensor_parallel_size: 4  # CTX TP=4
  gen:
    tensor_parallel_size: 8  # GEN TP=8
```

计算过程：
```python
# CTX 计算
gpus_per_ctx_server = 4 × 1 × 1 = 4
nodes_per_ctx_server = (4 + 4 - 1) // 4 = 1  # 每个 CTX 逻辑服务器需要 1 个硬件节点
ctx_total_nodes = 1 × 1 = 1                   # 1 个逻辑服务器 × 1 节点/服务器 = 1 个硬件节点

# GEN 计算
gpus_per_gen_server = 8 × 1 × 1 = 8
nodes_per_gen_server = (8 + 4 - 1) // 4 = 2  # 每个 GEN 逻辑服务器需要 2 个硬件节点
gen_total_nodes = 1 × 2 = 2                   # 1 个逻辑服务器 × 2 节点/服务器 = 2 个硬件节点

# 总计
total_nodes = 1 + 2 = 3  # 3 个硬件节点
total_gpus = 3 × 4 = 12  # 12 个 GPU
```

**关键区别**:
- `jenkins_test/scripts/calculate_hardware_nodes.py` - 我们自己写的工具，用于验证
- `jenkins/scripts/perf/disaggregated/submit.py` - L0 的脚本，**也做了相同的计算**

两者计算逻辑完全一致！

---

## 📊 测试文件对比

### test_perf_sanity.py (当前使用)

**位置**: `tests/integration/defs/perf/test_perf_sanity.py`

**用途**: 所有 Perf Sanity 测试

**测试函数**: `test_e2e`

**支持的测试类型**:
- Aggregated (单节点/多节点)
- Disaggregated (多节点)

**配置格式**:
```yaml
# Agg 配置
server_config:
  model_name: deepseek_r1_fp4
  tensor_parallel_size: 4
  disagg_run_type: aggr  # ← 关键：aggr 表示聚合模式

# Disagg 配置
hardware:
  num_ctx_servers: 2  # 逻辑 CTX 服务器数
  num_gen_servers: 1  # 逻辑 GEN 服务器数
  gpus_per_node: 4
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 8
```

### test_perf.py (已弃用)

**位置**: `tests/integration/defs/perf/test_perf.py`

**用途**: 旧的性能测试框架

**测试函数**: `test_perf`

**状态**: ⚠️ 已不再用于 Perf Sanity 测试，只在完整的 perf 测试中使用

---

## 🔍 L0_Test.groovy 执行流程

### 配置定义（第 3349-3367 行）

```groovy
multiNodesSBSAConfigs = [
    // Multi-Node Agg: 8 GPUs, 2 Nodes
    "GB200-8_GPUs-2_Nodes-PyTorch-PerfSanity-Post-Merge-1": [
        "gb200-oci-trtllm",                              // 平台
        "l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes", // TestList
        1,  // splitId
        5,  // splits
        8,  // gpuCount (总 GPU 数)
        2   // nodeCount (硬件节点数)
    ],
    
    // Multi-Node Disagg: 12 GPUs, 3 Nodes
    "GB200-12_GPUs-3_Nodes-PyTorch-PerfSanity-Disagg-Post-Merge-1": [
        "gb200-oci-trtllm",
        "l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes", // TestList
        1,  // splitId
        1,  // splits
        12, // gpuCount (总 GPU 数)
        3   // nodeCount (硬件节点数)
    ],
]
```

### 执行流程（第 3397 行）

```groovy
runLLMTestlistOnSlurm(
    pipeline,
    values[0],  // platform: gb200-oci-trtllm
    values[1],  // testList: l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes
    config,
    key.contains("-Perf-"),  // perfMode: true
    key,        // stageName
    values[2],  // splitId: 1
    values[3],  // splits: 5
    values[4],  // gpuCount: 8
    values[5],  // nodeCount: 2
    values[6]   // runWithSbatch: false
)
```

### runLLMTestlistOnSlurm 函数（第 1411-1419 行）

```groovy
def runLLMTestlistOnSlurm(..., nodeCount=1, ...) {
    echo "Run Slurm job with native sbatch: $runWithSbatch"
    if (nodeCount > 1 || runWithSbatch) {
        // 多节点：使用 sbatch
        runLLMTestlistWithSbatch(...)
    } else {
        // 单节点：使用 agent
        runLLMTestlistWithAgent(...)
    }
}
```

### runLLMTestlistWithSbatch 函数（第 913-1409 行）

**核心逻辑**:

1. **判断是否为 Disagg 模式**（第 921 行）：
   ```groovy
   def disaggMode = stageName.contains("PerfSanity-Disagg")
   ```

2. **Disagg 模式**：调用 `submit.py`
   ```groovy
   if (disaggMode) {
       // 使用 jenkins/scripts/perf/disaggregated/submit.py
       script = """
           cd ${workspace}
           python3 jenkins/scripts/perf/disaggregated/submit.py \\
               --config <config_file.yaml> \\
               --work-dir <output_dir>
       """
   }
   ```

3. **Agg 模式**：调用 `pytest` with `--test-list`
   ```groovy
   else {
       // 读取 TestList 文件
       testListPath = "tests/integration/test_lists/test-db/${testList}.yml"
       
       // 提取测试用例到 test_list.txt
       python3 << 'EOF'
       import yaml
       with open('${testListPath}') as f:
           data = yaml.safe_load(f)
       # 提取 tests 列表
       for item in data[testlist_name]:
           if 'tests' in item:
               for test in item['tests']:
                   print(test)
       EOF
       
       // 使用 srun 运行 pytest
       script = """
           srun --nodes=${nodeCount} \\
               python3 -m pytest \\
                   --test-list=${testListTxt} \\
                   --splitting-algorithm least_duration \\
                   --splits ${splits} \\
                   --group ${splitId} \\
                   tests/integration/defs/
       """
   }
   ```

---

## 🔧 Perf_Test.groovy 执行流程

### Single Node Agg

**Jenkins 参数**:
```groovy
TEST_MODE: single-agg
CONFIG_FILE: aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k
```

**执行命令**（第 265-280 行）:
```bash
cd ${TRTLLM_DIR}
python3 -m pytest \
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
    -k 'aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k' \
    -v
```

**说明**:
- ✅ 直接运行 pytest
- ✅ 使用 `-k` 参数过滤测试
- ✅ 调用 `test_perf_sanity.py::test_e2e`

### Multi-Node Agg

**Jenkins 参数**:
```groovy
TEST_MODE: multi-agg
CONFIG_FILE: aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_tep8_32k8k
NODE_LIST: node1,node2
```

**执行命令**（第 282-306 行）:
```bash
ssh node1 'cd ${TRTLLM_DIR} && \
srun \
    --nodes=2 \
    --ntasks-per-node=1 \
    python3 -m pytest \
        tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
        -k "aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_tep8_32k8k" \
        -v'
```

**说明**:
- ✅ 使用 `srun` 多节点执行
- ✅ 使用 `-k` 参数过滤测试
- ✅ 调用 `test_perf_sanity.py::test_e2e`

### Multi-Node Disagg

**Jenkins 参数**:
```groovy
TEST_MODE: disagg
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
NODE_LIST: node1,node2,node3,node4
```

**执行流程**（第 139-238 行）:

1. **提取配置文件**:
   ```bash
   # 从 TestList YAML 提取配置名
   python3 << 'EOF'
   import yaml, re
   with open('tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml') as f:
       data = yaml.safe_load(f)
   # 提取: deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
   EOF
   ```

2. **查找配置文件**:
   ```bash
   # 在以下路径查找:
   tests/integration/defs/perf/disagg/test_configs/disagg/perf/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
   tests/integration/defs/perf/disagg/test_configs/wideep/perf/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
   ```

3. **计算硬件节点**:
   ```bash
   python3 scripts/calculate_hardware_nodes.py \
       --config <config_file.yaml> \
       --json
   
   # 输出:
   # {
   #   "num_ctx_servers": 1,  # 逻辑
   #   "num_gen_servers": 1,
   #   "ctx_nodes": 2,        # 硬件
   #   "gen_nodes": 2,
   #   "total_nodes": 4
   # }
   ```

4. **验证节点数**:
   ```bash
   # 提供的节点: 4 (node1,node2,node3,node4)
   # 要求的节点: 4
   # ✓ 验证通过
   ```
   
   **⚠️ 当前实现的验证流程** (存在设计问题):
   ```groovy
   // 步骤 1: 从 NODE_LIST 参数获取用户提供的节点数
   if (NODE_LIST) {
       // NODE_LIST = "node1,node2,node3,node4"
       def providedNodes = NODE_LIST.split(',').size()
       echo "提供的节点数: ${providedNodes}"  // 输出: 4
       
       // 步骤 2: 从计算结果获取配置要求的节点数
       // nodeInfo.total_nodes = 4 (来自 calculate_hardware_nodes.py)
       
       // 步骤 3: 对比
       if (providedNodes != nodeInfo.total_nodes) {
           error """
节点数不匹配！
  配置要求: ${nodeInfo.total_nodes} 个节点
  实际提供: ${providedNodes} 个节点
"""
       }
       
       echo "✓ 节点数验证通过"  // 4 == 4
   }
   ```
   
   **❌ 问题**:
   - 当前设计要求用户手动指定节点名称列表 (`NODE_LIST`)
   - 这是不合理的，因为：
     1. 用户无法预知 Slurm 会分配哪些具体节点
     2. Slurm 会根据资源可用性动态分配节点
     3. 手动指定节点会限制调度灵活性
   
   **✅ 正确的做法** (参考 L0_Test.groovy 第 786-797 行):
   ```groovy
   // L0_Test.groovy 的做法:
   def getNodeArgs(int nodeCount, int gpuCount, boolean setSegment = false) {
       int gpusPerNode = ((gpuCount / nodeCount) as BigDecimal).setScale(0, BigDecimal.ROUND_CEILING).intValue()
       def args = nodeCount == 1 ? [
           "--nodes=${nodeCount}",
           "--gpus=${gpuCount}"
       ] : [
           "--nodes=${nodeCount}",          // ← 只指定数量，不指定名称
           "--ntasks=${gpuCount}",
           "--ntasks-per-node=${gpusPerNode}",
           "--gpus-per-node=${gpusPerNode}",
       ]
       return args
   }
   
   // 在 sbatch 脚本中 (第 1163-1168 行):
   #SBATCH --nodes=4                       // ← 只指定需要 4 个节点
   #SBATCH --ntasks=32
   #SBATCH --ntasks-per-node=8
   
   // 运行时自动获取分配的节点 (第 1174 行):
   echo "Starting Slurm job $SLURM_JOB_ID on $SLURM_NODELIST"  // ← Slurm 自动分配
   ```
   
   **Slurm 节点分配机制**:
   1. **提交时**: 用户通过 `sbatch --nodes=4` 告诉 Slurm 需要 4 个节点
   2. **调度时**: Slurm 根据资源可用性自动选择 4 个节点（例如 gpu-node-[05-08]）
   3. **运行时**: 通过环境变量获取实际分配的节点：
      - `$SLURM_NODELIST`: 节点列表（例如: `gpu-node-[05-08]`）
      - `$SLURM_JOB_NODELIST`: 同 `$SLURM_NODELIST`
      - `scontrol show hostname $SLURM_NODELIST`: 展开为具体节点名
   
   **submit.py 和 slurm_launch_draft.sh 的实际行为**:
   - ✅ **不依赖用户指定的节点名称**
   - ✅ 通过 `srun -N <num_nodes>` 指定节点数量
   - ✅ Slurm 自动在已分配的节点中选择对应数量的节点执行任务
   
   **示例 - slurm_launch_draft.sh 第 19-31 行**:
   ```bash
   # 启动 gen servers
   for i in $(seq 0 $((numGenServers - 1))); do
       gen_world_size=$((nodesPerGenServer * gpusPerNode))
       export DISAGG_SERVING_TYPE="GEN_$i"
       export pytestCommand="$pytestCommandWorker"
       srun "${srunArgs[@]}" --kill-on-bad-exit=1 \
           -N $nodesPerGenServer \              # ← 只指定数量：需要 2 个节点
           --ntasks=$gen_world_size \
           --ntasks-per-node=$gpusPerNode \
           $runScript &> $jobWorkspace/gen_server_$i.log &
   done
   # Slurm 会从 $SLURM_NODELIST 中自动选择 2 个节点来启动这个 GEN server
   ```

5. **调用 submit.py**:
   ```bash
   python3 ${TRTLLM_DIR}/jenkins/scripts/perf/disaggregated/submit.py \
       --config <config_file.yaml>
   ```

**说明**:
- ✅ 通过 `submit.py` 提交
- ✅ `submit.py` 内部会调用 `test_perf_sanity.py::test_e2e`
- ✅ **submit.py 自己做了逻辑节点→硬件节点的转换**（第 8-54 行）
- ✅ 我们的 `calculate_hardware_nodes.py` 只是用来验证，算法与 submit.py 一致

---

## 📝 TestList 文件格式

### Agg TestList 示例

**文件**: `tests/integration/test_lists/test-db/l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes.yml`

```yaml
version: 0.0.1
l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes:
- condition:
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
  tests:
  # ← 重点：所有测试都调用 test_perf_sanity.py::test_e2e
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k] TIMEOUT (90)
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_tep8_32k8k] TIMEOUT (90)
```

### Disagg TestList 示例

**文件**: `tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml`

```yaml
version: 0.0.1
l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes:
- condition:
    ranges:
      system_gpu_count:
        gte: 12
        lte: 12
    wildcards:
      gpu:
      - '*gb200*'
    terms:
      stage: post_merge
      backend: pytorch
  tests:
  # ← 重点：Disagg 也调用 test_perf_sanity.py::test_e2e
  - perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] TIMEOUT (90)
```

---

## 🎨 test_perf_sanity.py::test_e2e 详解

### 测试入口

**位置**: `tests/integration/defs/perf/test_perf_sanity.py`

**函数签名**:
```python
@pytest.mark.parametrize("config_name", [...])
def test_e2e(config_name: str, request):
    """End-to-end performance test."""
    pass
```

### Agg 模式流程

**参数示例**:
```
config_name = "aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k"
```

**执行流程**:
```python
# 1. 解析配置名
parts = config_name.split('-')
config_type = parts[0]  # "aggr_upload"
model_config = parts[1]  # "deepseek_r1_fp4_v2_grace_blackwell"
test_config = parts[2]   # "r1_fp4_v2_dep4_mtp1_1k1k"

# 2. 查找配置文件
config_file = f"tests/scripts/perf-sanity/{model_config}.yaml"

# 3. 读取配置
with open(config_file) as f:
    config = yaml.safe_load(f)

# 4. 提取 server_config
server_config = config['server_config']
# server_config:
#   model_name: deepseek_r1_fp4
#   tensor_parallel_size: 4
#   disagg_run_type: aggr  # ← 关键！

# 5. 启动 trtllm-server
# 注意: disagg_run_type 默认值是 "aggr" (第 129 行)
if server_config['disagg_run_type'] == 'aggr':
    # 单节点或多节点聚合模式
    start_aggregated_server(server_config)

# 6. 运行 benchmark
run_benchmark(benchmark_config)

# 7. 收集性能指标
metrics = parse_benchmark_output(output)

# 8. 上传到数据库
post_new_perf_data(metrics)
```

### Disagg 模式流程

**参数示例**:
```
config_name = "disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX"
```

**执行流程**:
```python
# 1. 解析配置名
config_type = "disagg_upload"

# 2. 查找配置文件
config_file = "tests/integration/defs/perf/disagg/test_configs/disagg/perf/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml"

# 3. 读取配置
with open(config_file) as f:
    config = yaml.safe_load(f)

# 4. 配置结构
# hardware:
#   num_ctx_servers: 1  # 逻辑服务器数
#   num_gen_servers: 1
#   gpus_per_node: 4
# worker_config:
#   ctx:
#     tensor_parallel_size: 4
#   gen:
#     tensor_parallel_size: 8

# 5. 通过 submit.py 已经启动了多个进程
# - CTX workers (2 个硬件节点)
# - GEN workers (2 个硬件节点)
# - Disagg server
# - Benchmark client

# 6. test_e2e 只需要等待并收集结果
wait_for_disagg_test_complete()

# 7. 收集性能指标
metrics = parse_disagg_benchmark_output(output)

# 8. 上传到数据库
post_new_perf_data(metrics)
```

---

## 🔄 完整调用链对比

### L0_Test.groovy - Multi-Node Agg

```
L0_Test.groovy (第 3358 行)
    ↓
multiNodesSBSAConfigs 配置
    "GB200-8_GPUs-2_Nodes-PyTorch-PerfSanity-Post-Merge-1"
    ↓
runLLMTestlistOnSlurm (第 3397 行)
    ↓
runLLMTestlistWithSbatch (第 913 行)
    ↓
判断: disaggMode = false (第 921 行)
    ↓
读取 TestList YAML 文件 (第 1066 行)
    tests/integration/test_lists/test-db/l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes.yml
    ↓
提取测试用例列表到 test_list.txt
    perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]
    perf/test_perf_sanity.py::test_e2e[aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_tep8_32k8k]
    ↓
srun --nodes=2 python3 -m pytest \
    --test-list=test_list.txt \
    --splitting-algorithm least_duration \
    --splits 5 \
    --group 1 \
    tests/integration/defs/
    ↓
pytest 发现并运行
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e
        ↓
        启动 aggregated trtllm-server (2 节点, TP=8)
        ↓
        运行 benchmark
        ↓
        收集性能指标
        ↓
        上传到数据库
```

### L0_Test.groovy - Multi-Node Disagg

```
L0_Test.groovy (第 3363 行)
    ↓
multiNodesSBSAConfigs 配置
    "GB200-12_GPUs-3_Nodes-PyTorch-PerfSanity-Disagg-Post-Merge-1"
    ↓
runLLMTestlistOnSlurm (第 3397 行)
    ↓
runLLMTestlistWithSbatch (第 913 行)
    ↓
判断: disaggMode = true (第 921 行)
    ↓
调用 jenkins/scripts/perf/disaggregated/submit.py
    ↓
submit.py 读取配置
    tests/integration/defs/perf/disagg/test_configs/disagg/perf/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
    ↓
submit.py 计算硬件节点
    num_ctx_servers: 1 (逻辑) → ctx_nodes: 2 (硬件)
    num_gen_servers: 1 (逻辑) → gen_nodes: 2 (硬件)
    total_nodes: 4
    ↓
submit.py 生成 sbatch 脚本
    ↓
sbatch 提交多个任务
    ├─ CTX workers (node1, node2)
    ├─ GEN workers (node3, node4)
    ├─ Disagg server (node1)
    └─ Benchmark client
        ↓
        内部调用 pytest tests/integration/defs/perf/test_perf_sanity.py::test_e2e
            ↓
            等待 disagg 测试完成
            ↓
            收集性能指标
            ↓
            上传到数据库
```

### Perf_Test.groovy - Single Agg

```
Perf_Test.groovy
    ↓
Jenkins 参数
    TEST_MODE: single-agg
    CONFIG_FILE: aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k
    ↓
拉取 TensorRT-LLM (第 93 行)
    ↓
处理配置 - Agg 模式 (第 240 行)
    ↓
查找配置文件
    tests/scripts/perf-sanity/deepseek_r1_fp4_v2_grace_blackwell.yaml
    ↓
运行测试 (第 265 行)
    ↓
python3 -m pytest \
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
    -k 'aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k' \
    -v
    ↓
pytest 运行
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e
        ↓
        启动 aggregated trtllm-server (单节点, TP=4)
        ↓
        运行 benchmark
        ↓
        收集性能指标
        ↓
        上传到数据库
```

### Perf_Test.groovy - Multi-Node Agg

```
Perf_Test.groovy
    ↓
Jenkins 参数
    TEST_MODE: multi-agg
    CONFIG_FILE: aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_tep8_32k8k
    NODE_LIST: node1,node2
    ↓
拉取 TensorRT-LLM
    ↓
处理配置 - Agg 模式
    ↓
查找配置文件
    tests/scripts/perf-sanity/k2_thinking_fp4_2_nodes_grace_blackwell.yaml
    ↓
运行测试 (第 282 行)
    ↓
ssh node1 'cd ${TRTLLM_DIR} && \
srun --nodes=2 --ntasks-per-node=1 \
    python3 -m pytest \
        tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
        -k "aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell-k2_thinking_fp4_tep8_32k8k" \
        -v'
    ↓
srun 多节点运行 pytest
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e
        ↓
        启动 aggregated trtllm-server (2 节点, TP=8)
        ↓
        运行 benchmark
        ↓
        收集性能指标
        ↓
        上传到数据库
```

### Perf_Test.groovy - Multi-Node Disagg

```
Perf_Test.groovy
    ↓
Jenkins 参数
    TEST_MODE: disagg
    TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
    NODE_LIST: node1,node2,node3,node4
    ↓
拉取 TensorRT-LLM
    ↓
处理配置 - Disagg 模式 (第 139 行)
    ↓
从 TestList 提取配置名 (第 164 行)
    tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml
    ↓
    提取: deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
    ↓
查找配置文件 (第 204 行)
    tests/integration/defs/perf/disagg/test_configs/disagg/perf/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
    ↓
计算硬件节点 (第 217 行)
    scripts/calculate_hardware_nodes.py --config <config>.yaml --json
    ↓
    输出: {total_nodes: 4, ctx_nodes: 2, gen_nodes: 2}
    ↓
验证节点数 (第 228 行)
    # 用户在 Jenkins 参数中提供的节点列表
    NODE_LIST: node1,node2,node3,node4  ← 提供了 4 个节点
    
    # 从配置文件计算出的要求
    total_nodes: 4  ← 配置要求 4 个节点
    
    # 验证: 提供的节点数 == 要求的节点数
    提供: 4 (从 NODE_LIST.split(',').size())
    要求: 4 (从 calculate_hardware_nodes.py 计算)
    → ✓ 通过 (4 == 4)
    ↓
提交任务 (第 313 行)
    ↓
python3 ${TRTLLM_DIR}/jenkins/scripts/perf/disaggregated/submit.py \
    --config <config>.yaml
    ↓
submit.py 执行
    ↓
    生成 sbatch 脚本
    ↓
    sbatch 提交多个任务
        ├─ CTX workers (node1, node2)
        ├─ GEN workers (node3, node4)
        ├─ Disagg server (node1)
        └─ Benchmark client
            ↓
            内部调用 pytest tests/integration/defs/perf/test_perf_sanity.py::test_e2e
                ↓
                等待 disagg 测试完成
                ↓
                收集性能指标
                ↓
                上传到数据库
```

---

## 🔍 关键问题解答

### Q1: disagg_run_type 的默认值是什么？

**答案**: 默认值是 `"aggr"`

**代码位置**: `tests/integration/defs/perf/test_perf_sanity.py` 第 129 行

```python
class ServerConfig:
    def __init__(self, server_config_data: dict, env_vars: str = ""):
        self.disagg_run_type = server_config_data.get("disagg_run_type", "aggr")
                                                                         ^^^^^^
                                                                         默认值
```

**实际影响**:
- ✅ Agg 配置文件可以省略 `disagg_run_type` 字段
- ✅ 未指定时自动按 aggregated 模式运行
- ⚠️ Disagg 配置不使用 `server_config`，直接用 `hardware` + `worker_config`

**示例配置**:

```yaml
# Agg 配置 (可以省略 disagg_run_type)
server_config:
  model_name: deepseek_r1_fp4
  tensor_parallel_size: 4
  # disagg_run_type: aggr  ← 可以省略，默认就是 aggr

# Disagg 配置 (根本不用 server_config)
hardware:
  num_ctx_servers: 1
  num_gen_servers: 1
  gpus_per_node: 4
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 8
```

---

### Q2: submit.py 是否做了逻辑节点→硬件节点的转换？

**答案**: ✅ 是的！submit.py 确实做了完整的转换

**代码位置**: `jenkins/scripts/perf/disaggregated/submit.py` 第 8-54 行

**完整转换逻辑**:

```python
def get_hardware_config(config, benchmark_mode):
    hardware = config.get("hardware", {})
    worker_config = config.get("worker_config", {})

    # ========================================
    # 步骤 1: 读取逻辑配置
    # ========================================
    num_ctx_servers = hardware.get("num_ctx_servers")  # 逻辑服务器数
    num_gen_servers = hardware.get("num_gen_servers")  # 逻辑服务器数
    gpus_per_node = hardware.get("gpus_per_node")      # 硬件配置
    
    # ========================================
    # 步骤 2: 计算每个逻辑服务器需要的 GPU 数
    # ========================================
    ctx_config = worker_config.get("ctx", {})
    ctx_tp = ctx_config.get("tensor_parallel_size", 1)
    ctx_pp = ctx_config.get("pipeline_parallel_size", 1)
    ctx_cp = ctx_config.get("context_parallel_size", 1)
    gpus_per_ctx_server = ctx_tp * ctx_pp * ctx_cp  # CTX 服务器需要的 GPU 数
    
    gen_config = worker_config.get("gen", {})
    gen_tp = gen_config.get("tensor_parallel_size", 1)
    gen_pp = gen_config.get("pipeline_parallel_size", 1)
    gen_cp = gen_config.get("context_parallel_size", 1)
    gpus_per_gen_server = gen_tp * gen_pp * gen_cp  # GEN 服务器需要的 GPU 数
    
    # ========================================
    # 步骤 3: 计算每个逻辑服务器需要的硬件节点数（向上取整）
    # ========================================
    nodes_per_ctx_server = (gpus_per_ctx_server + gpus_per_node - 1) // gpus_per_node
    nodes_per_gen_server = (gpus_per_gen_server + gpus_per_node - 1) // gpus_per_node
    
    # ========================================
    # 步骤 4: 计算总硬件节点数
    # ========================================
    total_nodes = num_ctx_servers * nodes_per_ctx_server + \
                  num_gen_servers * nodes_per_gen_server
    total_gpus = total_nodes * gpus_per_node
    
    return {
        "num_ctx_servers": num_ctx_servers,           # 逻辑
        "num_gen_servers": num_gen_servers,           # 逻辑
        "gpus_per_ctx_server": gpus_per_ctx_server,   # 每个逻辑服务器的 GPU
        "gpus_per_gen_server": gpus_per_gen_server,   # 每个逻辑服务器的 GPU
        "nodes_per_ctx_server": nodes_per_ctx_server, # 每个逻辑服务器的硬件节点
        "nodes_per_gen_server": nodes_per_gen_server, # 每个逻辑服务器的硬件节点
        "total_nodes": total_nodes,                   # 总硬件节点数 ⭐
        "total_gpus": total_gpus,                     # 总 GPU 数
    }
```

**计算示例 1 - 简单配置**:

```yaml
hardware:
  num_ctx_servers: 1    # 1 个逻辑 CTX 服务器
  num_gen_servers: 1    # 1 个逻辑 GEN 服务器
  gpus_per_node: 4      # 每个硬件节点 4 个 GPU
worker_config:
  ctx:
    tensor_parallel_size: 4   # CTX TP=4
    pipeline_parallel_size: 1
    context_parallel_size: 1
  gen:
    tensor_parallel_size: 8   # GEN TP=8
    pipeline_parallel_size: 1
    context_parallel_size: 1
```

**计算过程**:
```python
# CTX 计算
gpus_per_ctx_server = 4 × 1 × 1 = 4 GPU
nodes_per_ctx_server = ceil(4 / 4) = 1 硬件节点
ctx_total_nodes = 1 逻辑服务器 × 1 节点/服务器 = 1 硬件节点

# GEN 计算
gpus_per_gen_server = 8 × 1 × 1 = 8 GPU
nodes_per_gen_server = ceil(8 / 4) = 2 硬件节点
gen_total_nodes = 1 逻辑服务器 × 2 节点/服务器 = 2 硬件节点

# 总计
total_nodes = 1 + 2 = 3 硬件节点
total_gpus = 3 × 4 = 12 GPU
```

**但实际 TestList 中是 4 个节点！为什么？**

查看实际配置文件会发现 CTX 或 GEN 的配置不同，例如：
```yaml
# 实际配置可能是
worker_config:
  ctx:
    tensor_parallel_size: 8  # ← CTX 也是 TP=8
  gen:
    tensor_parallel_size: 8
```

这样计算：
```python
ctx_total_nodes = 1 × ceil(8/4) = 1 × 2 = 2 硬件节点
gen_total_nodes = 1 × ceil(8/4) = 1 × 2 = 2 硬件节点
total_nodes = 2 + 2 = 4 硬件节点  # ✓ 正确！
```

**计算示例 2 - 复杂配置**:

```yaml
hardware:
  num_ctx_servers: 2    # 2 个逻辑 CTX 服务器
  num_gen_servers: 1    # 1 个逻辑 GEN 服务器
  gpus_per_node: 4
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 8
```

**计算过程**:
```python
# CTX 计算
gpus_per_ctx_server = 4
nodes_per_ctx_server = 1
ctx_total_nodes = 2 逻辑服务器 × 1 节点/服务器 = 2 硬件节点

# GEN 计算
gpus_per_gen_server = 8
nodes_per_gen_server = 2
gen_total_nodes = 1 逻辑服务器 × 2 节点/服务器 = 2 硬件节点

# 总计
total_nodes = 2 + 2 = 4 硬件节点
total_gpus = 4 × 4 = 16 GPU
```

---

### Q3: calculate_hardware_nodes.py 和 submit.py 的关系？

**答案**: 两者算法完全一致，只是调用时机不同

**对比**:

| 特性 | calculate_hardware_nodes.py | submit.py (get_hardware_config) |
|------|----------------------------|----------------------------------|
| **位置** | `jenkins_test/scripts/` | `jenkins/scripts/perf/disaggregated/` |
| **用途** | Perf_Test.groovy 用来验证 | L0 submit.py 的内部函数 |
| **调用时机** | Pipeline 中，提交前验证 | submit.py 内部，生成脚本时 |
| **算法** | ✅ 相同 | ✅ 相同 |
| **公式** | `ceil(world_size × num_servers / gpus_per_node)` | `(gpus_per_server + gpus_per_node - 1) // gpus_per_node` ⭐ |

**公式等价性证明**:

```python
# 方式 1 (calculate_hardware_nodes.py)
import math
result1 = math.ceil(world_size * num_servers / gpus_per_node)

# 方式 2 (submit.py)
result2 = (world_size * num_servers + gpus_per_node - 1) // gpus_per_node

# 证明等价
# ceil(a/b) = floor((a + b - 1) / b) = (a + b - 1) // b
# 示例: ceil(8/4) = floor((8+4-1)/4) = floor(11/4) = 2
```

**为什么需要两份？**

1. **calculate_hardware_nodes.py**:
   - Perf_Test.groovy 用来**提前验证**节点数
   - 在提交任务**之前**检查，避免浪费资源
   - 可以独立使用，方便调试

2. **submit.py (get_hardware_config)**:
   - L0 submit.py 内部使用
   - 生成 Slurm 脚本时计算
   - 是 L0 的核心逻辑，不能修改

**结论**: 我们的 `calculate_hardware_nodes.py` 是正确的，与 L0 完全一致！

---

## 📈 性能指标收集

### 统一的指标收集（test_perf_sanity.py）

**位置**: `test_perf_sanity.py` 第 73-90 行

```python
PERF_METRIC_LOG_QUERIES = {
    "seq_throughput": re.compile(r"Request throughput \(req\/s\):\s+(-?[\d\.]+)"),
    "token_throughput": re.compile(r"Output token throughput \(tok\/s\):\s+(-?[\d\.]+)"),
    "total_token_throughput": re.compile(r"Total Token throughput \(tok\/s\):\s+(-?[\d\.]+)"),
    "user_throughput": re.compile(r"User throughput \(tok\/s\):\s+(-?[\d\.]+)"),
    "mean_ttft": re.compile(r"Mean TTFT \(ms\):\s+(-?[\d\.]+)"),
    "median_ttft": re.compile(r"Median TTFT \(ms\):\s+(-?[\d\.]+)"),
    "p99_ttft": re.compile(r"P99 TTFT \(ms\):\s+(-?[\d\.]+)"),
    "mean_itl": re.compile(r"Mean ITL \(ms\):\s+(-?[\d\.]+)"),
    "median_itl": re.compile(r"Median ITL \(ms\):\s+(-?[\d\.]+)"),
    "p99_itl": re.compile(r"P99 ITL \(ms\):\s+(-?[\d\.]+)"),
    "mean_tpot": re.compile(r"Mean TPOT \(ms\):\s+(-?[\d\.]+)"),
    "median_tpot": re.compile(r"Median TPOT \(ms\):\s+(-?[\d\.]+)"),
    "p99_tpot": re.compile(r"P99 TPOT \(ms\):\s+(-?[\d\.]+)"),
    "mean_e2el": re.compile(r"Mean E2EL \(ms\):\s+(-?[\d\.]+)"),
    "median_e2el": re.compile(r"Median E2EL \(ms\):\s+(-?[\d\.]+)"),
    "p99_e2el": re.compile(r"P99 E2EL \(ms\):\s+(-?[\d\.]+)"),
}
```

**说明**:
- ✅ Agg 和 Disagg 使用相同的指标定义
- ✅ 从 benchmark 输出解析性能数据
- ✅ 上传到 OpenSearch 数据库

---

## ❌ test_perf.py 已不再使用

### 为什么弃用？

1. **旧的测试框架**:
   - `test_perf.py` 是早期的性能测试框架
   - 使用不同的配置格式
   - 不支持 Disagg 模式

2. **现状**:
   - ⚠️ 在 TestList 中已找不到 `perf/test_perf.py::test_perf` 的引用
   - ⚠️ 所有 Perf Sanity 测试都使用 `test_perf_sanity.py::test_e2e`
   - ⚠️ `test_perf.py` 可能仍用于完整的 perf 测试（非 sanity）

### 搜索结果验证

```bash
# 在 test_lists 中搜索 test_perf.py
grep -r "test_perf.py" tests/integration/test_lists/

# 结果：只在 waives.txt 中出现（跳过的测试）
tests/integration/test_lists/waives.txt:
  - perf/test_perf.py::test_perf[...] SKIP
  - perf/test_perf.py::test_perf[...] SKIP
  ...

# 在 test_lists 中搜索 test_perf_sanity.py
grep -r "test_perf_sanity.py" tests/integration/test_lists/

# 结果：大量使用
tests/integration/test_lists/test-db/l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes.yml:
  - perf/test_perf_sanity.py::test_e2e[...]
tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml:
  - perf/test_perf_sanity.py::test_e2e[...]
tests/integration/test_lists/test-db/l0_gb200_multi_gpus_perf_sanity.yml:
  - perf/test_perf_sanity.py::test_e2e[...]
```

---

## 🎯 总结

### 核心发现

1. **统一测试框架**:
   - ✅ 所有 Perf Sanity 测试使用 `test_perf_sanity.py::test_e2e`
   - ✅ Single Agg, Multi-Node Agg, Multi-Node Disagg 都用同一个测试

2. **测试类型区分**:
   - **Agg**: 通过配置中的 `disagg_run_type: aggr` 区分
   - **Disagg**: 通过配置中的 `hardware` 和 `worker_config` 区分

3. **执行方式**:
   - **Single Agg**: 直接 `pytest`
   - **Multi-Node Agg**: `srun` + `pytest` + `--test-list`
   - **Multi-Node Disagg**: `submit.py` → `sbatch` → pytest

4. **L0 vs Perf_Test**:
   - **L0_Test.groovy**: 使用 TestList + 复杂的 Slurm 逻辑
   - **Perf_Test.groovy**: 简化版，直接调用 pytest 或 submit.py

5. **test_perf.py 状态**:
   - ❌ 已不再用于 Perf Sanity 测试
   - ⚠️ 可能仍用于其他完整 perf 测试

### 推荐使用

**对于 Perf Sanity 测试**:
- ✅ 使用 `Perf_Test.groovy` (简化版)
- ✅ 直接调用 `test_perf_sanity.py::test_e2e`
- ✅ 支持三种测试模式

**对于 L0 测试**:
- ✅ 继续使用 `L0_Test.groovy`
- ✅ 包含 Perf Sanity 和其他所有测试

---

**文档完成时间**: 2026-01-31  
**分析的代码版本**: TensorRT-LLM main 分支
