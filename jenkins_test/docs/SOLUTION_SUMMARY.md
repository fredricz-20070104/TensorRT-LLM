# 最终解决方案总结

## ✅ 完成的工作

### 创建的文件

1. **`jenkins/scripts/calculate_hardware_nodes.py`** ⭐
   - 从 YAML 配置计算硬件节点需求
   - 区分逻辑服务器数和硬件节点数
   - 可独立测试和验证

2. **`jenkins/scripts/run_perf_tests_simple.sh`**
   - 简化的运行脚本（可选使用）
   - 调用 calculate_hardware_nodes.py 和 L0 submit.py

3. **`jenkins/Perf_Test.groovy`** ⭐ (更新)
   - 简化的 Jenkins Pipeline
   - 只负责参数验证和流程编排
   - 直接调用 L0 submit.py

4. **`jenkins/ARCHITECTURE_FINAL.md`** ⭐
   - 完整的架构说明
   - 节点计算逻辑详解
   - 使用示例

## 🎯 核心逻辑

### 节点计算公式

```python
# 从 YAML 读取
num_ctx_servers = 2  # 逻辑服务器数
num_gen_servers = 1
ctx_tp = 4           # 并行度
gen_tp = 8
gpus_per_node = 4    # 硬件配置

# 计算 world size
ctx_world_size = ctx_tp × ctx_pp × ctx_cp
gen_world_size = gen_tp × gen_pp × gen_cp

# 计算硬件节点数
ctx_hardware_nodes = ceil(ctx_world_size × num_ctx_servers / gpus_per_node)
gen_hardware_nodes = ceil(gen_world_size × num_gen_servers / gpus_per_node)
total_hardware_nodes = ctx_hardware_nodes + gen_hardware_nodes
```

### 示例

```yaml
# 配置
hardware:
  gpus_per_node: 4
  num_ctx_servers: 2  # 逻辑
  num_gen_servers: 1
worker_config:
  ctx:
    tensor_parallel_size: 4
  gen:
    tensor_parallel_size: 8

# 计算结果
ctx_world_size = 4
ctx_nodes = ceil(4 × 2 / 4) = 2

gen_world_size = 8
gen_nodes = ceil(8 × 1 / 4) = 2

total_nodes = 4  # ← 这是硬件节点数！
```

## 🏗️ 调用链条

```
Perf_Test.groovy
    ↓
    1. 从 TestList 提取配置文件（或直接使用配置文件）
    ↓
calculate_hardware_nodes.py
    ↓
    2. 读取 YAML → 计算硬件节点数
    ↓
Perf_Test.groovy
    ↓
    3. 验证节点数（可选）
    ↓
jenkins/scripts/perf/disaggregated/submit.py (L0)
    ↓
    4. 生成 Slurm 脚本 → 提交任务
```

## 📝 使用方式

### 方式 1: 独立测试节点计算

```bash
# 查看需要多少节点
python3 jenkins/scripts/calculate_hardware_nodes.py \
    --config tests/integration/defs/perf/disagg/test_configs/disagg/perf/xxx.yaml

# 输出:
# 逻辑服务器配置:
#   CTX servers: 2
#   GEN servers: 1
#   CTX world size: 4
#   GEN world size: 8
# 
# 硬件节点计算:
#   GPUs per node: 4
#   CTX hardware nodes: 2
#   GEN hardware nodes: 2
#   Total hardware nodes: 4
#   Total GPUs: 16
```

### 方式 2: 验证节点数

```bash
# 检查 3 个节点是否够用
python3 jenkins/scripts/calculate_hardware_nodes.py \
    --config xxx.yaml \
    --check-nodes 3

# 输出:
# ❌ 节点数不匹配!
#   配置要求: 4 个节点
#   实际提供: 3 个节点
```

### 方式 3: Jenkins Pipeline

```groovy
// 参数设置
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
NODE_LIST: node1,node2,node3,node4 (可选)

// Pipeline 自动:
// 1. 从 TestList 提取配置
// 2. 计算节点需求
// 3. 验证节点数
// 4. 提交任务
```

