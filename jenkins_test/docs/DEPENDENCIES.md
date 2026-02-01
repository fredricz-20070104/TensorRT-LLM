# 性能测试依赖文件清单

## 通用依赖

所有测试模式都需要：

### 1. Jenkins 测试脚本
- `jenkins_test/scripts/load_cluster_config.py` - **加载集群配置（Python）**

### 2. 集群配置
- `jenkins_test/config/clusters.conf` - 集群配置文件

**注意**：不再使用 `load_cluster_config.sh` 和 `remote.sh`，改用 Python 实现配置加载。

---

## Single-Agg 模式依赖

### 必需文件
1. **执行脚本**
   - `jenkins_test/scripts/run_single_agg_test.sh`

2. **TensorRT-LLM 测试文件**
   - `tests/integration/defs/perf/test_perf_sanity.py` - pytest 测试主文件

3. **配置文件位置**（按优先级查找）
   - `jenkins_test/configs/single_agg/`
   - `tests/scripts/perf-sanity/`
   - `tests/integration/defs/perf/agg/`

---

## Multi-Agg 模式依赖

### 必需文件
1. **执行脚本**
   - `jenkins_test/scripts/run_multi_agg_test.sh`

2. **TensorRT-LLM 测试文件**
   - `tests/integration/defs/perf/test_perf_sanity.py` - pytest 测试主文件

3. **配置文件位置**（按优先级查找）
   - `jenkins_test/configs/multi_agg/`
   - `tests/scripts/perf-sanity/`
   - `tests/integration/defs/perf/agg/`

---

## Disagg 模式依赖

### 必需文件
1. **执行脚本**
   - `jenkins_test/scripts/run_disagg_test.sh`
   - `jenkins_test/scripts/calculate_hardware_nodes.py`

2. **TensorRT-LLM Jenkins 脚本**
   - `jenkins/scripts/perf/disaggregated/submit.py` - **核心提交脚本**
   - `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh` - **Slurm 启动模板**
   - `jenkins/scripts/slurm_run.sh` - **Slurm 运行脚本**
   - `jenkins/scripts/slurm_install.sh` - **Slurm 安装脚本**

3. **TensorRT-LLM 测试文件**
   - `tests/integration/defs/perf/test_perf_sanity.py` - **pytest 测试主文件（被 slurm_launch_draft.sh 调用）**
   - `tests/integration/test_lists/` - TestList 目录（用于解析）
   - `tests/integration/defs/perf/disagg/test_configs/` - **Disagg 配置文件目录（必需）**

4. **配置文件位置**
   - `tests/integration/defs/perf/disagg/test_configs/disagg/perf/` - 标准 disagg 配置
   - `tests/integration/defs/perf/disagg/test_configs/wideep/perf/` - Wideep 配置

---

## 依赖关系图

```
Perf_Test.groovy (Jenkins Pipeline)
    ↓
run_perf_tests.sh (统一入口)
    ↓
├─→ run_single_agg_test.sh
│       ↓
│       ├─→ load_cluster_config.sh
│       ├─→ remote.sh
│       ├─→ test_perf_sanity.py (pytest)
│       └─→ config YAML (single_agg/)
│
├─→ run_multi_agg_test.sh
│       ↓
│       ├─→ load_cluster_config.sh
│       ├─→ remote.sh
│       ├─→ test_perf_sanity.py (pytest)
│       └─→ config YAML (multi_agg/)
│
└─→ run_disagg_test.sh
        ↓
        ├─→ calculate_hardware_nodes.py
        ├─→ load_cluster_config.sh
        ├─→ remote.sh
        └─→ submit.py
                ↓
                ├─→ 读取 config YAML (test_configs/)
                ├─→ 读取 slurm_launch_draft.sh (模板)
                ├─→ 生成 launch.sh (最终脚本)
                └─→ 在 launch.sh 中引用:
                        ├─→ slurm_run.sh (运行 worker/server)
                        ├─→ slurm_install.sh (安装依赖)
                        └─→ test_perf_sanity.py (pytest 测试)
```

---

## Python 依赖

所有脚本都需要以下 Python 模块（通常在标准库中）：
- `yaml` (PyYAML)
- `json`
- `sys`
- `os`
- `argparse`

---

## 环境变量依赖

### 集群配置（从 clusters.conf 加载）
- `CLUSTER_ACCOUNT` - Slurm 账号
- `CLUSTER_PARTITION` - Slurm 分区
- `CLUSTER_LLM_DATA` - LLM 数据路径
- `DOCKER_IMAGE` - Docker 镜像
- `MPI_TYPE` - MPI 类型（pmix 或 openmpi）
- `CLUSTER_HOST` - 集群主机（SSH 远程执行时）
- `CLUSTER_USER` - 集群用户（SSH 远程执行时）
- `CLUSTER_TYPE` - 集群类型（local 或 remote）

### Jenkins 提供
- `WORKSPACE` - Jenkins 工作目录
- `BUILD_NUMBER` - 构建编号
- `TRTLLM_DIR` - TensorRT-LLM 代码目录

---

## 验证清单

使用以下命令验证所有依赖是否存在：

```bash
# 验证 single-agg 依赖
./scripts/run_single_agg_test.sh --help

# 验证 multi-agg 依赖
./scripts/run_multi_agg_test.sh --help

# 验证 disagg 依赖
./scripts/run_disagg_test.sh --help

# 检查 TensorRT-LLM 依赖
ls -l /path/to/TensorRT-LLM/jenkins/scripts/perf/disaggregated/
ls -l /path/to/TensorRT-LLM/jenkins/scripts/slurm_*.sh
ls -l /path/to/TensorRT-LLM/tests/integration/defs/perf/test_perf_sanity.py
```

---

## 注意事项

1. **TensorRT-LLM 仓库必须完整**：所有测试都依赖 TensorRT-LLM 仓库中的文件，确保正确 clone 完整仓库。

2. **所有测试模式都使用同一个 pytest 文件**：
   - `tests/integration/defs/perf/test_perf_sanity.py`
   - Single-agg, Multi-agg, Disagg 都用这个文件
   - 只是传递的参数和配置文件不同

3. **Disagg 模式依赖最复杂**：
   - 需要额外的 Jenkins 脚本目录
   - 需要 `test_configs/` 配置目录
   - 如果缺少会导致测试失败

4. **配置文件位置**：
   - **Single-agg/Multi-agg**: 支持多个位置查找（`jenkins_test/configs/`, `tests/scripts/perf-sanity/`, `tests/integration/defs/perf/agg/`）
   - **Disagg**: 只支持固定位置（`tests/integration/defs/perf/disagg/test_configs/`）

5. **Python 环境**：确保 Python 3 和 PyYAML 已安装：
   ```bash
   python3 -c "import yaml" || pip3 install pyyaml
   ```
