# 性能测试快速参考

## 🎯 常用命令

### 使用 TestList（推荐）

```bash
# 单机 Agg (2 节点配置)
./jenkins/scripts/run_perf_tests.sh \
    --mode single \
    --testlist l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes

# 多机 Agg (2 节点)
./jenkins/scripts/run_perf_tests.sh \
    --mode multi-agg \
    --testlist l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes \
    --nodes "gb200-node1,gb200-node2"

# 多机 Disagg (3 节点)
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --nodes "gb200-node1,gb200-node2,gb200-node3"

# 多机 Disagg (6 节点)
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_6_nodes \
    --nodes "node1,node2,node3,node4,node5,node6"
```

### 使用单个测试用例

```bash
# 单机
./jenkins/scripts/run_perf_tests.sh \
    --mode single \
    --test-case "aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml"

# 多机 Disagg
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --test-case "disagg_upload-deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128_eplb288_mtp3_ccb-DEFAULT" \
    --nodes "node1,node2,node3"
```

## 📋 可用的 TestList

| TestList | 类型 | 节点数 | GPU数 |
|----------|------|--------|-------|
| `l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes` | Agg | 2 | 8 |
| `l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes` | Disagg | 3 | 12 |
| `l0_gb200_multi_nodes_disagg_perf_sanity_6_nodes` | Disagg | 6 | 24 |
| `l0_gb200_multi_nodes_disagg_perf_sanity_8_nodes` | Disagg | 8 | 32 |

## 🔍 查看 TestList 内容

```bash
# 列出所有 perf testlist
ls tests/integration/test_lists/test-db/*perf*.yml

# 查看具体内容
cat tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml

# 提取测试用例
python3 << 'EOF'
import yaml
with open('tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml') as f:
    data = yaml.safe_load(f)
    for item in data[list(data.keys())[1]]:
        if 'tests' in item:
            for test in item['tests']:
                print(test)
EOF
```

## 🎨 Jenkins Pipeline 参数

| 参数 | 示例值 | 说明 |
|------|--------|------|
| TEST_MODE | `disagg` | single / multi-agg / disagg |
| TESTLIST | `l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes` | TestList 名称 |
| TEST_CASE | `aggr_upload-xxx.yaml` | 单个测试（可选） |
| NODE_LIST | `node1,node2,node3` | 节点列表（多机） |
| DOCKER_IMAGE | `nvcr.io/nvidia/tensorrt-llm:latest` | Docker 镜像 |
| OUTPUT_DIR | `/tmp/perf_test_output` | 输出目录 |

## 🚦 测试类型对应关系

### Agg 测试

```
TestList: l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes
  ↓
测试: aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-xxx
  ↓
配置: tests/scripts/perf-sanity/deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yaml
  ↓
运行: pytest --test-list=test_list.txt
```

### Disagg 测试

```
TestList: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
  ↓
测试: disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
  ↓
配置: tests/integration/defs/perf/disagg/test_configs/disagg/perf/deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
  ↓
运行: submit.py --config xxx.yaml
```

## 📂 文件结构

```
jenkins/
├── config/
│   └── perf_test_cases.yaml          # 测试用例参考（可选）
├── scripts/
│   └── run_perf_tests.sh             # 主运行脚本 ⭐
├── Perf_Test.groovy                  # Jenkins Pipeline ⭐
├── README_WITH_TESTLIST.md           # 详细文档
├── QUICK_REFERENCE.md                # 本文件
└── TESTLIST_EXPLANATION.md           # TestList 原理说明

tests/integration/
├── defs/
│   ├── conftest.py                   # 支持 --test-list 参数 ⭐
│   └── perf/
│       ├── test_perf_sanity.py       # 性能测试主文件 ⭐
│       └── disagg/test_configs/      # Disagg 配置文件
└── test_lists/
    └── test-db/                      # TestList 文件 ⭐
        ├── l0_gb200_multi_nodes_aggr_perf_sanity_2_nodes.yml
        ├── l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml
        └── ...
```

## 🔧 直接使用 pytest（高级）

### 单机 Agg

```bash
cd tests/integration/defs

python3 -m pytest -v -s \
    --test-list=/path/to/test_list.txt \
    --output-dir /tmp/output \
    perf/test_perf_sanity.py::test_e2e
```

### 多机 Agg (srun)

```bash
srun --nodes=2 --ntasks-per-node=1 --gpus-per-node=4 \
     --container-image=nvcr.io/nvidia/tensorrt-llm:latest \
     --container-mounts=$(pwd):/workspace \
     --container-workdir=/workspace/tests/integration/defs \
     python3 -m pytest -v -s \
     --test-list=/workspace/test_list.txt \
     --output-dir /tmp/output \
     perf/test_perf_sanity.py::test_e2e
```

### 多机 Disagg (submit.py)

```bash
python3 jenkins/scripts/perf/disaggregated/submit.py \
    --config tests/integration/defs/perf/disagg/test_configs/disagg/perf/xxx.yaml \
    --work-dir /tmp/output
```

## ⚡ 快速故障排查

| 问题 | 检查 | 解决 |
|------|------|------|
| 找不到 TestList | `ls tests/integration/test_lists/test-db/*.yml` | 确认文件名正确 |
| YAML 解析失败 | `python3 -c "import yaml"` | `pip install pyyaml` |
| 找不到配置文件 | `find tests -name "*xxx*.yaml"` | 检查配置文件路径 |
| SSH 连接失败 | `ssh node1 "echo OK"` | 配置 SSH 密钥 |
| Docker GPU 不可用 | `docker run --rm --gpus all nvidia/cuda:12.1.0-base nvidia-smi` | 安装 nvidia-container-toolkit |

## 🎯 推荐工作流

```bash
# 1. 列出可用的 TestList
ls tests/integration/test_lists/test-db/*perf*.yml

# 2. 查看 TestList 内容
cat tests/integration/test_lists/test-db/l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes.yml

# 3. Dry run 验证
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --nodes "node1,node2,node3" \
    --dry-run

# 4. 实际运行
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --testlist l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
    --nodes "node1,node2,node3"

# 5. 查看结果
ls -lh /tmp/perf_test_output/
```

## 📚 更多信息

- **详细文档**: `jenkins/README_WITH_TESTLIST.md`
- **TestList 原理**: `jenkins/TESTLIST_EXPLANATION.md`
- **架构分析**: `jenkins/ANALYSIS_SUMMARY.md`
