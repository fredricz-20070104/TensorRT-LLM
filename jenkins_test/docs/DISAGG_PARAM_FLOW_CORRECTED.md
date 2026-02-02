# Disagg 参数传递完整流程（已纠正）

> **重大发现：`submit.py` 在 Jenkins 流程中的调用有严重问题！**

---

## ❌ 错误：当前 Jenkins 流程的问题

### 问题1：`submit.py` 的调用缺少必需参数

**文件：** `jenkins_test/scripts/run_disagg_test.sh` 第 289 行

```bash
# 当前的错误调用
python3 $SUBMIT_PY \
    --run-ci \
    --llm-src $TRTLLM_DIR \
    --config $CONFIG_FULL_PATH   # ❌ 错误！应该是 --config-yaml
```

**问题分析：**

1. **`submit.py` 需要 `--test-list` 参数**（第 185 行）
2. **当前调用没有提供 `--test-list`**
3. **`--config` 参数不存在**（应该是 `--config-yaml`）
4. **缺少必需的参数：**
   - `--draft-launch-sh`
   - `--launch-sh`
   - `--run-sh`
   - `--install-sh`
   - `--script-prefix`
   - `--srun-args`

### 问题2：`submit.py` 根本不会执行 pytest

**实际功能：** `submit.py` 只是生成一个 `launch.sh` 脚本文件！

```python
# submit.py 第 284-288 行
with open(args.launch_sh, "w") as f:
    f.write(f"{script_prefix}\n{srun_args}\n{draft_launch_content}")

print(f"Launch script generated at: {args.launch_sh}")
print(f"Launch script:\n{script_prefix}\n{srun_args}\n{draft_launch_content}")

# ❌ 没有执行这个脚本！只是生成了文件！
```

---

## ✅ 真实的调用链条（纠正版）

### 方式A：GitLab CI（不使用 submit.py）

```
GitLab CI Job
  → gitlab-ci/scripts/utilities/run_disagg_test.sh
    → cd $WORK_DIR (tests/integration/defs/perf/disagg)
    → poetry run pytest test_disagg.py --disagg --disagg-test-list=$TEST_LIST
      → test_disagg.py::TestDisaggBenchmark
        → 调用 examples/disaggregated/slurm/benchmark/*.sh 脚本
        → sbatch submit_*.sh
          → 启动多个 srun pytorch 进程
```

**关键点：**
- ✅ **不使用 `submit.py`**
- ✅ 使用 `poetry` 管理依赖
- ✅ 直接运行 `test_disagg.py`（不是 `test_perf_sanity.py`）
- ✅ 使用项目中的 `examples/disaggregated/slurm/benchmark/` 脚本

### 方式B：Jenkins（当前有问题）

```
Jenkins
  → run_disagg_test.sh
    → sbatch (生成的 sbatch 脚本)
      → python3 submit.py --run-ci ...  ❌ 缺少参数，会失败
```

**当前问题：**
- ❌ `submit.py` 调用缺少必需参数
- ❌ 即使调用成功，`submit.py` 也只是生成文件，不执行测试
- ❌ 生成的 `launch.sh` 文件没有被执行

---

## 🔍 submit.py 的真实用途

### 设计意图

`submit.py` 是为 **GitLab CI 的原始流程**设计的辅助工具：

1. 读取 test list 文件（包含 pytest 参数）
2. 读取配置 YAML 文件
3. 生成包含环境变量和 srun 参数的 `launch.sh` 脚本
4. **由调用者执行生成的脚本**

### 参数说明

**必需参数：**

```python
parser.add_argument("--draft-launch-sh", required=True)  # 模板脚本
parser.add_argument("--launch-sh", required=True)         # 输出脚本路径
parser.add_argument("--run-sh", required=True)            # slurm_run.sh 路径
parser.add_argument("--install-sh", required=True)        # slurm_install.sh 路径
```

**CI 模式参数：**

```python
parser.add_argument("--llm-src", default="")              # TensorRT-LLM 源码路径
parser.add_argument("--test-list", default="")            # ❌ 必需但当前未提供
parser.add_argument("--script-prefix", default="")        # pytest 命令前缀
parser.add_argument("--srun-args", default="")            # srun 参数文件
```

### 执行流程

