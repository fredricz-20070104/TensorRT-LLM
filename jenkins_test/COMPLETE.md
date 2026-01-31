# 🎉 jenkins_test 完整版 - 支持所有测试模式！

## ✅ 已修复的问题

### 问题 1: 只支持 Disagg ✅ 已修复
**之前**: 只能运行 multi-node disagg 测试  
**现在**: 支持 single-agg, multi-agg, disagg 三种模式

### 问题 2: perf_test_cases.yaml 未复制 ✅ 已修复
**之前**: 配置文件遗漏  
**现在**: 已复制到 `jenkins_test/config/perf_test_cases.yaml`

### 问题 3: jenkins/ 目录旧文件未删除 ✅ 已修复
**已删除文件**:
- `ANALYSIS_SUMMARY.md`
- `ARCHITECTURE_FINAL.md`
- `QUICK_REFERENCE.md`
- `README_PERF_TESTS.md`
- `README_WITH_TESTLIST.md`
- `SOLUTION_SUMMARY.md`
- `TESTLIST_EXPLANATION.md`
- `scripts/run_perf_tests.sh`
- `scripts/run_perf_tests_simple.sh`
- `config/perf_test_cases.yaml`
- `scripts/calculate_hardware_nodes.py`

**保留文件**: 只保留 L0_Test.groovy 和相关的 L0 脚本

## 📊 新的目录结构

### jenkins_test/ (完整版)

```
jenkins_test/
├── Perf_Test.groovy              # ⭐ 支持 single-agg, multi-agg, disagg
├── scripts/
│   ├── calculate_hardware_nodes.py   # 节点计算 (disagg 用)
│   ├── deploy.sh
│   └── check.sh
├── config/
│   └── perf_test_cases.yaml      # ⭐ 测试用例配置参考
├── docs/
│   ├── ARCHITECTURE_FINAL.md
│   ├── SOLUTION_SUMMARY.md
│   ├── README_PERF_TESTS.md
│   ├── QUICK_REFERENCE.md
│   └── TESTLIST_EXPLANATION.md
└── README.md (已更新)
```

### jenkins/ (原目录，已清理)

```
jenkins/
├── L0_Test.groovy                # ✅ 保留 - L0 测试
├── scripts/
│   └── perf/disaggregated/
│       └── submit.py             # ✅ 保留 - L0 submit
└── (已删除所有 Perf_Test 相关文件)
```

## 🎯 支持的测试模式

### 1. Single Node Agg

**用途**: 单节点聚合测试  
**配置**: Agg 配置文件  
**运行方式**: 直接 pytest

```groovy
TEST_MODE: single-agg
CONFIG_FILE: aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell
```

**执行逻辑**:
```bash
python3 -m pytest \
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
    -k 'aggr_upload-<CONFIG_FILE>'
```

### 2. Multi-Node Agg

**用途**: 多节点聚合测试  
**配置**: Agg 配置文件 + 节点列表  
**运行方式**: srun + pytest

```groovy
TEST_MODE: multi-agg
CONFIG_FILE: aggr_upload-multi_node_config
NODE_LIST: node1,node2
```

**执行逻辑**:
```bash
srun --nodes=2 \
    python3 -m pytest \
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
    -k 'aggr_upload-<CONFIG_FILE>'
```

### 3. Multi-Node Disagg

**用途**: 多节点分离式测试  
**配置**: Disagg 配置文件或 TestList + 节点列表  
**运行方式**: submit.py

```groovy
TEST_MODE: disagg
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
NODE_LIST: node1,node2,node3,node4
```

**执行逻辑**:
```bash
# 1. 从 TestList 提取配置
# 2. 计算硬件节点需求
# 3. 验证节点数
# 4. 调用 submit.py
python3 jenkins/scripts/perf/disaggregated/submit.py \
    --config <extracted_config>.yaml
```

## 🔧 配置文件说明

### config/perf_test_cases.yaml

提供测试用例配置参考，包含：

```yaml
# Single Agg 测试
single_agg_tests:
  - aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml
  - aggr_upload-config_database_b200_nvl.yaml-r1_fp8_dep8_mtp1_1k1k
  - aggr_upload-config_database_h200_sxm.yaml

# Multi Agg 测试 (2 节点)
multi_agg_2nodes_tests:
  - aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml
  - aggr_upload-multi_node_config.yaml

# Multi Disagg 测试 (3/6/8 节点)
disagg_3nodes_tests:
  - disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-NIXL
  - disagg_upload-deepseek-r1-fp4_1k1k_ctx2_gen1_dep16_bs128_eplb288_mtp3_ccb-UCX
  # ...
```

