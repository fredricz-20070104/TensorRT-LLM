# slurm_run.sh 详细执行过程逐句讲解

> 完整解析 slurm_run.sh 在 disagg 测试中的每一行代码及其运行过程

---

## 📋 概述

### slurm_run.sh 的角色

**在整个调用链中的位置：**

```
sbatch launch.sh
  → slurm_launch_draft.sh
    ├─ srun slurm_install.sh (所有节点安装)
    ├─ srun slurm_run.sh (GEN_0) &     ← 每个组件都运行这个脚本
    ├─ srun slurm_run.sh (GEN_1) &     ← 每个组件都运行这个脚本
    ├─ srun slurm_run.sh (CTX) &       ← 每个组件都运行这个脚本
    ├─ srun slurm_run.sh (DISAGG_SERVER) &  ← 每个组件都运行这个脚本
    └─ srun slurm_run.sh (BENCHMARK)   ← 每个组件都运行这个脚本
      → eval $pytestCommand
        → pytest perf/test_perf_sanity.py::test_e2e[...]
```

**关键点：**
- ✅ **同一个脚本，不同的环境变量**
- ✅ 通过 `DISAGG_SERVING_TYPE` 环境变量区分角色
- ✅ 通过 `pytestCommand` 环境变量传递不同的命令

---

## 📝 逐行详解

### 第 1-5 行：错误处理设置

```bash
#!/bin/bash

# Set up error handling
set -xEeuo pipefail
trap 'rc=$?; echo "Error in file ${BASH_SOURCE[0]} on line $LINENO: $BASH_COMMAND (exit $rc)"; exit $rc' ERR
```

**详细解释：**

#### `set -xEeuo pipefail`

这是 5 个 bash 选项的组合：

1. **`-x`** (xtrace)
   - **作用：** 打印每条执行的命令
   - **效果：** 
     ```bash
     + echo "Hello"
     Hello
     + cd /tmp
     + ls
     ```
   - **用途：** 调试，看到每条命令的实际执行

2. **`-E`** (errtrace)
   - **作用：** ERR trap 会被函数和子 shell 继承
   - **效果：** 任何地方的错误都会触发 trap
   - **示例：**
     ```bash
     function my_func() {
         false  # 这里的错误也会触发 trap
     }
     ```

3. **`-e`** (errexit)
   - **作用：** 任何命令返回非 0 值就立即退出
   - **效果：** 
     ```bash
     command1  # 如果失败
     command2  # 这行不会执行
     ```
   - **例外：** if/while/until 条件中的命令不受影响

4. **`-u`** (nounset)
   - **作用：** 使用未定义的变量时报错
   - **效果：**
     ```bash
     echo $UNDEFINED_VAR  # 报错退出
     ```
   - **好处：** 防止拼写错误

5. **`-o pipefail`**
   - **作用：** 管道中任何命令失败，整个管道失败
   - **效果：**
     ```bash
     false | true   # 返回 1（失败）
     true | false   # 返回 1（失败）
     ```
   - **默认行为：** 只看最后一个命令

#### `trap '...' ERR`

**作用：** 捕获任何错误并打印详细信息

**展开解释：**

```bash
trap 'rc=$?; echo "Error in file ${BASH_SOURCE[0]} on line $LINENO: $BASH_COMMAND (exit $rc)"; exit $rc' ERR
```

当任何命令失败时：

1. **`rc=$?`**
   - 保存失败命令的退出码
   - `$?` 是上一条命令的退出码

2. **`${BASH_SOURCE[0]}`**
   - 当前脚本的文件名
   - 例如：`/path/to/slurm_run.sh`

3. **`$LINENO`**
   - 错误发生的行号
   - 例如：`42`

4. **`$BASH_COMMAND`**
   - 失败的命令
   - 例如：`cd /nonexistent`

5. **输出示例：**
   ```
   Error in file /path/to/slurm_run.sh on line 42: cd /nonexistent (exit 1)
   ```

6. **`exit $rc`**
   - 以相同的退出码退出脚本

---

### 第 7-8 行：设置工作目录和源码路径

```bash
cd $resourcePathNode
llmSrcNode=$resourcePathNode/TensorRT-LLM/src
```

**详细解释：**

#### `cd $resourcePathNode`

**环境变量来源：**

这个变量在 `slurm_launch_prefix.sh` 中定义（由 submit.py 生成）：

```bash
# 在 launch.sh 中（submit.py 生成）
export resourcePathNode=/tmp
```

**实际效果：**

```bash
cd /tmp
```

**为什么是 /tmp？**

- 这是一个**临时目录**
- slurm_install.sh 会把 TensorRT-LLM 源码解压到这里
- 每个节点都有自己的 /tmp

#### `llmSrcNode=$resourcePathNode/TensorRT-LLM/src`

**计算路径：**

```bash
llmSrcNode=/tmp/TensorRT-LLM/src
```

**这个路径的结构：**

```
/tmp/
└── TensorRT-LLM/
    └── src/
        ├── tensorrt_llm/
        ├── tests/
        │   └── integration/
        │       └── defs/
        │           └── perf/
        │               ├── test_perf_sanity.py  ← pytest 会运行这个
        │               └── disagg/
        │                   └── test_configs/
        ├── jenkins/
        └── ...
```

