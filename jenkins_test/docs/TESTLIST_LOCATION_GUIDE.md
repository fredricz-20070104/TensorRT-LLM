# Testlist 位置适配指南

## 📋 背景

`jenkins_test/testlists/` 目录只是示例/demo，实际的 test lists 应该使用 TensorRT-LLM 仓库中的：
```
tests/integration/test_lists/qa/
```

这是 QA 团队维护的标准位置，包含真实的测试用例。

---

## 🎯 适配方案

### 方案 1: 使用 TensorRT-LLM 仓库的 testlists（推荐）✅

**优点：**
- ✅ 使用标准位置，符合 TensorRT-LLM 架构
- ✅ 与 QA 团队共享同一份 testlists
- ✅ 无需维护 jenkins_test/testlists/ 的副本
- ✅ 简化 Pipeline 逻辑

**修改步骤：**

#### 1. 修改 `Perf_Test.groovy` 的 environment 部分

**修改前：**
```groovy
environment {
    // 工作目录
    WORKSPACE_ROOT = "${WORKSPACE}"
    TRTLLM_DIR = "${WORKSPACE}/TensorRT-LLM"
    SCRIPTS_DIR = "${WORKSPACE}/jenkins_test/scripts/perf"
    TESTLISTS_DIR = "${WORKSPACE}/jenkins_test/testlists"  // ← 旧位置
    
    // ...
}
```

**修改后：**
```groovy
environment {
    // 工作目录
    WORKSPACE_ROOT = "${WORKSPACE}"
    TRTLLM_DIR = "${WORKSPACE}/TensorRT-LLM"
    SCRIPTS_DIR = "${WORKSPACE}/jenkins_test/scripts/perf"
    TESTLISTS_DIR = "${TRTLLM_DIR}/tests/integration/test_lists/qa"  // ← 新位置
    
    // ...
}
```

#### 2. 更新 TESTLIST choices（可选）

**修改前：**
```groovy
choice(
    name: 'TESTLIST',
    choices: [
        // 🌟 YAML 格式测试套件（推荐生产环境）
        'gb200_unified_suite',
        'gb300_unified_suite',
        
        // 🔧 TXT 格式 Debug 列表（快速调试，支持所有测试类型）
        'debug_cases',
        
        // 手动调试模式
        'manual'
    ],
    // ...
)
```

**修改后（使用实际的 QA testlists）：**
```groovy
choice(
    name: 'TESTLIST',
    choices: [
        // 🌟 性能测试套件（YAML）
        'llm_perf_sanity',           // 性能 sanity 测试
        'llm_perf_core',             // 核心性能测试
        'llm_spark_perf',            // Spark 性能测试
        'llm_trt_integration_perf_sanity',  // TRT 集成性能 sanity
        'llm_trt_integration_perf',  // TRT 集成性能完整测试
        
        // 🧪 功能测试套件（TXT）
        'llm_function_core_sanity',  // 核心功能 sanity
        'llm_function_core',         // 核心功能完整测试
        'llm_function_multinode',    // 多节点功能测试
        'llm_function_l20',          // L20 功能测试
        'llm_function_rtx6k',        // RTX6000 功能测试
        'llm_function_stress',       // 压力测试
        
        // 🔧 其他
        'llm_triton_integration',    // Triton 集成测试
        'llm_spark_func',            // Spark 功能测试
        'llm_spark_core',            // Spark 核心测试
        
        // 🛠️ 手动模式
        'manual'
    ],
    description: '''选择测试列表（从 TensorRT-LLM/tests/integration/test_lists/qa/）:

📋 性能测试套件 (.yml):
  • llm_perf_sanity: 性能 sanity 测试（快速验证）
  • llm_perf_core: 核心性能测试（完整测试）
  • llm_spark_perf: Spark 性能测试
  • llm_trt_integration_perf_sanity: TRT 集成性能 sanity
  • llm_trt_integration_perf: TRT 集成性能完整测试

🧪 功能测试套件 (.txt):
  • llm_function_core_sanity: 核心功能 sanity（快速验证）
  • llm_function_core: 核心功能完整测试
  • llm_function_multinode: 多节点功能测试
  • llm_function_l20: L20 GPU 功能测试
  • llm_function_rtx6k: RTX6000 功能测试
  • llm_function_stress: 压力测试

🔧 其他测试套件:
  • llm_triton_integration: Triton 集成测试
  • llm_spark_func: Spark 功能测试
  • llm_spark_core: Spark 核心测试

🛠️ 手动模式:
  • manual: 手动指定单个配置文件

详见: TensorRT-LLM/tests/integration/test_lists/qa/README.md'''
)
```

#### 3. 验证修改

测试 Pipeline 能正确找到 testlists：

