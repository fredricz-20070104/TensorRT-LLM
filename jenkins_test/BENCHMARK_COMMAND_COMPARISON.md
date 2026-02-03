# Benchmark 命令对比详解

> 对比 test_perf_sanity.py、run_benchmark.sh、run_benchmark_nv_sa.sh 生成的 benchmark 命令

---

## 📋 三种 Benchmark 命令来源

### 1. test_perf_sanity.py（自动化测试）
- **位置：** `tests/integration/defs/perf/test_perf_sanity.py`
- **用途：** Jenkins CI/CD 自动化性能测试
- **特点：** 集成到 pytest 框架，自动上传到 OpenSearch

### 2. run_benchmark.sh（手动测试 - Dataset 模式）
- **位置：** `examples/disaggregated/slurm/benchmark/run_benchmark.sh`
- **用途：** 手动运行 disagg 性能测试，使用真实 dataset
- **特点：** 支持多轮测试，保存详细日志

### 3. run_benchmark_nv_sa.sh（手动测试 - Random 模式）
- **位置：** `examples/disaggregated/slurm/benchmark/run_benchmark_nv_sa.sh`
- **用途：** 手动运行 disagg 性能测试，使用随机数据
- **特点：** 克隆外部 bench_serving 仓库，使用自定义脚本

---

## 🔍 命令详细对比

### test_perf_sanity.py 生成的命令

#### 完整命令示例（BENCHMARK 节点）

```bash
python -m tensorrt_llm.serve.scripts.benchmark_serving \
    --model /data/DeepSeek-R1/DeepSeek-R1-FP4 \
    --tokenizer /data/DeepSeek-R1/DeepSeek-R1-FP4 \
    --dataset-name random \
    --random-ids \
    --num-prompts 768 \
    --max-concurrency 768 \
    --random-input-len 1024 \
    --random-output-len 1024 \
    --random-range-ratio 0.0 \
    --ignore-eos \
    --percentile-metrics ttft,tpot,itl,e2el \
    --dataset-path /data/datasets/ShareGPT_V3_unfiltered_cleaned_split.json \
    --backend openai \
    --use-chat-template \
    --trust-remote-code \
    --host <disagg_server_hostname> \
    --port <disagg_server_port>
```

#### 参数来源（从 YAML 配置）

**YAML 配置示例：**

```yaml
# deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml

benchmark:
  concurrency: 768
  iterations: 1
  isl: 1024
  osl: 1024
  random_range_ratio: 0.0
  backend: openai
  use_chat_template: true
  streaming: true
  trust_remote_code: true
```

#### 代码生成逻辑（test_perf_sanity.py:388-430）

```python
class ClientConfig:
    def to_cmd(self) -> List[str]:
        """Generate benchmark command."""
        # 1. 获取模型路径
        model_dir = get_model_dir(self.model_name)
        self.model_path = model_dir if os.path.exists(model_dir) else self.model_name
        
        # 2. 获取 dataset 路径
        dataset_path = get_dataset_path()  
        # → /data/datasets/ShareGPT_V3_unfiltered_cleaned_split.json
        
        # 3. 构建基础命令
        benchmark_cmd = [
            "python",
            "-m",
            "tensorrt_llm.serve.scripts.benchmark_serving",
            "--model", self.model_path,
            "--tokenizer", self.model_path,
            "--dataset-name", "random",           # ← 固定使用 random
            "--random-ids",                        # ← 生成随机 token IDs
            "--num-prompts", str(self.concurrency * self.iterations),  # 768 * 1 = 768
            "--max-concurrency", str(self.concurrency),                 # 768
            "--random-input-len", str(self.isl),                        # 1024
            "--random-output-len", str(self.osl),                       # 1024
            "--random-range-ratio", str(self.random_range_ratio),       # 0.0
            "--ignore-eos",
            "--percentile-metrics", "ttft,tpot,itl,e2el",
        ]
        
        # 4. 可选：添加 dataset-path（如果文件存在）
        if dataset_path and os.path.exists(dataset_path):
            benchmark_cmd.append("--dataset-path")
            benchmark_cmd.append(dataset_path)
        
        # 5. 可选：backend
        if self.backend:  # openai
            benchmark_cmd.append("--backend")
            benchmark_cmd.append(self.backend)
        
        # 6. 可选：use-chat-template
        if self.use_chat_template:  # true
            benchmark_cmd.append("--use-chat-template")
        
        # 7. 可选：streaming
        if not self.streaming:  # streaming=true → 不添加 --non-streaming
            benchmark_cmd.append("--non-streaming")
        
        # 8. 可选：trust-remote-code
        if self.trust_remote_code:  # true
            benchmark_cmd.append("--trust-remote-code")
        
        return benchmark_cmd
```

