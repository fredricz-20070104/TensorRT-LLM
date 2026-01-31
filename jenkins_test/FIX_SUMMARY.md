# Perf_Test.groovy 修复总结

## ✅ 已修复的问题

### 1. 移除了多余的 NODE_COUNT/NODE_LIST 参数

**之前的问题**:
- 要求用户手动提供 `NODE_LIST: node1,node2,node3,node4` 或 `NODE_COUNT: 4`
- 用户需要自己计算或猜测需要多少个节点
- 违背了 Slurm 的自动调度机制

**修复后**:
- ✅ 完全移除 `NODE_COUNT` 和 `NODE_LIST` 参数
- ✅ 系统自动从配置文件计算所需节点数
- ✅ 用户只需提供配置文件或 TestList 名称

### 2. 自动计算节点数的逻辑

#### Disagg 模式
```groovy
// 步骤 1: 从 TestList 或直接指定的配置文件名获取配置路径
configFullPath = "tests/integration/defs/perf/disagg/test_configs/wideep/perf/xxx.yaml"

// 步骤 2: 调用 calculate_hardware_nodes.py 自动计算
python3 calculate_hardware_nodes.py --config configFullPath --json

// 步骤 3: 解析结果
{
  "num_ctx_servers": 1,      // 逻辑
  "num_gen_servers": 1,
  "ctx_nodes": 2,             // 硬件
  "gen_nodes": 2,
  "total_nodes": 4,           // ← 自动计算出的总节点数
  "total_gpus": 32,
  "gpus_per_node": 8
}

// 步骤 4: 使用计算出的节点数生成 sbatch 脚本
#SBATCH --nodes=4             // ← 自动填充
```

#### Multi-Agg 模式
```groovy
// 从 Agg 配置文件中读取节点数
python3 << 'EOF'
import yaml
with open(config_file) as f:
    config = yaml.safe_load(f)

# 方式1: 从 world_size 计算
world_size = config['server_config']['world_size']
gpus_per_node = config.get('gpus_per_node', 8)
nodes = (world_size + gpus_per_node - 1) // gpus_per_node

# 方式2: 直接读取
nodes = config.get('num_nodes', 2)

print(nodes)
EOF

// 使用计算出的节点数
#SBATCH --nodes=<calculated_nodes>
```

#### Single-Agg 模式
```groovy
// 单节点，固定为 1
nodes = 1
```

### 3. 简化的用户界面

**Jenkins 参数**:
```groovy
properties([
    parameters([
        choice(name: 'TEST_MODE', choices: ['disagg', 'multi-agg', 'single-agg']),
        string(name: 'TESTLIST', defaultValue: '', description: 'TestList 名称 (disagg 模式)'),
        string(name: 'CONFIG_FILE', defaultValue: '', description: '配置文件名'),
        string(name: 'TRTLLM_REPO', defaultValue: 'https://github.com/NVIDIA/TensorRT-LLM.git'),
        string(name: 'TRTLLM_BRANCH', defaultValue: 'main'),
        booleanParam(name: 'DRY_RUN', defaultValue: false)
    ])
])
```

**用户只需要**:
1. 选择测试模式
2. 提供配置文件名或 TestList 名称
3. 点击运行

**系统自动完成**:
- ✅ 从配置文件读取逻辑节点配置
- ✅ 调用 `calculate_hardware_nodes.py` 计算硬件节点数
- ✅ 生成 sbatch 脚本
- ✅ 提交给 Slurm
- ✅ Slurm 自动分配节点

## 📋 修复的文件

### 1. `jenkins_test/Perf_Test.groovy`

**主要变更**:
- ❌ 删除 `NODE_COUNT` / `NODE_LIST` 参数
- ✅ 自动从配置计算节点数
- ✅ 使用 Python 脚本处理 sbatch 提交
- ✅ 最小化 Groovy 逻辑，主要逻辑在 Python 脚本中

**关键代码片段**:
```groovy
// Disagg 模式 - 自动计算节点数
stage('处理配置 - Disagg 模式') {
    def nodeInfoJson = sh(
        script: "python3 ${calcScript} --config ${configFullPath} --json",
        returnStdout: true
    ).trim()
    
    def nodeInfo = readJSON text: nodeInfoJson
    
    echo "✓ 将使用 ${nodeInfo.total_nodes} 个硬件节点"
    
    // 保存到环境变量
    env.REQUIRED_NODES = nodeInfo.total_nodes.toString()
}

// Multi-Agg 模式 - 从配置读取节点数
stage('处理配置 - Agg 模式') {
    if (TEST_MODE == 'multi-agg') {
        def nodeCount = sh(
            script: """
python3 << 'EOF'
import yaml
with open('${configFullPath}') as f:
    config = yaml.safe_load(f)
world_size = config['server_config'].get('world_size', 0)
gpus_per_node = config.get('gpus_per_node', 8)
nodes = (world_size + gpus_per_node - 1) // gpus_per_node if world_size > 0 else 2
print(nodes)
EOF
""",
            returnStdout: true
        ).trim().toInteger()
        
        env.REQUIRED_NODES = nodeCount.toString()
    }
}
```

### 2. `jenkins_test/scripts/submit_disagg.py`

**主要变更**:
- ❌ 删除 `--node-count` 参数
- ❌ 删除 `validate_node_count()` 函数
- ✅ 直接使用 `node_info.json` 中的信息
- ✅ 生成 sbatch 脚本并提交
- ✅ 等待作业完成（可选）