```bash
# 在 Jenkins Pipeline 的 '参数验证和模式识别' stage 中会看到：
echo "TestList 文件: ${env.TESTLIST_FILE}"
# 应该输出: TestList 文件: /workspace/TensorRT-LLM/tests/integration/test_lists/qa/llm_perf_sanity.yml
```

---

### 方案 2: 支持两个位置（兼容模式）

**优点：**
- ✅ 向后兼容，支持 jenkins_test/testlists/
- ✅ 同时支持 TensorRT-LLM 仓库的 testlists
- ✅ 灵活，可以保留一些自定义 testlists

**修改步骤：**

#### 1. 修改 `Perf_Test.groovy` 的参数验证逻辑

**完整实现：**

```groovy
stage('参数验证和模式识别') {
    steps {
        script {
            echo "=" * 80
            echo "TensorRT-LLM 性能测试 Pipeline"
            echo "=" * 80
            echo "模式: ${TESTLIST}"
            echo "目标集群: ${CLUSTER}"
            // ... 其他输出 ...
            
            // 判断运行模式
            if (TESTLIST == 'manual') {
                // 手动调试模式：直接调用单独的脚本
                env.USE_TESTLIST = 'false'
                env.TEST_MODE = MANUAL_TEST_MODE
                
                if (!CONFIG_FILE) {
                    error "手动模式需要指定 CONFIG_FILE"
                }
                
                echo "运行模式: 手动调试"
                echo "测试类型: ${env.TEST_MODE}"
                echo "配置文件: ${CONFIG_FILE}"
                
            } else {
                // TestList 模式：使用统一的 run_perf_tests.sh
                env.USE_TESTLIST = 'true'
                
                // ========================================
                // 智能查找 testlist 文件
                // ========================================
                def testlistLocations = [
                    // 优先使用 TensorRT-LLM 仓库（标准位置）
                    "${TRTLLM_DIR}/tests/integration/test_lists/qa/${TESTLIST}.yml",
                    "${TRTLLM_DIR}/tests/integration/test_lists/qa/${TESTLIST}.txt",
                    
                    // 备用：jenkins_test/testlists（兼容旧配置）
                    "${WORKSPACE}/jenkins_test/testlists/${TESTLIST}.yml",
                    "${WORKSPACE}/jenkins_test/testlists/${TESTLIST}.txt",
                ]
                
                def foundTestlist = null
                for (location in testlistLocations) {
                    if (fileExists(location)) {
                        foundTestlist = location
                        break
                    }
                }
                
                if (foundTestlist == null) {
                    error """找不到 testlist 文件: ${TESTLIST}
                    
查找路径:
  1. ${TRTLLM_DIR}/tests/integration/test_lists/qa/${TESTLIST}.yml
  2. ${TRTLLM_DIR}/tests/integration/test_lists/qa/${TESTLIST}.txt
  3. ${WORKSPACE}/jenkins_test/testlists/${TESTLIST}.yml
  4. ${WORKSPACE}/jenkins_test/testlists/${TESTLIST}.txt
  
请检查：
  - Testlist 名称是否正确
  - TensorRT-LLM 仓库是否已克隆
  - tests/integration/test_lists/qa/ 目录是否存在"""
                }
                
                env.TESTLIST_FILE = foundTestlist
                
                echo "运行模式: TestList"
                echo "TestList 文件: ${env.TESTLIST_FILE}"
                echo "测试过滤: ${FILTER_MODE}"
            }
            
            echo "=" * 80
        }
    }
}
```

#### 2. 更新 TESTLIST choices（推荐分组显示）

```groovy
choice(
    name: 'TESTLIST',
    choices: [
        // ========================================
        // 🌟 TensorRT-LLM QA Testlists（推荐）
        // ========================================
        '-- TensorRT-LLM QA Testlists --',
        'llm_perf_sanity',
        'llm_perf_core',
        'llm_function_core_sanity',
        'llm_function_core',
        'llm_function_multinode',
        // ... 其他 QA testlists ...
        
        // ========================================
        // 🔧 Jenkins Test Demo Testlists
        // ========================================
        '-- Jenkins Test Demo --',
        'debug_cases',
        'debug_single_agg',
        
        // ========================================
        // 🛠️ 手动模式
        // ========================================
        'manual'
    ],
    description: '''选择测试列表:

🌟 TensorRT-LLM QA Testlists（推荐）:
  位置: TensorRT-LLM/tests/integration/test_lists/qa/
  • llm_perf_sanity: 性能 sanity 测试
  • llm_perf_core: 核心性能测试
  • llm_function_core: 核心功能测试
  • llm_function_multinode: 多节点功能测试
  ... 查看完整列表: tests/integration/test_lists/qa/README.md

🔧 Jenkins Test Demo Testlists（示例）:
  位置: jenkins_test/testlists/
  • debug_cases: Debug 用测试列表（示例）
  • debug_single_agg: Single-Agg 示例

🛠️ 手动模式:
  • manual: 手动指定单个配置文件'''
)
```

