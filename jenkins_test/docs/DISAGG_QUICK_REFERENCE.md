# Disagg 测试关键问题快速参考

> 三个核心问题的快速查找表和实施指南

---

## 📊 问题 1: pytestCommand 差异速查表

### 三种命令对比

| 维度 | pytestCommandWorker | pytestCommandDisaggServer | pytestCommandBenchmark |
|------|---------------------|---------------------------|------------------------|
| **使用组件** | GEN_0, GEN_1, CTX_0, CTX_1 | DISAGG_SERVER | BENCHMARK |
| **llmapi-launch** | ✅ 使用 | ❌ 不使用 | ❌ 不使用 |
| **环境变量** | `unset UCX_TLS && worker_env_var` | `server_env_var` | `benchmark_env_var` |
| **实际命令** | `trtllm-llmapi-launch pytest ...` | `pytest ...` | `pytest ...` |
| **行为** | 启动推理服务器，等待 benchmark_status | 启动协调服务器，等待 benchmark_status | 运行 benchmark，创建 benchmark_status |
| **返回输出** | 空列表 | 空列表 | 性能数据 |

### 关键代码位置

```python
# submit.py (248-250 行)
export pytestCommandWorker="unset UCX_TLS && ${worker_env_vars} $pytestCommand"
export pytestCommandDisaggServer="${server_env_vars} $pytestCommandNoLLMAPILaunch"
export pytestCommandBenchmark="${env_config["benchmark_env_var"]} $pytestCommandNoLLMAPILaunch"

# test_perf_sanity.py (682-783 行)
def run_cmd(self, server_idx: int):
    if "CTX" in self.disagg_serving_type or "GEN" in self.disagg_serving_type:
        # 启动 server，生成 hostname，等待 benchmark_status
    elif self.disagg_serving_type == "DISAGG_SERVER":
        # 生成 server_config，启动协调服务器，等待 benchmark_status
    elif self.disagg_serving_type == "BENCHMARK":
        # 等待 server 就绪，运行 benchmark，创建 benchmark_status
```

---

## 📊 问题 2: 跳过性能检查速查表

### 三种方案对比

| 方案 | 实施难度 | 灵活性 | 向后兼容 | 推荐度 |
|------|---------|--------|---------|--------|
| **环境变量控制** | ⭐ 简单 | ⭐⭐⭐ 高 | ✅ 是 | ⭐⭐⭐ 推荐 |
| **stageName 判断** | ⭐⭐ 中等 | ⭐⭐ 中 | ✅ 是 | ⭐⭐ 可用 |
| **独立脚本** | ⭐⭐⭐ 复杂 | ⭐⭐⭐ 高 | ✅ 是 | ⭐ 备选 |

### 推荐方案：环境变量控制

**一行修改 - run_disagg_test.sh:**

```bash
# 在 slurm_launch_prefix.sh 中添加
export SKIP_PERF_CHECK=${SKIP_PERF_CHECK:-false}
```

**一行修改 - slurm_run.sh (129 行):**

```bash
# 修改前
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ]; then

# 修改后
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ] && [ "$SKIP_PERF_CHECK" != "true" ]; then
```

**使用:**

```bash
# L0 性能测试（执行性能检查）
export SKIP_PERF_CHECK=false
bash run_disagg_test.sh

# 功能测试（跳过性能检查）
export SKIP_PERF_CHECK=true
bash run_disagg_test.sh
```

---

## 📊 问题 3: 日志收集速查表

### 当前日志位置 vs 理想日志位置

| 日志类型 | 当前位置 | 理想位置 | 问题 |
|---------|---------|---------|------|
| 所有日志 | `$jobWorkspace/` | `$WORKSPACE/disagg_logs/${CONFIG_NAME}/` | ❌ 多个测试会覆盖 |
| Slurm 日志 | `$WORKSPACE/slurm_%j.log` | `$WORKSPACE/disagg_logs/${CONFIG_NAME}/slurm_%j.log` | ❌ 不按 case 分类 |
| Benchmark 日志 | ❌ 没有 | `$WORKSPACE/disagg_logs/${CONFIG_NAME}/benchmark.log` | ❌ 缺失 |

### 推荐方案：修改 jobWorkspace 路径

**修改位置 1 - run_disagg_test.sh (步骤 4.2):**

```bash
# 修改前
export jobWorkspace=$WORKSPACE/disagg_workspace

# 修改后
export jobWorkspace=$WORKSPACE/disagg_logs/${CONFIG_NAME}
mkdir -p $jobWorkspace  # 确保目录存在
```

**修改位置 2 - SBATCH 输出路径:**

```bash
# 修改前
#SBATCH --output=$WORKSPACE/slurm_%j.log

# 修改后
#SBATCH --output=$WORKSPACE/disagg_logs/${CONFIG_NAME}/slurm_%j.log
```

**修改位置 3 - pytest 输出路径:**

```bash
# 修改前
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=$WORKSPACE/results.xml"

# 修改后
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[...] -vv --junit-xml=\$jobWorkspace/results.xml"
```

### 效果对比

**修改前:**
```
$WORKSPACE/
├── slurm_12345.log
├── slurm_12346.log
└── disagg_workspace/
    ├── install.log          ← 最新的测试覆盖
    ├── gen_server_0.log     ← 最新的测试覆盖
    └── ...
```