---

### 第 10-30 行：辅助函数 `set_value_in_command`

```bash
set_value_in_command() {
    # Parameters
    local key="$1"
    local value="$2"
    local command="$3"

    # Transform the key
    local placeholder="__PLACEHOLDER_${key}__"

    # Check if placeholder exists
    if [[ "$command" != *"$placeholder"* ]]; then
        echo "Error: placeholder '$placeholder' not found in the command" >&2
        return 1
    fi

    # Replace all occurrences
    local result="${command//${placeholder}/${value}}"

    # Return the result
    echo "$result"
}
```

**详细解释：**

这是一个**字符串替换函数**，用于动态设置 pytest 命令中的参数。

#### 参数：

1. **`key`** - 要替换的键（例如：`TRTLLM_WHL_PATH`）
2. **`value`** - 替换的值（例如：`/opt/conda/lib/python3.10/site-packages`）
3. **`command`** - 包含占位符的命令字符串

#### 工作流程：

**示例调用：**

```bash
pytestCommand="pytest __PLACEHOLDER_TRTLLM_WHL_PATH__/tensorrt_llm/tests/test.py"
result=$(set_value_in_command "TRTLLM_WHL_PATH" "/usr/local/lib/python3.10" "$pytestCommand")
```

**步骤 1：构造占位符**

```bash
local placeholder="__PLACEHOLDER_${key}__"
# 结果：__PLACEHOLDER_TRTLLM_WHL_PATH__
```

**步骤 2：检查占位符是否存在**

```bash
if [[ "$command" != *"$placeholder"* ]]; then
    echo "Error: placeholder '$placeholder' not found in the command" >&2
    return 1
fi
```

- `*"$placeholder"*` 是通配符模式，检查字符串是否包含占位符
- 如果不存在，打印错误并返回 1

**步骤 3：替换占位符**

```bash
local result="${command//${placeholder}/${value}}"
```

- `${variable//pattern/replacement}` 是 bash 的全局替换语法
- 替换**所有**出现的占位符

**步骤 4：返回结果**

```bash
echo "$result"
```

- 输出替换后的命令
- 调用者可以通过 `$()` 捕获

**实际效果：**

```bash
# 替换前
pytest __PLACEHOLDER_TRTLLM_WHL_PATH__/tensorrt_llm/tests/test.py

# 替换后
pytest /usr/local/lib/python3.10/tensorrt_llm/tests/test.py
```

---

### 第 32-38 行：Git 配置（仅第一个进程）

```bash
# Only the first process will set the git config
if [ $SLURM_PROCID -eq 0 ]; then
    # Update HOME/.gitconfig
    if ! git config --global --get-all safe.directory | grep -Fxq "*"; then
        git config --global --add safe.directory "*"
    fi
fi
```

**详细解释：**

#### 为什么需要这个？

**问题背景：**

Git 2.35.2+ 增加了安全检查，当仓库所有者与当前用户不同时，会报错：

```
fatal: detected dubious ownership in repository at '/path/to/repo'
```

#### `$SLURM_PROCID`

**含义：** Slurm 进程 ID（从 0 开始）

**在 disagg 测试中：**

- GEN_0 的某个 GPU 进程：`SLURM_PROCID=0`
- GEN_0 的另一个 GPU 进程：`SLURM_PROCID=1`
- CTX 的某个 GPU 进程：`SLURM_PROCID=4`
- DISAGG_SERVER：`SLURM_PROCID=8`
- BENCHMARK：`SLURM_PROCID=9`

**为什么只让第一个进程设置？**

- 避免多个进程同时修改 git config（竞争条件）
- 一次设置全局生效

#### `git config --global --get-all safe.directory`

**作用：** 获取所有安全目录配置

**输出示例：**

```
/home/user/repo1
/home/user/repo2
*
```

#### `grep -Fxq "*"`

- **`-F`** (fixed-string): 按字面匹配，不用正则
- **`-x`** (line-regexp): 整行匹配
- **`-q`** (quiet): 静默模式，不输出
- **效果：** 检查是否有 `*` 这一行

#### `git config --global --add safe.directory "*"`

**作用：** 添加 `*` 到安全目录列表

**效果：** 信任所有目录

**配置文件：** `~/.gitconfig`

```ini
[safe]
    directory = *
```

---

### 第 40-46 行：条件性运行安装脚本

```bash
# Aggregated mode will run install together with pytest in slurm_run.sh
# Disaggregated mode will run install separately in slurm_install.sh
if [[ "$stageName" != *Disagg* ]]; then
    installScriptPath="$(dirname "${BASH_SOURCE[0]}")/$(basename "${BASH_SOURCE[0]}" | sed 's/slurm_run\.sh/slurm_install.sh/')"
    source "$installScriptPath"
    slurm_install_setup
fi
```

**详细解释：**

#### 判断是否为 Disagg 模式

```bash
if [[ "$stageName" != *Disagg* ]]; then
```

**`stageName` 来源：**

在 `slurm_launch_prefix.sh` 中定义：

```bash
export stageName="disagg_perf_test_deepseek-r1-fp4_..."
```

**模式判断：**

