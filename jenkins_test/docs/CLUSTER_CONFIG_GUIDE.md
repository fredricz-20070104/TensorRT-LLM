# 集群配置加载器使用指南

## 概述

使用 Python 脚本 `load_cluster_config.py` 替代原来的 Shell 脚本，实现更可靠的配置加载。

## 优势

### 为什么用 Python 替代 Shell？

1. **跨进程环境变量传递**
   - Shell 子进程设置的环境变量无法传递给父进程
   - Python 输出 JSON → Groovy 解析 → 设置环境变量（完全控制）

2. **更好的可维护性**
   - Python 代码更易读易维护
   - 支持多种输出格式（JSON, Shell, Env）
   - 完善的错误处理和提示

3. **配置验证**
   - 自动检查配置文件是否存在
   - 验证集群名称是否有效
   - 提供友好的错误信息

## 使用方法

### 1. 在 Jenkins Pipeline 中使用

```groovy
// 加载集群配置
def configJson = sh(
    script: "python3 ${SCRIPTS_DIR}/load_cluster_config.py ${CLUSTER}",
    returnStdout: true
).trim()

// 解析 JSON
def configMap = readJSON text: configJson

// 设置环境变量
configMap.each { key, value ->
    env."${key}" = value
}

// 使用配置
echo "集群主机: ${env.CLUSTER_HOST}"
echo "Slurm 分区: ${env.CLUSTER_PARTITION}"
```

### 2. 在 Shell 脚本中使用

```bash
# 方法 1: JSON 格式（推荐用于解析）
config_json=$(python3 scripts/load_cluster_config.py gb200)
echo "$config_json" | jq -r '.CLUSTER_HOST'

# 方法 2: Shell export 格式
eval "$(python3 scripts/load_cluster_config.py gb200 --format shell)"
echo "集群主机: $CLUSTER_HOST"

# 方法 3: Env 格式
source <(python3 scripts/load_cluster_config.py gb200 --format env | sed 's/^/export /')
```

### 3. 命令行使用

```bash
# 查看配置（美化输出）
python3 scripts/load_cluster_config.py gb200 --pretty

# 输出 shell export 语句
python3 scripts/load_cluster_config.py gb200 --format shell

# 输出 KEY=VALUE 格式
python3 scripts/load_cluster_config.py gb200 --format env

# 指定配置文件路径
python3 scripts/load_cluster_config.py gb200 --config-file /path/to/clusters.conf

# 查看帮助
python3 scripts/load_cluster_config.py --help
```

## 输出格式

### JSON 格式（默认）

```json
{
  "CLUSTER_NAME": "gb200",
  "CLUSTER_HOST": "oci-hsg-cs-001-login-01",
  "CLUSTER_USER": "fredricz",
  "CLUSTER_TYPE": "ssh",
  "CLUSTER_PARTITION": "batch",
  "CLUSTER_ACCOUNT": "coreai_comparch_trtllm",
  "CLUSTER_STORAGE": "/lustre/fs1/...",
  "CLUSTER_LLM_DATA": "/lustre/fs1/...",
  "DOCKER_IMAGE": "nvcr.io/nvidia/tensorrt-llm:latest",
  "MPI_TYPE": "pmix",
  "EXTRA_SRUN_PARAMS": "--gres=gpu:4"
}
```

### Shell 格式

```bash
export CLUSTER_NAME="gb200"
export CLUSTER_HOST="oci-hsg-cs-001-login-01"
export CLUSTER_USER="fredricz"
export CLUSTER_TYPE="ssh"
export CLUSTER_PARTITION="batch"
...
```

### Env 格式

```
CLUSTER_NAME=gb200
CLUSTER_HOST=oci-hsg-cs-001-login-01
CLUSTER_USER=fredricz
CLUSTER_TYPE=ssh
CLUSTER_PARTITION=batch
...
```

## 配置文件格式

位置：`jenkins_test/config/clusters.conf`

