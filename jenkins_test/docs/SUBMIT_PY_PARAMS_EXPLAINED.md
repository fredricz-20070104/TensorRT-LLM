# submit.py 参数详解与 L0 对齐方案

> 基于 L0_Test.groovy 的 disagg 模式，完整解析 submit.py 的每个参数及其用途

---

## 🎯 L0_Test.groovy 的 Disagg 调用方式

### 完整调用（第 1208-1219 行）

```groovy
python3 ${scriptSubmitLocalPath} \
    --run-ci \
    --llm-src ${llmSrcLocal} \
    --test-list ${testListPathLocal} \
    --draft-launch-sh ${scriptLaunchDraftPathLocal} \
    --launch-sh ${scriptLaunchPathLocal} \
    --run-sh ${scriptRunPathNode} \
    --install-sh ${scriptInstallPathNode} \
    --script-prefix ${scriptLaunchPrefixPathLocal} \
    --srun-args ${scriptLaunchSrunArgsPathLocal}
```

---

## 📋 每个参数的详细解释

### 1. `--run-ci` (必需标志)

**类型：** Flag（布尔值）
**作用：** 告诉 `submit.py` 使用 CI 模式

**代码位置：** submit.py 第 168-172 行

```python
parser.add_argument(
    "--run-ci",
    action="store_true",
    default=False,
    help="Run in CI mode (true) or local mode (false)",
)
```

**说明：**
- CI 模式：从 test-list 文件中提取配置名
- Local 模式：直接使用 `--config-yaml` 参数

**L0 使用：** 总是设置此标志（使用 CI 模式）

---

### 2. `--llm-src` (必需，CI 模式)

**类型：** 字符串
**作用：** TensorRT-LLM 源码的路径

**代码位置：** submit.py 第 184 行

```python
parser.add_argument("--llm-src", default="", help="Path to LLM source code")
```

**在 submit.py 中的使用：** 第 199 行

```python
config_yaml = get_config_yaml(args.test_list, args.llm_src)
# 构建配置文件路径：
# {llm_src}/tests/integration/defs/perf/disagg/test_configs/disagg/perf/{config_name}.yaml
```

**L0 的值：** `${llmSrcLocal}` = `/path/to/workspace/TensorRT-LLM/src`

**Jenkins 应该传什么：** `$TRTLLM_DIR` (TensorRT-LLM 的根目录)

---

### 3. `--test-list` (必需，CI 模式)

**类型：** 字符串（文件路径）
**作用：** Test list 文件，包含 pytest 命令

**代码位置：** submit.py 第 185 行

```python
parser.add_argument("--test-list", default="", help="Path to test list file")
```

**文件内容格式：**

```
perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX]
```

**在 submit.py 中的使用：** 第 126-161 行

```python
def get_config_yaml(test_list_path, llm_src):
    # 1. 读取 test list 文件的第一行
    with open(test_list_path, "r") as f:
        first_line = f.readline().strip()
    
    # 2. 从 test case name 中提取配置文件名
    # 例如: test_e2e[disagg_upload-deepseek-r1-fp4_1k1k...]
    # 提取: deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
    bracket_content = first_line.split("[")[-1].split("]")[0]
    parts = bracket_content.split("-")
    config_base_name = "-".join(parts[1:])  # 跳过 "disagg_upload" 或 "disagg"
    
    # 3. 构建配置文件完整路径
    config_yaml_path = os.path.join(
        llm_src,
        "tests/integration/defs/perf/disagg/test_configs/disagg/perf",
        f"{config_base_name}.yaml"
    )
    
    return config_yaml_path
```

**关键：** test-list 文件的第一行必须包含完整的 pytest 参数化名称！

**L0 的值：** `${testListPathNode}` = `/home/svc_tensorrt/bloom/scripts/{job_uid}/{test_list_name}.txt`

**Jenkins 应该怎么做：**

```bash
# 创建临时 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
echo "perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}]" > "$TEST_LIST_FILE"
```

---

### 4. `--draft-launch-sh` (必需)

**类型：** 字符串（文件路径）
**作用：** 模板脚本，包含启动逻辑