- **Aggregated 模式：** `stageName` 不包含 "Disagg"
  - 示例：`"GB200-8_GPUs-PyTorch-PerfSanity"`
  - **行为：** 在 slurm_run.sh 中运行安装

- **Disaggregated 模式：** `stageName` 包含 "Disagg"
  - 示例：`"disagg_perf_test_deepseek-r1-fp4_..."`
  - **行为：** 跳过安装（已在 slurm_launch_draft.sh 中运行）

#### 为什么 Disagg 要单独安装？

**原因：**

1. **所有节点同时安装**
   - Disagg 需要在多个节点上运行
   - slurm_install.sh 在启动任何组件前运行一次

2. **避免重复安装**
   - 每个组件（GEN/CTX/DISAGG_SERVER/BENCHMARK）都会运行 slurm_run.sh
   - 如果每个都安装，会浪费时间并可能冲突

**Disagg 的安装流程：**

```bash
# 在 slurm_launch_draft.sh 中（第 13-16 行）
srun "${srunArgs[@]}" $installScript &> $jobWorkspace/install.log
```

#### 构造安装脚本路径（Aggr 模式）

```bash
installScriptPath="$(dirname "${BASH_SOURCE[0]}")/$(basename "${BASH_SOURCE[0]}" | sed 's/slurm_run\.sh/slurm_install.sh/')"
```

**步骤拆解：**

1. **`${BASH_SOURCE[0]}`**
   - 当前脚本的完整路径
   - 例如：`/home/user/jenkins/scripts/slurm_run.sh`

2. **`dirname "${BASH_SOURCE[0]}"`**
   - 获取目录部分
   - 结果：`/home/user/jenkins/scripts`

3. **`basename "${BASH_SOURCE[0]}"`**
   - 获取文件名
   - 结果：`slurm_run.sh`

4. **`sed 's/slurm_run\.sh/slurm_install.sh/'`**
   - 替换文件名
   - 结果：`slurm_install.sh`

5. **拼接：**
   ```
   /home/user/jenkins/scripts/slurm_install.sh
   ```

#### `source "$installScriptPath"`

**作用：** 在当前 shell 中执行脚本

**效果：**
- 脚本中定义的函数和变量会保留在当前环境
- 不会创建子进程

#### `slurm_install_setup`

**作用：** 调用 slurm_install.sh 中定义的函数

**功能：**
- 解压 TensorRT-LLM tarball
- 安装 Python wheel
- 设置环境变量

---

### 第 48-51 行：GB200 特定检查

```bash
if [[ "$stageName" == *GB200* ]]; then
    echo "Checking Coherent GPU mapping (for GB200)..."
    grep Coherent /proc/driver/nvidia/params || echo "Unable to grep Coherent from /proc/driver/nvidia/params"
fi
```

**详细解释：**

#### 为什么需要这个检查？

**GB200 特性：**

GB200 是 NVIDIA 的新一代 GPU 架构，支持 **Coherent GPU 映射**，这是一种特殊的内存访问模式。

#### 检查内容

```bash
grep Coherent /proc/driver/nvidia/params
```

**查找：** `/proc/driver/nvidia/params` 文件中包含 "Coherent" 的行

**示例输出：**

```
CoherentAccess: 1
```

#### `|| echo "Unable to grep ..."`

**作用：** 如果 grep 失败（返回非 0），打印警告

**为什么要这样？**

- 不是所有 GPU 都有这个参数
- 不影响测试，仅供诊断

---

### 第 53-55 行：准备 llmapi-launch 脚本

```bash
llmapiLaunchScript="$llmSrcNode/tensorrt_llm/llmapi/trtllm-llmapi-launch"
chmod +x $llmapiLaunchScript
cd $llmSrcNode/tests/integration/defs
```

**详细解释：**

#### `trtllm-llmapi-launch`

**这是什么？**

这是一个**wrapper 脚本**，用于启动 TensorRT-LLM 的高级 API (LLMAPI)。

**路径：**

```
/tmp/TensorRT-LLM/src/tensorrt_llm/llmapi/trtllm-llmapi-launch
```

**作用：**

- 设置环境变量
- 配置 GPU 设备
- 启动 Python 进程

#### `chmod +x`

**作用：** 添加可执行权限

**为什么需要？**

- Tarball 中的文件可能没有执行权限
- 确保可以直接运行

#### `cd $llmSrcNode/tests/integration/defs`

**切换到测试目录：**

```bash
cd /tmp/TensorRT-LLM/src/tests/integration/defs
```

**为什么切换到这里？**

- pytest 需要从这个目录运行
- 相对路径导入会基于这个目录
- 例如：`pytest perf/test_perf_sanity.py`

---

### 第 57-61 行：获取 TensorRT-LLM wheel 路径

```bash
# get trtllm wheel path and add to pytest command
trtllmWhlPath=$(pip3 show tensorrt_llm | grep Location | cut -d ' ' -f 2)
trtllmWhlPath=$(echo "$trtllmWhlPath" | sed 's/[[:space:]]+/_/g')
echo "TRTLLM WHEEL PATH: $trtllmWhlPath"
pytestCommand=$(set_value_in_command "TRTLLM_WHL_PATH" "$trtllmWhlPath" "$pytestCommand")
```

**详细解释：**

#### 为什么需要 wheel 路径？

**问题：**

