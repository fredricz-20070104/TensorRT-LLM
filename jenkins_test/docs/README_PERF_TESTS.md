# 性能测试运行指南

简化版的多节点性能测试框架，直接使用 `test_perf_sanity.py`。

## 📁 文件结构

```
jenkins/
├── config/
│   └── perf_test_cases.yaml          # 测试用例列表（可选参考）
├── scripts/
│   └── run_perf_tests.sh             # 简化运行脚本
└── Perf_Test.groovy                  # Jenkins Pipeline
```

## ✨ 核心原理

`test_perf_sanity.py` 已经实现了所有测试逻辑：
- **单机 agg**: 本地 Docker 运行
- **多机 agg**: 通过 srun + Docker 运行
- **多机 disagg**: 通过 srun + Docker，自动处理 CTX/GEN/DISAGG_SERVER/BENCHMARK 角色

我们只需要：
1. 调用 pytest
2. 传入正确的测试用例名称
3. 设置环境（Docker 或 srun）

## 🚀 使用方法

### 方法 1: 直接使用 Shell 脚本

#### 单机 Agg 测试

```bash
./jenkins/scripts/run_perf_tests.sh \
    --mode single \
    --test-case "aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml"
```

#### 多机 Agg 测试（2 节点）

```bash
./jenkins/scripts/run_perf_tests.sh \
    --mode multi-agg \
    --test-case "aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml" \
    --nodes "gb200-node1,gb200-node2"
```

#### 多机 Disagg 测试（3 节点）

```bash
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --test-case "disagg_upload-deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128_eplb288_mtp3_ccb-DEFAULT" \
    --nodes "gb200-node1,gb200-node2,gb200-node3"
```

### 方法 2: 直接调用 pytest (高级用法)

#### 单机 Agg

```bash
# 本地 Docker 运行
docker run --rm --gpus all \
    --network host --shm-size 32g \
    -v $(pwd):/workspace -w /workspace \
    nvcr.io/nvidia/tensorrt-llm:latest \
    python3 -m pytest -v -s \
    tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
    -k 'aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml' \
    --output-dir /tmp/output
```

#### 多机 Agg

```bash
# SSH 到主节点，使用 srun
ssh gb200-node1
cd /workspace/TensorRT-LLM

srun --nodes=2 --ntasks-per-node=1 --gpus-per-node=4 \
     --container-image=nvcr.io/nvidia/tensorrt-llm:latest \
     --container-mounts=$(pwd):/workspace \
     --container-workdir=/workspace \
     python3 -m pytest -v -s \
     tests/integration/defs/perf/test_perf_sanity.py::test_e2e \
     -k 'aggr_upload-config.yaml' \
     --output-dir /tmp/output
```

#### 多机 Disagg

```bash
# SSH 到主节点，使用现有的 submit.py
ssh gb200-node1
cd /workspace/TensorRT-LLM

python3 jenkins/scripts/perf/disaggregated/submit.py \
    --config tests/integration/defs/perf/disagg/test_configs/disagg/perf/deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128_eplb288_mtp3_ccb-DEFAULT.yaml \
    --output-dir /tmp/output
```

### 方法 3: Jenkins Pipeline

1. 创建 Jenkins Pipeline Job
2. 使用 `jenkins/Perf_Test.groovy` 作为 Jenkinsfile
3. 配置参数：
   - **TEST_MODE**: `single`, `multi-agg`, 或 `disagg`
   - **TEST_CASE**: 测试用例名称
   - **NODE_LIST**: 节点列表（多机模式需要）
   - **DOCKER_IMAGE**: Docker 镜像
4. 运行构建

## 📝 测试用例格式

### Agg 测试用例

格式：`aggr_upload-<config_file>.yaml[-<server_config_name>]`

示例：
- `aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml`
- `aggr_upload-config_database_b200_nvl.yaml-r1_fp8_dep8_mtp1_1k1k`

配置文件位置：`tests/scripts/perf-sanity/*.yaml`

### Disagg 测试用例

格式：`disagg_upload-<config_base>`

示例：
- `disagg_upload-deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128_eplb288_mtp3_ccb-DEFAULT`
- `disagg_upload-kimi-k2-thinking-fp4_1k1k_ctx3_gen1_dep32_bs1024_eplb384_mtp0_ccb-NIXL`

配置文件位置：
- `tests/integration/defs/perf/disagg/test_configs/disagg/perf/*.yaml`
- `tests/integration/defs/perf/disagg/test_configs/wideep/perf/*.yaml`

## 🔧 环境变量

`test_perf_sanity.py` 会自动处理以下环境变量：