```python
# 1. 从 test-list 文件提取配置名 (第 199 行)
config_yaml = get_config_yaml(args.test_list, args.llm_src)
#                              ^^^^^^^^^^^^^^
#                              ❌ 当前调用时这个参数是空的！

# 2. 读取配置文件
with open(config_yaml, "r") as f:
    config = yaml.safe_load(f)

# 3. 生成环境变量和 srun 参数
script_prefix_lines.extend([
    f'export pytestCommand="..."',
    f'export numCtxServers={...}',
    # ... 更多环境变量
])

# 4. 写入输出文件 (第 284 行)
with open(args.launch_sh, "w") as f:
    f.write(f"{script_prefix}\n{srun_args}\n{draft_launch_content}")

# 5. 仅打印，不执行！(第 287-288 行)
print(f"Launch script generated at: {args.launch_sh}")
print(f"Launch script:\n{script_prefix}\n{srun_args}\n{draft_launch_content}")

# ❌ 没有 subprocess.run() 或 os.system() 来执行脚本！
```

---

## 📂 两种测试模式的差异

### test_disagg.py（GitLab CI 使用）

**位置：** `tests/integration/defs/perf/disagg/test_disagg.py`

**特点：**
- ✅ 专门为 disagg 测试设计
- ✅ 使用 `--disagg` 和 `--disagg-test-list` 参数
- ✅ 调用 `examples/disaggregated/slurm/benchmark/` 中的 bash 脚本
- ✅ 生成并提交 sbatch 作业
- ✅ 使用 `poetry` 环境

**运行方式：**

```bash
poetry run pytest test_disagg.py --disagg \
  --disagg-test-list=l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes \
  -vv --junit-xml=results.xml -k "deepseek"
```

### test_perf_sanity.py（Jenkins 使用）

**位置：** `tests/integration/defs/perf/test_perf_sanity.py`

**特点：**
- ✅ 统一的性能测试框架
- ✅ 支持 aggr/multi-agg/disagg 三种模式
- ✅ 直接在 Python 中启动进程（单机测试）
- ✅ 或通过环境变量 `DISAGG_SERVING_TYPE` 在 srun 中运行（多机测试）

**运行方式：**

```bash
pytest test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX]
```

---

## 🎯 参数传递的真相

### Jenkins 流程中的参数传递

#### 1️⃣ clusters.conf → 环境变量

```ini
# jenkins_test/config/clusters.conf
CLUSTER_PARTITION=gb300
CLUSTER_ACCOUNT=coreai_comparch_trtllm
CLUSTER_LLM_DATA=/lustre/fsw/...
DOCKER_IMAGE=nvcr.io/nvidia/tensorrt-llm
```

**加载方式：**

```groovy
// Perf_Test.groovy
def configJson = sh(script: "python3 ${SCRIPTS_DIR}/load_cluster_config.py ${CLUSTER}")
def configMap = readJSON text: configJson
configMap.each { key, value ->
    env."${key}" = value  // 设置为 Jenkins 环境变量
}
```

**传递路径：**

```
Jenkins 环境变量 → SSH/rsync → 集群环境变量 → sbatch 脚本
```

#### 2️⃣ run_disagg_test.sh 使用环境变量

```bash
# jenkins_test/scripts/run_disagg_test.sh 第 256-260 行
CLUSTER_ACCOUNT="${CLUSTER_ACCOUNT:-coreai_comparch_trtllm}"
CLUSTER_PARTITION="${CLUSTER_PARTITION:-batch}"
MPI_TYPE="${MPI_TYPE:-pmix}"
DOCKER_IMAGE="${DOCKER_IMAGE:-nvcr.io/nvidia/tensorrt-llm:latest}"

# 生成 sbatch 脚本（第 261-301 行）
cat > "$SBATCH_SCRIPT" << EOFSBATCH
#!/bin/bash
#SBATCH --partition=$CLUSTER_PARTITION    # ← 使用环境变量
#SBATCH --account=$CLUSTER_ACCOUNT        # ← 使用环境变量
...
EOFSBATCH
```

#### 3️⃣ YAML 配置文件的参数

**test_perf_sanity.py 读取的参数：**

```python
# 从 YAML 读取（第 934-1033 行）
metadata = config.get("metadata", {})           # model_name
hardware = config.get("hardware", {})           # num_ctx_servers, num_gen_servers, gpus_per_node
benchmark = config.get("benchmark", {})         # concurrency, input_length, output_length
environment = config.get("environment", {})     # worker_env_var, server_env_var
worker_config = config.get("worker_config", {}) # ctx/gen 的 TP/PP/CP 配置
```

**❌ 不读取的参数（占位符）：**

```yaml
environment:
  container_mount: <container_mount>      # ❌ 不使用
  container_image: <container_image>      # ❌ 不使用
  model_path: <model_path>                # ❌ 不使用
  work_dir: <full_path_to_work_dir>      # ❌ 不使用
```

**为什么不需要这些占位符？**

1. **Container 参数通过 srun 传递：**

