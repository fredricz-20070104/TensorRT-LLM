# Jenkins 远程执行架构设计

## 📋 需求分析

### 执行环境

1. **中转机（Jenkins Runner）**: 运行 Jenkins Pipeline 的机器
2. **目标 Cluster**: 实际执行测试的 Slurm 集群

### 测试模式与执行方式

| 测试模式 | 执行位置 | 执行方式 | 需要 SSH | 结果归档 |
|---------|---------|---------|---------|---------|
| **Disagg** | Cluster | `sbatch` | ✅ | SSH 拉回中转机 |
| **Single Agg** | Cluster | `srun` (单节点) | ✅ | SSH 拉回中转机 |
| **Multi Agg** | Cluster | `srun` (多节点) | ✅ | SSH 拉回中转机 |

### Docker 镜像

- Single Agg: 需要 Docker 镜像
- Multi Agg: 需要 Docker 镜像
- Disagg: 通过 sbatch 调用的 submit.py 处理

## 🏗️ 架构设计

### 1. Cluster 配置管理

**文件**: `jenkins_test/config/clusters.conf`

```ini
[gb200]
CLUSTER_NAME=gb200
CLUSTER_HOST=oci-hsg-cs-001-login-01
CLUSTER_USER=fredricz
CLUSTER_TYPE=ssh
CLUSTER_PARTITION=batch
CLUSTER_ACCOUNT=coreai_comparch_trtllm
CLUSTER_STORAGE=/lustre/fs1/portfolios/...
CLUSTER_LLM_DATA=/lustre/fs1/portfolios/...
DOCKER_IMAGE=nvcr.io/nvidia/tensorrt-llm:latest
MPI_TYPE=pmix

[gb300]
CLUSTER_NAME=gb300
...
```

### 2. 远程执行库

**文件**: `jenkins_test/scripts/lib/remote.sh`

核心功能：
- `init_remote()` - 自动检测 SSH vs Local 模式
- `remote_exec()` - 执行远程命令
- `remote_copy()` - 复制文件
- `remote_mkdir()` - 创建远程目录
- `remote_script()` - 执行远程脚本

### 3. 执行流程

```
Jenkins Pipeline (中转机)
    ↓
加载 Cluster 配置
    ↓
初始化 Remote 库
    ↓
┌─────────────────────────────────┐
│  拉取 TensorRT-LLM 到中转机     │
└─────────────────────────────────┘
    ↓
┌─────────────────────────────────┐
│  同步代码和脚本到 Cluster       │
│  (SSH/SCP)                      │
└─────────────────────────────────┘
    ↓
┌─────────────────────────────────┐
│  在 Cluster 上执行测试          │
│  - Disagg: sbatch               │
│  - Agg: srun                    │
└─────────────────────────────────┘
    ↓
┌─────────────────────────────────┐
│  拉取测试结果回中转机           │
│  (SSH/SCP)                      │
└─────────────────────────────────┘
    ↓
Jenkins 归档 Artifacts
```

## 🔧 实现细节

### Disagg 模式

```bash
# 步骤 1: 同步代码到 cluster
remote_copy TensorRT-LLM/ ${CLUSTER_WORKDIR}/

# 步骤 2: 上传测试脚本
remote_copy run_disagg_test.sh ${CLUSTER_WORKDIR}/scripts/

# 步骤 3: 远程执行 (生成 sbatch 脚本并提交)
remote_script ${CLUSTER_WORKDIR}/scripts/run_disagg_test.sh \
    --trtllm-dir ${CLUSTER_WORKDIR}/TensorRT-LLM \
    --testlist xxx \
    --workspace ${CLUSTER_WORKDIR}/workspace

# 步骤 4: 等待作业完成（通过 SSH 轮询 sacct）

# 步骤 5: 拉取结果
remote_copy ${CLUSTER_WORKDIR}/workspace/output/ ./artifacts/
```

### Single/Multi Agg 模式

```bash
# 步骤 1: 同步代码
remote_copy TensorRT-LLM/ ${CLUSTER_WORKDIR}/

# 步骤 2: 上传测试脚本
remote_copy run_single_agg_test.sh ${CLUSTER_WORKDIR}/scripts/

# 步骤 3: 远程执行 (直接用 srun)
remote_exec "
cd ${CLUSTER_WORKDIR}/TensorRT-LLM &&
srun \\
    --container-image=${DOCKER_IMAGE} \\
    --container-workdir=${CLUSTER_WORKDIR}/TensorRT-LLM \\
    --mpi=${MPI_TYPE} \\
    python3 -m pytest tests/integration/defs/perf/test_perf_sanity.py::test_e2e \\
    -k 'aggr_upload-${CONFIG_FILE}' -v
"

# 步骤 4: 拉取结果
remote_copy ${CLUSTER_WORKDIR}/output/ ./artifacts/
```

## 📁 文件结构

```
jenkins_test/
├── config/
│   └── clusters.conf                # Cluster 配置
├── scripts/
│   ├── lib/
│   │   ├── remote.sh                # 远程执行库
│   │   └── load_cluster_config.sh   # 加载 cluster 配置
│   ├── run_disagg_test.sh           # Disagg 测试脚本（更新：支持远程）
│   ├── run_single_agg_test.sh       # Single Agg 测试脚本（更新：支持远程）
│   ├── run_multi_agg_test.sh        # Multi Agg 测试脚本（更新：支持远程）
│   └── sync_and_run.sh              # 新增：通用同步和执行脚本
└── Perf_Test.groovy                 # Jenkins Pipeline（更新：添加 cluster 参数）
```

