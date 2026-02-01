# Perf_Test.groovy NODE_LIST 参数设计问题

## 🚨 问题概述

当前 `Perf_Test.groovy` 中的 `NODE_LIST` 参数设计存在根本性错误，与 Slurm 的实际工作机制不符。

## ❌ 当前错误实现

### 参数定义
```groovy
properties([
    parameters([
        string(name: 'NODE_LIST', defaultValue: '', description: '节点列表'),
        ...
    ])
])
```

### 用户使用方式
```groovy
NODE_LIST: node1,node2,node3,node4  // 用户手动指定节点名称
```

### 验证逻辑 (第 244-257 行)
```groovy
if (NODE_LIST) {
    def providedNodes = NODE_LIST.split(',').size()
    echo "提供的节点数: ${providedNodes}"
    
    if (providedNodes != nodeInfo.total_nodes) {
        error """
节点数不匹配！
  配置要求: ${nodeInfo.total_nodes} 个节点
  实际提供: ${providedNodes} 个节点
"""
    }
    
    echo "✓ 节点数验证通过"
}
```

## 🔍 为什么这是错误的

### 1. Slurm 的节点分配机制

Slurm 作业调度器的工作方式：

```bash
# 步骤 1: 提交作业时，只告诉 Slurm 需要多少个节点
$ sbatch --nodes=4 my_job.sh
Submitted batch job 12345

# 步骤 2: Slurm 根据当前集群状态，自动选择 4 个可用节点
# 可能分配: gpu-node-05, gpu-node-06, gpu-node-07, gpu-node-08

# 步骤 3: 作业运行时，通过环境变量获取实际分配的节点
$ echo $SLURM_NODELIST
gpu-node-[05-08]

$ echo $SLURM_JOB_NUM_NODES
4
```

**关键点**:
- ✅ 用户只需指定**数量**，不需要指定**名称**
- ✅ Slurm 动态分配可用节点
- ✅ 节点名称在运行时才能确定

### 2. submit.py 完全不使用 NODE_LIST

查看 `jenkins/scripts/perf/disaggregated/submit.py`:

```python
# submit.py 生成的启动脚本中使用的是节点数量，不是节点名称
srun -N $nodesPerGenServer \      # ← 只使用数量
     --ntasks=$gen_world_size \
     --ntasks-per-node=$gpusPerNode \
     $runScript
```

查看 `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`:

```bash
# 启动 gen servers (第 19-31 行)
for i in $(seq 0 $((numGenServers - 1))); do
    srun "${srunArgs[@]}" \
        -N $nodesPerGenServer \              # ← 只指定数量: 2
        --ntasks=$gen_world_size \
        --ntasks-per-node=$gpusPerNode \
        $runScript &
done

# Slurm 自动从已分配的节点池中选择 2 个节点
# 根本不需要用户提供的 node1,node2,node3,node4 列表！
```

### 3. 限制调度灵活性

如果用户指定了具体节点：
- ❌ 这些节点可能正在被其他作业使用
- ❌ 可能有更好的节点可用，但被限制了
- ❌ 违背了 Slurm 智能调度的初衷

### 4. 用户体验差

用户需要：
1. 查询哪些节点当前可用
2. 手动构造节点列表字符串
3. 确保节点数量正确

这些步骤完全是多余的！

## ✅ 正确的实现方式

参考 `L0_Test.groovy` 的实现：

### 1. 参数定义

```groovy
properties([
    parameters([
        string(name: 'NODE_COUNT', defaultValue: '', description: '节点数量（可选，disagg模式会自动从配置计算）'),
        ...
    ])
])
```

### 2. 生成节点参数的函数 (L0_Test.groovy 第 783-798 行)