**代码位置：** submit.py 第 174 行

```python
parser.add_argument("--draft-launch-sh", required=True, help="Path to draft-launch.sh script")
```

**文件位置：** `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`

**文件内容：** （第 1-77 行，就是你之前看到的那个文件）

```bash
cleanup_on_failure() { ... }
mkdir -p $jobWorkspace
chmod +x $runScript
chmod +x $installScript

# Run installation on all nodes...
srun "${srunArgs[@]}" $installScript

# Start gen servers...
for i in $(seq 0 $((numGenServers - 1))); do
    export DISAGG_SERVING_TYPE="GEN_$i"
    export pytestCommand="$pytestCommandWorker"
    srun "${srunArgs[@]}" ... $runScript &
done

# Start ctx servers...
# Start disagg server...
# Start benchmark...
```

**在 submit.py 中的使用：** 第 278-282 行

```python
with open(args.draft_launch_sh, "r") as f:
    draft_launch_content = f.read()
draft_launch_lines = draft_launch_content.split("\n")
remove_whitespace_lines(draft_launch_lines)
draft_launch_content = "\n".join(draft_launch_lines)
```

**L0 的值：** `${llmSrcLocal}/jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`

**Jenkins 应该传什么：** `$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`

---

### 5. `--launch-sh` (必需)

**类型：** 字符串（文件路径）
**作用：** 输出脚本路径，submit.py 会生成这个文件

**代码位置：** submit.py 第 175 行

```python
parser.add_argument("--launch-sh", required=True, help="Path to output launch.sh script")
```

**在 submit.py 中的使用：** 第 284-285 行

```python
with open(args.launch_sh, "w") as f:
    f.write(f"{script_prefix}\n{srun_args}\n{draft_launch_content}")
```

**生成的文件结构：**

```bash
#!/bin/bash

# ============ Part 1: script_prefix ============
# 环境变量导出
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]"
export pytestCommandWorker="unset UCX_TLS && TLLM_LOG_LEVEL=INFO ... $pytestCommand"
export pytestCommandDisaggServer="TRTLLM_SERVER_DISABLE_GC=1 $pytestCommandNoLLMAPILaunch"
export pytestCommandBenchmark="... $pytestCommandNoLLMAPILaunch"
export runScript=/path/to/slurm_run.sh
export installScript=/path/to/slurm_install.sh
export numCtxServers=1
export numGenServers=1
export gpusPerNode=4
export totalNodes=2
export totalGpus=8

# ============ Part 2: srun_args ============
srunArgs=(
  "--container-name=multi_node_test-${SLURM_JOB_ID}"
  "--container-image=/path/to/image.sqsh"
  "--container-workdir=/job/workspace"
  "--container-mounts=/data:/data"
  "--mpi=pmix"
  "--container-env=DISAGG_SERVING_TYPE"
  "--container-env=pytestCommand"
)

# ============ Part 3: draft_launch_content ============
# slurm_launch_draft.sh 的内容
cleanup_on_failure() { ... }
mkdir -p $jobWorkspace
...
# 启动所有组件的逻辑
```

**L0 的值：** 临时文件路径（每次生成新的）

**Jenkins 应该传什么：** `$WORKSPACE/slurm_launch_generated.sh`

---

### 6. `--run-sh` (必需)

**类型：** 字符串（文件路径）
**作用：** slurm_run.sh 脚本的路径（在集群节点上）

**代码位置：** submit.py 第 176 行

```python
parser.add_argument("--run-sh", required=True, help="Path to slurm_run.sh script")
```

**在 submit.py 中的使用：** 第 251 行

```python
script_prefix_lines.extend([
    f"export runScript={args.run_sh}",  # ← 这里
    ...
])
```

**slurm_run.sh 的作用：**

```bash
#!/bin/bash
# jenkins/scripts/slurm_run.sh

cd $resourcePathNode
llmSrcNode=$resourcePathNode/TensorRT-LLM/src

# ... 安装和环境设置 ...

cd $llmSrcNode/tests/integration/defs

echo "Full Command: $pytestCommand"
eval $pytestCommand  # ← 执行 pytest
```