#### 关键参数说明

| 参数 | 值 | 说明 |
|------|-----|------|
| `--dataset-name` | `random` | **固定使用 random 模式** |
| `--random-ids` | - | 使用随机生成的 token IDs |
| `--dataset-path` | `/data/datasets/ShareGPT_V3_unfiltered_cleaned_split.json` | ❓ **虽然设置了，但因为 `--dataset-name=random`，实际不使用** |
| `--num-prompts` | `768` | = concurrency × iterations |
| `--max-concurrency` | `768` | 并发数 |
| `--random-input-len` | `1024` | 随机输入长度 |
| `--random-output-len` | `1024` | 随机输出长度 |
| `--random-range-ratio` | `0.0` | 输入长度变化范围（0 表示固定） |
| `--backend` | `openai` | 使用 OpenAI API 格式 |
| `--use-chat-template` | - | 使用对话模板 |
| `--trust-remote-code` | - | 信任远程代码 |

#### ❓ 疑问：dataset-path 的作用

**虽然代码添加了 `--dataset-path`，但实际不会使用：**

```python
# benchmark_serving.py 的逻辑（简化）
if args.dataset_name == "random":
    # 使用随机数据生成
    prompts = generate_random_prompts(
        num_prompts=args.num_prompts,
        input_len=args.random_input_len,
        output_len=args.random_output_len,
        random_ids=args.random_ids
    )
    # ❌ 不会读取 dataset_path
elif args.dataset_name == "trtllm_custom":
    # ✅ 读取 dataset_path
    prompts = load_dataset(args.dataset_path)
```

**结论：**
- ✅ `test_perf_sanity.py` 使用 **random 模式**
- ❌ `--dataset-path` 虽然传递了，但**不会被使用**
- ✅ 数据完全随机生成

---

### run_benchmark.sh 生成的命令

#### 完整命令示例

```bash
# Warmup (如果 ucx_warmup_requests > 0)
python -m tensorrt_llm.serve.scripts.benchmark_serving \
    --model DeepSeek-R1 \
    --dataset-name random \
    --random-ids \
    --random-input-len 100 \
    --random-output-len 10 \
    --num-prompts 10 \
    --host node001 \
    --port 8000 \
    --ignore-eos \
    --non-streaming

# 实际 Benchmark
for concurrency in ${concurrency_list}; do
    python -m tensorrt_llm.serve.scripts.benchmark_serving \
        --model DeepSeek-R1 \
        --backend openai \
        --host node001 \
        --port 8000 \
        --dataset-name trtllm_custom \
        --dataset-path /data/ShareGPT_V3_unfiltered_cleaned_split.json \
        --num-prompts 768 \
        --max-concurrency 768 \
        --trust-remote-code \
        --ignore-eos \
        --no-test-input \
        --save-result \
        --result-dir /logs/concurrency_768 \
        --result-filename result.json \
        --percentile-metrics ttft,tpot,itl,e2el \
        # --non-streaming (如果 streaming=false)
done
```

#### 参数说明

| 参数 | 值 | 说明 |
|------|-----|------|
| `--dataset-name` | **`trtllm_custom`** | ✅ **使用真实 dataset** |
| `--dataset-path` | `/data/ShareGPT_V3_...` | ✅ **实际读取文件** |
| `--num-prompts` | `768` | = concurrency × multi_round |
| `--max-concurrency` | `768` | 并发数 |
| `--save-result` | - | 保存结果到文件 |
| `--result-dir` | `/logs/concurrency_768` | 结果目录 |
| `--result-filename` | `result.json` | 结果文件名 |
| `--no-test-input` | - | 不测试输入有效性 |
| `--backend` | `openai` | OpenAI API 格式 |

