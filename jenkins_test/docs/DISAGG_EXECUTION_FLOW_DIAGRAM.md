# Disagg 完整执行流程图

> 从 Jenkins 到 pytest，完整的参数和脚本调用链路

---

## 🎯 完整调用链路（修正后）

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Jenkins Pipeline                                │
│  • 读取 clusters.conf                                                    │
│  • 设置环境变量: CLUSTER_*, DOCKER_IMAGE, MPI_TYPE                      │
│  • 调用: jenkins_test/scripts/run_disagg_test.sh                        │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│              run_disagg_test.sh (在集群上运行)                           │
│                                                                          │
│  步骤1: 从 TestList 或配置文件名提取配置                                 │
│  步骤2: 查找配置文件完整路径                                             │
│    └─ tests/integration/defs/perf/disagg/test_configs/disagg/perf/      │
│       deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml │
│                                                                          │
│  步骤3: calculate_hardware_nodes.py 计算节点数                          │
│    • 读取 YAML: hardware, worker_config                                 │
│    • 计算: num_ctx_servers=1, num_gen_servers=1, total_nodes=2         │
│                                                                          │
│  步骤4: 生成 submit.py 输入文件                                          │
│    ┌─ test_list_disagg.txt                                              │
│    │   perf/test_perf_sanity.py::test_e2e[disagg_upload-CONFIG_NAME]   │
│    │                                                                     │
│    ┌─ slurm_launch_prefix.sh                                            │
│    │   #SBATCH --nodes=2                                                │
│    │   #SBATCH --partition=gb300                                        │
│    │   export pytestCommand="pytest perf/test_perf_sanity.py..."       │
│    │   export jobWorkspace=$WORKSPACE/disagg_workspace                  │
│    │   export stageName="disagg_perf_test"                              │
│    │                                                                     │
│    └─ slurm_srun_args.txt                                               │
│        --container-image=$DOCKER_IMAGE                                  │
│        --container-mounts=$CLUSTER_LLM_DATA:/data                       │
│        --mpi=pmix                                                        │
│                                                                          │
│  步骤5: 调用 submit.py 生成 launch.sh                                    │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         submit.py                                        │
│                                                                          │
│  输入:                                                                   │
│    • test_list_disagg.txt       → 提取 CONFIG_NAME                      │
│    • slurm_launch_prefix.sh     → SBATCH 指令 + 环境变量               │
│    • slurm_srun_args.txt        → srun 参数                             │
│    • slurm_launch_draft.sh      → 启动逻辑模板                          │
│    • slurm_run.sh               → 执行脚本路径                          │
│    • slurm_install.sh           → 安装脚本路径                          │
│    • CONFIG_NAME.yaml           → 读取 hardware, worker_config         │
│                                                                          │
│  处理:                                                                   │
│    1. 从 test-list 提取配置名                                           │
│    2. 读取 YAML 配置文件                                                │
│    3. 计算硬件资源 (节点数、GPU数)                                      │
│    4. 添加环境变量到 script_prefix:                                     │
│       • pytestCommandWorker                                             │
│       • pytestCommandDisaggServer                                       │
│       • numCtxServers, numGenServers                                    │
│       • totalNodes, totalGpus                                           │
│    5. 添加参数到 srun_args:                                              │
│       • --container-env=DISAGG_SERVING_TYPE                             │
│       • --container-env=pytestCommand                                   │
│    6. 组合生成 launch.sh:                                                │
│       script_prefix + srun_args + draft_launch_content                 │
│                                                                          │
│  输出: slurm_launch_generated.sh                                         │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│          sbatch slurm_launch_generated.sh                                │
│                                                                          │
│  #!/bin/bash                                                             │
│  #SBATCH --nodes=2                                                       │
│  #SBATCH --ntasks=12                                                     │
│  #SBATCH --partition=gb300                                               │
│  #SBATCH --account=...                                                   │
│                                                                          │
│  export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]" │
│  export pytestCommandWorker="unset UCX_TLS && ... $pytestCommand"       │
│  export pytestCommandDisaggServer="... $pytestCommandNoLLMAPILaunch"    │
│  export pytestCommandBenchmark="... $pytestCommandNoLLMAPILaunch"       │
│  export numCtxServers=1                                                  │
│  export numGenServers=1                                                  │
│  export totalNodes=2                                                     │
│  export totalGpus=12                                                     │
│                                                                          │
│  srunArgs=(                                                              │
│    "--container-image=$DOCKER_IMAGE"                                     │
│    "--container-mounts=..."                                              │
│    "--mpi=pmix"                                                          │
│    "--container-env=DISAGG_SERVING_TYPE"                                 │
│    "--container-env=pytestCommand"                                       │
│  )                                                                       │
│                                                                          │
│  # 以下是 slurm_launch_draft.sh 的内容                                  │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                  slurm_launch_draft.sh 逻辑                              │
│                                                                          │
│  步骤1: 安装 (所有节点)                                                  │
│    srun "${srunArgs[@]}" slurm_install.sh                               │
│      → 所有节点并行: 解压 tarball, 安装 wheel                           │
│                                                                          │
│  步骤2: 启动 GEN Servers (后台)                                          │
│    for i in 0..$((numGenServers-1)); do                                │
│      export DISAGG_SERVING_TYPE="GEN_$i"                                │
│      export pytestCommand="$pytestCommandWorker"                        │
│      srun -N 1 --ntasks=8 slurm_run.sh &  ← 后台运行                   │
│    done                                                                  │
│                                                                          │
│  步骤3: 启动 CTX Servers (后台)                                          │
│    for i in 0..$((numCtxServers-1)); do                                │
│      export DISAGG_SERVING_TYPE="CTX_$i"                                │
│      export pytestCommand="$pytestCommandWorker"                        │
│      srun -N 1 --ntasks=4 slurm_run.sh &  ← 后台运行                   │
│    done                                                                  │
│                                                                          │
│  步骤4: 启动 DISAGG_SERVER (后台)                                         │
│    export DISAGG_SERVING_TYPE="DISAGG_SERVER"                           │
│    export pytestCommand="$pytestCommandDisaggServer"                    │
│    srun -N 1 --ntasks=1 slurm_run.sh &    ← 后台运行                   │
│                                                                          │
│  步骤5: 启动 BENCHMARK (前台)                                             │
│    export DISAGG_SERVING_TYPE="BENCHMARK"                               │
│    export pytestCommand="$pytestCommandBenchmark"                       │
│    srun -N 1 --ntasks=1 slurm_run.sh      ← 前台运行，阻塞等待         │
│                                                                          │
│  步骤6: BENCHMARK 完成后，其他组件检测并退出                             │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    slurm_run.sh (每个组件都运行)                         │
│                                                                          │
│  [同一脚本，通过 DISAGG_SERVING_TYPE 区分角色]                          │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 环境准备 (所有组件相同)                                          │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │ 1. 错误处理: set -xEeuo pipefail, trap ERR                     │   │
│  │ 2. 切换目录: cd /tmp                                            │   │
│  │ 3. Git 配置: git config safe.directory (仅 rank 0)            │   │
│  │ 4. 跳过安装: Disagg 模式已安装                                  │   │
│  │ 5. GB200检查: grep Coherent (如果是 GB200)                     │   │
│  │ 6. 准备脚本: chmod +x trtllm-llmapi-launch                     │   │
│  │ 7. 切换目录: cd tests/integration/defs                         │   │
│  │ 8. 获取路径: pip3 show tensorrt_llm → wheel 路径              │   │
│  │ 9. 替换占位符: set_value_in_command                            │   │
│  │ 10. 设置coverage: sed 替换 ---wheel_path--- (仅 rank 0)       │   │
│  │ 11. 设置库路径: LD_LIBRARY_PATH 添加 libs 目录                 │   │
│  │ 12. 打印调试: env | sort                                       │   │
│  │ 13. 清理变量: unset MPI/SLURM 变量 (单节点)                    │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                          │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 执行 pytest (根据 DISAGG_SERVING_TYPE 不同行为)                │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │ eval $pytestCommand                                             │   │
│  │   → pytest perf/test_perf_sanity.py::test_e2e[...]            │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                │                                         │
│                                ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │                  test_perf_sanity.py                            │   │
│  │                                                                 │   │
│  │  根据 DISAGG_SERVING_TYPE 分支:                                │   │
│  │                                                                 │   │
│  │  if DISAGG_SERVING_TYPE == "GEN_0":                            │   │
│  │      启动 GEN worker (TP=8)                                     │   │
│  │      生成 hostname 文件                                         │   │
│  │      等待 benchmark_status 文件 (阻塞)                         │   │
│  │                                                                 │   │
│  │  elif DISAGG_SERVING_TYPE == "CTX_0":                          │   │
│  │      启动 CTX worker (TP=4)                                     │   │
│  │      生成 hostname 文件                                         │   │
│  │      等待 benchmark_status 文件 (阻塞)                         │   │
│  │                                                                 │   │
│  │  elif DISAGG_SERVING_TYPE == "DISAGG_SERVER":                  │   │
│  │      等待所有 hostname 文件就绪                                 │   │
│  │      生成 server_config.yaml                                    │   │
│  │      启动协调服务器                                             │   │
│  │      等待 benchmark_status 文件 (阻塞)                         │   │
│  │                                                                 │   │
│  │  elif DISAGG_SERVING_TYPE == "BENCHMARK":                      │   │
│  │      等待 server_config.yaml                                    │   │
│  │      等待 /health 端点就绪                                      │   │
│  │      运行 benchmark:                                            │   │
│  │        • 发送请求                                               │   │
│  │        • 收集性能指标                                           │   │
│  │        • 生成 results.xml                                       │   │
│  │        • 上传到 OpenSearch (如果 upload_to_db)                 │   │
│  │      创建 benchmark_status.txt                                  │   │
│  │      返回退出码                                                 │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                │                                         │
│                                ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 后处理 (仅 rank 0 且 perfMode=true)                             │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │ 1. 性能检查: sanity_perf_check.py                              │   │
│  │    → 比较当前性能与基准                                         │   │
│  │ 2. 生成报告: create_perf_comparison_report.py                  │   │
│  │    → 生成 PDF 报告                                              │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                │                                         │
│                                ▼                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │ 最终退出码                                                      │   │
│  ├─────────────────────────────────────────────────────────────────┤   │
│  │ if pytest_exit_code != 0:                                       │   │
│  │     final_exit_code = pytest_exit_code                          │   │
│  │ elif perf_check_exit_code != 0:                                 │   │
│  │     final_exit_code = perf_check_exit_code                      │   │
│  │ else:                                                            │   │
│  │     final_exit_code = 0                                         │   │
│  │                                                                  │   │
│  │ exit $final_exit_code                                           │   │
│  └─────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘

