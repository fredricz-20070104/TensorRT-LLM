# TensorRT-LLM 性能测试框架

## 📚 快速导航

- **[TEST_PROCESS.md](./TEST_PROCESS.md)** - 完整的执行流程详解和调试指南
- **[testlists/](./testlists/)** - TestList 文件（test-db 格式）
- **[configs/](./configs/)** - 测试配置文件
- **[scripts/](./scripts/)** - 测试执行脚本

---

## 🚀 快速开始

### 方式1: 使用 Jenkins Pipeline（推荐）

```groovy
// 参数设置
TESTLIST: single_agg/gb200_perf_sanity  // 选择预定义的 testlist
CLUSTER: gb200                           // 选择目标集群
```

### 方式2: 本地命令行调试

```bash
# 使用 testlist
./scripts/run_single_agg_test.sh \
    --testlist testlists/single_agg/gb200_perf_sanity.yml \
    --trtllm-dir /path/to/TensorRT-LLM

# 直接指定配置文件
./scripts/run_single_agg_test.sh \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --trtllm-dir /path/to/TensorRT-LLM

# 试运行模式
./scripts/run_single_agg_test.sh \
    --testlist testlists/single_agg/gb200_perf_sanity.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run
```

---

## 📁 目录结构

```
jenkins_test/
├── README.md                    # 本文件
├── TEST_PROCESS.md              # 详细文档
├── Perf_Test.groovy             # Jenkins Pipeline
│
├── testlists/                   # TestList 文件（兼容 test-db 格式）
│   ├── single_agg/              # 单节点聚合测试
│   │   ├── gb200_perf_sanity.yml
│   │   └── gb300_perf_sanity.yml
│   ├── multi_agg/               # 多节点聚合测试
│   │   └── gb200_2nodes_perf.yml
│   └── disagg/                  # 分离式测试
│       └── gb200_3nodes_sanity.yml
│
├── configs/                     # 配置文件（按测试模式分类）
│   ├── single_agg/
│   │   ├── deepseek_r1_fp4_v2_grace_blackwell.yml
│   │   ├── deepseek_v32_fp4_grace_blackwell.yml
│   │   └── k2_thinking_fp4_grace_blackwell.yml
│   ├── multi_agg/
│   │   └── deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yml
│   └── disagg/
│       └── deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768.yaml
│
├── scripts/                     # 执行脚本
│   ├── parse_testlist.py        # TestList 解析工具
│   ├── run_single_agg_test.sh   # 单节点测试
│   ├── run_multi_agg_test.sh    # 多节点聚合测试
│   ├── run_disagg_test.sh       # 分离式测试
│   └── lib/                     # 工具库
│       ├── remote.sh            # 远程执行库
│       └── load_cluster_config.sh
│
└── config/                      # 集群配置
    └── clusters.conf            # 集群定义
```

---

## 🎯 TestList 格式

### 格式说明（完全兼容 test-db）

```yaml
version: 0.0.1
testlist_name:
- condition:
    ranges:
      system_gpu_count:
        gte: 4
        lte: 4
    wildcards:
      gpu:
      - '*gb200*'
    terms:
      stage: pre_merge
      backend: pytorch
  tests:
  # 格式: test_e2e[aggr_upload-{配置文件名}-{配置项名}] TIMEOUT (分钟)
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k]
  - perf/test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_dep4_mtp1_1k1k] TIMEOUT (90)
```

### 配置名称映射

```
测试名称:
  aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k
  
映射到:
  配置文件: configs/single_agg/deepseek_r1_fp4_v2_grace_blackwell.yml
  配置项:   server_configs 中 name="r1_fp4_v2_tp4_mtp3_1k1k"
```

---

## 🔧 常用命令

### 解析 TestList

```bash
# 查看 testlist 包含的测试
python3 scripts/parse_testlist.py \
    testlists/single_agg/gb200_perf_sanity.yml \
    --pretty
```

### 试运行测试

```bash
# 查看将执行的命令（不实际运行）
./scripts/run_single_agg_test.sh \
    --testlist testlists/single_agg/gb200_perf_sanity.yml \
    --trtllm-dir /path/to/TensorRT-LLM \
    --dry-run
```

### 运行单个配置

```bash
# 直接运行某个配置文件的所有测试
./scripts/run_single_agg_test.sh \
    --config-file deepseek_r1_fp4_v2_grace_blackwell \
    --trtllm-dir /path/to/TensorRT-LLM
```

---

## ✨ 特性

- ✅ **兼容 test-db** - TestList 格式与现有 test-db 完全兼容
- ✅ **统一管理** - 配置文件集中在 `configs/` 目录
- ✅ **批量执行** - 一个 testlist 管理多个测试用例
- ✅ **本地调试** - 支持脱离 Jenkins 在本地运行
- ✅ **试运行模式** - 查看命令而不实际执行
- ✅ **灵活切换** - 支持 testlist 模式和手动模式

---

## 📖 详细文档

完整的使用说明、调试技巧和最佳实践请参考：

👉 **[TEST_PROCESS.md](./TEST_PROCESS.md)**

包含内容：
- 完整执行流程详解
- 三种运行模式对比
- 调试技巧和常见问题
- 添加新测试的步骤
- 架构设计说明

---

## 🆘 获取帮助

```bash
# 查看脚本帮助
./scripts/run_single_agg_test.sh --help
./scripts/run_multi_agg_test.sh --help
./scripts/run_disagg_test.sh --help

# 查看解析工具帮助
python3 scripts/parse_testlist.py --help
```