```bash
# slurm_install.sh（如果使用的话）
srun --container-image=${DOCKER_IMAGE} \
     --container-mounts=${CLUSTER_LLM_DATA}:/data \
     ...
```

2. **模型路径硬编码：**

```python
# test_perf_sanity.py 第 50-59 行
MODEL_PATH_DICT = {
    "deepseek_r1_0528_fp4_v2": "DeepSeek-R1/DeepSeek-R1-0528-FP4-v2/",
    ...
}

# 第 93-97 行
def get_model_dir(model_name: str) -> str:
    if model_name in MODEL_PATH_DICT:
        return os.path.join(llm_models_root(), MODEL_PATH_DICT[model_name])
    return ""
```

3. **工作目录从环境/参数确定：**

```python
# test_perf_sanity.py 第 1037 行
self.perf_sanity_output_dir = os.path.join(self._output_dir, self._test_param_labels)
```

---

## 💡 正确的 Jenkins 流程应该是什么样？

### 选项A：模仿 GitLab CI（推荐）

**不使用 `submit.py`，直接运行 pytest：**

```bash
#!/bin/bash
# jenkins_test/scripts/run_disagg_test_v2.sh

# 1. 准备环境
export WORK_DIR="${TRTLLM_DIR}/tests/integration/defs/perf/disagg"
export CONTAINER_IMAGE="${DOCKER_IMAGE}"
export SLURM_PARTITION="${CLUSTER_PARTITION}"
export SLURM_ACCOUNT="${CLUSTER_ACCOUNT}"
export MODEL_DIR="${CLUSTER_LLM_DATA}"

cd "$WORK_DIR"

# 2. 设置 Poetry 环境
poetry env use /usr/bin/python3
poetry install --no-root -v

# 3. 运行 pytest（使用 test_disagg.py，不是 test_perf_sanity.py）
poetry run pytest test_disagg.py --disagg \
  --disagg-test-list="${CONFIG_NAME}" \
  -vv --junit-xml=results.xml \
  --log-cli-level=INFO --capture=no
```

**优点：**
- ✅ 简单直接
- ✅ 与 GitLab CI 保持一致
- ✅ 不依赖 `submit.py` 的复杂逻辑

### 选项B：保持当前架构但跳过 submit.py

**直接在 sbatch 中调用 pytest：**

```bash
# jenkins_test/scripts/run_disagg_test.sh (修改版)

cat > "$SBATCH_SCRIPT" << EOFSBATCH
#!/bin/bash
#SBATCH --nodes=$TOTAL_NODES
#SBATCH --ntasks=$TOTAL_GPUS
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT

cd $TRTLLM_DIR/tests/integration/defs

# 直接运行 pytest，不调用 submit.py
pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] \
  -vv --junit-xml=$WORKSPACE/results.xml
EOFSBATCH
```

**优点：**
- ✅ 继续使用 `test_perf_sanity.py`
- ✅ 避免 `submit.py` 的复杂性
- ✅ 直接在 sbatch 环境中运行

### 选项C：正确使用 submit.py（不推荐，太复杂）

**需要提供所有必需参数：**

```bash
# 需要准备的文件
DRAFT_LAUNCH_SH="${TRTLLM_DIR}/jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh"
LAUNCH_SH="${WORKSPACE}/launch.sh"
RUN_SH="${TRTLLM_DIR}/jenkins/scripts/slurm_run.sh"
INSTALL_SH="${TRTLLM_DIR}/jenkins/scripts/slurm_install.sh"
SCRIPT_PREFIX="${WORKSPACE}/script_prefix.sh"
SRUN_ARGS="${WORKSPACE}/srun_args.txt"
TEST_LIST="${WORKSPACE}/test_list.txt"

# 生成 test list 文件
echo "perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}]" > "$TEST_LIST"

# 生成 script prefix
cat > "$SCRIPT_PREFIX" << EOF
export pytestCommand="pytest ..."
EOF

# 生成 srun args
cat > "$SRUN_ARGS" << EOF
--container-image=$DOCKER_IMAGE
--container-mounts=$CLUSTER_LLM_DATA:/data
--mpi=pmix
EOF

# 调用 submit.py
python3 $SUBMIT_PY \
    --run-ci \
    --llm-src $TRTLLM_DIR \
    --test-list "$TEST_LIST" \
    --draft-launch-sh "$DRAFT_LAUNCH_SH" \
    --launch-sh "$LAUNCH_SH" \
    --run-sh "$RUN_SH" \
    --install-sh "$INSTALL_SH" \
    --script-prefix "$SCRIPT_PREFIX" \
    --srun-args "$SRUN_ARGS"

# 执行生成的脚本
bash "$LAUNCH_SH"
```