**L0 的值：** `${scriptRunPathNode}` = `/home/svc_tensorrt/bloom/scripts/{job_uid}/{job_uid}-slurm_run.sh`

**Jenkins 应该传什么：** 在集群上的 slurm_run.sh 路径（需要先同步过去）

---

### 7. `--install-sh` (必需)

**类型：** 字符串（文件路径）
**作用：** slurm_install.sh 脚本的路径（在集群节点上）

**代码位置：** submit.py 第 177 行

```python
parser.add_argument("--install-sh", required=True, help="Path to slurm_install.sh script")
```

**在 submit.py 中的使用：** 第 205, 252 行

```python
install_script = args.install_sh
script_prefix_lines.extend([
    ...
    f"export installScript={install_script}",  # ← 这里
    ...
])
```

**slurm_install.sh 的作用：**

```bash
#!/bin/bash
# jenkins/scripts/slurm_install.sh

# 解压 TensorRT-LLM 源码
# 安装 Python wheel
# 设置环境
```

**L0 的值：** `${scriptInstallPathNode}` = `/home/svc_tensorrt/bloom/scripts/{job_uid}/{job_uid}-slurm_install.sh`

**Jenkins 应该传什么：** 在集群上的 slurm_install.sh 路径（需要先同步过去）

---

### 8. `--script-prefix` (必需，CI 模式)

**类型：** 字符串（文件路径）
**作用：** 包含环境变量和 pytest 命令的脚本

**代码位置：** submit.py 第 186-189 行

```python
parser.add_argument(
    "--script-prefix",
    default="",
    help="Launch script prefix file path (optional, CI mode only)",
)
```

**在 submit.py 中的使用：** 第 220-222 行

```python
with open(args.script_prefix, "r") as f:
    script_prefix_content = f.read()
script_prefix_lines = script_prefix_content.split("\n")
```

**文件内容示例：** （L0_Test.groovy 第 1162-1192 行生成）

```bash
#!/bin/bash
#SBATCH --output=/path/to/job-output.log
#SBATCH --nodes=2
#SBATCH --ntasks=8
#SBATCH --gpus-per-node=4
#SBATCH --partition=batch
#SBATCH --time=04:00:00

set -xEeuo pipefail
trap 'rc=$?; echo "Error ..."; exit $rc' ERR

echo "Starting Slurm job $SLURM_JOB_ID on $SLURM_NODELIST"
export jobWorkspace=/home/svc_tensorrt/bloom/scripts/{job_uid}
export tarName=tensorrt_llm-*.tar.gz
export llmTarfile=https://urm.nvidia.com/artifactory/.../tensorrt_llm-*.tar.gz
export llmSrcNode=/tmp/TensorRT-LLM/src
export stageName="GB200-12_GPUs-3_Nodes-PyTorch-PerfSanity-Disagg-Post-Merge-1"
export perfMode=true
export resourcePathNode=/tmp
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] -vv --junit-xml=..."
export coverageConfigFile=/path/to/coverage_config.json
export NVIDIA_IMEX_CHANNELS=${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-...}
export OPEN_SEARCH_DB_BASE_URL="..."
export BUILD_ID="123"
export BUILD_URL="..."
export JOB_NAME="..."

# Enroot 容器导入逻辑（如果使用 ENROOT）
importContainerWithRetries() { ... }
importContainerWithRetries "urm.nvidia.com#..." "/path/to/container.sqsh"
```

**关键内容：**
1. SBATCH 指令（节点数、GPU 数、分区等）
2. 环境变量导出
3. pytestCommand 定义
4. 容器镜像导入（如果使用 ENROOT）

**L0 如何生成：**

```groovy
// L0_Test.groovy 第 1199 行
def scriptLaunchPrefixPathLocal = Utils.createTempLocation(pipeline, "./slurm_launch_prefix.sh")
// 第 1204 行
pipeline.writeFile(file: scriptLaunchPrefixPathLocal, text: scriptLaunchPrefix)
```

**Jenkins 应该怎么做：**