#### 关键差异

1. ✅ **使用真实 dataset**（`trtllm_custom`）
2. ✅ **保存详细结果**到 JSON 文件
3. ✅ **支持 UCX warmup**（预热 UCX 连接）
4. ✅ **处理 CTX/GEN 日志**（提取 ctx-only 和 gen-only 请求）

---

### run_benchmark_nv_sa.sh 生成的命令

#### 完整命令示例

```bash
# 1. 克隆外部 benchmark 仓库
git clone https://github.com/kedarpotdar-nv/bench_serving.git /tmp/bench_serving

# 2. Warmup (如果 ucx_warmup_requests > 0)
python -m tensorrt_llm.serve.scripts.benchmark_serving \
    --model DeepSeek-R1 \
    --dataset-name random \
    --random-ids \
    --random-input-len 100 \
    --random-output-len 10 \
    --num-prompts 10 \
    --host node001 \
    --port 8000 \
    --ignore-eos \
    --non-streaming

# 3. 实际 Benchmark（使用外部脚本）
for concurrency in ${concurrency_list}; do
    python /tmp/bench_serving/benchmark_serving.py \
        --model DeepSeek-R1 \
        --host node001 \
        --port 8000 \
        --dataset-name random \
        --num-prompts 768 \
        --max-concurrency 768 \
        --trust-remote-code \
        --ignore-eos \
        --random-input-len 1024 \
        --random-output-len 1024 \
        --random-range-ratio 0.0 \
        --save-result \
        --use-chat-template \
        --result-dir /logs/concurrency_768 \
        --result-filename result.json \
        --percentile-metrics ttft,tpot,itl,e2el \
        # --non-streaming (如果 streaming=false)
done
```

#### 参数说明

| 参数 | 值 | 说明 |
|------|-----|------|
| `--dataset-name` | **`random`** | ✅ **使用随机数据** |
| `--random-input-len` | `1024` | 随机输入长度 |
| `--random-output-len` | `1024` | 随机输出长度 |
| `--random-range-ratio` | `0.0` | 输入长度变化范围 |
| `--use-chat-template` | - | 使用对话模板 |
| `--save-result` | - | 保存结果 |

#### 关键差异

1. ✅ **使用外部 benchmark_serving.py**（从 GitHub 克隆）
2. ✅ **使用 random 模式**（类似 test_perf_sanity.py）
3. ✅ **支持 UCX warmup**
4. ✅ **处理 CTX/GEN 日志**

---

## 📊 三种命令对比总结

### 核心差异表

| 维度 | test_perf_sanity.py | run_benchmark.sh | run_benchmark_nv_sa.sh |
|------|---------------------|------------------|------------------------|
| **数据源** | ✅ Random | ✅ **真实 Dataset** | ✅ Random |
| **dataset-name** | `random` | `trtllm_custom` | `random` |
| **dataset-path** | ❌ 传递但不使用 | ✅ 实际使用 | ❌ 不传递 |
| **random-ids** | ✅ 是 | ❌ 否 | ❌ 否 |
| **UCX Warmup** | ❌ 否 | ✅ 是 | ✅ 是 |
| **保存结果** | ❌ 否（内存处理） | ✅ JSON 文件 | ✅ JSON 文件 |
| **日志处理** | ❌ 否 | ✅ 提取 ctx/gen only | ✅ 提取 ctx/gen only |
| **Benchmark 脚本** | 内置 | 内置 | 外部克隆 |
| **适用场景** | CI/CD 自动化 | 手动测试（真实数据） | 手动测试（随机数据） |
| **集成方式** | pytest 框架 | 独立 shell 脚本 | 独立 shell 脚本 |

---

## 🎯 关键问题解答

### Q1: test_perf_sanity.py 的 BENCHMARK 需要 dataset file 吗？

**答案：虽然传递了 `--dataset-path`，但实际不使用。**

**原因：**