```ini
[cluster_name]
CLUSTER_NAME=gb200
CLUSTER_HOST=oci-hsg-cs-001-login-01
CLUSTER_USER=fredricz
CLUSTER_TYPE=ssh
CLUSTER_PARTITION=batch
CLUSTER_ACCOUNT=coreai_comparch_trtllm
CLUSTER_STORAGE=/lustre/fs1/...
CLUSTER_LLM_DATA=/lustre/fs1/...
DOCKER_IMAGE=nvcr.io/nvidia/tensorrt-llm:latest
MPI_TYPE=pmix
EXTRA_SRUN_PARAMS=--gres=gpu:4
```

## 错误处理

### 配置文件不存在

```bash
$ python3 scripts/load_cluster_config.py gb200 --config-file /nonexistent
错误: 配置文件不存在: /nonexistent
```

### 集群名称无效

```bash
$ python3 scripts/load_cluster_config.py invalid_cluster
错误: 集群 'invalid_cluster' 未在配置文件中找到。
可用集群: gb200, gb300, gb200_lyris
```

## 迁移指南

### 从 Shell 脚本迁移

**旧方式（Shell）**：
```bash
source scripts/lib/load_cluster_config.sh gb200
echo "主机: $CLUSTER_HOST"
```

**新方式（Python + JSON）**：
```bash
eval "$(python3 scripts/load_cluster_config.py gb200 --format shell)"
echo "主机: $CLUSTER_HOST"
```

**或者在 Jenkins Groovy 中**：
```groovy
def config = readJSON text: sh(
    script: "python3 scripts/load_cluster_config.py gb200",
    returnStdout: true
).trim()

env.CLUSTER_HOST = config.CLUSTER_HOST
```

## 添加新集群

1. 编辑 `jenkins_test/config/clusters.conf`
2. 添加新的配置块：

```ini
[my_new_cluster]
CLUSTER_NAME=my_new_cluster
CLUSTER_HOST=my-cluster-login
CLUSTER_USER=myuser
CLUSTER_TYPE=ssh
CLUSTER_PARTITION=batch
CLUSTER_ACCOUNT=my_account
CLUSTER_STORAGE=/path/to/storage
CLUSTER_LLM_DATA=/path/to/llm/data
DOCKER_IMAGE=nvcr.io/nvidia/tensorrt-llm:latest
MPI_TYPE=pmix
EXTRA_SRUN_PARAMS=
```

3. 测试配置：

```bash
python3 scripts/load_cluster_config.py my_new_cluster --pretty
```

4. 在 Jenkins Pipeline 中添加选项：

```groovy
choice(
    name: 'CLUSTER',
    choices: ['gb300', 'gb200', 'gb200_lyris', 'my_new_cluster'],
    ...
)
```

## 故障排查

### 问题：JSON 解析失败

```bash
# 检查 JSON 格式是否正确
python3 scripts/load_cluster_config.py gb200 | jq .

# 如果 jq 报错，说明 JSON 格式有问题
```

### 问题：环境变量未设置

```bash
# 在 Jenkins 中，确保使用 readJSON
def config = readJSON text: configJson

# 不要直接解析字符串
```

### 问题：找不到 Python 模块

```bash
# 确保 Python 3 可用
python3 --version

# 脚本只使用标准库，不需要额外安装
```

## 最佳实践

1. **始终使用 JSON 格式在 Jenkins 中**
   - 最可靠的跨语言数据传递
   - Jenkins Groovy 原生支持 `readJSON`

2. **在 Shell 脚本中使用 Shell 格式**
   - 可以直接 `eval` 加载
   - 避免依赖 `jq`

3. **使用 --pretty 进行调试**
   - 便于人工查看配置
   - 排查配置问题

4. **配置文件使用版本控制**
   - 跟踪配置变更
   - 便于回滚

5. **不要硬编码路径**
   - 使用脚本的相对路径查找配置文件
   - 或通过 `--config-file` 参数指定