```bash
# 生成 script prefix 文件
SCRIPT_PREFIX_FILE="$WORKSPACE/slurm_launch_prefix.sh"
cat > "$SCRIPT_PREFIX_FILE" << 'EOF'
#!/bin/bash
#SBATCH --output=$WORKSPACE/slurm_%j.log
#SBATCH --nodes=$TOTAL_NODES
#SBATCH --ntasks=$TOTAL_GPUS
#SBATCH --gpus-per-node=$GPUS_PER_NODE
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT
#SBATCH --time=04:00:00

set -xEeuo pipefail
export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test"
export perfMode=true
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
EOF
```

---

### 9. `--srun-args` (必需，CI 模式)

**类型：** 字符串（文件路径）
**作用：** 包含 srun 命令行参数的文件

**代码位置：** submit.py 第 191-194 行

```python
parser.add_argument(
    "--srun-args",
    default="",
    help="Path to file containing srun args (optional, CI mode only)",
)
```

**在 submit.py 中的使用：** 第 223-226 行

```python
with open(args.srun_args, "r") as f:
    srun_args_content = f.read()

srun_args_lines = srun_args_content.split()  # ← 按空格分割
```

**文件内容示例：** （L0_Test.groovy 第 1137-1146 行生成）

```
--container-name=multi_node_test-${SLURM_JOB_ID}
--container-image=/path/to/container.sqsh
--container-workdir=/home/svc_tensorrt/bloom/scripts/{job_uid}
--container-mounts=/lustre/fsw:/lustre/fsw,/home:/home
--container-env=NVIDIA_IMEX_CHANNELS
--container-env=OPEN_SEARCH_DB_BASE_URL
--container-env=BUILD_ID
--container-env=BUILD_URL
--mpi=pmix
```

**submit.py 会添加额外参数：** 第 269-274 行

```python
srun_args_lines.extend([
    "--container-env=DISAGG_SERVING_TYPE",  # ← disagg 特有
    "--container-env=pytestCommand",        # ← disagg 特有
])
```

**L0 如何生成：**

```groovy
// L0_Test.groovy 第 1200 行
def scriptLaunchSrunArgsPathLocal = Utils.createTempLocation(pipeline, "./slurm_srun_args.txt")
// 第 1205 行
pipeline.writeFile(file: scriptLaunchSrunArgsPathLocal, text: srunArgs.join(" "))
```

**Jenkins 应该怎么做：**

```bash
# 生成 srun args 文件
SRUN_ARGS_FILE="$WORKSPACE/slurm_srun_args.txt"
cat > "$SRUN_ARGS_FILE" << EOF
--container-name=disagg_test_\${SLURM_JOB_ID}
--container-image=${DOCKER_IMAGE}
--container-workdir=${WORKSPACE}/disagg_workspace
--container-mounts=${CLUSTER_LLM_DATA}:/data
--mpi=pmix
EOF
```

---

## 🔄 submit.py 的工作流程

### 输入处理（第 197-215 行）

```python
args = parser.parse_args()

# 1. 从 test-list 提取配置文件路径
config_yaml = get_config_yaml(args.test_list, args.llm_src)

# 2. 读取配置文件
with open(config_yaml, "r") as f:
    config = yaml.safe_load(f)

# 3. 解析配置
env_config = get_env_config(config)           # environment 部分
benchmark_config = get_benchmark_config(config)  # benchmark 部分
hardware_config = get_hardware_config(config, benchmark_mode)  # hardware + worker_config
```

### 读取输入文件（第 217-226 行）

```python
script_prefix_lines = []
srun_args_lines = []

# 读取 script prefix 文件
with open(args.script_prefix, "r") as f:
    script_prefix_content = f.read()
script_prefix_lines = script_prefix_content.split("\n")

# 读取 srun args 文件
with open(args.srun_args, "r") as f:
    srun_args_content = f.read()
srun_args_lines = srun_args_content.split()
```

### 处理 pytest 命令（第 228-229 行）

```python
# 从 script_prefix_lines 中提取 pytestCommand
# 生成 pytestCommandNoLLMAPILaunch（去掉 trtllm-llmapi-launch）
pytest_command_no_llmapi_launch = get_pytest_command_no_llmapilaunch(script_prefix_lines)
```