```groovy
def getNodeArgs(int nodeCount, int gpuCount, boolean setSegment = false) {
    int gpusPerNode = ((gpuCount / nodeCount) as BigDecimal)
        .setScale(0, BigDecimal.ROUND_CEILING).intValue()
    
    def args = nodeCount == 1 ? [
        "--nodes=${nodeCount}",
        "--gpus=${gpuCount}"
    ] : [
        "--nodes=${nodeCount}",           // ← 只指定数量
        "--ntasks=${gpuCount}",
        "--ntasks-per-node=${gpusPerNode}",
        "--gpus-per-node=${gpusPerNode}",
    ]
    
    if (setSegment && gpuCount > 1) {
        args += ["--segment=${nodeCount}"]
    }
    
    return args
}
```

### 3. 在 sbatch 脚本中使用 (L0_Test.groovy 第 1163-1174 行)

```groovy
def scriptLaunchPrefix = """#!/bin/bash
    #SBATCH --output=${slurmJobLogPath}
    ${taskArgs.collect { "#SBATCH $it" }.join('\n')}
    
    set -xEeuo pipefail
    
    echo "Starting Slurm job \$SLURM_JOB_ID on \$SLURM_NODELIST"
    
    export jobWorkspace=$jobWorkspace
    ...
""".replaceAll("(?m)^\\s*", "")
```

生成的脚本内容：
```bash
#!/bin/bash
#SBATCH --output=/path/to/log
#SBATCH --nodes=4              # ← 只告诉 Slurm 需要 4 个节点
#SBATCH --ntasks=32
#SBATCH --ntasks-per-node=8
#SBATCH --gpus-per-node=8

set -xEeuo pipefail

echo "Starting Slurm job $SLURM_JOB_ID on $SLURM_NODELIST"  # ← 运行时打印实际分配的节点
```

### 4. 验证逻辑

```groovy
// 方式 1: 如果用户提供了 NODE_COUNT，验证是否匹配
if (params.NODE_COUNT) {
    def requestedNodes = params.NODE_COUNT.toInteger()
    if (requestedNodes != nodeInfo.total_nodes) {
        error """
节点数不匹配！
  配置要求: ${nodeInfo.total_nodes} 个节点
  用户指定: ${requestedNodes} 个节点
"""
    }
    echo "✓ 节点数验证通过"
}

// 方式 2: 直接使用计算出的节点数（更简单）
def requiredNodes = nodeInfo.total_nodes
echo "配置要求 ${requiredNodes} 个节点，将提交给 Slurm"
```

## 📋 修复步骤

### 步骤 1: 修改参数定义

```diff
--- a/jenkins_test/Perf_Test.groovy
+++ b/jenkins_test/Perf_Test.groovy
@@ -7,7 +7,7 @@ properties([
         choice(name: 'TEST_MODE', choices: ['disagg', 'multi-agg', 'single-agg'], description: '测试模式'),
         string(name: 'TESTLIST', defaultValue: '', description: 'TestList 名称 (disagg 模式)'),
         string(name: 'CONFIG_FILE', defaultValue: '', description: '或直接指定配置文件名'),
-        string(name: 'NODE_LIST', defaultValue: '', description: '节点列表'),
+        string(name: 'NODE_COUNT', defaultValue: '', description: '节点数量（可选，disagg会自动计算）'),
         string(name: 'TRTLLM_REPO', defaultValue: 'https://github.com/NVIDIA/TensorRT-LLM.git', description: 'TensorRT-LLM 仓库地址'),
         string(name: 'TRTLLM_BRANCH', defaultValue: 'main', description: 'TensorRT-LLM 分支名称'),
         booleanParam(name: 'DRY_RUN', defaultValue: false, description: '试运行')
```

### 步骤 2: 修改验证逻辑

```diff
--- a/jenkins_test/Perf_Test.groovy
+++ b/jenkins_test/Perf_Test.groovy
@@ -241,14 +241,14 @@ pipeline {
                     echo "  总 GPU 数: ${nodeInfo.total_gpus}"
                     
                     // 验证节点数
-                    if (NODE_LIST) {
-                        def providedNodes = NODE_LIST.split(',').size()
-                        echo "提供的节点数: ${providedNodes}"
+                    if (params.NODE_COUNT) {
+                        def requestedNodes = params.NODE_COUNT.toInteger()
+                        echo "用户指定节点数: ${requestedNodes}"
                         
-                        if (providedNodes != nodeInfo.total_nodes) {
+                        if (requestedNodes != nodeInfo.total_nodes) {
                             error """
 节点数不匹配！
   配置要求: ${nodeInfo.total_nodes} 个节点
-  实际提供: ${providedNodes} 个节点
+  用户指定: ${requestedNodes} 个节点
 """
                         }
```

