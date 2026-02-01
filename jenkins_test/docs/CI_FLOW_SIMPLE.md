# CI 执行流程简明版

## 🚀 TXT 格式执行流程 (debug_cases.txt)

### 5 步完成测试

```
1️⃣ Jenkins 选择参数
   TESTLIST = 'debug_cases'
   ↓

2️⃣ 中转机同步文件
   SCP scripts/ + testlists/ + TensorRT-LLM/ → Cluster
   ↓

3️⃣ Cluster 解析 TXT
   parse_unified_testlist.py debug_cases.txt
   ↓
   提取测试用例:
   - profiling-deepseek_r1_fp4_v2_blackwell
   - benchmark-llama3_70b_disagg
   ↓

4️⃣ Cluster 执行测试
   run_single_agg_test.sh → srun + Docker + pytest
   run_disagg_test.sh → sbatch + 3 nodes + pytest
   ↓

5️⃣ 收集结果
   SCP Cluster:output/ → 中转机:output_${BUILD}
```

### 详细说明

**TXT 文件内容**:
```txt
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]
```

**解析过程**:
```python
# parse_unified_testlist.py 识别测试类型

"profiling-deepseek_r1_fp4_v2_blackwell"
→ test_type = "profiling"
→ config_yml = "deepseek_r1_fp4_v2_blackwell"
→ mode = "single-agg" (默认)

"benchmark-llama3_70b_disagg"
→ test_type = "benchmark"
→ config_yml = "llama3_70b_disagg"
→ mode = "disagg" (自动识别 *_disagg)
```

**执行命令**:
```bash
# Single-Agg
srun --gpus=8 \
  --container-image=tensorrt-llm:latest \
  pytest test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]

# Disagg (3 nodes)
sbatch --nodes=3 slurm_launch_draft.sh
  → Node 1: PREFILL server
  → Node 2: KV_CACHE server
  → Node 3: BENCHMARK client
```

---

## 🚀 YAML 格式执行流程 (gb200_3nodes_sanity.yml)

### 5 步 + 条件检查

```
1️⃣ Jenkins 选择参数
   TESTLIST = 'gb200_3nodes_sanity'
   FILTER_MODE = 'disagg'
   ↓

2️⃣ 中转机同步文件
   SCP testlists/disagg/gb200_3nodes_sanity.yml → Cluster
   ↓

3️⃣ Cluster 解析 YAML + 条件检查
   parse_unified_testlist.py gb200_3nodes_sanity.yml
   ↓
   检查条件:
   ✓ GPU 数量: 12 (3 nodes × 4 GPUs) ✓
   ✓ GPU 类型: GB200 ✓
   ✓ Stage: post_merge ✓
   ↓
   提取测试:
   - test_e2e[disagg_upload-deepseek-r1-fp4_...] (timeout: 90 min)
   ↓

4️⃣ Cluster 执行测试
   run_disagg_test.sh
   ↓
   计算节点: 12 GPUs ÷ 4 per node = 3 nodes
   ↓
   sbatch --nodes=3 --timeout=90 slurm_launch_draft.sh
   ↓

5️⃣ 收集结果
   同 TXT 方式
```

### 详细说明

**YAML 文件内容**:
```yaml
gb200_disagg_3nodes_sanity:
- condition:
    ranges:
      system_gpu_count:
        gte: 12  # 最少 12 个 GPU
        lte: 12
    wildcards:
      gpu: ['*gb200*']  # 必须是 GB200
    terms:
      stage: post_merge
      backend: pytorch
  tests:
  - perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_...] TIMEOUT (90)
```

**解析过程**:
```python
# parse_yaml_testlist() 解析步骤

1. 读取 YAML 文件
2. 检查 condition (条件过滤)
   - GPU 数量: 12 ✓
   - GPU 类型: GB200 ✓
   - Stage: post_merge ✓
3. 提取 tests 列表
4. 识别测试类型:
   - 包含 "disagg" → disagg 模式
   - TIMEOUT (90) → 设置超时 90 分钟
5. 生成 JSON 输出
```

**执行命令**:
```bash
# Disagg 测试 (3 nodes, 90 min timeout)
sbatch \
  --nodes=3 \
  --gpus-per-node=4 \
  --time=90 \
  slurm_launch_draft.sh

# slurm_launch_draft.sh 内容:
# Node 1: srun ... trtllm-server --disagg-type=PREFILL
# Node 2: srun ... trtllm-server --disagg-type=KV
# Node 3: srun ... pytest test_perf_sanity.py::test_e2e[disagg_upload-...]
```

---

## 🔍 关键区别

| 特性 | TXT (debug_cases.txt) | YAML (gb200_3nodes_sanity.yml) |
|------|---------------------|-------------------------------|
| **解析器** | `parse_txt_testlist()` | `parse_yaml_testlist()` |
| **条件检查** | ❌ 无 | ✅ GPU 数量、类型、stage |
| **超时控制** | ❌ 无 | ✅ TIMEOUT (90) |
| **测试识别** | 基于命名 (`*_disagg`) | 基于 condition + test_type |
| **适用场景** | Debug、快速重跑 | 生产环境、自动化 CI |

---

## 💡 快速对比

### TXT 格式（快速 Debug）
```bash
# 从失败日志直接复制
FAILED test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]

# 粘贴到 debug_cases.txt
test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]

# Jenkins 运行
TESTLIST = 'debug_cases' → 立即执行
```

### YAML 格式（生产环境）
```yaml
# 定义完整测试套件
condition:
  ranges:
    system_gpu_count: {gte: 12, lte: 12}
  wildcards:
    gpu: ['*gb200*']
tests:
  - test_perf_sanity.py::test_e2e[...] TIMEOUT (90)

# Jenkins 运行
TESTLIST = 'gb200_3nodes_sanity' → 先检查条件 → 再执行
```

---

## 🎯 核心流程图

```
Jenkins (中转机)
    ↓
sync_and_run.sh
    ├─ SCP 文件到 Cluster
    └─ SSH 执行 run_perf_tests.sh
        ↓
Cluster Login Node
    ├─ 解析 testlist (TXT 或 YAML)
    ├─ 识别测试类型
    └─ 调用对应脚本
        ├─ run_single_agg_test.sh → srun (单节点)
        ├─ run_multi_agg_test.sh → srun (多节点)
        └─ run_disagg_test.sh → sbatch (分离式)
            ↓
Cluster Compute Nodes
    └─ Docker + pytest + test_e2e()
        ↓
结果收集 → 中转机 → Jenkins
```

---

**总结一句话**：
- **TXT**: 直接粘贴 pytest 路径 → 快速 Debug
- **YAML**: 结构化配置 + 条件检查 → 生产级别测试
