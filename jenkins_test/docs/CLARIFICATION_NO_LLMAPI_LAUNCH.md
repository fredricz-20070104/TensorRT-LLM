# 澄清：test_perf_sanity.py 不使用 trtllm-llmapi-launch

> **重要发现：你是对的！test_perf_sanity.py 确实没有使用 trtllm-llmapi-launch！**

---

## 🎯 核心发现

### test_perf_sanity.py 使用 `trtllm-serve` 而不是 `trtllm-llmapi-launch`

**代码证据（test_perf_sanity.py:250-258）：**

```python
def to_cmd(
    self, output_dir: str, numa_bind: bool = False, disagg_serving_type: str = ""
) -> List[str]:
    """Generate server command."""
    model_dir = get_model_dir(self.model_name)
    self.model_path = model_dir if os.path.exists(model_dir) else self.model_name
    config_filename = f"extra-llm-api-config.{self.disagg_run_type}.{self.name}.yml"
    config_path = os.path.join(output_dir, config_filename)

    numa_bind_cmd = []
    if numa_bind:
        numa_bind_cmd = ["numactl", "-m 0,1"]

    cmd = numa_bind_cmd + [
        "trtllm-serve",  # ← 使用 trtllm-serve，不是 trtllm-llmapi-launch！
        self.model_path,
        "--backend",
        "pytorch",
        "--config",
        config_path,
    ]
    return cmd
```

---

## 📊 完整的启动流程分析

### disaggregated 模式下的实际执行

#### 1. slurm_launch_draft.sh 启动多个组件

```bash
# GEN servers
for ((i=0; i<$numGenServers; i++)); do
    export DISAGG_SERVING_TYPE="GEN_$i"
    export pytestCommand="$pytestCommandWorker"
    srun ... slurm_run.sh  # ← 每个 srun 启动一个 pytest 进程
done

# CTX servers  
for ((i=0; i<$numCtxServers; i++)); do
    export DISAGG_SERVING_TYPE="CTX_$i"
    export pytestCommand="$pytestCommandWorker"
    srun ... slurm_run.sh  # ← 每个 srun 启动一个 pytest 进程
done

# DISAGG_SERVER
export DISAGG_SERVING_TYPE="DISAGG_SERVER"
export pytestCommand="$pytestCommandDisaggServer"
srun ... slurm_run.sh

# BENCHMARK
export DISAGG_SERVING_TYPE="BENCHMARK"
export pytestCommand="$pytestCommandBenchmark"
srun ... slurm_run.sh
```

#### 2. 每个 slurm_run.sh 执行 pytest

```bash
# slurm_run.sh
eval $pytestCommand
# 实际执行: pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4]
```

#### 3. pytest 调用 test_perf_sanity.py::test_e2e

```python
# test_perf_sanity.py
def test_e2e(test_case_name, request):
    config = PerfSanityTestConfig(...)
    config.parse_config_file()
    commands = config.get_commands()  # ← 生成所有服务器/客户端命令
    outputs = config.run_ex(commands)  # ← 执行命令
```

#### 4. test_perf_sanity.py 根据 DISAGG_SERVING_TYPE 分支执行

**代码（test_perf_sanity.py:682-733）：**

