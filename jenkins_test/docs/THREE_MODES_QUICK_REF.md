# 三种测试模式快速对照

## 📊 一图看懂

```
┌─────────────────────┬─────────────────────┬─────────────────────┬─────────────────────┐
│                     │  Single-Node Agg    │  Multi-Node Agg     │  Multi-Node Disagg  │
├─────────────────────┼─────────────────────┼─────────────────────┼─────────────────────┤
│ 🖥️  节点数           │  1 节点             │  2+ 节点            │  3-8 节点           │
│ 🎮  GPU 数           │  4-8 GPU            │  8-16 GPU           │  12-32 GPU          │
│ ⏱️  超时             │  1 hour             │  2 hours            │  3 hours            │
│ 📂  配置文件         │  tests/scripts/     │  tests/scripts/     │  tests/integration/ │
│                     │  perf-sanity/       │  perf-sanity/       │  defs/perf/disagg/  │
│ 🔧  执行脚本         │  run_single_agg_    │  run_multi_agg_     │  run_disagg_test.sh │
│                     │  test.sh            │  test.sh            │                     │
│ 💻  Slurm 命令       │  srun --nodes=1     │  srun --nodes=2+    │  sbatch --nodes=3+  │
└─────────────────────┴─────────────────────┴─────────────────────┴─────────────────────┘
```

---

## 🎯 核心区别

### 架构对比

#### Single-Node Agg (单机)
```
┌──────────────────────┐
│   Node 1 (8 GPUs)    │
│                      │
│   trtllm-server      │
│   TP=8, PP=1         │
│                      │
│   ┌─┬─┬─┬─┬─┬─┬─┬─┐  │
│   │0│1│2│3│4│5│6│7│  │
│   └─┴─┴─┴─┴─┴─┴─┴─┘  │
│    All GPUs on       │
│    one node          │
└──────────────────────┘
```

#### Multi-Node Agg (多机聚合)
```
┌──────────────────────┐     ┌──────────────────────┐
│   Node 1 (4 GPUs)    │<--->│   Node 2 (4 GPUs)    │
│                      │ NCCL│                      │
│   trtllm-server      │ /UCX│   trtllm-server      │
│   TP rank 0-3        │     │   TP rank 4-7        │
│                      │     │                      │
│   ┌─┬─┬─┬─┐          │     │   ┌─┬─┬─┬─┐          │
│   │0│1│2│3│          │     │   │4│5│6│7│          │
│   └─┴─┴─┴─┘          │     │   └─┴─┴─┴─┘          │
│   Model Shard 0-3    │     │   Model Shard 4-7    │
└──────────────────────┘     └──────────────────────┘
```

#### Multi-Node Disagg (多机分离)
```
┌──────────────────────┐     ┌──────────────────────┐     ┌──────────────────────┐
│  Node 1-2 (8 GPUs)   │     │  Node 3 (4 GPUs)     │     │  Node 4 (Client)     │
│  PREFILL (CONTEXT)   │<--->│  KV (GENERATION)     │<--->│  BENCHMARK           │
│                      │ UCX │                      │ UCX │                      │
│  Process prompts     │     │  Generate tokens     │     │  Send requests       │
│  Send KV cache ───>  │     │  Store KV cache      │     │  Collect results     │
│                      │     │  Return tokens       │     │                      │
│  ┌─┬─┬─┬─┬─┬─┬─┬─┐  │     │  ┌─┬─┬─┬─┐          │     │  (No GPUs)           │
│  │0│1│2│3│4│5│6│7│  │     │  │0│1│2│3│          │     │                      │
│  └─┴─┴─┴─┴─┴─┴─┴─┘  │     │  └─┴─┴─┴─┘          │     │                      │
└──────────────────────┘     └──────────────────────┘     └──────────────────────┘
```

---

## 📝 文件格式对比

### debug_cases.txt (TXT 格式)

```txt
# Single-Node Agg
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
                                      ↑                ↑
                                   test_type        config_yml

# Multi-Node Agg
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]
                                      ↑           ↑
                                   test_type   config_yml (包含 TP 信息)

# Multi-Node Disagg
test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_...-UCX]
                                      ↑                    ↑      ↑    ↑      ↑
                                   test_type          model   ctx2  gen1  transport
                                                             (2节点)(1节点)
```

### perf_test_cases.yaml (YAML 格式)

```yaml
# 按节点数分组
single_agg_tests:
  - aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml

multi_agg_2nodes_tests:
  - aggr_upload-multi_node_config.yaml

disagg_3nodes_tests:
  # ctx2_gen1 = 2 PREFILL + 1 KV + 1 BENCHMARK = 3 nodes
  - disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_...-UCX

disagg_6nodes_tests:
  # ctx6_gen1 = 6 PREFILL + 1 KV + 1 BENCHMARK = 8 nodes (示例)
  - disagg_upload-deepseek-r1-fp4_8k1k_ctx6_gen1_...-UCX
```