某些测试需要知道 TensorRT-LLM 安装在哪里，例如：
- 加载 C++ 库
- 查找测试数据
- 验证安装

#### 获取路径

```bash
trtllmWhlPath=$(pip3 show tensorrt_llm | grep Location | cut -d ' ' -f 2)
```

**步骤拆解：**

1. **`pip3 show tensorrt_llm`**
   - 显示包信息
   - 输出示例：
     ```
     Name: tensorrt-llm
     Version: 0.14.0
     Location: /opt/conda/lib/python3.10/site-packages
     Requires: ...
     ```

2. **`grep Location`**
   - 提取包含 "Location" 的行
   - 结果：`Location: /opt/conda/lib/python3.10/site-packages`

3. **`cut -d ' ' -f 2`**
   - `-d ' '`: 使用空格分隔
   - `-f 2`: 取第 2 个字段
   - 结果：`/opt/conda/lib/python3.10/site-packages`

#### 清理路径中的空格

```bash
trtllmWhlPath=$(echo "$trtllmWhlPath" | sed 's/[[:space:]]+/_/g')
```

**作用：** 把所有空格替换为下划线

**为什么？**

- 防止路径中有空格导致命令解析错误
- 虽然正常情况不会有空格，但这是防御性编程

#### 替换 pytest 命令中的占位符

```bash
pytestCommand=$(set_value_in_command "TRTLLM_WHL_PATH" "$trtllmWhlPath" "$pytestCommand")
```

**展开过程：**

**替换前：**

```bash
pytestCommand="pytest perf/test_perf_sanity.py --some-option=__PLACEHOLDER_TRTLLM_WHL_PATH__/data"
```

**替换后：**

```bash
pytestCommand="pytest perf/test_perf_sanity.py --some-option=/opt/conda/lib/python3.10/site-packages/data"
```

---

### 第 63-69 行：保存 coverage 配置（仅第一个进程）

```bash
# Only the first process will save the coverage config file
if [ $SLURM_PROCID -eq 0 ]; then
    sed -i "s|---wheel_path---|$trtllmWhlPath|g" "$coverageConfigFile"
else
    # Sleep 30 seconds to wait for the coverage config file to be saved
    sleep 30
fi
```

**详细解释：**

#### Coverage 配置文件

**`$coverageConfigFile` 来源：**

在 `slurm_launch_prefix.sh` 中定义：

```bash
export coverageConfigFile=$WORKSPACE/coverage_config.json
```

**文件内容示例：**

```json
{
    "source": "---wheel_path---/tensorrt_llm",
    "omit": [
        "---wheel_path---/tensorrt_llm/tests/*"
    ]
}
```

#### 为什么只有第一个进程修改？

**原因：**

- 避免多个进程同时写入同一个文件（竞争条件）
- 文件共享，修改一次全局生效

#### `sed -i`

**作用：** 就地修改文件

```bash
sed -i "s|---wheel_path---|$trtllmWhlPath|g" "$coverageConfigFile"
```

**替换前：**

```json
{
    "source": "---wheel_path---/tensorrt_llm"
}
```

**替换后：**

```json
{
    "source": "/opt/conda/lib/python3.10/site-packages/tensorrt_llm"
}
```

**语法说明：**

- `s|pattern|replacement|g`
  - `s`: substitute（替换）
  - `|`: 分隔符（可以用 `/` 但路径中有 `/` 所以用 `|`）
  - `g`: global（全局替换）

#### 其他进程等待

```bash
else
    sleep 30
fi
```

**为什么等待 30 秒？**

- 确保第一个进程完成文件修改
- 避免读取到未完成的文件
- 30 秒是经验值（文件修改很快，但要考虑文件系统延迟）

---

### 第 71-82 行：设置 LD_LIBRARY_PATH

```bash
containerPipLLMLibPath=$(pip3 show tensorrt_llm | grep "Location" | awk -F ":" '{ gsub(/ /, "", $2); print $2"/tensorrt_llm/libs"}')
containerPipLLMLibPath=$(echo "$containerPipLLMLibPath" | sed 's/[[:space:]]+/_/g')
containerLDLibPath=$LD_LIBRARY_PATH
containerLDLibPath=$(echo "$containerLDLibPath" | sed 's/[[:space:]]+/_/g')
if [[ "$containerLDLibPath" != *"$containerPipLLMLibPath"* ]]; then
  containerLDLibPath="$containerPipLLMLibPath:$containerLDLibPath"
  containerLDLibPath="${containerLDLibPath%:}"
fi
export LD_LIBRARY_PATH=$containerLDLibPath
echo "Library Path:"
echo "$LD_LIBRARY_PATH"
env | sort
```

**详细解释：**

#### 为什么需要这个？

**问题：**

TensorRT-LLM 包含 C++ 共享库（.so 文件），Python 需要加载这些库。

**解决：**

将库路径添加到 `LD_LIBRARY_PATH`，Linux 动态链接器会在这些路径中查找 .so 文件。

#### 获取库路径

```bash
containerPipLLMLibPath=$(pip3 show tensorrt_llm | grep "Location" | awk -F ":" '{ gsub(/ /, "", $2); print $2"/tensorrt_llm/libs"}')
```

**步骤拆解：**