```python
def run_cmd(self, server_idx: int) -> List[str]:
    """Run commands for a server and return outputs."""
    outputs = []
    benchmark_status_file = os.path.join(self.output_dir, f"benchmark_status.{server_idx}.txt")
    port = get_free_port()

    ctx_cmd, gen_cmd, disagg_cmd = self.server_cmds[server_idx]
    
    # 分支 1: CTX 或 GEN servers
    if "CTX" in self.disagg_serving_type or "GEN" in self.disagg_serving_type:
        self._generate_hostname_file(server_idx, port)
        server_file_path = os.path.join(
            self.output_dir, f"trtllm-serve.{server_idx}.{self.disagg_serving_type}.log"
        )
        is_ctx = "CTX" in self.disagg_serving_type
        server_cmd = ctx_cmd if is_ctx else gen_cmd
        server_cmd = add_host_port_to_cmd(server_cmd, self.hostname, port)
        try:
            print_info(
                f"Starting server. disagg_serving_type: {self.disagg_serving_type} cmd is {server_cmd}"
            )
            with open(server_file_path, "w") as server_ctx:
                # ← 直接 subprocess.Popen 启动 trtllm-serve
                server_proc = subprocess.Popen(
                    server_cmd,  # ["trtllm-serve", model_path, "--backend", "pytorch", ...]
                    stdout=server_ctx,
                    stderr=subprocess.STDOUT,
                    env=copy.deepcopy(os.environ),
                )
            self.wait_for_benchmark_ready(benchmark_status_file)
        finally:
            print_info(f"Server {self.disagg_serving_type} stopped")
            server_proc.terminate()
            server_proc.wait()

    # 分支 2: DISAGG_SERVER
    elif self.disagg_serving_type == "DISAGG_SERVER":
        disagg_server_file_path = os.path.join(
            self.output_dir, f"trtllm-serve.{server_idx}.{self.disagg_serving_type}.log"
        )
        try:
            self._generate_disagg_server_config(server_idx, port)
            print_info(f"Starting disagg server. cmd is {disagg_cmd}")
            with open(disagg_server_file_path, "w") as disagg_server_ctx:
                # ← 启动协调器
                disagg_server_proc = subprocess.Popen(
                    disagg_cmd,  # ["trtllm-serve-coordinator", ...]
                    stdout=disagg_server_ctx,
                    stderr=subprocess.STDOUT,
                    env=copy.deepcopy(os.environ),
                )
            self.wait_for_benchmark_ready(benchmark_status_file)
        finally:
            print_info(f"Disagg server {self.disagg_serving_type} stopped")
            disagg_server_proc.terminate()
            disagg_server_proc.wait()

    # 分支 3: BENCHMARK
    elif self.disagg_serving_type == "BENCHMARK":
        try:
            disagg_server_hostname, disagg_server_port = (
                self._get_disagg_server_hostname_and_port(server_idx)
            )
            # 等待所有服务器启动
            wait_for_endpoint_ready(
                f"http://{disagg_server_hostname}:{disagg_server_port}/health",
                timeout=self.timeout,
                check_files=server_files,
            )

            # 运行 benchmark 客户端
            for client_cmd in self.client_cmds[server_idx]:
                client_cmd_with_port = add_host_port_to_cmd(
                    client_cmd, disagg_server_hostname, disagg_server_port
                )
                print_info(f"Starting benchmark. cmd is {client_cmd_with_port}")

                # ← 直接运行 benchmark_serving.py
                output = subprocess.check_output(
                    client_cmd_with_port,  # ["python", "-m", "tensorrt_llm.serve.scripts.benchmark_serving", ...]
                    env=copy.deepcopy(os.environ),
                    stderr=subprocess.STDOUT,
                ).decode()

                outputs.append(output)

            # 通知所有服务器可以退出了
            with open(benchmark_status_file, "w") as f:
                f.write("done\n")
```

---

## 🔍 关键区别：trtllm-serve vs trtllm-llmapi-launch

### trtllm-llmapi-launch（L0_Test.groovy 使用）

**用途：**
- pytest 的多进程启动器
- 用于 MPI/分布式测试框架
- 启动多个 pytest 进程，每个进程有不同的 rank

**命令格式：**
```bash
trtllm-llmapi-launch pytest test_module.py::test_func[test_case]
```

**执行流程：**
```
trtllm-llmapi-launch
  ↓ 启动 N 个 pytest 进程
  ├── Rank 0: pytest test_module.py (MASTER)
  ├── Rank 1: pytest test_module.py (WORKER)
  └── Rank N-1: pytest test_module.py (WORKER)
  ↓
每个 pytest 进程执行测试
  ↓ 测试内部可能启动 TensorRT-LLM 服务
```

**适用场景：**
- 通用的多 GPU 测试
- 需要 MPI 通信的测试
- 标准的 pytest 分布式框架

