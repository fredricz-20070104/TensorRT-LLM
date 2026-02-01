# CI 测试执行流程详解 - 三种模式全覆盖

## 📚 目录
1. [文件说明](#文件说明)
2. [模式 1: Single-Node Agg (单机聚合)](#模式-1-single-node-agg-单机聚合)
3. [模式 2: Multi-Node Agg (多机聚合)](#模式-2-multi-node-agg-多机聚合)
4. [模式 3: Multi-Node Disagg (多机分离)](#模式-3-multi-node-disagg-多机分离)
5. [对比总结](#对比总结)

---

## 📄 文件说明

### 1. `debug_cases.txt` (TXT 格式)
- **用途**: 快速 Debug，手动指定测试用例
- **格式**: 一行一个 pytest 路径
- **适用**: 三种模式都支持

### 2. `perf_test_cases.yaml` (YAML 格式)
- **用途**: 生产环境测试套件管理
- **格式**: 按节点数分组的 YAML 配置
- **适用**: 三种模式都支持，有明确分组

---

## 🔧 模式 1: Single-Node Agg (单机聚合)

### 📋 定义
- **节点数**: 1 个节点
- **GPU 数**: 4-8 个 GPU（单节点内）
- **特点**: 所有计算在一个节点上完成
- **配置文件位置**: `tests/scripts/perf-sanity/*.yaml`

---

### 📝 方式 A: 使用 debug_cases.txt

#### 文件内容示例
```txt
# jenkins_test/testlists/debug_cases.txt

# Single-Node Agg 测试
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[profiling-llama3_8b]
```

#### 执行流程

```
┌─────────────────────────────────────────────────────────────────┐
│ 1️⃣ Jenkins 触发 (中转机)                                          │
│                                                                  │
│    用户选择:                                                       │
│    - TESTLIST = 'debug_cases'                                   │
│    - FILTER_MODE = 'single-agg'  # 或 'all'                     │
│    - CLUSTER = 'gb200'                                          │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2️⃣ sync_and_run.sh (中转机 → Cluster)                            │
│                                                                  │
│    SCP 同步文件:                                                   │
│    ├─ testlists/debug_cases.txt                                 │
│    ├─ scripts/                                                  │
│    └─ TensorRT-LLM/                                             │
│                                                                  │
│    SSH 执行:                                                      │
│    └─ cluster: run_perf_tests.sh --testlist debug_cases.txt    │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3️⃣ parse_unified_testlist.py (Cluster)                          │
│                                                                  │
│    解析 debug_cases.txt:                                         │
│    ├─ 读取每一行                                                  │
│    ├─ 识别测试类型:                                                │
│    │   "profiling-deepseek_r1_fp4_v2_blackwell"                 │
│    │   → test_type = "profiling"                                │
│    │   → config_yml = "deepseek_r1_fp4_v2_blackwell"           │
│    │   → mode = "single-agg" (默认)                             │
│    │                                                             │
│    └─ 输出 JSON:                                                  │
│        {                                                         │
│          "tests_by_mode": {                                     │
│            "single-agg": [                                      │
│              "test_perf_sanity.py::test_e2e[profiling-...]",   │
│              "test_perf_sanity.py::test_e2e[benchmark-...]"    │
│            ]                                                     │
│          }                                                       │
│        }                                                         │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4️⃣ run_single_agg_test.sh (Cluster)                             │
│                                                                  │
│    对于每个测试:                                                    │
│    test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2] │
│                                                                  │
│    ├─ 查找配置文件:                                                │
│    │   tests/scripts/perf-sanity/deepseek_r1_fp4_v2_blackwell.yaml│
│    │                                                             │
│    ├─ 提交 Slurm 任务 (单节点):                                    │
│    │   srun \                                                    │
│    │     --nodes=1 \              # 单节点                       │
│    │     --gpus=8 \               # 8 个 GPU                    │
│    │     --container-image=tensorrt-llm:latest \                │
│    │     pytest tests/integration/defs/perf/test_perf_sanity.py\│
│    │       ::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]  │
│    │                                                             │
│    └─ test_e2e 执行流程:                                          │
│        ├─ 解析测试 ID                                             │
│        ├─ 读取 YAML 配置                                          │
│        ├─ 启动 trtllm-server (单节点, 8 GPUs)                    │
│        ├─ 运行 benchmark/profiling                              │
│        └─ 收集性能指标 (throughput, latency, etc.)               │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 5️⃣ 结果收集                                                       │
│                                                                  │
│    Cluster:~/workspace/output/ → SCP → 中转机:~/output_${BUILD} │
│    └─ Jenkins archiveArtifacts                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

### 📝 方式 B: 使用 perf_test_cases.yaml

#### 文件内容示例
```yaml
# jenkins_test/config/perf_test_cases.yaml

single_agg_tests:
  - aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml
  - aggr_upload-config_database_b200_nvl.yaml-r1_fp8_dep8_mtp1_1k1k
  - aggr_upload-config_database_h200_sxm.yaml

execution_config:
  timeout:
    single_agg: 3600  # 1 hour
```

#### 执行流程（与 TXT 类似，但有额外配置）

```
解析 YAML:
  ├─ 读取 single_agg_tests 列表
  ├─ 应用 execution_config (timeout, docker_image)
  └─ 转换为 pytest 路径:
      test_perf_sanity.py::test_e2e[aggr_upload-k2_thinking_fp4_...]
      
执行命令:
  srun --nodes=1 --gpus=8 --time=3600 \
    pytest test_perf_sanity.py::test_e2e[...]
```

---

## 🔧 模式 2: Multi-Node Agg (多机聚合)

### 📋 定义
- **节点数**: 2+ 个节点
- **GPU 数**: 8-16 个 GPU（跨多个节点）
- **特点**: 模型并行（TP/PP）跨多个节点
- **配置文件位置**: `tests/scripts/perf-sanity/*.yaml`

---

### 📝 方式 A: 使用 debug_cases.txt

#### 文件内容示例
```txt
# jenkins_test/testlists/debug_cases.txt

# Multi-Node Agg 测试 (2 nodes)
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]
test_perf_sanity.py::test_e2e[profiling-k2_thinking_fp4_2nodes]
```

#### 执行流程

```
┌─────────────────────────────────────────────────────────────────┐
│ 1️⃣ Jenkins 触发                                                  │
│    - TESTLIST = 'debug_cases'                                   │
│    - FILTER_MODE = 'multi-agg'                                  │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2️⃣ sync_and_run.sh (同 Single-Agg)                              │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3️⃣ parse_unified_testlist.py                                    │
│                                                                  │
│    识别为 Multi-Agg:                                              │
│    - 方式 1: 手动标记 # mode:multi-agg                            │
│    - 方式 2: YAML condition.terms.nodes > 1                     │
│    - 方式 3: 配置文件名包含 "multi_node" 或 "2_nodes"              │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4️⃣ run_multi_agg_test.sh (Cluster)                              │
│                                                                  │
│    对于测试: benchmark-llama3_70b_tp4                             │
│                                                                  │
│    ├─ 查找配置文件:                                                │
│    │   tests/scripts/perf-sanity/llama3_70b_tp4.yaml           │
│    │   └─ 配置示例:                                               │
│    │       server_configs:                                       │
│    │         tensor_parallel_size: 4    # TP=4                  │
│    │         gpus: 8                    # 需要 8 GPUs           │
│    │         gpus_per_node: 4           # 每节点 4 GPUs         │
│    │                                                             │
│    ├─ 计算节点需求:                                                │
│    │   nodes = ceil(8 GPUs / 4 GPUs per node) = 2 nodes        │
│    │                                                             │
│    ├─ 提交 Slurm 任务 (多节点):                                    │
│    │   srun \                                                    │
│    │     --nodes=2 \              # 2 个节点                     │
│    │     --gpus-per-node=4 \      # 每节点 4 GPU                │
│    │     --ntasks-per-node=1 \    # 每节点 1 任务                │
│    │     --container-image=tensorrt-llm:latest \                │
│    │     --container-mounts=/data:/data \                       │
│    │     pytest test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]│
│    │                                                             │
│    └─ test_e2e 执行流程:                                          │
│        ├─ 启动 trtllm-server (跨 2 节点, TP=4)                   │
│        │   Node 1: GPU 0-3 → TP rank 0-3                        │
│        │   Node 2: GPU 0-3 → TP rank 4-7 (如果需要)              │
│        │                                                          │
│        ├─ 模型分片:                                                │
│        │   模型被分成 4 份，分布在 4 个 GPU 上                      │
│        │   通过 NCCL/UCX 进行跨节点通信                            │
│        │                                                          │
│        ├─ 运行 benchmark                                         │
│        └─ 收集性能指标                                             │
└─────────────────────────────────────────────────────────────────┘
```

---

### 📝 方式 B: 使用 perf_test_cases.yaml

#### 文件内容示例
```yaml
# jenkins_test/config/perf_test_cases.yaml

multi_agg_2nodes_tests:
  # 2 节点，8 GPUs
  - aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml
  - aggr_upload-multi_node_config.yaml

execution_config:
  node_groups:
    gb200_2nodes: "gb200-node1,gb200-node2"  # 指定节点
  timeout:
    multi_agg: 7200  # 2 hours
```

#### 执行命令
```bash
# 指定节点列表
srun --nodes=2 \
  --nodelist=gb200-node1,gb200-node2 \
  --gpus-per-node=4 \
  --time=7200 \
  pytest test_perf_sanity.py::test_e2e[...]
```

---

## 🔧 模式 3: Multi-Node Disagg (多机分离)

### 📋 定义
- **节点数**: 3-8 个节点
- **GPU 数**: 12-32 个 GPU
- **特点**: 
  - PREFILL 节点：处理输入
  - KV_CACHE 节点：存储 KV cache
  - BENCHMARK 节点：发送请求和收集结果
- **配置文件位置**: `tests/integration/defs/perf/disagg/test_configs/disagg/perf/*.yaml`

---

### 📝 方式 A: 使用 debug_cases.txt

#### 文件内容示例
```txt
# jenkins_test/testlists/debug_cases.txt

# Multi-Node Disagg 测试 (3 nodes)
test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-UCX]
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]
```

#### 执行流程

```
┌─────────────────────────────────────────────────────────────────┐
│ 1️⃣ Jenkins 触发                                                  │
│    - TESTLIST = 'debug_cases'                                   │
│    - FILTER_MODE = 'disagg'                                     │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 2️⃣ sync_and_run.sh (同前)                                        │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 3️⃣ parse_unified_testlist.py                                    │
│                                                                  │
│    识别为 Disagg:                                                 │
│    - 测试 ID 包含 "disagg" 或 "_disagg"                           │
│    - 自动分类到 disagg 模式                                        │
│                                                                  │
│    解析:                                                          │
│    "disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-UCX"│
│    → test_type = "disagg_upload"                                │
│    → config_yml = "deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-UCX"│
│    → mode = "disagg"                                            │
└─────────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────────┐
│ 4️⃣ run_disagg_test.sh (Cluster)                                 │
│                                                                  │
│    对于测试: disagg_upload-deepseek-r1-fp4_...-UCX              │
│                                                                  │
│    ├─ 步骤 1: 查找配置文件                                         │
│    │   tests/integration/defs/perf/disagg/test_configs/disagg/perf/│
│    │     deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-UCX.yaml│
│    │                                                             │
│    │   配置文件示例:                                               │
│    │   server_configs:                                           │
│    │     - name: "prefill_server"                               │
│    │       disagg_run_type: "PREFILL"                           │
│    │       disagg_serving_type: "CONTEXT"  # ctx2 = 2 nodes    │
│    │       tensor_parallel_size: 8                              │
│    │       gpus: 8                                              │
│    │                                                             │
│    │     - name: "kv_server"                                    │
│    │       disagg_run_type: "KV"                                │
│    │       disagg_serving_type: "GENERATION"  # gen1 = 1 node  │
│    │       tensor_parallel_size: 4                              │
│    │       gpus: 4                                              │
│    │                                                             │
│    │     - name: "benchmark_client"                             │
│    │       disagg_serving_type: "BENCHMARK"                     │
│    │                                                             │
│    ├─ 步骤 2: 计算节点需求                                         │
│    │   python calculate_hardware_nodes.py                       │
│    │   └─ 输出: 需要 3 nodes (ctx2 + gen1 + benchmark1)         │
│    │       - PREFILL (CONTEXT): 2 nodes × 4 GPUs = 8 GPUs      │
│    │       - KV (GENERATION): 1 node × 4 GPUs = 4 GPUs         │
│    │       - BENCHMARK: 1 node × 0 GPUs (client only)          │
│    │       Total: 3 nodes, 12 GPUs                              │
│    │                                                             │
│    ├─ 步骤 3: 准备 Disagg 启动脚本                                 │
│    │   创建 slurm_launch_draft.sh:                              │
│    │   #!/bin/bash                                              │
│    │   # Node 1-2: PREFILL servers                             │
│    │   srun --nodes=2 --gpus-per-node=4 \                      │
│    │     --output=prefill_%n.log \                             │
│    │     trtllm-server \                                        │
│    │       --disagg-type=PREFILL \                             │
│    │       --disagg-serving-type=CONTEXT \                     │
│    │       --transport=UCX \                                    │
│    │       --tp-size=8 &                                        │
│    │                                                             │
│    │   # Node 3: KV server                                      │
│    │   srun --nodes=1 --gpus-per-node=4 \                      │
│    │     --output=kv_%n.log \                                   │
│    │     trtllm-server \                                        │
│    │       --disagg-type=KV \                                   │
│    │       --disagg-serving-type=GENERATION \                  │
│    │       --transport=UCX \                                    │
│    │       --tp-size=4 &                                        │
│    │                                                             │
│    │   # 等待服务就绪                                             │
│    │   sleep 60                                                 │
│    │                                                             │
│    │   # Node 4: BENCHMARK client                               │
│    │   srun --nodes=1 --gpus-per-node=0 \                      │
│    │     pytest test_perf_sanity.py::test_e2e[...]            │
│    │                                                             │
│    ├─ 步骤 4: 使用 submit.py 提交任务                              │
│    │   python jenkins/scripts/perf/disaggregated/submit.py \   │
│    │     --script slurm_launch_draft.sh \                      │
│    │     --nodes 3 \                                            │
│    │     --gpus-per-node 4                                      │
│    │                                                             │
│    └─ 步骤 5: 执行和监控                                           │
│        sbatch slurm_launch_draft.sh                             │
│        └─ Slurm 分配节点:                                         │
│            Node 1-2: PREFILL servers (8 GPUs, TP=8)            │
│            Node 3: KV server (4 GPUs, TP=4)                    │
│            Node 4: BENCHMARK client (运行 pytest)               │
│                                                                  │
│        执行流程:                                                   │
│        ├─ PREFILL 接收输入 → 处理 prompt → 发送 KV cache        │
│        ├─ KV 存储 cache → 生成 token                            │
│        └─ BENCHMARK 发送请求 → 收集结果 → 上传性能数据           │
└─────────────────────────────────────────────────────────────────┘
```

---

### 📝 方式 B: 使用 perf_test_cases.yaml

#### 文件内容示例
```yaml
# jenkins_test/config/perf_test_cases.yaml

disagg_3nodes_tests:
  # 3 节点，12 GPUs (ctx2_gen1)
  - disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-UCX
  - disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-NIXL

disagg_6nodes_tests:
  # 6 节点，24 GPUs (ctx6_gen1 or ctx4_gen2)
  - disagg_upload-deepseek-r1-fp4_8k1k_ctx6_gen1_dep16_bs64_eplb288_mtp0_ccb-UCX

disagg_8nodes_tests:
  # 8 节点，32 GPUs (ctx8_gen1)
  - disagg_upload-deepseek-r1-fp4_8k1k_ctx8_gen1_dep32_bs16_eplb288_mtp3_ccb-UCX

execution_config:
  node_groups:
    gb200_3nodes: "gb200-node1,gb200-node2,gb200-node3"
    gb200_6nodes: "gb200-node1,gb200-node2,gb200-node3,gb200-node4,gb200-node5,gb200-node6"
    gb200_8nodes: "gb200-node[1-8]"
  timeout:
    disagg: 10800  # 3 hours
```

#### 执行命令
```bash
# 3 节点 Disagg
sbatch --nodes=3 \
  --nodelist=gb200-node1,gb200-node2,gb200-node3 \
  --time=10800 \
  slurm_launch_draft.sh
```

---

## 📊 三种模式对比总结

| 特性 | Single-Node Agg | Multi-Node Agg | Multi-Node Disagg |
|------|----------------|----------------|------------------|
| **节点数** | 1 | 2+ | 3-8 |
| **GPU 数** | 4-8 | 8-16+ | 12-32+ |
| **拓扑** | 单机 TP/PP | 跨节点 TP/PP | PREFILL + KV + BENCH |
| **配置位置** | `tests/scripts/perf-sanity/` | 同左 | `tests/integration/defs/perf/disagg/test_configs/` |
| **执行脚本** | `run_single_agg_test.sh` | `run_multi_agg_test.sh` | `run_disagg_test.sh` |
| **Slurm 命令** | `srun --nodes=1` | `srun --nodes=2+` | `sbatch --nodes=3+` + 多脚本 |
| **通信** | GPU 内部/NVLink | NCCL/UCX 跨节点 | UCX/NIXL 跨节点 |
| **测试标识** | 默认 | 手动标记或 YAML | 包含 `*_disagg` 或 `disagg_upload` |
| **超时默认** | 1 hour | 2 hours | 3 hours |

---

## 🔑 关键配置解析

### Single-Node Agg 配置
```yaml
# tests/scripts/perf-sanity/deepseek_r1_fp4_v2_blackwell.yaml
server_configs:
  - name: "default_config"
    model_name: "deepseek_r1_0528_fp4_v2"
    tensor_parallel_size: 8    # TP=8, 单节点 8 GPU
    gpus: 8
    gpus_per_node: 8           # 所有 GPU 在一个节点
```

### Multi-Node Agg 配置
```yaml
# tests/scripts/perf-sanity/llama3_70b_tp4.yaml
server_configs:
  - name: "multi_node_config"
    model_name: "llama3_70b"
    tensor_parallel_size: 4    # TP=4
    gpus: 8                    # 总共 8 GPU
    gpus_per_node: 4           # 每节点 4 GPU → 需要 2 节点
```

### Multi-Node Disagg 配置
```yaml
# tests/integration/defs/perf/disagg/test_configs/disagg/perf/
# deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-UCX.yaml
server_configs:
  - name: "prefill_server"
    disagg_run_type: "PREFILL"
    disagg_serving_type: "CONTEXT"   # ctx2 = 2 nodes for PREFILL
    tensor_parallel_size: 8
    gpus: 8                          # 2 nodes × 4 GPUs = 8 GPUs
    gpus_per_node: 4

  - name: "kv_server"
    disagg_run_type: "KV"
    disagg_serving_type: "GENERATION" # gen1 = 1 node for KV
    tensor_parallel_size: 4
    gpus: 4                          # 1 node × 4 GPUs = 4 GPUs
    gpus_per_node: 4

  - name: "benchmark_client"
    disagg_serving_type: "BENCHMARK"  # Client node (no GPUs)
```

**节点计算**：
- `ctx2` = 2 PREFILL 节点
- `gen1` = 1 KV 节点
- `+1` BENCHMARK 节点
- **Total**: 3 节点

---

## 🎯 实际命令对比

### Single-Node Agg
```bash
srun --nodes=1 --gpus=8 \
  --container-image=tensorrt-llm:latest \
  pytest test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
```

### Multi-Node Agg
```bash
srun --nodes=2 --gpus-per-node=4 --ntasks-per-node=1 \
  --container-image=tensorrt-llm:latest \
  --container-mounts=/data:/data \
  pytest test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]
```

### Multi-Node Disagg
```bash
# 提交脚本（包含 PREFILL + KV + BENCHMARK）
sbatch --nodes=3 --gpus-per-node=4 slurm_launch_draft.sh

# slurm_launch_draft.sh 内部:
srun --nodes=2 trtllm-server --disagg-type=PREFILL &
srun --nodes=1 trtllm-server --disagg-type=KV &
sleep 60  # 等待服务就绪
srun --nodes=1 pytest test_perf_sanity.py::test_e2e[disagg_upload-...]
```

---

**总结**：
- **Single-Agg**: 1 节点，直接 srun
- **Multi-Agg**: 2+ 节点，srun 跨节点 TP
- **Disagg**: 3+ 节点，sbatch 编排多服务