---

## 🔄 执行流程对比

### 三种模式的统一流程

```
1️⃣  Jenkins 选择参数
    ├─ debug_cases.txt → 快速 Debug
    └─ perf_test_cases.yaml → 生产测试
           ↓
2️⃣  sync_and_run.sh (中转机 → Cluster)
    └─ SCP 文件 + SSH 执行
           ↓
3️⃣  parse_unified_testlist.py (Cluster)
    ├─ TXT: 基于命名识别类型
    └─ YAML: 基于分组和配置识别
           ↓
4️⃣  run_*_test.sh (Cluster)
    ├─ Single-Agg: run_single_agg_test.sh → srun --nodes=1
    ├─ Multi-Agg: run_multi_agg_test.sh → srun --nodes=2+
    └─ Disagg: run_disagg_test.sh → sbatch --nodes=3+
           ↓
5️⃣  Slurm 执行 (Cluster compute nodes)
    ├─ Single-Agg: 直接启动 trtllm-server
    ├─ Multi-Agg: 跨节点 TP/PP 启动
    └─ Disagg: PREFILL + KV + BENCHMARK 分离启动
           ↓
6️⃣  收集结果 (Cluster → 中转机)
```

---

## 🎯 命令对比

### Single-Node Agg
```bash
# 识别
"profiling-deepseek_r1_fp4_v2_blackwell"
→ mode = single-agg (默认)

# 执行
srun --nodes=1 --gpus=8 \
  pytest test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
```

### Multi-Node Agg
```bash
# 识别
"benchmark-llama3_70b_tp4"
→ YAML: gpus=8, gpus_per_node=4
→ nodes = 8/4 = 2
→ mode = multi-agg

# 执行
srun --nodes=2 --gpus-per-node=4 --ntasks-per-node=1 \
  pytest test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]
```

### Multi-Node Disagg
```bash
# 识别
"disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_..."
→ 包含 "disagg_upload" 或 "_disagg"
→ ctx2 = 2 PREFILL nodes
→ gen1 = 1 KV node
→ +1 BENCHMARK node
→ Total = 3 nodes
→ mode = disagg

# 执行
sbatch --nodes=3 slurm_launch_draft.sh

# slurm_launch_draft.sh:
srun --nodes=2 trtllm-server --disagg-type=PREFILL &
srun --nodes=1 trtllm-server --disagg-type=KV &
sleep 60
srun --nodes=1 pytest test_perf_sanity.py::test_e2e[disagg_upload-...]
```

---

## 🔑 关键配置字段

### Single-Node Agg
```yaml
server_configs:
  tensor_parallel_size: 8
  gpus: 8
  gpus_per_node: 8  # 所有 GPU 在一个节点
```
→ `nodes = ceil(8/8) = 1`

### Multi-Node Agg
```yaml
server_configs:
  tensor_parallel_size: 4
  gpus: 8
  gpus_per_node: 4  # 每节点 4 GPU
```
→ `nodes = ceil(8/4) = 2`

### Multi-Node Disagg
```yaml
server_configs:
  - disagg_run_type: "PREFILL"
    disagg_serving_type: "CONTEXT"   # ctx2 → 2 nodes
    gpus: 8
  
  - disagg_run_type: "KV"
    disagg_serving_type: "GENERATION"  # gen1 → 1 node
    gpus: 4
  
  - disagg_serving_type: "BENCHMARK"  # +1 node
```
→ `nodes = 2 + 1 + 1 = 4`

---

## 📋 快速识别指南

### 从测试名称识别模式

| 测试名称特征 | 模式 | 节点数 |
|------------|------|--------|
| `profiling-xxx` | Single-Agg | 1 |
| `benchmark-xxx` (无 disagg) | Single-Agg | 1 |
| `benchmark-xxx_tp4` | Multi-Agg | 2+ |
| `xxx_2_nodes_xxx` | Multi-Agg | 2 |
| `disagg_upload-xxx` | Disagg | 3+ |
| `xxx_disagg` | Disagg | 3+ |
| `xxx_ctx2_gen1_xxx` | Disagg | 4 (2+1+1) |
| `xxx_ctx6_gen1_xxx` | Disagg | 8 (6+1+1) |
| `xxx_ctx8_gen1_xxx` | Disagg | 10 (8+1+1) |

---

## 💡 使用建议

### 何时使用 TXT (debug_cases.txt)
- ✅ 快速 Debug 失败测试
- ✅ 从 CI 日志直接复制
- ✅ 临时测试单个 case
- ✅ 不需要复杂配置

### 何时使用 YAML (perf_test_cases.yaml)
- ✅ 生产环境测试套件
- ✅ 需要节点分组管理
- ✅ 需要设置超时和其他参数
- ✅ CI/CD 自动化集成

---

**详细文档**: `docs/THREE_MODES_EXECUTION.md`
