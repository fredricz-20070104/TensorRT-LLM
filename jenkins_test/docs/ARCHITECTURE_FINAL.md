# 性能测试架构 - 最终简化版

## 🎯 核心原则

**不重新实现轮子，复用现有的 L0 submit.py**

## 📊 问题根源

### 节点数的两种概念

1. **逻辑服务器数** (配置文件中)
   ```yaml
   hardware:
     num_ctx_servers: 2    # 2 个 CTX 逻辑服务器
     num_gen_servers: 1    # 1 个 GEN 逻辑服务器
   ```

2. **硬件节点数** (Slurm 分配的物理节点)
   ```
   CTX: 2 servers × 4 GPUs/server ÷ 4 GPUs/node = 2 硬件节点
   GEN: 1 server  × 8 GPUs/server ÷ 4 GPUs/node = 2 硬件节点
   总计: 4 硬件节点
   ```

### L0_Test.groovy 的配置

```groovy
// 第 3363 行
"GB200-12_GPUs-3_Nodes-...": [..., 12, 3]
                                   ^^  ^
                            总GPU数  硬件节点数
```

这里的 `3` 是**硬件节点数**，不是逻辑服务器数！

## 🏗️ 架构设计

```
┌──────────────────────────────────────────────────────────────┐
│                     Perf_Test.groovy                         │
│                    (Jenkins Pipeline)                        │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     │ 调用
                     ↓
┌──────────────────────────────────────────────────────────────┐
│              calculate_hardware_nodes.py                     │
│           (从 YAML 计算硬件节点需求)                          │
│                                                              │
│  输入: YAML 配置文件                                          │
│  输出: {                                                     │
│    num_ctx_servers: 2,      # 逻辑服务器数                  │
│    num_gen_servers: 1,                                       │
│    ctx_world_size: 4,       # TP×PP×CP                      │
│    gen_world_size: 8,                                        │
│    ctx_nodes: 2,            # 硬件节点数                     │
│    gen_nodes: 2,                                             │
│    total_nodes: 4,          # 总硬件节点                     │
│    total_gpus: 16                                            │
│  }                                                           │
└────────────────────┬─────────────────────────────────────────┘
                     │
                     │ 验证节点数匹配
                     ↓
┌──────────────────────────────────────────────────────────────┐
│      jenkins/scripts/perf/disaggregated/submit.py           │
│                  (L0 的 submit.py)                           │
│                                                              │
│  - 读取 YAML 配置                                            │
│  - 生成 Slurm 脚本                                           │
│  - 分配 GPU 到节点                                           │
│  - 启动 CTX/GEN workers                                      │
│  - 运行 benchmark                                            │
└──────────────────────────────────────────────────────────────┘
```

## 🔄 调用流程

### 1. 使用 TestList

```bash
Jenkins Pipeline 参数:
  TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
  NODE_LIST: node1,node2,node3 (可选，用于验证)

↓

Perf_Test.groovy:
  1. 查找 TestList YAML 文件
  2. 提取第一个 disagg 测试用例
  3. 解析出配置文件名 (例如: deepseek-r1-fp4_1k1k...)
  4. 查找配置文件
     - tests/integration/defs/perf/disagg/test_configs/disagg/perf/xxx.yaml
     - tests/integration/defs/perf/disagg/test_configs/wideep/perf/xxx.yaml

↓

calculate_hardware_nodes.py:
  1. 读取 YAML 配置
  2. 提取:
     - num_ctx_servers, num_gen_servers (逻辑)
     - ctx_tp, ctx_pp, ctx_cp (并行度)
     - gen_tp, gen_pp, gen_cp
     - gpus_per_node (硬件配置)
  3. 计算:
     ctx_world_size = ctx_tp × ctx_pp × ctx_cp
     ctx_nodes = ceil(ctx_world_size × num_ctx_servers / gpus_per_node)
     gen_world_size = gen_tp × gen_pp × gen_cp
     gen_nodes = ceil(gen_world_size × num_gen_servers / gpus_per_node)
     total_nodes = ctx_nodes + gen_nodes
  4. 输出 JSON 结果

↓

Perf_Test.groovy (验证):
  if (provided_nodes != required_nodes):
    ERROR: 节点数不匹配!

↓

L0 submit.py:
  sbatch --nodes=4 ... jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh
```

### 2. 直接使用配置文件

```bash
Jenkins Pipeline 参数:
  CONFIG_FILE: tests/.../deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml

↓

Perf_Test.groovy:
  直接使用指定的配置文件

↓

calculate_hardware_nodes.py:
  (同上)

↓

L0 submit.py:
  (同上)
```