**修改后:**
```
$WORKSPACE/
└── disagg_logs/
    ├── deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX/
    │   ├── slurm_12345.log
    │   ├── install.log
    │   ├── gen_server_0.log
    │   ├── ctx_server_0.log
    │   ├── disagg_server.log
    │   ├── benchmark.log       ← 新增（需要额外修改）
    │   ├── results.xml
    │   └── perf_script_test_results.csv
    │
    └── llama3_8b_tp4_pp2/
        ├── slurm_12346.log
        └── ...
```

---

## 🔧 实施检查清单

### 问题 1: pytestCommand 差异
- [ ] 理解三种命令的差异
- [ ] 理解 DISAGG_SERVING_TYPE 的作用
- [ ] 理解 test_perf_sanity.py 的分流逻辑
- [ ] ✅ **无需修改代码，理解即可**

### 问题 2: 跳过性能检查
- [ ] 在 `run_disagg_test.sh` 添加 `export SKIP_PERF_CHECK=${SKIP_PERF_CHECK:-false}`
- [ ] 在 `slurm_run.sh` 第 129 行添加条件 `&& [ "$SKIP_PERF_CHECK" != "true" ]`
- [ ] 在 Jenkins 中设置环境变量
- [ ] 测试功能测试（`SKIP_PERF_CHECK=true`）
- [ ] 测试 L0 性能测试（`SKIP_PERF_CHECK=false`）

### 问题 3: 日志收集
- [ ] 修改 `run_disagg_test.sh` 的 `jobWorkspace` 路径
- [ ] 修改 SBATCH `--output` 路径
- [ ] 修改 `pytestCommand` 的 `--junit-xml` 路径
- [ ] 修改 `coverageConfigFile` 路径
- [ ] 测试运行并检查日志位置
- [ ] （可选）添加 benchmark.log 重定向

---

## 📚 完整文档索引

| 文档 | 位置 | 内容 |
|------|------|------|
| **三个关键问题详解** | `jenkins_test/docs/DISAGG_THREE_KEY_QUESTIONS.md` | 本问题的详细解答 |
| **slurm_run.sh 逐行讲解** | `jenkins_test/docs/SLURM_RUN_DETAILED_EXPLANATION.md` | slurm_run.sh 的每一行代码解释 |
| **完整执行流程图** | `jenkins_test/docs/DISAGG_EXECUTION_FLOW_DIAGRAM.md` | 从 Jenkins 到 pytest 的完整链路 |
| **submit.py 参数详解** | `jenkins_test/docs/SUBMIT_PY_PARAMS_EXPLAINED.md` | 9 个参数的详细说明 |
| **最终总结** | `jenkins_test/docs/DISAGG_FINAL_SUMMARY.md` | 完整流程和检查清单 |

---

## 💡 常见问题

### Q1: 为什么 Worker 需要 llmapi-launch？

**A:** 因为 GEN/CTX 是真正的推理服务器，需要：
- 初始化 GPU 和 CUDA 环境
- 设置 MPI 进程间通信
- 加载 TensorRT-LLM 模型
- 配置内存和缓存

`trtllm-llmapi-launch` 封装了这些初始化逻辑。

### Q2: 性能检查失败会导致测试失败吗？

**A:** 是的。在 `slurm_run.sh` 的最终退出码逻辑中（156-164 行）：

```bash
if [ "$pytest_exit_code" -ne 0 ]; then
    final_exit_code=$pytest_exit_code
elif [ "$perf_check_exit_code" -ne 0 ]; then
    final_exit_code=$perf_check_exit_code  # ← 性能检查失败也会失败
else
    final_exit_code=0
fi
```

所以如果不需要性能检查，务必跳过它。

### Q3: 如何快速查看某个 case 的日志？

**A:** 实施日志收集方案后：

```bash
# 查看所有日志
ls -lh $WORKSPACE/disagg_logs/${CONFIG_NAME}/

# 查看 benchmark 日志
cat $WORKSPACE/disagg_logs/${CONFIG_NAME}/benchmark.log

# 查看性能结果
cat $WORKSPACE/disagg_logs/${CONFIG_NAME}/perf_script_test_results.csv

# 打包所有日志
tar -czf logs.tar.gz -C $WORKSPACE/disagg_logs ${CONFIG_NAME}
```

### Q4: 如何调试 DISAGG_SERVER 启动失败？

**A:** 检查这些日志（按顺序）：

1. **install.log** - 检查安装是否成功
2. **gen_server_0.log / ctx_server_0.log** - 检查 worker 是否启动
3. **disagg_server.log** - 检查协调服务器错误
4. **Slurm 作业日志** - 检查资源分配和环境变量

### Q5: 如何验证日志收集方案是否生效？

**A:** 运行两个不同的 case，检查是否有独立目录：

```bash
# 运行第一个 case
bash run_disagg_test.sh deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX

# 运行第二个 case
bash run_disagg_test.sh llama3_8b_tp4_pp2

# 验证
ls -lh $WORKSPACE/disagg_logs/
# 应该看到两个独立目录
```

---

**所有问题都有清晰的答案和实施方案！需要我帮忙实施任何修改吗？** 🚀
