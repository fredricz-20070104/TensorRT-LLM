# Disagg 参数传递 - 最终正确版本

> 基于 L0_Test.groovy 的实现，完全对齐的 Jenkins disagg 测试方案

---

## ✅ 核心结论

### `submit.py` 的真实作用

**❌ 不执行测试**  
**✅ 只生成 launch 脚本**

```python
# submit.py 第 284-288 行
with open(args.launch_sh, "w") as f:
    f.write(f"{script_prefix}\n{srun_args}\n{draft_launch_content}")

print(f"Launch script generated at: {args.launch_sh}")
# ❌ 没有执行！只是生成文件
```

### 正确的流程

```
Jenkins
  → run_disagg_test.sh
    → 准备 8 个输入文件/参数
    → python3 submit.py --run-ci ... (生成 launch.sh)
    → sbatch launch.sh (提交作业)
      → slurm_launch_draft.sh 逻辑
        ├─ srun slurm_install.sh (所有节点)
        ├─ srun slurm_run.sh (GEN Server 0) &
        ├─ srun slurm_run.sh (GEN Server 1) &
        ├─ srun slurm_run.sh (CTX Server) &
        ├─ srun slurm_run.sh (DISAGG_SERVER) &
        └─ srun slurm_run.sh (BENCHMARK) ← 前台运行
          → eval $pytestCommand
            → pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-...]
```

---

## 📋 submit.py 所需的 9 个参数

### 1. `--run-ci` (标志)
**作用：** 启用 CI 模式

### 2. `--llm-src` (路径)
**作用：** TensorRT-LLM 源码路径  
**值：** `$TRTLLM_DIR`

### 3. `--test-list` (文件)
**作用：** 包含 pytest 命令的文件  
**内容：**
```
perf/test_perf_sanity.py::test_e2e[disagg_upload-CONFIG_NAME]
```

### 4. `--draft-launch-sh` (文件)
**作用：** 启动逻辑模板  
**值：** `$TRTLLM_DIR/jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`

### 5. `--launch-sh` (路径)
**作用：** 输出脚本路径  
**值：** `$WORKSPACE/slurm_launch_generated.sh`

### 6. `--run-sh` (文件)
**作用：** slurm_run.sh 路径  
**值：** `$TRTLLM_DIR/jenkins/scripts/slurm_run.sh`

### 7. `--install-sh` (文件)
**作用：** slurm_install.sh 路径  
**值：** `$TRTLLM_DIR/jenkins/scripts/slurm_install.sh`

### 8. `--script-prefix` (文件)
**作用：** SBATCH 指令和环境变量  
**内容：**
```bash
#!/bin/bash
#SBATCH --nodes=2
#SBATCH --partition=batch
#SBATCH --account=...
...
export pytestCommand="pytest ..."
export jobWorkspace=...
```

### 9. `--srun-args` (文件)
**作用：** srun 命令行参数  
**内容：**
```
--container-image=...
--container-mounts=...
--mpi=pmix
```

---

## 🔄 submit.py 的处理流程

### 输入

**从 test-list 提取配置名：**
```python
# test-list 内容: perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_...]
# 提取: deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
```

**读取配置 YAML：**
```python
config_yaml = f"{llm_src}/tests/integration/defs/perf/disagg/test_configs/disagg/perf/{config_name}.yaml"
config = yaml.safe_load(open(config_yaml))
```

**解析配置：**
- `hardware` → 节点数计算
- `worker_config` → TP/PP/CP 配置
- `environment` → 环境变量

### 处理

**添加环境变量到 script_prefix：**
```bash
export pytestCommandWorker="unset UCX_TLS && TLLM_LOG_LEVEL=INFO ... $pytestCommand"
export numCtxServers=1
export numGenServers=1
export gpusPerNode=4
export totalNodes=2
```

**添加参数到 srun_args：**
```bash
srunArgs=(
  ...原有参数...
  "--container-env=DISAGG_SERVING_TYPE"
  "--container-env=pytestCommand"
)
```

### 输出

**生成 launch.sh：**
```bash
# Part 1: script_prefix (SBATCH + 环境变量)
# Part 2: srun_args (bash 数组)
# Part 3: draft_launch_content (启动逻辑)
```

---

## 📂 YAML 配置文件的作用

### submit.py 使用的字段

```yaml
hardware:
  num_ctx_servers: 1          # ← 用于计算节点数
  num_gen_servers: 1          # ← 用于计算节点数
  gpus_per_node: 4            # ← 用于计算节点数

worker_config:
  ctx:
    tensor_parallel_size: 4   # ← 计算 gpus_per_ctx_server
    pipeline_parallel_size: 1
    context_parallel_size: 1
  gen:
    tensor_parallel_size: 8   # ← 计算 gpus_per_gen_server
    pipeline_parallel_size: 1
    context_parallel_size: 1

environment:
  worker_env_var: "..."       # ← 添加到 pytestCommandWorker
  server_env_var: "..."       # ← 添加到 pytestCommandDisaggServer
  benchmark_env_var: "..."    # ← 添加到 pytestCommandBenchmark

benchmark:
  mode: e2e                   # ← 判断是否 gen_only 模式
  concurrency_list: '1024'
```

### submit.py 不使用的字段（占位符）

