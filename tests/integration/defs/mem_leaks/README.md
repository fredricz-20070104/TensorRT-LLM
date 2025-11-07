# Memory Leak Debugging Tools

本目录包含用于调试 TensorRT-LLM Disaggregated 模式内存泄漏的工具和脚本。

## 📋 目录结构

```
mem_leaks/
├── README.md                          # 本文件
├── debug_memory_leak_auto.sh          # 方案1：全自动 sbatch 脚本
└── debug_memory_leak_interactive.sh   # 方案2：交互式调试脚本
```

## 🎯 测试目标

在单节点 4GPU 环境中：
1. 使用 valgrind 监控 trtllm-serve 的内存使用
2. 运行 sglang benchmark 进行压力测试
3. 收集和分析内存泄漏数据

## 📦 方案对比

| 特性 | 方案1（自动化） | 方案2（交互式） |
|------|----------------|----------------|
| **自动化程度** | 全自动 | 手动分步执行 |
| **灵活性** | 低（需修改脚本） | 高（随时调整） |
| **日志管理** | 自动整理 | 手动查看 |
| **适用场景** | 生产测试、无人值守 | 开发调试、探索 |
| **重入能力** | 支持（srun --jobid） | 原生支持 |
| **学习曲线** | 低 | 中（需了解screen） |

## 🚀 方案1：全自动 sbatch 脚本

### 特点
- 提交后无需人工干预
- 自动安装依赖、启动服务、运行压测
- 所有日志自动保存
- 可通过 `srun --jobid` 重入查看

### 使用方法

```bash
# 1. 提交任务
cd /lustre/fsw/portfolios/coreai/users/fredricz/tensorrt_llm/tests/integration/defs/perf/disagg/mem_leaks
sbatch debug_memory_leak_auto.sh

# 2. 查看任务状态
squeue -u $USER

# 3. 查看实时输出
tail -f debug-memory-leak-auto-<JOBID>.out

# 4. 重入容器查看（任务运行中）
srun --jobid=<JOBID> --overlap --pty bash

# 5. 查看结果
ls -lh /lustre/fsw/portfolios/coreai/users/fredricz/output/debug_memory_leak_<JOBID>/
```

### 输出文件

```
$OUTPUT_PATH/debug_memory_leak_<JOBID>/
├── valgrind-*.log          # Valgrind 内存泄漏报告
├── trtllm_serve.log        # 服务器运行日志
├── benchmark.log           # Benchmark 结果
├── install_valgrind.log    # Valgrind 安装日志
├── install_sglang.log      # SGLang 安装日志
├── step1_install.log       # 安装步骤总日志
└── final_gpu_memory.csv    # 最终 GPU 内存使用
```

### 查看内存泄漏

```bash
# 查看泄漏摘要
grep "LEAK SUMMARY" /path/to/debug_memory_leak_<JOBID>/valgrind-*.log

# 查看详细泄漏信息
less /path/to/debug_memory_leak_<JOBID>/valgrind-*.log

# 查看 benchmark 结果
tail /path/to/debug_memory_leak_<JOBID>/benchmark.log
```

## 🔧 方案2：交互式调试脚本

### 特点
- 完全交互式控制
- 使用 screen 管理后台服务
- 可随时调整参数
- 适合探索性测试

### 使用方法

```bash
# 1. 启动交互式会话
cd /lustre/fsw/portfolios/coreai/users/fredricz/tensorrt_llm/tests/integration/defs/perf/disagg/mem_leaks
bash debug_memory_leak_interactive.sh

# 2. 进入容器后，按照提示执行
[DEBUG] $ setup_deps        # 安装依赖
[DEBUG] $ start_server      # 启动服务（后台 + screen）
[DEBUG] $ run_benchmark     # 运行压测
[DEBUG] $ check_logs        # 查看结果
```

### 内置命令

| 命令 | 说明 |
|------|------|
| `setup_deps` | 安装 valgrind 和 sglang |
| `start_server` | 在 screen 中启动 trtllm-serve + valgrind |
| `run_benchmark` | 运行 sglang benchmark |
| `check_gpu` | 查看 GPU 内存使用 |
| `check_logs` | 查看日志摘要 |
| `help` | 显示帮助信息 |

### Screen 会话管理

```bash
# 查看所有 screen 会话
screen -ls

# 连接到服务器会话（查看实时输出）
screen -r trtllm-server

# 从 screen 中分离（服务继续运行）
# 按 Ctrl+A, 然后按 D

# 终止服务器会话
screen -X -S trtllm-server quit
```

### 多终端工作流

**终端1：主控制**
```bash
[DEBUG] $ setup_deps
[DEBUG] $ start_server
[DEBUG] $ run_benchmark
```