## 🎯 Perf_Test.groovy 更新

### 新增参数

```groovy
choice(
    name: 'CLUSTER',
    choices: ['gb200', 'gb300', 'gb200_lyris', 'local'],
    description: '目标 Cluster'
),
string(
    name: 'SSH_PRIVATE_KEY_ID',
    defaultValue: 'jenkins-ssh-key',
    description: 'Jenkins Credential ID (SSH 私钥)'
)
```

### 执行流程

```groovy
stage('初始化 Cluster 配置') {
    steps {
        script {
            // 加载 cluster 配置
            sh """
                source ${WORKSPACE_ROOT}/scripts/lib/load_cluster_config.sh ${CLUSTER}
                env | grep CLUSTER_ > cluster.env
            """
            
            // 读取配置到环境变量
            def clusterConfig = readFile('cluster.env')
            // ... 解析并设置环境变量
        }
    }
}

stage('配置 SSH') {
    when {
        expression { CLUSTER_TYPE == 'ssh' }
    }
    steps {
        script {
            // 从 Jenkins Credentials 获取 SSH 私钥
            sshagent(credentials: [params.SSH_PRIVATE_KEY_ID]) {
                sh "ssh-keyscan -H ${CLUSTER_HOST} >> ~/.ssh/known_hosts"
            }
        }
    }
}

stage('同步代码到 Cluster') {
    steps {
        script {
            sh """
                source ${WORKSPACE_ROOT}/scripts/lib/remote.sh
                remote_mkdir ${CLUSTER_WORKDIR}
                remote_copy ${TRTLLM_DIR} ${REMOTE_PREFIX}${CLUSTER_WORKDIR}/
                remote_copy ${WORKSPACE_ROOT}/scripts ${REMOTE_PREFIX}${CLUSTER_WORKDIR}/
            """
        }
    }
}

stage('运行测试') {
    steps {
        script {
            sshagent(credentials: [params.SSH_PRIVATE_KEY_ID]) {
                def testScript = "${TEST_MODE}_test"
                sh """
                    export CLUSTER_NAME=${CLUSTER}
                    export CLUSTER_WORKDIR=${CLUSTER_WORKDIR}
                    source ${WORKSPACE_ROOT}/scripts/lib/remote.sh
                    
                    remote_script ${CLUSTER_WORKDIR}/scripts/run_${testScript}.sh \\
                        --trtllm-dir ${CLUSTER_WORKDIR}/TensorRT-LLM \\
                        --config-file ${CONFIG_FILE} \\
                        --workspace ${CLUSTER_WORKDIR}/workspace
                """
            }
        }
    }
}

stage('拉取结果') {
    steps {
        script {
            sshagent(credentials: [params.SSH_PRIVATE_KEY_ID]) {
                sh """
                    source ${WORKSPACE_ROOT}/scripts/lib/remote.sh
                    remote_copy ${REMOTE_PREFIX}${CLUSTER_WORKDIR}/workspace/output/ \\
                                ${WORKSPACE_ROOT}/artifacts/
                """
            }
        }
    }
}
```

## ⚙️ 配置说明

### Jenkins Credentials

需要在 Jenkins 中配置：

1. **SSH 私钥**: 
   - Type: SSH Username with private key
   - ID: `jenkins-ssh-key`
   - Username: `fredricz` (或对应的 cluster 用户)
   - Private Key: 添加 SSH 私钥

### Cluster 访问权限

确保：
1. Jenkins Runner 可以 SSH 到目标 cluster
2. SSH 用户有 Slurm 权限（sbatch, srun, sacct）
3. 有足够的存储空间在 CLUSTER_STORAGE

## 🔍 调试

### 本地测试

```bash
# 设置 cluster 配置
export CLUSTER=gb200
source jenkins_test/scripts/lib/load_cluster_config.sh $CLUSTER

# 加载远程执行库
source jenkins_test/scripts/lib/remote.sh

# 测试远程命令
remote_exec "echo 'Hello from cluster'"

# 测试文件复制
remote_copy test.txt ${CLUSTER_STORAGE}/
```

### Dry Run

```bash
# 使用 --dry-run 参数测试
./run_disagg_test.sh \
    --trtllm-dir ~/TensorRT-LLM \
    --testlist xxx \
    --workspace /tmp/test \
    --dry-run
```

## 📊 对比：GitLab CI vs Jenkins

| 特性 | GitLab CI | Jenkins |
|------|-----------|---------|
| **Runner 位置** | 可以在 cluster 上 (lyris) | 通常在中转机上 |
| **SSH 需求** | GB200 需要，GB300 不需要 | 所有 cluster 都需要 |
| **配置方式** | YAML + env vars | Groovy + properties |
| **远程库** | `scripts/lib/remote.sh` | 相同的 `remote.sh` |
| **Cluster 配置** | 硬编码在 YAML 中 | `clusters.conf` 文件 |

## ✅ 优势

1. **统一的远程执行接口** - `remote.sh` 库
2. **配置化的 Cluster 管理** - `clusters.conf`
3. **可调试** - 所有脚本可以独立运行
4. **灵活** - 支持 SSH 和本地两种模式
5. **与 GitLab CI 一致** - 相同的设计模式

## 🚧 待实现

1. 更新三个测试脚本支持远程执行
2. 创建 `sync_and_run.sh` 通用脚本
3. 更新 `Perf_Test.groovy` 添加 cluster 支持
4. 添加结果拉取逻辑
5. 添加清理逻辑（可选）