最终结果:
  • BENCHMARK 组件退出 (exit 0 或 exit 1)
  • 创建 benchmark_status.txt 文件
  • 其他组件检测到文件后退出
  • Slurm 作业完成
```

---

## 📊 关键环境变量流转

### Jenkins → run_disagg_test.sh

```bash
export CLUSTER_PARTITION=gb300
export CLUSTER_ACCOUNT=coreai_comparch_trtllm
export CLUSTER_LLM_DATA=/lustre/fsw/...
export DOCKER_IMAGE=nvcr.io/nvidia/tensorrt-llm:latest
export MPI_TYPE=pmix
```

### run_disagg_test.sh → submit.py (通过文件)

**slurm_launch_prefix.sh:**
```bash
#SBATCH --nodes=2
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT

export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...]"
export jobWorkspace=$WORKSPACE/disagg_workspace
export stageName="disagg_perf_test"
```

**slurm_srun_args.txt:**
```
--container-image=$DOCKER_IMAGE
--container-mounts=$CLUSTER_LLM_DATA:/data
--mpi=$MPI_TYPE
```

### submit.py → launch.sh

**添加的环境变量:**
```bash
export pytestCommandWorker="unset UCX_TLS && TLLM_LOG_LEVEL=INFO ... $pytestCommand"
export pytestCommandDisaggServer="TRTLLM_SERVER_DISABLE_GC=1 ..."
export pytestCommandBenchmark="..."
export numCtxServers=1
export numGenServers=1
export totalNodes=2
export totalGpus=12
```

### slurm_launch_draft.sh → slurm_run.sh

**为每个组件设置:**
```bash
export DISAGG_SERVING_TYPE="GEN_0"  # 或 CTX_0, DISAGG_SERVER, BENCHMARK
export pytestCommand="$pytestCommandWorker"  # 或其他变体
```

### slurm_run.sh → pytest

**所有环境变量可用:**
```bash
DISAGG_SERVING_TYPE=BENCHMARK
pytestCommand="pytest ..."
jobWorkspace=/workspace/disagg_workspace
LD_LIBRARY_PATH=/opt/.../tensorrt_llm/libs:...
TRTLLM_WHL_PATH=/opt/conda/lib/python3.10/site-packages
```

---

## 🎯 关键要点

### 1. 参数传递层次

```
clusters.conf
  → Jenkins 环境变量
    → run_disagg_test.sh 生成的文件
      → submit.py 读取并处理
        → launch.sh 包含所有环境变量
          → slurm_launch_draft.sh 设置角色
            → slurm_run.sh 执行
              → pytest 运行测试