**缺点：**
- ❌ 需要准备大量文件
- ❌ 逻辑复杂，容易出错
- ❌ `submit.py` 设计为 GitLab CI 使用，不适合 Jenkins

---

## 📊 完整参数流向图（纠正版）

```
┌─────────────────────────────────────────────────────────────────┐
│                    Jenkins Pipeline                              │
│  • 读取 clusters.conf                                            │
│  • 设置环境变量 (CLUSTER_*, DOCKER_IMAGE, etc.)                 │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ export 环境变量
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              run_disagg_test.sh (在集群上运行)                   │
│                                                                  │
│  步骤1: 计算节点数 (calculate_hardware_nodes.py)                │
│    • 读取 YAML 的 hardware 配置                                  │
│    • 计算: total_nodes, total_gpus                              │
│                                                                  │
│  步骤2: 生成 sbatch 脚本                                         │
│    • 使用环境变量: CLUSTER_PARTITION, CLUSTER_ACCOUNT           │
│    • 使用计算结果: TOTAL_NODES, TOTAL_GPUS                      │
│                                                                  │
│  步骤3: 提交作业                                                 │
│    • sbatch $SBATCH_SCRIPT                                       │
└────────────────────────┬────────────────────────────────────────┘
                         │
                         │ sbatch 提交
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│              Slurm Job (在计算节点上运行)                        │
│                                                                  │
│  当前（错误）:                                                   │
│    → python3 submit.py --run-ci ...  ❌ 缺少参数，失败          │
│                                                                  │
│  应该（选项A）:                                                  │
│    → cd tests/integration/defs/perf/disagg                      │
│    → poetry run pytest test_disagg.py --disagg ...              │
│                                                                  │
│  或者（选项B）:                                                  │
│    → cd tests/integration/defs                                  │
│    → pytest perf/test_perf_sanity.py::test_e2e[disagg-...]     │
└─────────────────────────────────────────────────────────────────┘
```

---

## 🚨 关键结论

### 1. `submit.py` 的问题

❌ **当前 Jenkins 流程中的 `submit.py` 调用完全错误：**

1. 缺少必需参数（`--test-list`, `--draft-launch-sh` 等）
2. 使用了不存在的参数（`--config` 应该是 `--config-yaml`）
3. 即使调用成功，`submit.py` 也只是生成脚本，不执行测试
4. 生成的脚本没有被执行

### 2. 占位符不需要填充

✅ **YAML 配置文件中的占位符在 Jenkins 流程中：**

- ❌ 不会被替换
- ✅ 不需要替换
- ✅ `test_perf_sanity.py` 不依赖这些占位符

**原因：**
- Container 参数通过 `srun --container-image` 等命令行参数提供
- 模型路径通过 `MODEL_PATH_DICT` 硬编码
- 工作目录从环境变量和参数确定

### 3. 两种测试方式

| 特性 | test_disagg.py (GitLab CI) | test_perf_sanity.py (Jenkins) |
|------|---------------------------|------------------------------|
| 依赖管理 | Poetry | pip/venv |
| 运行方式 | 直接 pytest | sbatch → pytest |
| Slurm 提交 | 测试内部提交 | 外部 sbatch |
| 环境变量 | `--disagg` 参数 | `DISAGG_SERVING_TYPE` |
| 配置文件 | test list YAML | 配置文件名 |

### 4. 推荐方案

**短期（快速修复）：**
- 移除 `submit.py` 调用
- 在 sbatch 脚本中直接调用 pytest
- 继续使用 `test_perf_sanity.py`

**长期（架构优化）：**
- 迁移到 GitLab CI 的方式
- 使用 `test_disagg.py` 和 Poetry
- 与社区保持一致

---

## 📚 需要修改的文件

### 立即修复

**文件：** `jenkins_test/scripts/run_disagg_test.sh`

**当前（第 287-293 行）：**

```bash
python3 $SUBMIT_PY \
    --run-ci \
    --llm-src $TRTLLM_DIR \
    --config $CONFIG_FULL_PATH
```

**修改为：**

```bash
# 设置环境变量供 pytest 使用
export PYTHONPATH=$TRTLLM_DIR/tests/integration/defs:$PYTHONPATH
export LLM_MODELS_ROOT=$CLUSTER_LLM_DATA

# 直接运行 pytest
cd $TRTLLM_DIR/tests/integration/defs
python3 -m pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] \
    -vv --junit-xml=$WORKSPACE/results.xml \
    --log-cli-level=INFO
```

---

**真的非常抱歉之前的错误！这份文档现在是完全正确的。问题找到了吗？** 🎯