### 步骤 3: 添加 sbatch 生成逻辑

在 disagg 模式下，需要生成 sbatch 脚本并提交（类似 L0_Test.groovy）：

```groovy
// 在 disagg 模式的 Run Test stage 中
if (TEST_MODE == 'disagg') {
    // ... 前面的验证逻辑 ...
    
    // 生成 sbatch 参数
    def nodeArgs = [
        "--nodes=${nodeInfo.total_nodes}",
        "--ntasks=${nodeInfo.total_gpus}",
        "--ntasks-per-node=${nodeInfo.gpus_per_node}",
        "--gpus-per-node=${nodeInfo.gpus_per_node}"
    ]
    
    // 生成 sbatch 脚本
    def sbatchScript = """#!/bin/bash
${nodeArgs.collect { "#SBATCH $it" }.join('\n')}

set -xEeuo pipefail

echo "Starting Slurm job \\$SLURM_JOB_ID on \\$SLURM_NODELIST"

cd ${TRTLLM_DIR}
python3 jenkins/scripts/perf/disaggregated/submit.py \\
    --config ${RESOLVED_CONFIG} \\
    ...
"""
    
    // 写入脚本并提交
    sh "echo '${sbatchScript}' > /tmp/sbatch_script.sh"
    sh "chmod +x /tmp/sbatch_script.sh"
    sh "sbatch /tmp/sbatch_script.sh"
}
```

## 🎯 修复后的效果

### 用户使用

**之前（错误）**:
```groovy
// 用户需要猜测或查询节点名称
NODE_LIST: node1,node2,node3,node4
```

**之后（正确）**:
```groovy
// 选项 1: 让系统自动计算（推荐）
NODE_COUNT: (留空)

// 选项 2: 手动指定数量（用于验证）
NODE_COUNT: 4
```

### Jenkins 输出

```
配置要求 4 个节点
用户指定 4 个节点
✓ 节点数验证通过

正在生成 sbatch 脚本...
#SBATCH --nodes=4
#SBATCH --ntasks=32
#SBATCH --ntasks-per-node=8

提交 Slurm 作业...
Submitted batch job 12345

Starting Slurm job 12345 on gpu-node-[05-08]  ← Slurm 自动分配的节点
```

## 📚 参考

- `L0_Test.groovy` 第 783-798 行: `getNodeArgs()` 函数
- `L0_Test.groovy` 第 1076 行: 调用 `getNodeArgs()`
- `L0_Test.groovy` 第 1163-1174 行: 生成 sbatch 脚本
- `L0_Test.groovy` 第 1271 行: 提交 sbatch 作业
- Slurm 文档: https://slurm.schedmd.com/sbatch.html

## 🏁 总结

| 维度 | 当前错误实现 | 正确实现 |
|------|-------------|----------|
| **参数名称** | `NODE_LIST` | `NODE_COUNT` |
| **参数类型** | 字符串列表 | 整数 |
| **用户输入** | `node1,node2,node3,node4` | `4` |
| **验证方式** | `NODE_LIST.split(',').size()` | `params.NODE_COUNT.toInteger()` |
| **sbatch 参数** | 未使用 | `--nodes=4` |
| **节点分配** | 假装用户知道节点名称 | Slurm 自动分配 |
| **submit.py** | 完全不使用 NODE_LIST | 使用 total_nodes 数量 |
| **用户体验** | 复杂、容易出错 | 简单、自动化 |
| **调度灵活性** | 受限 | 灵活 |
| **符合 Slurm 最佳实践** | ❌ 否 | ✅ 是 |