## 📝 关键文件

### 1. calculate_hardware_nodes.py

**功能**: 从 YAML 计算硬件节点需求

**输入**:
```yaml
hardware:
  gpus_per_node: 4
  num_ctx_servers: 2
  num_gen_servers: 1
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 8
```

**计算逻辑**:
```python
ctx_world_size = 4 × 1 × 1 = 4
ctx_nodes = ceil(4 × 2 / 4) = 2

gen_world_size = 8 × 1 × 1 = 8
gen_nodes = ceil(8 × 1 / 4) = 2

total_nodes = 2 + 2 = 4
```

**输出**:
```json
{
  "total_nodes": 4,
  "total_gpus": 16,
  "ctx_nodes": 2,
  "gen_nodes": 2,
  ...
}
```

### 2. Perf_Test.groovy

**功能**: Jenkins Pipeline 入口

**简化原则**:
- ✅ 只负责参数验证和流程编排
- ✅ 不重新实现节点计算
- ✅ 复用 L0 submit.py
- ❌ 不自己生成 Slurm 脚本
- ❌ 不自己分配 GPU

### 3. L0 submit.py

**功能**: 生成和提交 Slurm 任务

**保持不变**: 
- 继续使用现有的 L0 submit.py
- 不需要修改
- 天天更新也没关系，因为我们只是调用它

## 🎨 使用示例

### 示例 1: 使用 TestList

```groovy
// Jenkins Pipeline 参数
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
NODE_LIST: (留空，自动计算)

// 执行结果
✓ 从 TestList 提取配置
✓ 计算节点需求: 4 个硬件节点
✓ 提交任务到 Slurm
```

### 示例 2: 验证节点数

```groovy
// Jenkins Pipeline 参数
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
NODE_LIST: node1,node2,node3

// 执行结果
✓ 计算节点需求: 4 个硬件节点
✗ 错误: 节点数不匹配! (提供 3，需要 4)
```

### 示例 3: 直接使用配置文件

```groovy
// Jenkins Pipeline 参数
CONFIG_FILE: tests/integration/defs/perf/disagg/test_configs/disagg/perf/xxx.yaml
NODE_LIST: node1,node2,node3,node4

// 执行结果
✓ 计算节点需求: 4 个硬件节点
✓ 节点数验证通过
✓ 提交任务到 Slurm
```

## 🔍 节点计算示例

### 配置 A: 3 硬件节点

```yaml
hardware:
  gpus_per_node: 4
  num_ctx_servers: 2  # 逻辑
  num_gen_servers: 1
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 4
```

**计算**:
```
CTX: 4 × 2 ÷ 4 = 2 节点
GEN: 4 × 1 ÷ 4 = 1 节点
总计: 3 节点
```

### 配置 B: 4 硬件节点

```yaml
hardware:
  gpus_per_node: 4
  num_ctx_servers: 2
  num_gen_servers: 1
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 8
```

**计算**:
```
CTX: 4 × 2 ÷ 4 = 2 节点
GEN: 8 × 1 ÷ 4 = 2 节点
总计: 4 节点
```

### 配置 C: 6 硬件节点

```yaml
hardware:
  gpus_per_node: 4
  num_ctx_servers: 6  # 增加到 6 个
  num_gen_servers: 1
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 8
```

**计算**:
```
CTX: 4 × 6 ÷ 4 = 6 节点
GEN: 8 × 1 ÷ 4 = 2 节点
总计: 8 节点  # 注意！不是 6
```

## ✅ 优点

1. **简单**: 不重新实现复杂的节点分配逻辑
2. **解耦**: 节点计算独立，可单独测试
3. **复用**: 直接用 L0 submit.py，保持一致
4. **维护性**: L0 submit.py 更新不影响我们
5. **验证**: 自动检查节点数是否匹配

## 🚀 快速开始

```bash
# 1. 计算某个配置需要多少节点
python3 jenkins/scripts/calculate_hardware_nodes.py \
    --config tests/.../xxx.yaml

# 2. 验证节点数
python3 jenkins/scripts/calculate_hardware_nodes.py \
    --config tests/.../xxx.yaml \
    --check-nodes 4

# 3. 在 Jenkins 中运行
# 设置参数: TESTLIST, NODE_LIST
# 点击 Build
```

## 📚 相关文件

- **calculate_hardware_nodes.py**: 节点计算工具
- **Perf_Test.groovy**: Jenkins Pipeline
- **jenkins/scripts/perf/disaggregated/submit.py**: L0 submit.py (不修改)
- **examples/disaggregated/slurm/benchmark/submit.py**: 参考实现 (不使用)