**使用方式**:
```bash
python3 submit_disagg.py \
    --node-info-json node_info.json \    # 包含所有节点信息
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file config.yaml \
    --workspace /path/to/workspace \
    --dry-run                             # 可选：试运行
```

## 🎯 执行流程对比

### 之前的流程（错误）
```
用户输入:
  TEST_MODE: disagg
  TESTLIST: xxx
  NODE_LIST: node1,node2,node3,node4  ← 用户需要猜测

Pipeline:
  1. 计算配置要求的节点数: 4
  2. 解析 NODE_LIST: 4 个节点
  3. 验证: 4 == 4 ✓
  4. 提交作业（但不使用 NODE_LIST 的节点名称！）
  
问题: 用户提供的节点名称根本没用！
```

### 现在的流程（正确）
```
用户输入:
  TEST_MODE: disagg
  TESTLIST: xxx
  (不需要提供节点信息)  ← 系统自动计算

Pipeline:
  1. 从 TestList 提取配置文件
  2. 调用 calculate_hardware_nodes.py
     → 自动计算: total_nodes = 4
  3. 生成 sbatch 脚本:
     #SBATCH --nodes=4      ← 告诉 Slurm 需要 4 个节点
  4. sbatch 提交作业
  5. Slurm 自动分配 4 个可用节点
     → 例如: gpu-node-[05-08]
  6. 运行时通过 $SLURM_NODELIST 获取实际节点

完美！用户不需要关心节点细节
```

## 📝 使用示例

### Disagg 模式
```groovy
// Jenkins 参数
TEST_MODE: disagg
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes

// 系统自动完成:
// 1. 从 TestList 提取配置: deepseek-r1-fp4_1k1k_ctx1_gen1...
// 2. 查找配置文件: tests/integration/defs/perf/disagg/test_configs/wideep/perf/xxx.yaml
// 3. 计算节点数: total_nodes = 4
// 4. 生成并提交 sbatch 脚本
// 5. Slurm 分配节点并运行
```

### Multi-Agg 模式
```groovy
// Jenkins 参数
TEST_MODE: multi-agg
CONFIG_FILE: deepseek_r1_fp4_v2_grace_blackwell

// 系统自动完成:
// 1. 查找配置文件: tests/scripts/perf-sanity/deepseek_r1_fp4_v2_grace_blackwell.yaml
// 2. 从配置读取: world_size = 16, gpus_per_node = 8
// 3. 计算节点数: nodes = (16 + 8 - 1) // 8 = 2
// 4. 生成并提交 sbatch 脚本
// 5. Slurm 分配 2 个节点并运行
```

### Single-Agg 模式
```groovy
// Jenkins 参数
TEST_MODE: single-agg
CONFIG_FILE: some_single_node_config

// 系统自动完成:
// 1. 直接运行 pytest（单节点，不需要 sbatch）
// 2. 在当前节点执行测试
```

## 🔧 技术细节

### Slurm 节点分配机制
```bash
# 步骤 1: 提交时只告诉 Slurm 需要多少个节点
sbatch --nodes=4 script.sh

# 步骤 2: Slurm 自动选择 4 个可用节点
# 可能是: gpu-node-[05-08]
# 也可能是: gpu-node-[10-13]
# 取决于当前哪些节点可用

# 步骤 3: 运行时获取实际分配的节点
echo $SLURM_NODELIST      # gpu-node-[05-08]
echo $SLURM_JOB_NUM_NODES # 4

# 步骤 4: srun 在已分配的节点中执行任务
srun -N 2 hostname        # 从 4 个节点中选 2 个
```

### calculate_hardware_nodes.py 的作用
```python
def calculate_hardware_nodes(config_path):
    """
    从 disagg 配置文件计算硬件节点数
    
    输入: YAML 配置文件
    hardware:
      num_ctx_servers: 1        # 逻辑
      num_gen_servers: 1
      gpus_per_node: 8
    worker_config:
      ctx:
        tensor_parallel_size: 16
      gen:
        tensor_parallel_size: 16
    
    计算:
    ctx_world_size = 16
    gen_world_size = 16
    
    ctx_nodes = ceil(16 * 1 / 8) = 2
    gen_nodes = ceil(16 * 1 / 8) = 2
    
    total_nodes = 2 + 2 = 4
    
    输出: 
    {
      "num_ctx_servers": 1,
      "num_gen_servers": 1,
      "ctx_nodes": 2,
      "gen_nodes": 2,
      "total_nodes": 4,
      "total_gpus": 32,
      "gpus_per_node": 8
    }
    """
```

## 🎉 修复效果

### 用户体验
- ✅ 简单：只需提供配置文件名或 TestList
- ✅ 自动：系统自动计算所有细节
- ✅ 正确：符合 Slurm 的最佳实践
- ✅ 灵活：Slurm 可以自由选择最优节点

### 技术实现
- ✅ 符合 Slurm 规范
- ✅ 逻辑清晰，易于维护
- ✅ Python 脚本处理复杂逻辑
- ✅ Groovy 只做编排和调用

### 与 L0_Test.groovy 一致
- ✅ 都使用 `--nodes=<count>` 而不是具体节点名称
- ✅ 都由 Slurm 自动分配节点
- ✅ 都在运行时获取 `$SLURM_NODELIST`

## 📚 相关文档

- `jenkins_test/NODE_LIST_ISSUE.md` - 详细的问题分析
- `jenkins_test/TEST_PROCESS.md` - 测试执行流程文档
- `jenkins_test/README.md` - 使用说明
