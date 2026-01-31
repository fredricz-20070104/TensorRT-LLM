# TestList 使用说明

## 问题解答

### 1. 模型列表是怎么读取的？在哪行？

**答案：模型列表不是在 `Perf_Test.groovy` 中读取的！**

在我们简化的 `Perf_Test.groovy` 中：
- **没有读取模型列表**
- **直接通过测试用例名称传入模型信息**

示例：
```groovy
// Perf_Test.groovy 第 28 行
TEST_CASE = 'aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml'
//                        ^^^^^^^^^^^^^^^^  这就是模型名称
```

模型信息实际上在：
1. **配置文件名称中**：
   - `k2_thinking_fp4_2_nodes_grace_blackwell.yaml`
   - `deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128...`

2. **YAML 配置文件内部**：
```yaml
# tests/scripts/perf-sanity/k2_thinking_fp4_2_nodes_grace_blackwell.yaml
metadata:
  model_name: k2_thinking_fp4           # ← 模型名称
  precision: fp4
  model_dir_name: Kimi-K2-Thinking-NVFP4
```

3. **test_perf_sanity.py 内部定义**：
```python
# tests/integration/defs/perf/test_perf_sanity.py 第 50-59 行
MODEL_PATH_DICT = {
    "deepseek_r1_fp8": "DeepSeek-R1/DeepSeek-R1",
    "deepseek_r1_nvfp4": "DeepSeek-R1/DeepSeek-R1-FP4",
    "k2_thinking_fp4": "Kimi-K2-Thinking-NVFP4",    # ← 模型路径映射
    ...
}
```

---

### 2. Disagg 和 Agg 的 Node 个数在哪里配置的？

**答案：在 3 个地方配置！**

#### 方式 1: YAML 配置文件中（推荐）

**Agg 配置：**
```yaml
# tests/scripts/perf-sanity/k2_thinking_fp4_2_nodes_grace_blackwell.yaml
hardware:
  gpus_per_node: 4        # 每个节点的 GPU 数
  # 多机配置通过运行时自动识别
```

**Disagg 配置：**
```yaml
# tests/integration/defs/perf/disagg/test_configs/disagg/perf/xxx.yaml
hardware:
  gpus_per_node: 4
  num_ctx_servers: 2      # Context server 数量 ← 节点分配
  num_gen_servers: 1      # Generation server 数量
```

从这个配置自动计算节点数：
```python
# jenkins/scripts/perf/disaggregated/submit.py 第 38-41 行
nodes_per_ctx_server = (gpus_per_ctx_server + gpus_per_node - 1) // gpus_per_node
nodes_per_gen_server = (gpus_per_gen_server + gpus_per_node - 1) // gpus_per_node

total_nodes = num_ctx_servers * nodes_per_ctx_server + num_gen_servers * nodes_per_gen_server
```

#### 方式 2: Jenkins Pipeline 参数中

**在 `Perf_Test.groovy` 中：**
```groovy
// 第 31-33 行
string(
    name: 'NODE_LIST',
    defaultValue: '',
    description: '节点列表（多机模式需要，逗号分隔），例如: gb200-node1,gb200-node2,gb200-node3'
)
```

节点数 = `NODE_LIST.split(',').size()`

#### 方式 3: TestList 文件中（原 L0_Test.groovy 使用）

**在 testlist YAML 文件中：**
```yaml
# tests/integration/test_lists/test-db/l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes.yml
l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes:
- condition:
    ranges:
      system_gpu_count:
        gte: 8               # 8 GPUs = 2 节点 × 4 GPUs/节点
        lte: 8
  tests:
    - perf/test_perf_sanity.py::test_e2e[...]
```

```yaml
# tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml
l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes:
- condition:
    ranges:
      system_gpu_count:
        gte: 12              # 12 GPUs = 3 节点 × 4 GPUs/节点
        lte: 12
```

---

### 3. TestList 列表是怎么用的？怎么选择 TestList？

#### 在原始 L0_Test.groovy 中的使用流程：

**步骤 1: 定义 TestList 名称**
```groovy
// L0_Test.groovy 第 3349-3367 行
multiNodesSBSAConfigs = [
    "GB200-8_GPUs-2_Nodes-PyTorch-1": [
        "gb200-oci-trtllm",                                    // platform
        "l0_gb200_multi_nodes",                                // ← testList 名称
        1, 2, 8, 2                                             // splitId, splits, gpus, nodes
    ],
    "GB200-12_GPUs-3_Nodes-PyTorch-PerfSanity-Disagg-Post-Merge-1": [
        "gb200-oci-trtllm",
        "l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes",     // ← testList 名称
        1, 1, 12, 3
    ],
]
```

**步骤 2: 调用 runLLMTestlistOnSlurm**
```groovy
// L0_Test.groovy 第 3397 行
runLLMTestlistOnSlurm(
    pipeline, 
    values[0],      // platform = "gb200-oci-trtllm"
    values[1],      // testList = "l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes"
    config, 
    perfMode, 
    stageName, 
    values[2],      // splitId = 1
    values[3],      // splits = 1
    values[4],      // gpuCount = 12
    values[5],      // nodeCount = 3
    ...
)
```

**步骤 3: renderTestDB 渲染 TestList**
```groovy
// L0_Test.groovy 第 1009 行
def testListPathLocal = renderTestDB(
    testList,              // "l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes"
    llmSrcLocal, 
    stageName, 
    makoOptsJson
)
```

这个函数会：
1. 查找 `tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml`
2. 解析 YAML 文件
3. 根据条件（GPU 数、平台等）筛选测试用例
4. 生成临时的测试列表文件（.txt）