```python
# test_perf_sanity.py (388-430 行)
benchmark_cmd = [
    # ...
    "--dataset-name", "random",  # ← 固定使用 random 模式
    "--random-ids",               # ← 生成随机 token IDs
    # ...
]

# 虽然添加了 dataset-path
if dataset_path and os.path.exists(dataset_path):
    benchmark_cmd.append("--dataset-path")
    benchmark_cmd.append(dataset_path)

# 但 benchmark_serving.py 的逻辑是：
# if dataset_name == "random":
#     使用随机数据，不读取 dataset_path
```

**结论：**
- ❌ **不需要** dataset file
- ✅ 数据完全随机生成
- ✅ 如果 dataset file 不存在，也不会报错

---

### Q2: 为什么 test_perf_sanity.py 要传递 dataset-path？

**可能的原因：**

1. **向后兼容**：历史代码可能曾使用 `trtllm_custom` 模式
2. **调试方便**：如果需要切换到真实数据，只需修改 `--dataset-name`
3. **代码复用**：`ClientConfig` 类可能同时用于其他测试

**实际效果：**
- ✅ 不影响测试运行
- ✅ 参数会被忽略

---

### Q3: 三种命令的性能测试结果有差异吗？

**有显著差异！**

| 维度 | Random 模式 | Dataset 模式 |
|------|-------------|--------------|
| **输入长度** | 固定或随机范围 | 真实分布 |
| **输出长度** | 固定或随机范围 | 真实分布 |
| **Token 分布** | 均匀随机 | 真实文本 |
| **性能结果** | 理想情况 | 真实场景 |
| **可重复性** | ✅ 高 | ❌ 低（依赖 dataset） |

**建议：**
- ✅ **CI/CD 自动化**：使用 random 模式（test_perf_sanity.py）
- ✅ **真实场景测试**：使用 dataset 模式（run_benchmark.sh）
- ✅ **性能对比**：两种模式都运行

---

## 📝 完整命令对比（并排）

### test_perf_sanity.py

```bash
python -m tensorrt_llm.serve.scripts.benchmark_serving \
    --model /data/DeepSeek-R1/DeepSeek-R1-FP4 \
    --tokenizer /data/DeepSeek-R1/DeepSeek-R1-FP4 \
    --dataset-name random \                          # ← Random 模式
    --random-ids \                                   # ← 随机 token IDs
    --num-prompts 768 \
    --max-concurrency 768 \
    --random-input-len 1024 \                        # ← 固定输入长度
    --random-output-len 1024 \                       # ← 固定输出长度
    --random-range-ratio 0.0 \                       # ← 无变化
    --ignore-eos \
    --percentile-metrics ttft,tpot,itl,e2el \
    --dataset-path /data/datasets/ShareGPT_V3_...json \  # ← 不使用
    --backend openai \
    --use-chat-template \
    --trust-remote-code \
    --host <disagg_server_hostname> \
    --port <disagg_server_port>
```

### run_benchmark.sh

```bash
python -m tensorrt_llm.serve.scripts.benchmark_serving \
    --model DeepSeek-R1 \
    --backend openai \
    --host node001 \
    --port 8000 \
    --dataset-name trtllm_custom \                   # ← Dataset 模式
    --dataset-path /data/ShareGPT_V3_...json \       # ← 实际使用
    --num-prompts 768 \
    --max-concurrency 768 \
    --trust-remote-code \
    --ignore-eos \
    --no-test-input \                                # ← 额外参数
    --save-result \                                  # ← 保存结果
    --result-dir /logs/concurrency_768 \             # ← 结果目录
    --result-filename result.json \                  # ← 结果文件
    --percentile-metrics ttft,tpot,itl,e2el
```

### run_benchmark_nv_sa.sh