```yaml
environment:
  container_mount: <container_mount>     # ❌ 不使用（从 srun-args 提供）
  container_image: <container_image>     # ❌ 不使用（从 srun-args 提供）
  model_path: <model_path>               # ❌ 不使用（pytest 硬编码）
  work_dir: <full_path_to_work_dir>     # ❌ 不使用（从 script-prefix 提供）
```

**为什么不需要填充这些占位符？**

1. **Container 参数：** 从 `--srun-args` 文件提供
2. **模型路径：** `test_perf_sanity.py` 使用 `MODEL_PATH_DICT` 硬编码
3. **工作目录：** 从 `--script-prefix` 的 `jobWorkspace` 环境变量提供

---

## 🎯 与 L0 保持一致

### L0_Test.groovy 的方式

```groovy
// 1. 生成输入文件
def scriptLaunchPrefixPathLocal = Utils.createTempLocation(pipeline, "./slurm_launch_prefix.sh")
def scriptLaunchSrunArgsPathLocal = Utils.createTempLocation(pipeline, "./slurm_srun_args.txt")
pipeline.writeFile(file: scriptLaunchPrefixPathLocal, text: scriptLaunchPrefix)
pipeline.writeFile(file: scriptLaunchSrunArgsPathLocal, text: srunArgs.join(" "))

// 2. 调用 submit.py
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

// 3. 通过 sbatch 提交生成的脚本
jobId=$(sbatch ${scriptLaunchPathNode} | awk '{print $4}')
```

### Jenkins 的方式（已修正）

```bash
# 1. 生成输入文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
echo "perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}]" > "$TEST_LIST_FILE"

SCRIPT_PREFIX_FILE="$WORKSPACE/slurm_launch_prefix.sh"
cat > "$SCRIPT_PREFIX_FILE" << 'EOF'
#!/bin/bash
#SBATCH --nodes=$TOTAL_NODES
...
export pytestCommand="pytest ..."
EOF

SRUN_ARGS_FILE="$WORKSPACE/slurm_srun_args.txt"
cat > "$SRUN_ARGS_FILE" << 'EOF'
--container-image=...
--mpi=pmix
EOF

# 2. 调用 submit.py
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

# 3. 通过 sbatch 提交生成的脚本
sbatch "$LAUNCH_SH"
```

---

## 🚨 常见问题

### Q1: 为什么不直接调用 pytest？

**A:** Disagg 需要启动多个组件（CTX/GEN/DISAGG_SERVER/BENCHMARK），每个组件都是一个独立的 srun 进程，需要复杂的协调逻辑，这些逻辑在 `slurm_launch_draft.sh` 中实现。

### Q2: submit.py 为什么这么复杂？

**A:** 它需要：
1. 从多个输入源收集信息
2. 解析 YAML 配置文件
3. 计算硬件资源
4. 生成环境变量
5. 组装最终的 launch 脚本

### Q3: 可以简化吗？

**A:** 可以，但会失去与 L0 的一致性。L0 已经在生产环境稳定运行，保持一致可以：
- 复用已验证的逻辑
- 减少维护成本
- 避免重复踩坑

### Q4: test_disagg.py 和 test_perf_sanity.py 的区别？

**区别：**

| 特性 | test_disagg.py | test_perf_sanity.py |
|------|----------------|---------------------|
| 依赖管理 | Poetry | pip/venv |
| Slurm 提交 | 测试内部提交 | 外部 sbatch + submit.py |
| 环境变量 | `--disagg` 参数 | `DISAGG_SERVING_TYPE` |
| 使用场景 | GitLab CI | L0 Jenkins |

**为什么选择 test_perf_sanity.py？**
- ✅ 与 L0 保持一致
- ✅ 统一的测试框架（aggr/multi-agg/disagg）
- ✅ 更好的 CI/CD 集成

---

## ✅ 最终检查清单

部署前确认：

**环境变量：**
- [ ] `CLUSTER_PARTITION` 已设置
- [ ] `CLUSTER_ACCOUNT` 已设置
- [ ] `DOCKER_IMAGE` 已设置
- [ ] `CLUSTER_LLM_DATA` 已设置
- [ ] `MPI_TYPE` 已设置（默认 pmix）

**文件路径：**
- [ ] `TRTLLM_DIR` 指向正确的仓库根目录
- [ ] `WORKSPACE` 目录存在且可写
- [ ] 以下文件存在：
  - `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`
  - `jenkins/scripts/perf/disaggregated/submit.py`
  - `jenkins/scripts/slurm_run.sh`
  - `jenkins/scripts/slurm_install.sh`

**配置文件：**
- [ ] `CONFIG_NAME` 对应的 YAML 文件存在
- [ ] YAML 文件包含所需的 `hardware`, `worker_config`, `environment`, `benchmark` 部分

**测试运行：**
- [ ] 先用 `--dry-run` 测试
- [ ] 检查生成的 launch.sh 内容
- [ ] 确认环境变量正确导出
- [ ] 确认 srun 参数正确

---

## 📚 相关文档

1. **参数详解：** `jenkins_test/docs/SUBMIT_PY_PARAMS_EXPLAINED.md`
2. **完整流程：** `jenkins_test/docs/DISAGG_PARAM_FLOW_CORRECTED.md`
3. **快速参考：** `jenkins_test/docs/DISAGG_QUICK_REF_v2.md`

---

**现在完全对齐 L0 了！准备好测试了吗？** 🚀