```

### 2. 同一脚本，多种角色

**slurm_run.sh** 被所有组件运行，通过环境变量区分：

| 组件 | DISAGG_SERVING_TYPE | pytestCommand | 行为 |
|------|---------------------|---------------|------|
| GEN Server | GEN_0 | pytestCommandWorker | 启动并等待 |
| CTX Server | CTX_0 | pytestCommandWorker | 启动并等待 |
| DISAGG SERVER | DISAGG_SERVER | pytestCommandDisaggServer | 协调服务器 |
| BENCHMARK | BENCHMARK | pytestCommandBenchmark | 运行并收集 |

### 3. 配置文件的作用

**YAML 配置文件提供:**
- `hardware` → 计算节点数
- `worker_config` → TP/PP/CP 配置
- `environment` → 环境变量

**不需要填充的占位符:**
- `<container_image>` → 从 clusters.conf
- `<container_mount>` → 从 clusters.conf
- `<model_path>` → test_perf_sanity.py 硬编码
- `<work_dir>` → 从 launch.sh

### 4. 关键同步机制

**文件协调:**
- **hostname 文件** → GEN/CTX 写入，DISAGG_SERVER 读取
- **server_config.yaml** → DISAGG_SERVER 写入，BENCHMARK 读取
- **benchmark_status.txt** → BENCHMARK 写入，其他组件读取

---

## 📚 相关文档

1. **slurm_run.sh 详解：** `jenkins_test/docs/SLURM_RUN_DETAILED_EXPLANATION.md`
2. **submit.py 参数：** `jenkins_test/docs/SUBMIT_PY_PARAMS_EXPLAINED.md`
3. **最终总结：** `jenkins_test/docs/DISAGG_FINAL_SUMMARY.md`

---

**现在完全理解整个流程了吗？从头到尾，每个参数如何传递，每个脚本如何调用！** 🚀