1. **`pip3 show tensorrt_llm`**
   - 输出示例：
     ```
     Location: /opt/conda/lib/python3.10/site-packages
     ```

2. **`grep "Location"`**
   - 结果：`Location: /opt/conda/lib/python3.10/site-packages`

3. **`awk -F ":" '{ gsub(/ /, "", $2); print $2"/tensorrt_llm/libs"}'`**
   - `-F ":"`: 使用冒号分隔
   - `gsub(/ /, "", $2)`: 删除第 2 字段的所有空格
   - `print $2"/tensorrt_llm/libs"`: 拼接路径
   - 结果：`/opt/conda/lib/python3.10/site-packages/tensorrt_llm/libs`

#### 清理空格

```bash
containerPipLLMLibPath=$(echo "$containerPipLLMLibPath" | sed 's/[[:space:]]+/_/g')
containerLDLibPath=$LD_LIBRARY_PATH
containerLDLibPath=$(echo "$containerLDLibPath" | sed 's/[[:space:]]+/_/g')
```

**作用：** 防御性编程，处理可能的空格

#### 添加到 LD_LIBRARY_PATH

```bash
if [[ "$containerLDLibPath" != *"$containerPipLLMLibPath"* ]]; then
  containerLDLibPath="$containerPipLLMLibPath:$containerLDLibPath"
  containerLDLibPath="${containerLDLibPath%:}"
fi
```

**逻辑：**

1. **检查是否已包含：**
   ```bash
   if [[ "$containerLDLibPath" != *"$containerPipLLMLibPath"* ]]; then
   ```
   - 避免重复添加

2. **添加到最前面：**
   ```bash
   containerLDLibPath="$containerPipLLMLibPath:$containerLDLibPath"
   ```
   - 格式：`new_path:old_paths`
   - 冒号分隔

3. **删除末尾的冒号（如果有）：**
   ```bash
   containerLDLibPath="${containerLDLibPath%:}"
   ```
   - `${var%pattern}`: 删除末尾匹配的最短模式
   - 避免 `path1:path2:` 这种情况

**最终结果示例：**

```bash
export LD_LIBRARY_PATH=/opt/conda/lib/python3.10/site-packages/tensorrt_llm/libs:/usr/local/lib:/lib64
```

#### 打印调试信息

```bash
echo "Library Path:"
echo "$LD_LIBRARY_PATH"
env | sort
```

**输出示例：**

```
Library Path:
/opt/conda/lib/python3.10/site-packages/tensorrt_llm/libs:/usr/local/lib:/lib64
BUILD_ID=123
CLUSTER_ACCOUNT=...
DISAGG_SERVING_TYPE=BENCHMARK
...
```

---

### 第 84 行：打印最终命令

```bash
echo "Full Command: $pytestCommand"
```

**示例输出：**

```bash
Full Command: pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] -vv --junit-xml=/workspace/results.xml
```

---

### 第 86-97 行：清理 Slurm 环境变量（单节点模式）

```bash
# For single-node test runs, clear all environment variables related to Slurm and MPI.
# This prevents test processes (e.g., pytest) from incorrectly initializing MPI
# when running under a single-node srun environment.
# TODO: check if we can take advantage of --export=None arg when execute srun instead
# of unset them in the script
 if [ "${SLURM_JOB_NUM_NODES:-1}" -eq 1 ]; then
    for v in ${!PMI@} ${!PMIX@} ${!MPI@} ${!OMPI@} ${!SLURM@}; do
        if [ "$v" != "SLURM_PROCID" ]; then
            unset "$v"
        fi
    done
 fi
```

**详细解释：**

#### 为什么需要清理环境变量？

**问题：**

在单节点测试中，Slurm 和 MPI 环境变量可能导致：
- pytest 进程错误地初始化 MPI
- 多进程通信失败
- 资源分配错误

#### 判断是否单节点

```bash
if [ "${SLURM_JOB_NUM_NODES:-1}" -eq 1 ]; then
```

**`${SLURM_JOB_NUM_NODES:-1}`**
- 如果 `SLURM_JOB_NUM_NODES` 未定义，使用默认值 1
- 对于 disagg 测试，这个值通常 > 1

#### 遍历并删除环境变量

```bash
for v in ${!PMI@} ${!PMIX@} ${!MPI@} ${!OMPI@} ${!SLURM@}; do
    if [ "$v" != "SLURM_PROCID" ]; then
        unset "$v"
    fi
done
```

**语法解释：**

**`${!prefix@}`** - 获取所有以 prefix 开头的变量名

示例：

```bash
export PMI_RANK=0
export PMI_SIZE=4
export PMIX_RANK=0

for v in ${!PMI@}; do
    echo "$v"
done
# 输出：
# PMI_RANK
# PMI_SIZE
```

**删除的变量类型：**

1. **`${!PMI@}`** - PMI (Process Management Interface) 变量
   - 例如：`PMI_RANK`, `PMI_SIZE`

2. **`${!PMIX@}`** - PMIx (PMI Extended) 变量
   - 例如：`PMIX_RANK`, `PMIX_SERVER_URI`

3. **`${!MPI@}`** - MPI 相关变量
   - 例如：`MPI_LOCALRANKID`