### 添加环境变量（第 231-263 行）

```python
# 构建 worker 环境变量
worker_env_vars = env_config["worker_env_var"]
server_env_vars = env_config["server_env_var"]

# 如果是 gen_only 模式，添加额外环境变量
if "gen_only" in benchmark_config["mode"]:
    worker_env_vars = f"TRTLLM_DISAGG_BENCHMARK_GEN_ONLY=1 ... {worker_env_vars}"
    server_env_vars = f"TRTLLM_DISAGG_BENCHMARK_GEN_ONLY=1 {server_env_vars}"

# 添加到 script_prefix_lines
script_prefix_lines.extend([
    pytest_command_no_llmapi_launch,
    f'export pytestCommandWorker="unset UCX_TLS && {worker_env_vars} $pytestCommand"',
    f'export pytestCommandDisaggServer="{server_env_var} $pytestCommandNoLLMAPILaunch"',
    f'export pytestCommandBenchmark="{env_config["benchmark_env_var"]} $pytestCommandNoLLMAPILaunch"',
    f"export runScript={args.run_sh}",
    f"export installScript={install_script}",
    f"export numCtxServers={hardware_config['num_ctx_servers']}",
    f"export numGenServers={hardware_config['num_gen_servers']}",
    f"export gpusPerNode={hardware_config['gpus_per_node']}",
    f"export gpusPerCtxServer={hardware_config['gpus_per_ctx_server']}",
    f"export gpusPerGenServer={hardware_config['gpus_per_gen_server']}",
    f"export nodesPerCtxServer={hardware_config['nodes_per_ctx_server']}",
    f"export nodesPerGenServer={hardware_config['nodes_per_gen_server']}",
    f"export totalNodes={hardware_config['total_nodes']}",
    f"export totalGpus={hardware_config['total_gpus']}",
])
```

### 添加 srun 参数（第 268-276 行）

```python
srun_args_lines.extend([
    "--container-env=DISAGG_SERVING_TYPE",
    "--container-env=pytestCommand",
])

# 格式化为 bash 数组
srun_args_lines = ["srunArgs=("] + [f'  "{line}"' for line in srun_args_lines] + [")"]
srun_args = "\n".join(srun_args_lines)
```

### 读取模板并生成最终脚本（第 278-288 行）

```python
# 读取 draft-launch.sh
with open(args.draft_launch_sh, "r") as f:
    draft_launch_content = f.read()

# 组合：script_prefix + srun_args + draft_launch_content
with open(args.launch_sh, "w") as f:
    f.write(f"{script_prefix}\n{srun_args}\n{draft_launch_content}")

print(f"Launch script generated at: {args.launch_sh}")
print(f"Launch script:\n{script_prefix}\n{srun_args}\n{draft_launch_content}")
```

---

## 📝 Jenkins run_disagg_test.sh 修正方案

### 当前问题

```bash
# jenkins_test/scripts/run_disagg_test.sh 第 287-293 行
python3 $SUBMIT_PY \
    --run-ci \
    --llm-src $TRTLLM_DIR \
    --config $CONFIG_FULL_PATH    # ❌ 错误！
```

**缺少的参数：**
- `--test-list` ❌
- `--draft-launch-sh` ❌
- `--launch-sh` ❌
- `--run-sh` ❌
- `--install-sh` ❌
- `--script-prefix` ❌
- `--srun-args` ❌

### 完整修正版本