**用途**: 
- 参考可用的测试用例
- 了解测试覆盖范围
- 快速查找配置文件名

## 📝 使用示例

### 示例 1: 运行 Single Node Agg

```groovy
Jenkins 参数:
  TEST_MODE: single-agg
  CONFIG_FILE: aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell
  TRTLLM_BRANCH: main
  DRY_RUN: false

结果:
  ✓ 拉取 TensorRT-LLM
  ✓ 查找配置文件
  ✓ 运行 pytest 单节点测试
```

### 示例 2: 运行 Multi-Node Agg

```groovy
Jenkins 参数:
  TEST_MODE: multi-agg
  CONFIG_FILE: aggr_upload-multi_node_config
  NODE_LIST: gb200-node1,gb200-node2
  TRTLLM_BRANCH: main
  DRY_RUN: false

结果:
  ✓ 拉取 TensorRT-LLM
  ✓ 查找配置文件
  ✓ 使用 srun 运行 2 节点测试
```

### 示例 3: 运行 Multi-Node Disagg (TestList)

```groovy
Jenkins 参数:
  TEST_MODE: disagg
  TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
  NODE_LIST: gb200-node1,gb200-node2,gb200-node3,gb200-node4
  TRTLLM_BRANCH: main
  DRY_RUN: false

结果:
  ✓ 拉取 TensorRT-LLM
  ✓ 从 TestList 提取配置
  ✓ 计算节点需求: 4 个硬件节点
  ✓ 验证节点数匹配
  ✓ 调用 submit.py 提交任务
```

### 示例 4: 运行 Multi-Node Disagg (直接配置)

```groovy
Jenkins 参数:
  TEST_MODE: disagg
  CONFIG_FILE: deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
  NODE_LIST: gb200-node1,gb200-node2,gb200-node3,gb200-node4
  TRTLLM_BRANCH: main
  DRY_RUN: false

结果:
  ✓ 拉取 TensorRT-LLM
  ✓ 查找 disagg 配置文件
  ✓ 计算节点需求并验证
  ✓ 调用 submit.py 提交任务
```

## 🔍 调用链条

### Single Agg
```
Perf_Test.groovy
    ↓ 拉取
TensorRT-LLM/
    ↓ 查找配置
tests/scripts/perf-sanity/<CONFIG>.yaml
    ↓ 运行
pytest test_perf_sanity.py::test_e2e
```

### Multi Agg
```
Perf_Test.groovy
    ↓ 拉取
TensorRT-LLM/
    ↓ 查找配置
tests/scripts/perf-sanity/<CONFIG>.yaml
    ↓ 运行
srun → pytest test_perf_sanity.py::test_e2e
```

### Disagg
```
Perf_Test.groovy
    ↓ 拉取
TensorRT-LLM/
    ↓ 提取配置 (如果用 TestList)
tests/integration/test_lists/test-db/<TESTLIST>.yml
    ↓ 计算节点
calculate_hardware_nodes.py
    ↓ 验证节点
(check nodes)
    ↓ 提交任务
jenkins/scripts/perf/disaggregated/submit.py
```

## 🎉 改进总结

### 功能完整性
- ✅ Single Node Agg
- ✅ Multi-Node Agg
- ✅ Multi-Node Disagg

### 文件整理
- ✅ 所有相关文件移至 jenkins_test/
- ✅ jenkins/ 目录只保留 L0 相关
- ✅ 配置文件完整复制

### 代码质量
- ✅ 支持三种测试模式
- ✅ 清晰的参数和流程
- ✅ 完善的文档

## 🚀 快速开始

### 1. 验证完整性

```bash
cd /localhome/swqa/fzhu/TensorRT-LLM/jenkins_test
./scripts/check.sh
```

### 2. 查看配置参考

```bash
cat config/perf_test_cases.yaml
```

### 3. 部署到 GitLab

```bash
./scripts/deploy.sh https://gitlab.com/your-org/trtllm-perf-test.git
```

### 4. 在 Jenkins 中运行

```
Pipeline 配置:
  Repository URL: <your-gitlab-repo>
  Script Path: Perf_Test.groovy

参数:
  TEST_MODE: single-agg / multi-agg / disagg
  CONFIG_FILE: <配置文件名>
  NODE_LIST: <节点列表> (multi 模式)
  DRY_RUN: true (首次运行建议)
```

## 📚 相关文档

- **README.md** - 主文档（已更新，包含三种模式说明）
- **DEPLOYMENT.md** - 部署指南
- **config/perf_test_cases.yaml** - 测试用例配置参考
- **docs/** - 详细文档

---

**🎊 完成！现在支持所有测试模式了！** 🚀