4. **`${!OMPI@}`** - OpenMPI 变量
   - 例如：`OMPI_COMM_WORLD_RANK`

5. **`${!SLURM@}`** - Slurm 变量
   - 例如：`SLURM_JOBID`, `SLURM_TASKS_PER_NODE`
   - **除外：** `SLURM_PROCID`（保留用于判断）

**为什么保留 `SLURM_PROCID`？**

- 前面的代码需要它判断是否第一个进程
- 不影响 MPI 初始化

#### 对 Disagg 的影响

**Disagg 测试：**
- `SLURM_JOB_NUM_NODES` = 2 或更多
- **不会执行**这段清理逻辑
- 保留所有 MPI/Slurm 环境变量

---

### 第 99-108 行：执行 pytest 并捕获退出码

```bash
# Turn off "exit on error" so the following lines always run
set +e

pytest_exit_code=0
perf_check_exit_code=0
perf_report_exit_code=0

eval $pytestCommand
pytest_exit_code=$?
echo "Rank${SLURM_PROCID} Pytest finished execution with exit code $pytest_exit_code"
```

**详细解释：**

#### 关闭 errexit 模式

```bash
set +e
```

**为什么？**

- 前面设置了 `set -e`（任何命令失败就退出）
- 现在需要**即使 pytest 失败也继续执行**
- 目的：
  - 收集性能数据
  - 生成报告
  - 清理资源

#### 初始化退出码变量

```bash
pytest_exit_code=0
perf_check_exit_code=0
perf_report_exit_code=0
```

**作用：** 设置默认值，避免未定义

#### 执行 pytest

```bash
eval $pytestCommand
```

**`eval` 的作用：**

将字符串作为命令执行，支持变量展开和命令替换。

**示例展开：**

**pytestCommand 的值：**

```bash
pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] -vv --junit-xml=/workspace/results.xml"
```

**执行：**

```bash
eval $pytestCommand
```

**等价于：**

```bash
pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX] -vv --junit-xml=/workspace/results.xml
```

**实际运行过程：**

1. **pytest 启动**
2. **加载 test_perf_sanity.py**
3. **读取环境变量：**
   - `DISAGG_SERVING_TYPE` → 决定是 GEN/CTX/BENCHMARK
4. **根据角色执行不同逻辑：**
   - **BENCHMARK**：运行 benchmark 并收集结果
   - **GEN/CTX**：启动 server 并阻塞等待
   - **DISAGG_SERVER**：启动协调服务器

#### 捕获退出码

```bash
pytest_exit_code=$?
```

**退出码含义：**

- `0` - 所有测试通过
- `1` - 有测试失败
- `2` - 测试执行被中断
- `3` - 内部错误
- `4` - pytest 使用错误
- `5` - 没有收集到测试

#### 打印退出码

```bash
echo "Rank${SLURM_PROCID} Pytest finished execution with exit code $pytest_exit_code"
```

**示例输出：**

```
Rank0 Pytest finished execution with exit code 0
Rank1 Pytest finished execution with exit code 0
Rank8 Pytest finished execution with exit code 0  ← DISAGG_SERVER
Rank9 Pytest finished execution with exit code 0  ← BENCHMARK
```

**在 disagg 测试中：**
- 每个组件都会打印这行
- 通过 `SLURM_PROCID` 区分

---

### 第 110-127 行：调试 Exit Code 4

```bash
# DEBUG: Diagnose intermittent "unrecognized arguments" failure (Exit Code 4)
# Remove this after the issue is resolved
if [ $pytest_exit_code -eq 4 ]; then
    echo "DEBUG: Pytest failed with usage error (exit code 4)"
    echo "DEBUG: Directory state at $(pwd):"
    ls -l
    echo "DEBUG: Directory state at $llmSrcNode/tests/integration/defs:"
    ls -l $llmSrcNode/tests/integration/defs

    echo "DEBUG: conftest.py content:"
    md5sum $llmSrcNode/tests/integration/defs/conftest.py

    echo "DEBUG: pytest.ini content:"
    md5sum $llmSrcNode/tests/integration/defs/pytest.ini

    echo "DEBUG: Check importability of conftest.py"
    python3 -c "import sys; sys.path.insert(0, '.'); import conftest; print('DEBUG: conftest imported successfully')"
fi
```

**详细解释：**

#### 为什么有这段调试代码？

**问题背景：**

在生产环境中，偶尔会出现 Exit Code 4（pytest 使用错误），通常是：
- pytest 参数错误
- conftest.py 加载失败
- pytest.ini 配置错误

#### Exit Code 4 的含义

**Pytest Exit Code 4：** Command line usage error

**常见原因：**
- 无法识别的参数
- 配置文件语法错误
- 插件加载失败

#### 诊断步骤

**1. 打印当前目录状态**

```bash
echo "DEBUG: Directory state at $(pwd):"
ls -l
```

**检查：** 文件是否完整，权限是否正确

**2. 打印测试目录状态**

```bash
echo "DEBUG: Directory state at $llmSrcNode/tests/integration/defs:"
ls -l $llmSrcNode/tests/integration/defs
```

**检查：** conftest.py 和 pytest.ini 是否存在

**3. 检查文件完整性**