---

## 📝 完整的修改示例（方案 1）

### 修改 `jenkins_test/Perf_Test.groovy`

```groovy
// 第 124-129 行（environment 部分）
environment {
    // 工作目录
    WORKSPACE_ROOT = "${WORKSPACE}"
    TRTLLM_DIR = "${WORKSPACE}/TensorRT-LLM"
    SCRIPTS_DIR = "${WORKSPACE}/jenkins_test/scripts/perf"
    TESTLISTS_DIR = "${TRTLLM_DIR}/tests/integration/test_lists/qa"  // ✅ 修改这里
    
    // 输出目录（每个 build 独立）
    OUTPUT_DIR = "${WORKSPACE}/output_${BUILD_NUMBER}"
    // ... 其他配置 ...
}
```

### 对应的 sync_and_run.sh 修改（可选）

如果 `sync_and_run.sh` 需要同步 testlists，需要确保同步 TensorRT-LLM 仓库时包含了 `tests/integration/test_lists/qa/` 目录。

**好消息：** 因为你的 Pipeline 已经克隆了完整的 TensorRT-LLM 仓库，所以 testlists 会自动包含在内，无需额外修改！

```bash
# sync_and_run.sh 已经同步了整个 TensorRT-LLM 仓库
# 所以 tests/integration/test_lists/qa/ 会自动被同步
```

---

## 🗑️ 清理建议

采用方案 1 后，可以删除：

```bash
# 可选：删除 jenkins_test/testlists/ demo 目录
rm -rf jenkins_test/testlists/

# 或者保留作为参考文档
mv jenkins_test/testlists jenkins_test/testlists.examples
```

**最终目录结构：**

```
jenkins_test/
├── scripts/
│   └── perf/              ← 性能测试脚本
├── config/
│   └── clusters.conf      ← 集群配置（唯一需要的配置）
├── Perf_Test.groovy       ← Jenkins Pipeline（已更新）
└── docs/                  ← 文档

TensorRT-LLM/
└── tests/
    └── integration/
        └── test_lists/
            └── qa/        ← ✅ 实际的 testlists 位置
                ├── llm_perf_sanity.yml
                ├── llm_perf_core.yml
                ├── llm_function_core.txt
                ├── llm_function_multinode.txt
                └── ...    (共 19 个 testlists)
```

---

## ✅ 验证步骤

### 1. 本地验证 testlist 文件存在

```bash
# 检查 TensorRT-LLM 仓库的 testlists
ls -la TensorRT-LLM/tests/integration/test_lists/qa/

# 应该看到：
# llm_perf_sanity.yml
# llm_perf_core.yml
# llm_function_core.txt
# ... 等 19 个文件
```

### 2. 在 Jenkins 中测试

选择一个真实的 testlist（如 `llm_perf_sanity`）运行 Pipeline，检查日志：

```
运行模式: TestList
TestList 文件: /workspace/TensorRT-LLM/tests/integration/test_lists/qa/llm_perf_sanity.yml
测试过滤: all
```

### 3. 验证 parse_unified_testlist.py 能正确解析

```bash
# 在 Cluster 上测试
python scripts/perf/parse_unified_testlist.py \
    TensorRT-LLM/tests/integration/test_lists/qa/llm_perf_sanity.yml \
    --summary
```

---

## 🎯 推荐方案

**推荐使用方案 1**（直接使用 TensorRT-LLM 仓库的 testlists），因为：

1. ✅ **简单直接**：只需修改一行代码
2. ✅ **标准化**：使用 TensorRT-LLM 的标准位置
3. ✅ **易维护**：QA 团队统一维护，无需同步副本
4. ✅ **避免冗余**：不需要在 jenkins_test/ 保留副本

**方案 2** 适合需要保留一些自定义 testlists 的场景。

---

## 📋 相关文档

- TensorRT-LLM Testlists: `tests/integration/test_lists/qa/README.md`
- Testlist 格式说明: `jenkins_test/docs/TESTLIST_FORMAT_GUIDE.md`
- Parse 工具文档: `jenkins_test/docs/PARSE_UNIFIED_TESTLIST.md`

---

## 💡 总结

- ✅ `jenkins_test/testlists/` 只是 demo，可以删除
- ✅ 实际使用 `tests/integration/test_lists/qa/` 中的 testlists
- ✅ 只需修改 `Perf_Test.groovy` 中的 `TESTLISTS_DIR` 即可
- ✅ 方案 1 最简单，方案 2 最灵活