```bash
#!/bin/bash
# jenkins_test/scripts/run_disagg_test.sh

# ... 前面的代码保持不变 ...

# ============================================
# 步骤 4: 准备 submit.py 所需的输入文件
# ============================================
echo ""
echo "[步骤 4] 准备 submit.py 输入文件..."

# 4.1 创建 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}]
EOF
echo "✓ 生成 test list: $TEST_LIST_FILE"

# 4.2 创建 script prefix 文件（包含 SBATCH 指令和环境变量）
SCRIPT_PREFIX_FILE="$WORKSPACE/slurm_launch_prefix.sh"
cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX
#!/bin/bash
#SBATCH --output=$WORKSPACE/slurm_%j.log
#SBATCH --nodes=$TOTAL_NODES
#SBATCH --ntasks=$TOTAL_GPUS
#SBATCH --ntasks-per-node=$GPUS_PER_NODE
#SBATCH --gpus-per-node=$GPUS_PER_NODE
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT
#SBATCH --job-name=disagg_perf_test
#SBATCH --time=04:00:00

set -xEeuo pipefail
trap 'rc=\$?; echo "Error in file \${BASH_SOURCE[0]} on line \$LINENO: \$BASH_COMMAND (exit \$rc)"; exit \$rc' ERR

echo "Starting Slurm job \$SLURM_JOB_ID on \$SLURM_NODELIST"
export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test"
export perfMode=true
export resourcePathNode=$TRTLLM_DIR
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
export coverageConfigFile=$WORKSPACE/coverage_config.json
export NVIDIA_IMEX_CHANNELS=\${NVIDIA_IMEX_CHANNELS:-0}
export NVIDIA_VISIBLE_DEVICES=\${NVIDIA_VISIBLE_DEVICES:-\$(seq -s, 0 \$((\$(nvidia-smi --query-gpu=count -i 0 --format=csv,noheader)-1)))}
EOFPREFIX
echo "✓ 生成 script prefix: $SCRIPT_PREFIX_FILE"

# 4.3 创建 srun args 文件
SRUN_ARGS_FILE="$WORKSPACE/slurm_srun_args.txt"
cat > "$SRUN_ARGS_FILE" << EOFSRUN
--container-name=disagg_test_\${SLURM_JOB_ID}
--container-image=${DOCKER_IMAGE}
--container-workdir=$WORKSPACE/disagg_workspace
--container-mounts=${CLUSTER_LLM_DATA}:/data,${TRTLLM_DIR}:${TRTLLM_DIR}
--mpi=pmix
EOFSRUN
echo "✓ 生成 srun args: $SRUN_ARGS_FILE"

# 4.4 准备其他文件路径
DRAFT_LAUNCH_SH="$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh"
LAUNCH_SH="$WORKSPACE/slurm_launch_generated.sh"
RUN_SH="$TRTLLM_DIR/jenkins/scripts/slurm_run.sh"
INSTALL_SH="$TRTLLM_DIR/jenkins/scripts/slurm_install.sh"

# 验证文件存在
for file in "$DRAFT_LAUNCH_SH" "$RUN_SH" "$INSTALL_SH"; do
    if [[ ! -f "$file" ]]; then
        echo "错误：找不到文件: $file"
        exit 1
    fi
done

echo "✓ 所有输入文件准备完成"

# ============================================
# 步骤 5: 调用 submit.py 生成 launch 脚本
# ============================================
echo ""
echo "[步骤 5] 调用 submit.py 生成 launch 脚本..."

SUBMIT_PY="$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/submit.py"

if [[ ! -f "$SUBMIT_PY" ]]; then
    echo "错误：找不到 submit.py: $SUBMIT_PY"
    exit 1
fi

python3 "$SUBMIT_PY" \
    --run-ci \
    --llm-src "$TRTLLM_DIR" \
    --test-list "$TEST_LIST_FILE" \
    --draft-launch-sh "$DRAFT_LAUNCH_SH" \
    --launch-sh "$LAUNCH_SH" \
    --run-sh "$RUN_SH" \
    --install-sh "$INSTALL_SH" \
    --script-prefix "$SCRIPT_PREFIX_FILE" \
    --srun-args "$SRUN_ARGS_FILE"

if [[ ! -f "$LAUNCH_SH" ]]; then
    echo "错误：submit.py 未生成 launch 脚本: $LAUNCH_SH"
    exit 1
fi

echo "✓ Launch 脚本已生成: $LAUNCH_SH"
echo ""
echo "生成的脚本内容："
echo "----------------------------------------"
cat "$LAUNCH_SH"
echo "----------------------------------------"

# ============================================
# 步骤 6: 提交作业
# ============================================
if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo "[试运行模式] 跳过实际提交"
    echo "要手动提交，请运行:"
    echo "  sbatch $LAUNCH_SH"
    exit 0
fi

echo ""
echo "[步骤 6] 提交 Slurm 作业..."

SUBMIT_OUTPUT=$(sbatch "$LAUNCH_SH")
echo "$SUBMIT_OUTPUT"

JOB_ID=$(echo "$SUBMIT_OUTPUT" | awk '{print $NF}')

if [[ -z "$JOB_ID" ]]; then
    echo "错误：无法获取作业 ID"
    exit 1
fi

echo "Slurm Job ID: $JOB_ID"
LOG_FILE="$WORKSPACE/slurm_${JOB_ID}.log"
echo "日志文件: $LOG_FILE"

# ... 后续等待作业完成的逻辑保持不变 ...
```