---

### trtllm-serve（test_perf_sanity.py 使用）

**用途：**
- TensorRT-LLM 的服务器启动命令
- 直接启动推理服务
- 不涉及 pytest 的多进程管理

**命令格式：**
```bash
trtllm-serve /path/to/model --backend pytorch --config extra-llm-api-config.yml
```

**执行流程：**
```
pytest test_perf_sanity.py (单个进程)
  ↓ 读取 DISAGG_SERVING_TYPE 环境变量
  ↓ 根据类型分支执行
  ├── CTX/GEN: subprocess.Popen(["trtllm-serve", model, ...])
  ├── DISAGG_SERVER: subprocess.Popen(["trtllm-serve-coordinator", ...])
  └── BENCHMARK: subprocess.check_output(["python", "-m", "benchmark_serving", ...])
```

**适用场景：**
- disaggregated 性能测试
- 每个组件独立启动
- pytest 作为编排工具，不需要多进程

---

## 🎯 为什么 test_perf_sanity.py 不需要 trtllm-llmapi-launch？

### 原因 1: Slurm 已经负责多进程管理

```bash
# slurm_launch_draft.sh 使用 srun 为每个组件启动独立的进程

# GEN_0
srun -N 1 -n $gpusPerNode ... slurm_run.sh
  ↓ DISAGG_SERVING_TYPE=GEN_0
  ↓ pytest test_perf_sanity.py
  ↓ subprocess.Popen(["trtllm-serve", ...])

# CTX_0
srun -N 1 -n $gpusPerNode ... slurm_run.sh
  ↓ DISAGG_SERVING_TYPE=CTX_0
  ↓ pytest test_perf_sanity.py
  ↓ subprocess.Popen(["trtllm-serve", ...])

# DISAGG_SERVER
srun -N 1 ... slurm_run.sh
  ↓ DISAGG_SERVING_TYPE=DISAGG_SERVER
  ↓ pytest test_perf_sanity.py
  ↓ subprocess.Popen(["trtllm-serve-coordinator", ...])

# BENCHMARK
srun -N 1 ... slurm_run.sh
  ↓ DISAGG_SERVING_TYPE=BENCHMARK
  ↓ pytest test_perf_sanity.py
  ↓ subprocess.check_output(["benchmark_serving", ...])
```

**关键：**
- ✅ 每个 `srun` 启动一个独立的 **pytest 进程**
- ✅ 每个 pytest 进程根据 `DISAGG_SERVING_TYPE` 执行不同的任务
- ✅ 不需要 `trtllm-llmapi-launch` 来管理多个 pytest 进程

---

### 原因 2: trtllm-serve 已经支持多 GPU

**trtllm-serve 内部处理：**
- 自动检测可用的 GPU（通过 `CUDA_VISIBLE_DEVICES` 或 `NVIDIA_VISIBLE_DEVICES`）
- 根据配置（TP/PP/EP）自动分配 GPU
- 不需要外部的 MPI 启动器

**示例命令：**
```bash
# Slurm 设置环境变量
export CUDA_VISIBLE_DEVICES=0,1,2,3

# 直接启动 trtllm-serve（会自动使用 4 个 GPU）
trtllm-serve /path/to/model --backend pytorch --config config.yml
```

---

### 原因 3: disaggregated 架构的特殊性

**disaggregated 架构：**
- 每个组件（GEN/CTX/DISAGG_SERVER/BENCHMARK）是**独立的进程**
- 通过 HTTP/gRPC 通信，不是通过 MPI
- 不需要共享的 pytest 多进程框架

**对比标准 aggregated 模式（L0 测试）：**
- 所有 GPU 在一个进程组中
- 需要 MPI 通信（NCCL）
- 需要 `trtllm-llmapi-launch` 来协调多个 pytest 进程

---

## 📊 两种模式的完整对比

### L0_Test.groovy 模式（Aggregated）