**终端2：监控（可选）**
```bash
# 在另一个窗口重入同一容器
srun --jobid=<JOBID> --overlap --pty bash
[DEBUG] $ watch -n 1 check_gpu
```

**终端3：查看日志（可选）**
```bash
[DEBUG] $ screen -r trtllm-server  # 实时查看服务器输出
```

## 🔍 故障排查

### 问题1：依赖安装失败

**症状**：valgrind 或 sglang 安装报错

**解决**：
```bash
# 检查网络连接
curl -I https://pypi.org

# 手动安装
apt-get update && apt-get install -y valgrind
pip install --no-cache-dir sglang --index-url https://pypi.org/simple
```

### 问题2：服务器启动超时

**症状**：等待 300 秒后提示 "Server failed to start"

**解决**：
```bash
# 方案1：查看服务器日志
tail -f $LOG_DIR/trtllm_serve.log

# 方案2：重入容器手动启动
srun --jobid=<JOBID> --overlap --pty bash
# 不用 valgrind 先测试
trtllm-serve $MODEL_DIR/gpt-oss-120b --trust_remote_code --tp_size 4 --ep_size 1 --backend pytorch
```

### 问题3：MPI spawn 失败

**症状**：`mpi4py.MPI.Exception: MPI_ERR_SPAWN`

**原因**：任务数不足

**解决**：
```bash
# 确保 -n 参数 >= GPU 数量
srun -N1 -n4 --ntasks-per-node=4 --gres=gpu:4 ...
```

### 问题4：Valgrind 速度太慢

**症状**：服务启动需要超过 10 分钟

**解决**：
- Valgrind 会降低 10-50 倍性能，这是正常的
- 如果无法接受，考虑使用 Python tracemalloc：
  ```bash
  python3 -X tracemalloc=25 $(which trtllm-serve) ...
  ```

### 问题5：SGLang 安装失败

**症状**：`torch_memory_saver` 编译错误

**解决**：
```bash
# 只安装基础版本
pip install --no-deps sglang
pip install requests aiohttp fastapi uvicorn
```

## 📊 分析结果

### 查看 Valgrind 内存泄漏报告

```bash
# 泄漏摘要
grep -A 10 "LEAK SUMMARY" valgrind-*.log

# 查找确定的内存泄漏
grep "definitely lost" valgrind-*.log

# 查找可能的内存泄漏
grep "possibly lost" valgrind-*.log

# 查看泄漏的调用栈
grep -A 20 "by 0x" valgrind-*.log | less
```

### GPU 内存分析

```bash
# 查看最终 GPU 内存
cat final_gpu_memory.csv

# 对比初始和最终内存
nvidia-smi --query-gpu=index,memory.used --format=csv
```

### Benchmark 性能分析

```bash
# 查看吞吐量和延迟
tail -50 benchmark.log | grep -E "throughput|latency|requests"
```

## ⚙️ 自定义配置

### 修改测试参数

编辑脚本中的配置变量：

```bash
# 模型路径
MODEL_DIR="/lustre/fs1/.../common"

# GPU 配置
--tp_size 4        # Tensor Parallel 大小
--ep_size 1        # Expert Parallel 大小

# Benchmark 配置
--num-prompt 40980      # 请求总数
--max-concurrency 8196  # 最大并发数
--random-input 1024     # 输入 token 数
--random-output 1024    # 输出 token 数
```

### 调整时间限制

```bash
# sbatch 脚本中
#SBATCH --time=04:00:00  # 改为 08:00:00 延长到 8 小时

# 服务器启动超时（方案1）
MAX_WAIT=300  # 改为 600 延长到 10 分钟
```

## 📚 相关文档

- [TensorRT-LLM Disaggregated 文档](../../examples/disaggregated/slurm/benchmark/README.md)
- [SLURM 用户手册](https://slurm.schedmd.com/)
- [Valgrind 用户手册](https://valgrind.org/docs/manual/quick-start.html)
- [SGLang Benchmark 文档](https://github.com/sgl-project/sglang)

## 💡 最佳实践

1. **首次测试**：使用方案2（交互式）先验证环境和配置
2. **正式测试**：使用方案1（自动化）进行长时间测试
3. **并行测试**：可以同时提交多个不同配置的任务
4. **日志保留**：定期清理旧日志，保留最近的测试结果
5. **资源预约**：对于长时间测试，考虑使用 `salloc` 预约资源

## 🐛 已知问题

1. **Valgrind + MPI**：可能产生大量误报，需要过滤
2. **Python 内存**：Python 解释器本身会有内存分配，需要区分
3. **CUDA 内存**：Valgrind 主要检测 CPU 内存，GPU 内存需要其他工具
4. **性能开销**：Valgrind 会显著降低性能，影响 benchmark 结果

## 📞 支持

如有问题，请联系：
- 项目维护者
- 或在项目仓库提交 Issue