## 🎨 为什么这样设计？

### 问题

原来的设计：
- ❌ 混淆了逻辑服务器数和硬件节点数
- ❌ 重新实现了 examples submit.py 的逻辑
- ❌ examples submit.py 天天变，难以维护
- ❌ 没有自动验证节点数

### 解决方案

新设计：
- ✅ 明确区分逻辑服务器数和硬件节点数
- ✅ 提取节点计算逻辑到独立工具
- ✅ 直接调用 L0 submit.py（不重新实现）
- ✅ 自动验证节点数匹配
- ✅ L0 submit.py 更新不影响我们

## 🔍 关键代码

### calculate_hardware_nodes.py (核心)

```python
def calculate_nodes(world_size, num_servers, gpus_per_node):
    """计算硬件节点数"""
    return math.ceil(world_size * num_servers / gpus_per_node)

# 从 YAML 读取逻辑配置
num_ctx_servers = hardware.get('num_ctx_servers', 0)  # 逻辑
num_gen_servers = hardware.get('num_gen_servers', 0)

ctx_tp = ctx_config.get('tensor_parallel_size', 1)
ctx_world_size = ctx_tp * ctx_pp * ctx_cp

# 计算硬件节点
ctx_nodes = calculate_nodes(ctx_world_size, num_ctx_servers, gpus_per_node)
gen_nodes = calculate_nodes(gen_world_size, num_gen_servers, gpus_per_node)
total_nodes = ctx_nodes + gen_nodes
```

### Perf_Test.groovy (简化)

```groovy
// 1. 提取配置文件（从 TestList 或直接指定）
def configToUse = extractConfigFromTestList(TESTLIST)

// 2. 计算节点需求
def nodeInfo = sh(
    script: "python3 jenkins/scripts/calculate_hardware_nodes.py --config ${configToUse} --json",
    returnStdout: true
)

// 3. 验证节点数（可选）
if (NODE_LIST && nodeInfo.total_nodes != providedNodes) {
    error "节点数不匹配"
}

// 4. 调用 L0 submit.py
sh "python3 jenkins/scripts/perf/disaggregated/submit.py --config ${configToUse}"
```

## ✨ 优势

1. **简单**: 职责清晰，每个组件只做一件事
2. **复用**: 利用现有的 L0 submit.py
3. **解耦**: 节点计算独立，可测试
4. **稳定**: L0 submit.py 更新不影响
5. **验证**: 自动检查节点数匹配

## 📚 文件清单

### 新增文件

- ✅ `jenkins/scripts/calculate_hardware_nodes.py` - 节点计算工具
- ✅ `jenkins/scripts/run_perf_tests_simple.sh` - 简化运行脚本（可选）
- ✅ `jenkins/ARCHITECTURE_FINAL.md` - 架构文档

### 更新文件

- ✅ `jenkins/Perf_Test.groovy` - 简化的 Pipeline

### 不修改的文件

- ✅ `jenkins/scripts/perf/disaggregated/submit.py` - L0 submit (保持不变)
- ✅ `examples/disaggregated/slurm/benchmark/submit.py` - 参考实现（不使用）

## 🚀 下一步

1. **测试节点计算工具**:
   ```bash
   python3 jenkins/scripts/calculate_hardware_nodes.py \
       --config tests/integration/defs/perf/disagg/test_configs/disagg/perf/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
   ```

2. **在 Jenkins 中测试**:
   - 设置 TESTLIST 参数
   - Dry run 查看执行计划
   - 实际运行测试

3. **验证节点数匹配**:
   - 提供正确的 NODE_LIST
   - 提供错误的 NODE_LIST（测试验证逻辑）

## 💡 总结

**最核心的改进**：
- 明确区分了**逻辑服务器数**和**硬件节点数**
- 提取节点计算到独立工具，复用 L0 submit.py
- 简单、清晰、易维护

**架构**：
```
Perf_Test.groovy → calculate_hardware_nodes.py → L0 submit.py
      ↓                      ↓                         ↓
   验证参数              计算节点数                提交任务
```

Done! 🎉