**步骤 4: 传递给 pytest**
```groovy
// L0_Test.groovy 第 1066 行
"--test-list=$testListPathNode",  // 传递给 pytest
```

**步骤 5: Pytest 读取测试列表**
```bash
pytest \
    --test-list=/path/to/test_list.txt \
    --splitting-algorithm least_duration \
    --splits 1 \
    --group 1 \
    tests/integration/defs/
```

Pytest 会读取 test_list.txt，内容类似：
```
perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] TIMEOUT (90)
```

---

## TestList 文件结构说明

### TestList YAML 格式

```yaml
# tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml
version: 0.0.1
l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes:   # ← TestList 名称
- condition:                                       # 运行条件
    ranges:
      system_gpu_count:                            # GPU 数量范围
        gte: 12                                    # 大于等于 12
        lte: 12                                    # 小于等于 12
    wildcards:
      gpu:                                         # GPU 类型
      - '*gb200*'                                  # 匹配 GB200
    terms:
      stage: post_merge                            # 阶段：post_merge
      backend: pytorch                             # 后端：pytorch
  tests:                                           # 测试列表
  - perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] TIMEOUT (90)
```

### TestList 类型对应关系

| TestList 名称 | 节点数 | GPU 数 | 测试类型 | 文件位置 |
|---------------|--------|--------|----------|----------|
| `l0_gb200_multi_nodes` | 2 | 8 | Agg | `test-db/l0_gb200_multi_nodes.yml` |
| `l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes` | 2 | 8 | Agg Perf | `test-db/l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes.yml` |
| `l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes` | 3 | 12 | Disagg Perf | `test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml` |
| `l0_gb200_multi_nodes_disagg_perf_sanity_6_nodes` | 6 | 24 | Disagg Perf | `test-db/l0_gb200_multi_nodes_disagg_perf_sanity_6_nodes.yml` |
| `l0_gb200_multi_nodes_disagg_perf_sanity_8_nodes` | 8 | 32 | Disagg Perf | `test-db/l0_gb200_multi_nodes_disagg_perf_sanity_8_nodes.yml` |

---

## 简化版 Perf_Test.groovy 与 TestList

**关键区别：**

### 原始 L0_Test.groovy（使用 TestList）
```
L0_Test.groovy → runLLMTestlistOnSlurm → renderTestDB(testList) → test_list.txt → pytest --test-list=test_list.txt
```

优点：
- 可以批量管理测试用例
- 根据条件自动筛选测试
- 支持分片（splits）

缺点：
- 流程复杂
- 需要维护 TestList YAML 文件
- 不够直观

### 简化版 Perf_Test.groovy（不使用 TestList）
```
Perf_Test.groovy → run_perf_tests.sh → pytest -k 'test_case_name'
```

优点：
- 流程简单
- 直接传入测试用例名称
- 容易理解和调试

缺点：
- 不支持批量管理
- 不支持条件筛选

---

## 如何选择使用方式

### 场景 1: 需要批量运行大量测试（使用 TestList）

**适合：** 完整的 CI/CD，post-merge 验证

```groovy
// 使用原始 L0_Test.groovy
runLLMTestlistOnSlurm(
    pipeline, 
    "gb200-oci-trtllm",
    "l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes",  // ← 使用 TestList
    ...
)
```

### 场景 2: 运行单个或少量测试（不使用 TestList）

**适合：** 开发调试，单个测试验证

```bash
# 使用简化版 Perf_Test.groovy
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --test-case "disagg_upload-deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128_eplb288_mtp3_ccb-DEFAULT"
```

或者直接用 pytest：
```bash
pytest -v -s \
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
    -k 'disagg_upload-deepseek-r1-fp4_8k1k...'
```

---

## 总结

### 问题 1: 模型列表在哪里读取？

**答案：**
- ❌ **不在** `Perf_Test.groovy` 中读取
- ✅ **在** YAML 配置文件中定义（`metadata.model_name`）
- ✅ **在** `test_perf_sanity.py` 中映射（`MODEL_PATH_DICT`）

### 问题 2: Node 个数在哪里配置？

**答案：**
1. ✅ YAML 配置文件中（`hardware.num_ctx_servers`, `hardware.num_gen_servers`）
2. ✅ Jenkins 参数中（`NODE_LIST` 的节点数量）
3. ✅ TestList 文件中（`system_gpu_count` 推算）

### 问题 3: TestList 怎么用？

**答案：**
1. **定义 TestList 名称** → `multiNodesSBSAConfigs` 中指定
2. **查找 TestList 文件** → `tests/integration/test_lists/test-db/<testlist_name>.yml`
3. **渲染测试列表** → `renderTestDB()` 生成 `.txt` 文件
4. **传递给 pytest** → `pytest --test-list=test_list.txt`

**简化版不使用 TestList：**
- 直接传入测试用例名称
- 使用 `pytest -k 'test_case_name'` 筛选

---

## 推荐使用方式

### 对于性能测试（Perf）

**推荐：直接使用测试用例名称（不需要 TestList）**

理由：
1. 性能测试通常单独运行
2. 配置文件已经包含所有信息
3. 更简单直观

示例：
```bash
# Agg
./jenkins/scripts/run_perf_tests.sh \
    --mode multi-agg \
    --test-case "aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml" \
    --nodes "node1,node2"

# Disagg  
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --test-case "disagg_upload-deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128_eplb288_mtp3_ccb-DEFAULT" \
    --nodes "node1,node2,node3"
```

### 对于功能测试（L0）

**推荐：使用 TestList（原始方式）**

理由：
1. 需要批量运行大量测试
2. 需要根据条件筛选
3. 需要分片并行执行

保持使用原始 `L0_Test.groovy` 和 TestList 机制。