```bash
md5sum $llmSrcNode/tests/integration/defs/conftest.py
md5sum $llmSrcNode/tests/integration/defs/pytest.ini
```

**作用：**
- 验证文件没有损坏
- 可以与已知的好版本对比

**4. 测试 conftest.py 导入**

```bash
python3 -c "import sys; sys.path.insert(0, '.'); import conftest; print('DEBUG: conftest imported successfully')"
```

**作用：**
- 验证 conftest.py 语法正确
- 验证依赖项可用
- 如果导入失败，会打印错误信息

---

### 第 129-154 行：性能检查和报告（仅 rank 0 且 perfMode）

```bash
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ]; then
    if [[ "$stageName" == *PyTorch* ]]; then
        basePerfFilename="base_perf_pytorch.csv"
    else
        basePerfFilename="base_perf.csv"
    fi
    basePerfPath="$llmSrcNode/tests/integration/defs/perf/$basePerfFilename"
    echo "Check Perf Result"
    python3 $llmSrcNode/tests/integration/defs/perf/sanity_perf_check.py \
        $stageName/perf_script_test_results.csv \
        $basePerfPath
    perf_check_exit_code=$?

    echo "Create Perf Report"
    python3 $llmSrcNode/tests/integration/defs/perf/create_perf_comparison_report.py \
        --output_path $stageName/report.pdf \
        --files $stageName/perf_script_test_results.csv \
        $basePerfPath
    perf_report_exit_code=$?
    echo "Rank${SLURM_PROCID} Perf report finished execution with exit code $perf_report_exit_code"

    if [ "$perf_check_exit_code" -eq 0 ] && [ "$perf_report_exit_code" -ne 0 ]; then
        perf_check_exit_code=$perf_report_exit_code
    fi
    echo "Rank${SLURM_PROCID} Perf check finished execution with exit code $perf_check_exit_code"
fi
```

**详细解释：**

#### 条件判断

```bash
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ]; then
```

**为什么只在 rank 0？**

- 避免多个进程同时生成报告
- 性能数据通常由 BENCHMARK 组件收集

**`perfMode` 来源：**

在 `slurm_launch_prefix.sh` 中定义：

```bash
export perfMode=true
```

#### 选择基准文件

```bash
if [[ "$stageName" == *PyTorch* ]]; then
    basePerfFilename="base_perf_pytorch.csv"
else
    basePerfFilename="base_perf.csv"
fi
basePerfPath="$llmSrcNode/tests/integration/defs/perf/$basePerfFilename"
```

**作用：** 根据测试类型选择不同的基准

**文件示例：**

```
/tmp/TensorRT-LLM/src/tests/integration/defs/perf/base_perf.csv
```

**内容示例：**

```csv
test_name,throughput,latency
test_gpt2,1000,10
test_llama,800,12
```

#### 性能检查

```bash
python3 $llmSrcNode/tests/integration/defs/perf/sanity_perf_check.py \
    $stageName/perf_script_test_results.csv \
    $basePerfPath
perf_check_exit_code=$?
```

**作用：** 比较当前性能与基准

**参数：**
1. 当前测试结果
2. 基准性能数据

**检查内容：**
- 吞吐量是否下降超过阈值
- 延迟是否增加超过阈值

**退出码：**
- `0` - 性能正常
- `1` - 性能回归

#### 生成性能报告

```bash
python3 $llmSrcNode/tests/integration/defs/perf/create_perf_comparison_report.py \
    --output_path $stageName/report.pdf \
    --files $stageName/perf_script_test_results.csv \
    $basePerfPath
perf_report_exit_code=$?
```

**作用：** 生成 PDF 报告

**输出：** `{stageName}/report.pdf`

**内容：**
- 性能对比图表
- 详细指标表格
- 回归分析

#### 合并退出码

```bash
if [ "$perf_check_exit_code" -eq 0 ] && [ "$perf_report_exit_code" -ne 0 ]; then
    perf_check_exit_code=$perf_report_exit_code
fi
```

**逻辑：**

如果性能检查通过，但报告生成失败，使用报告的退出码。

**原因：** 报告生成失败也需要标记为失败

---

### 第 156-164 行：最终退出码处理

```bash
if [ "$pytest_exit_code" -ne 0 ]; then
    final_exit_code=$pytest_exit_code
elif [ "$perf_check_exit_code" -ne 0 ]; then
    final_exit_code=$perf_check_exit_code
else
    final_exit_code=0
fi
echo "Rank${SLURM_PROCID} Final Slurm run finished execution with exit code $final_exit_code"
exit $final_exit_code
```

**详细解释：**

#### 退出码优先级

```bash
if [ "$pytest_exit_code" -ne 0 ]; then
    final_exit_code=$pytest_exit_code
elif [ "$perf_check_exit_code" -ne 0 ]; then
    final_exit_code=$perf_check_exit_code
else
    final_exit_code=0
fi
```

**优先级顺序：**

1. **pytest 失败** → 使用 pytest 退出码（最高优先级）
2. **性能检查失败** → 使用性能检查退出码
3. **全部成功** → 退出码 0

**原因：**

- pytest 失败是最严重的错误
- 性能回归次之
- 只有全部通过才算成功

#### 打印最终退出码

```bash
echo "Rank${SLURM_PROCID} Final Slurm run finished execution with exit code $final_exit_code"
```