```bash
python /tmp/bench_serving/benchmark_serving.py \    # ← 外部脚本
    --model DeepSeek-R1 \
    --host node001 \
    --port 8000 \
    --dataset-name random \                          # ← Random 模式
    --num-prompts 768 \
    --max-concurrency 768 \
    --trust-remote-code \
    --ignore-eos \
    --random-input-len 1024 \                        # ← 随机输入长度
    --random-output-len 1024 \                       # ← 随机输出长度
    --random-range-ratio 0.0 \                       # ← 无变化
    --save-result \                                  # ← 保存结果
    --use-chat-template \                            # ← 对话模板
    --result-dir /logs/concurrency_768 \             # ← 结果目录
    --result-filename result.json \                  # ← 结果文件
    --percentile-metrics ttft,tpot,itl,e2el
```

---

## 🔧 如何切换模式？

### 修改 test_perf_sanity.py 使用真实 Dataset

**方法 1: 修改代码（不推荐）**

```python
# test_perf_sanity.py (388-430 行)
def to_cmd(self) -> List[str]:
    # ...
    benchmark_cmd = [
        # ...
        "--dataset-name", "trtllm_custom",  # ← 改为 trtllm_custom
        # "--random-ids",                   # ← 删除这行
        # ...
    ]
```

**方法 2: 通过 YAML 配置（推荐）**

在 YAML 中添加 `dataset_mode` 字段：

```yaml
benchmark:
  dataset_mode: "trtllm_custom"  # ← 新增字段
  concurrency: 768
  iterations: 1
  isl: 1024
  osl: 1024
```

然后修改 `ClientConfig` 类支持这个字段：

```python
class ClientConfig:
    def __init__(self, client_config_data: dict, model_name: str, env_vars: str = ""):
        # ...
        self.dataset_mode = client_config_data.get("dataset_mode", "random")
    
    def to_cmd(self) -> List[str]:
        # ...
        benchmark_cmd = [
            # ...
            "--dataset-name", self.dataset_mode,  # ← 使用配置值
        ]
        
        if self.dataset_mode == "random":
            benchmark_cmd.append("--random-ids")
            benchmark_cmd.extend([
                "--random-input-len", str(self.isl),
                "--random-output-len", str(self.osl),
                "--random-range-ratio", str(self.random_range_ratio),
            ])
        
        # dataset-path 在两种模式下都可以添加
        if dataset_path and os.path.exists(dataset_path):
            benchmark_cmd.append("--dataset-path")
            benchmark_cmd.append(dataset_path)
```

---

## 📚 相关文档

1. **test_perf_sanity.py**: `tests/integration/defs/perf/test_perf_sanity.py`
2. **run_benchmark.sh**: `examples/disaggregated/slurm/benchmark/run_benchmark.sh`
3. **run_benchmark_nv_sa.sh**: `examples/disaggregated/slurm/benchmark/run_benchmark_nv_sa.sh`
4. **benchmark_serving.py**: `tensorrt_llm/serve/scripts/benchmark_serving.py`（内置）
5. **外部 bench_serving**: https://github.com/kedarpotdar-nv/bench_serving.git

---

## ✅ 总结

### 核心要点

1. **test_perf_sanity.py 的 BENCHMARK**
   - ✅ 使用 **random 模式**
   - ❌ **不需要** dataset file（虽然传递了路径）
   - ✅ 数据完全随机生成
   - ✅ 适合 CI/CD 自动化

2. **run_benchmark.sh**
   - ✅ 使用 **真实 dataset**（`trtllm_custom`）
   - ✅ 需要 dataset file
   - ✅ 保存详细结果
   - ✅ 适合真实场景测试

3. **run_benchmark_nv_sa.sh**
   - ✅ 使用 **random 模式**
   - ❌ 不需要 dataset file
   - ✅ 使用外部 benchmark 脚本
   - ✅ 适合快速测试

### 推荐使用场景

| 场景 | 推荐方案 | 原因 |
|------|---------|------|
| **CI/CD 自动化** | test_perf_sanity.py | 稳定、可重复、快速 |
| **真实场景评估** | run_benchmark.sh | 真实数据分布 |
| **快速验证** | run_benchmark_nv_sa.sh | 简单、快速 |
| **性能回归测试** | test_perf_sanity.py | 集成 OpenSearch |
| **对外演示** | run_benchmark.sh | 真实场景 |

---

**现在你完全清楚三种 benchmark 命令的区别了吗？** 🚀