### Disagg 模式

- `DISAGG_SERVING_TYPE`: 
  - `CTX` - Context server
  - `GEN` - Generation server  
  - `DISAGG_SERVER` - Disagg coordinator
  - `BENCHMARK` - Benchmark client

### 其他

- `TRTLLM_CONFIG_FOLDER`: 配置文件目录（可选）
- `CUDA_VISIBLE_DEVICES`: GPU 设备

## 📊 结果收集

测试完成后，会在输出目录生成：

```
/tmp/perf_test_output/
├── trtllm-serve.*.log          # 服务器日志
├── benchmark.*.log             # Benchmark 日志
├── perf_results_*.json         # 性能结果（JSON）
└── *.xml                       # Pytest 结果（如果配置了）
```

## 🐛 Bug 修复建议

### 当前问题

1. **`run_perf_tests.sh` 的 disagg 模式需要完善**
   - 需要调用现有的 `submit.py` 或直接使用 `srun` 启动不同角色
   - 需要处理 `DISAGG_SERVING_TYPE` 环境变量

2. **配置文件路径需要统一**
   - Agg: `tests/scripts/perf-sanity/*.yaml`
   - Disagg: `tests/integration/defs/perf/disagg/test_configs/disagg/perf/*.yaml`

3. **节点分配需要智能化**
   - 根据配置文件自动计算需要的节点数
   - 自动分配 CTX/GEN/DISAGG_SERVER/BENCHMARK 角色

### 修复建议

#### 方案 1: 使用现有的 `submit.py`（推荐）

`submit.py` 已经实现了完整的 disagg 启动逻辑：
- ✅ 自动计算节点分配
- ✅ 生成正确的 srun 命令
- ✅ 设置环境变量
- ✅ 处理不同角色

**修改点**：
```bash
# run_perf_tests.sh 中的 disagg 分支直接调用 submit.py
python3 jenkins/scripts/perf/disaggregated/submit.py \
    --config <config_file> \
    --output-dir <output_dir>
```

#### 方案 2: 直接在脚本中实现（如果需要更细粒度控制）

```bash
# 示例：手动启动 disagg
# 节点 1-2: CTX servers
srun --nodes=2 --ntasks=2 \
     -w node1,node2 \
     --container-env=DISAGG_SERVING_TYPE=CTX \
     ... &

# 节点 3: GEN server
srun --nodes=1 --ntasks=1 \
     -w node3 \
     --container-env=DISAGG_SERVING_TYPE=GEN \
     ... &

# 节点 3: DISAGG_SERVER
srun --nodes=1 --ntasks=1 \
     -w node3 \
     --container-env=DISAGG_SERVING_TYPE=DISAGG_SERVER \
     ... &

# 节点 3: BENCHMARK
srun --nodes=1 --ntasks=1 \
     -w node3 \
     --container-env=DISAGG_SERVING_TYPE=BENCHMARK \
     ...
```

## ✅ 总结

### 优点

1. **简单**: 直接调用 `test_perf_sanity.py`，不需要额外的 Python 包装器
2. **统一**: 所有测试逻辑都在 `test_perf_sanity.py` 中
3. **灵活**: 支持单机/多机，agg/disagg 所有场景
4. **易维护**: 只需要维护测试用例列表

### 需要完善的地方

1. **Disagg 启动逻辑**: 建议直接使用现有的 `submit.py`
2. **错误处理**: 添加更详细的错误信息
3. **日志收集**: 自动收集所有节点的日志

### 下一步

1. 测试 `run_perf_tests.sh` 脚本
2. 根据实际情况调整节点配置
3. 集成到 Jenkins Pipeline
4. 添加结果上传功能（如果需要）

## 💡 示例命令汇总

```bash
# 1. 单机 agg
./jenkins/scripts/run_perf_tests.sh \
    --mode single \
    --test-case "aggr_upload-k2_thinking_fp4_2_nodes_grace_blackwell.yaml"

# 2. 多机 agg (2节点)
./jenkins/scripts/run_perf_tests.sh \
    --mode multi-agg \
    --test-case "aggr_upload-config.yaml" \
    --nodes "node1,node2"

# 3. 多机 disagg (3节点)
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --test-case "disagg_upload-deepseek-r1-fp4_8k1k_ctx2_gen1_dep32_bs128_eplb288_mtp3_ccb-DEFAULT" \
    --nodes "node1,node2,node3"

# 4. Dry run 查看命令
./jenkins/scripts/run_perf_tests.sh \
    --mode disagg \
    --test-case "..." \
    --nodes "..." \
    --dry-run
```