**示例输出：**

```
Rank0 Final Slurm run finished execution with exit code 0
Rank1 Final Slurm run finished execution with exit code 0
Rank9 Final Slurm run finished execution with exit code 0
```

#### 退出

```bash
exit $final_exit_code
```

**效果：**

- 脚本以指定的退出码结束
- Slurm 会捕获这个退出码
- 如果任何组件失败，整个作业失败

---

## 🔄 完整执行流程示例

### Disagg 测试场景

**配置：**
- 1 CTX Server (4 GPUs)
- 1 GEN Server (8 GPUs)
- 2 节点，12 GPUs

**执行过程：**

#### 1. slurm_install.sh 运行（所有节点）

```bash
srun --nodes=2 --ntasks=12 slurm_install.sh
```

**每个节点：**
- 解压 TensorRT-LLM tarball 到 /tmp
- 安装 wheel
- 设置环境

#### 2. 启动 GEN Server（后台）

```bash
# 在 slurm_launch_draft.sh 中
export DISAGG_SERVING_TYPE="GEN_0"
export pytestCommand="$pytestCommandWorker"
srun --nodes=1 --ntasks=8 --gpus-per-node=8 slurm_run.sh &
```

**slurm_run.sh 执行：**

- **Rank 0-7：** 8 个进程（每个 GPU 一个）
- **工作目录：** `/tmp/TensorRT-LLM/src/tests/integration/defs`
- **执行命令：**
  ```bash
  eval "TLLM_LOG_LEVEL=INFO TRTLLM_WORKER_DISABLE_GC=1 pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_...]"
  ```
- **pytest 行为：**
  - 检测到 `DISAGG_SERVING_TYPE=GEN_0`
  - 启动 GEN worker
  - 等待请求（阻塞）

#### 3. 启动 CTX Server（后台）

```bash
export DISAGG_SERVING_TYPE="CTX_0"
export pytestCommand="$pytestCommandWorker"
srun --nodes=1 --ntasks=4 --gpus-per-node=4 slurm_run.sh &
```

**slurm_run.sh 执行：**

- **Rank 8-11：** 4 个进程
- **启动 CTX worker**
- 等待请求（阻塞）

#### 4. 启动 DISAGG_SERVER（后台）

```bash
export DISAGG_SERVING_TYPE="DISAGG_SERVER"
export pytestCommand="$pytestCommandDisaggServer"
srun --nodes=1 --ntasks=1 slurm_run.sh &
```

**slurm_run.sh 执行：**

- **Rank 12：** 1 个进程
- **启动协调服务器**
- 读取 hostname 文件
- 连接到 GEN/CTX servers
- 等待请求（阻塞）

#### 5. 启动 BENCHMARK（前台）

```bash
export DISAGG_SERVING_TYPE="BENCHMARK"
export pytestCommand="$pytestCommandBenchmark"
srun --nodes=1 --ntasks=1 slurm_run.sh
```

**slurm_run.sh 执行：**

- **Rank 13：** 1 个进程
- **运行 benchmark**
  1. 等待所有 servers 就绪
  2. 发送请求
  3. 收集性能数据
  4. 生成报告
  5. 退出

#### 6. 清理

**当 BENCHMARK 退出：**

```bash
# 在 slurm_launch_draft.sh 中
# 创建 benchmark_status 文件
touch $jobWorkspace/benchmark_status.txt
```

**其他组件检测到文件：**

```bash
# 在 slurm_launch_draft.sh 的 wait_for_benchmark_ready 函数
while true; do
    if [ -f $jobWorkspace/benchmark_status.txt ]; then
        break
    fi
    sleep 10
done
```

**所有组件退出**

---

## 🎯 关键要点

### 1. 同一脚本，多种角色

**通过环境变量区分：**

| DISAGG_SERVING_TYPE | pytestCommand | 行为 |
|---------------------|---------------|------|
| GEN_0 | pytestCommandWorker | 启动 GEN worker |
| CTX_0 | pytestCommandWorker | 启动 CTX worker |
| DISAGG_SERVER | pytestCommandDisaggServer | 启动协调服务器 |
| BENCHMARK | pytestCommandBenchmark | 运行 benchmark |

### 2. 环境准备

**每次执行都会：**
1. 设置 Git safe.directory
2. 获取 wheel 路径
3. 设置 LD_LIBRARY_PATH
4. 清理空格
5. 替换占位符

### 3. 错误处理

**三层退出码：**
1. pytest_exit_code
2. perf_check_exit_code
3. final_exit_code（综合）

### 4. 并发协调

**机制：**
- **Rank 0** 修改共享文件
- **其他 Rank** 等待
- **文件系统** 作为通信媒介

### 5. 调试支持

**丰富的输出：**
- 每条命令执行（set -x）
- 环境变量打印
- 退出码打印
- 文件状态检查

---

## 📚 相关文档

1. **submit.py 参数：** `jenkins_test/docs/SUBMIT_PY_PARAMS_EXPLAINED.md`
2. **完整流程：** `jenkins_test/docs/DISAGG_FINAL_SUMMARY.md`
3. **slurm_launch_draft.sh：** `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`

---

**现在完全理解 slurm_run.sh 的每一行了吗？** 🚀