```
sbatch launch.sh
  ↓
srun trtllm-llmapi-launch pytest test_module.py
  ↓
trtllm-llmapi-launch 启动 8 个 pytest 进程（8 GPUs）
  ├── Rank 0 (GPU 0): pytest → 启动 TensorRT-LLM (MASTER)
  ├── Rank 1 (GPU 1): pytest → 启动 TensorRT-LLM (WORKER)
  ├── ...
  └── Rank 7 (GPU 7): pytest → 启动 TensorRT-LLM (WORKER)
  ↓
所有 GPU 在同一个推理引擎中协作（TP=8）
```

**关键：**
- 需要 `trtllm-llmapi-launch` 启动多个 pytest 进程
- 所有进程通过 MPI/NCCL 通信
- 测试代码在每个 rank 中执行

---

### test_perf_sanity.py 模式（Disaggregated）

```
sbatch launch.sh
  ↓
slurm_launch_draft.sh 启动 4 个独立的 srun
  ↓
├── srun -N 1 -n 4 pytest test_perf_sanity.py (GEN_0)
│   ↓ subprocess.Popen(["trtllm-serve", model, ...])
│   ↓ trtllm-serve 自己管理 4 个 GPU（TP=4）
│
├── srun -N 1 -n 4 pytest test_perf_sanity.py (CTX_0)
│   ↓ subprocess.Popen(["trtllm-serve", model, ...])
│   ↓ trtllm-serve 自己管理 4 个 GPU（TP=4）
│
├── srun -N 1 pytest test_perf_sanity.py (DISAGG_SERVER)
│   ↓ subprocess.Popen(["trtllm-serve-coordinator", ...])
│
└── srun -N 1 pytest test_perf_sanity.py (BENCHMARK)
    ↓ subprocess.check_output(["benchmark_serving", ...])
```

**关键：**
- **不需要** `trtllm-llmapi-launch`
- 每个 `srun` 启动一个 pytest 进程
- pytest 内部用 `subprocess.Popen` 启动服务
- `trtllm-serve` 自己管理多 GPU

---

## ✅ 结论

### 你是完全正确的！ ✅

1. **test_perf_sanity.py 确实不使用 trtllm-llmapi-launch**
   - 它使用 `trtllm-serve` 直接启动服务
   - 通过 `subprocess.Popen` 调用

2. **run_disagg_test.sh 不需要添加 trtllm-llmapi-launch**
   - 当前实现是正确的
   - 只需要简单的 `pytest` 命令

3. **两种模式的根本区别：**
   - **L0 模式**: pytest 多进程 → 需要 `trtllm-llmapi-launch`
   - **Disagg 模式**: pytest 单进程 → 内部启动多个服务 → 不需要 `trtllm-llmapi-launch`

---

## 🔧 最终的 run_disagg_test.sh 实现

### 正确的简化版（推荐）✅

```bash
# 步骤 0: 读取自定义测试模块配置
PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"

# 步骤 4.2: 生成 slurm_launch_prefix.sh
cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX
#!/bin/bash
# ... SBATCH directives ...

export pytestCommand="pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
# ↑ 不需要 trtllm-llmapi-launch！
EOFPREFIX
```

**这是正确的实现，因为：**
- ✅ test_perf_sanity.py 内部自己管理服务启动
- ✅ Slurm 的 srun 负责多进程编排
- ✅ trtllm-serve 自己管理多 GPU
- ✅ 不需要额外的 pytest 多进程框架

---

## 📚 相关文档

1. **L0 vs Disagg 对比**: `jenkins_test/docs/L0_VS_DISAGG_PYTEST_COMMAND.md`（需要更新）
2. **submit.py 逻辑**: `jenkins_test/docs/SUBMIT_PY_PYTEST_COMMAND_LOGIC.md`
3. **参数传递**: `jenkins_test/docs/SLURM_LAUNCH_PREFIX_PARAM_PASSING.md`

---

**总结：你的观察非常敏锐！test_perf_sanity.py 使用的是 `trtllm-serve`（通过 subprocess.Popen），而不是 `trtllm-llmapi-launch`。这是 disaggregated 模式的正确实现方式。** 🎯