---

## 🎯 关键要点总结

### 1. submit.py 不执行测试

**它只生成脚本！** 生成的 `launch.sh` 需要通过 `sbatch` 提交。

### 2. 所有参数都是必需的

**没有可选参数！** 除了 `--config-yaml` 和 `--stage-name`（local 模式用），其他全部必需。

### 3. 参数的职责划分

| 参数 | 职责 | 来源 |
|------|------|------|
| `--test-list` | 提供 pytest 命令和配置名 | Jenkins 生成 |
| `--script-prefix` | 提供 SBATCH 指令和环境变量 | Jenkins 生成 |
| `--srun-args` | 提供容器和 MPI 参数 | Jenkins 生成 |
| `--draft-launch-sh` | 提供启动逻辑模板 | TensorRT-LLM 仓库 |
| `--run-sh` / `--install-sh` | 提供执行脚本 | TensorRT-LLM 仓库 |
| `--llm-src` | 查找配置文件 | Jenkins 传递 |
| `--launch-sh` | 输出文件路径 | Jenkins 指定 |

### 4. YAML 配置文件的作用

**submit.py 从 YAML 读取：**
- `hardware` → 计算节点数
- `worker_config` → 计算每个 server 的 GPU 数
- `environment.worker_env_var` → 添加到 pytestCommandWorker
- `environment.server_env_var` → 添加到 pytestCommandDisaggServer
- `benchmark.mode` → 判断是否 gen_only 模式

**YAML 占位符不需要：**
- `container_image` ❌ (从 srun-args 提供)
- `container_mount` ❌ (从 srun-args 提供)
- `model_path` ❌ (test_perf_sanity.py 硬编码)
- `work_dir` ❌ (从 script-prefix 的 jobWorkspace 提供)

### 5. 与 L0 保持一致

**L0 的方式：**
1. ✅ 使用 `test_perf_sanity.py`
2. ✅ 通过 `submit.py` 生成 launch 脚本
3. ✅ 所有环境变量在 script-prefix 中定义
4. ✅ 所有 srun 参数在 srun-args 文件中定义
5. ✅ 使用 sbatch 提交生成的脚本

**你的 Jenkins 也应该：**
1. ✅ 继续使用 `test_perf_sanity.py`
2. ✅ 生成所有必需的输入文件
3. ✅ 调用 `submit.py` 生成 launch 脚本
4. ✅ 通过 sbatch 提交生成的脚本

---

## ✅ 检查清单

在运行修正的脚本前，确认：

- [ ] `TRTLLM_DIR` 指向正确的 TensorRT-LLM 根目录
- [ ] `CLUSTER_PARTITION` 和 `CLUSTER_ACCOUNT` 已设置
- [ ] `DOCKER_IMAGE` 已设置
- [ ] `CLUSTER_LLM_DATA` 已设置（模型和数据路径）
- [ ] `CONFIG_NAME` 正确（配置文件名，不带 `.yaml` 后缀）
- [ ] `WORKSPACE` 目录存在且可写
- [ ] 所有 TensorRT-LLM 仓库中的脚本文件存在：
  - `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`
  - `jenkins/scripts/slurm_run.sh`
  - `jenkins/scripts/slurm_install.sh`
  - `jenkins/scripts/perf/disaggregated/submit.py`

---

**现在参数清楚了吗？需要我帮你修改 `run_disagg_test.sh` 文件吗？** 🚀
