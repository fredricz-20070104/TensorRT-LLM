# Disagg Perf 测试稳定性优化提案

> 目标：让 disagg perf sanity 测试输出的 **Total Token Throughput**、**Output token throughput**（e2e case）以及 **prev_device_step_time**（gen_only case）更稳定，降低 run-to-run 抖动带来的误报回归。
>
> 本文基于对 TensorRT-LLM 计量链路的源码分析，供开发一起审阅。所有结论均带 `file:line` 出处，方便核对。

---

## 1. 背景：这三个数是怎么算出来的

### 1.1 Total Token Throughput / Output token throughput

计量公式在 `tensorrt_llm/serve/scripts/benchmark_serving.py:246-249`：

```python
output_throughput      = sum(actual_output_lens) / dur_s
total_token_throughput = (total_input + sum(actual_output_lens)) / dur_s
```

分母 `dur_s` 在 `benchmark_serving.py:473`：

```python
benchmark_duration = time.perf_counter() - benchmark_start_time
```

即 **"第一个请求发出 → 最后一个请求收完" 的整段墙钟时间**。

分子（token 总数）在 ISL/OSL 固定时几乎是常数，因此：

> **吞吐的抖动 ≈ 100% 来自分母 `dur_s` 的抖动。**

测试喂请求的方式（`tests/integration/defs/perf/test_perf_sanity.py:934-936` + disagg yaml）：

- `num_prompts = concurrency × iterations`，其中 `iterations = multi_round`（e2e）
  （`test_perf_sanity.py:1857-1859`）
- `--max-concurrency <concurrency>` → 请求按并发度串行/并行发出
- 默认带 `--no-test-input`（`test_perf_sanity.py:938`），**关闭了 warmup 请求**
  （对照 `benchmark_serving.py:321-351`）

以 `gb200_deepseek-r1-fp4_8k1k_con1_...` 为例：`concurrency=1`、`multi_round=10` → **10 个请求完全串行**，且**无 warmup**。

### 1.2 gen_only 的 prev_device_step_time

数据源在引擎，用两个 CUDA event 测的**纯 GPU forward 耗时**：
`tensorrt_llm/_torch/pyexecutor/py_executor.py:1682-1693`。

测试侧聚合已有较完善的降噪（`test_perf_sanity.py:172-315`）：

- `iter < 5` 全丢：iter 0/1 含 KV cache transfer 等待，iter 2-4 为 warmup
- 按 `num_generation_tokens` 分桶，只取样本最多的桶（mode），避开尾部批次缩小干扰
- 桶内 Welford **均值**，再跨 gen worker 求平均

---

## 2. 根因分析：用"相位分解"看问题

一次请求的生命周期可切成多个**相位**（disagg 场景约 11 段：`disagg_preprocessing → ctx_queue → ctx_processing → disagg_relay → gen_kv_transfer → gen step forward → ...`）。同一个 e2e 抖动，落在不同相位，根因完全不同：

| 抖动落在 | 根因方向 | 性质 |
|---|---|---|
| `*_queue` / `gen_queue_wait` | 调度 / 负载 / batch 波动 | 测试环境噪声 |
| `disagg_relay` / `*_preprocessing` | 框架 IPC / HTTP / 网络 | 噪声 |
| `gen_kv_transfer` | KV 传输 / NIXL-UCX | 半噪声 |
| `ctx_processing` / **step forward** | 真实 kernel / 计算 | **真回归** |

**核心问题**：

- **吞吐 `token / dur_s`**：`dur_s` 是一整段墙钟，把上表**所有相位（噪声相位 + 计算相位）压进同一个分母**。我们想测的"计算性能"被 queue / relay / kv_transfer / 冷启动等噪声相位污染 → 天然不稳。
- **`prev_device_step_time`**：只测 step-forward **一个计算相位**，天生把噪声相位排除在外 → 因此本来就比吞吐稳。

> **优化总纲：把噪声相位从计量里剔除，只保留计算相位。**

### 2.1 具体不稳来源

1. **无 warmup 的冷启动开销**（最大来源）
   `--no-test-input` 关掉了预热。第 1 个请求要付：CUDA graph capture、首个 KV block 分配、disagg KV transfer 建链、调度器首次排队。这笔一次性开销被完整摊进 `dur_s`。

2. **样本量太小，固定开销权重高**
   con=1、multi_round=10 时，冷启动开销权重高达 `1/10`。它抖 200ms，整体吞吐就抖 ~2%。

3. **均值对尖刺敏感**
   `prev_device_step_time` 桶内用 mean（`test_perf_sanity.py:229`），单次 CUDA graph fallback / batch 拼接的 step 尖刺会拉高均值。

4. **分子/批次抖动**
   spec-decode 的 accept 数决定 OSL 与 `num_generation_tokens`；若不锁定，分子和分桶都会漂。

### 2.2 举例

ISL=8192、OSL=1024、10 请求串行，单请求稳态 ≈ 1.0s：

- 正常：`dur_s = 10.0s` → `10×1024 / 10.0 = 1024 tok/s`
- 首请求碰上 KV transfer 建链慢 + 首步 graph capture 多花 0.3s：`dur_s = 10.3s` → `994 tok/s`，**掉 3%**

分子没变，纯粹是分母被一次性冷启动 + 网络抖动带偏。样本越少，抖得越狠。

---

## 3. 优化方案（按性价比排序）

### 方案 1 — Warmup / 丢弃前 N 个请求 ✅ P0

现状 `--no-test-input` 关闭了 warmup。建议：

- **简单版**：去掉 `--no-test-input`，让 benchmark 先打一个不计入统计的 test 请求预热（`benchmark_serving.py:330-351`）。对 con=1 帮助有限（只热身一次）。
- **稳健版（推荐）**：引入 **ramp-up 丢弃**——多发几个请求，`dur_s` 和 token 只统计"第 K 个之后"的稳态请求。等价于把 `prev_device_step_time` 里 `iter<5 全丢` 的思路搬到 e2e 吞吐上。

### 方案 2 — 增大样本量稀释固定开销 ✅ P0

对 con 小的 case，把 `multi_round` 从 10 提到 30~50。冷启动权重从 `1/10` 降到 `1/50`，抖动约除以 5。代价是测试时间变长，对短 case 可接受。

### 方案 3 — 用引擎侧"相位吞吐"替代墙钟吞吐 ✅ P1（最治本）

既然已能拿到 `prev_device_step_time`（纯 decode step GPU 时间）和 `num_generation_tokens`，可直接算不含噪声相位的 decode 吞吐：

```
decode_throughput (tok/s) = num_generation_tokens / (prev_device_step_time_ms / 1000)
```

该指标只依赖计算相位，天然排除排队 / KV 传输 / HTTP / 冷启动。可作为 e2e case 的**稳定版陪跑指标**，回归判定优先看它。实现上复用 gen_only 已有的扫描逻辑（`test_perf_sanity.py:236-257`），推广到 e2e。

### 方案 4 — median / trimmed-mean 代替 mean ✅ P1

- **吞吐侧**：`multi_round` 每轮算一个吞吐，取**中位数**入库，而非把所有请求塞进一个 `dur_s` 求总吞吐。中位数对单次冷启动/网络尖刺免疫。
- **`prev_device_step_time` 侧**：桶内 Welford 均值（`test_perf_sanity.py:229`）改成 **median 或 trimmed-mean（掐掉最高 10%）**，抗 step 尖刺。

### 方案 5 — 锁住改变分子/批次的变量 ✅ P1

- Spec-decode：保留 `TLLM_SPEC_DECODE_FORCE_NUM_ACCEPTED_TOKENS=3`（disagg yaml 已设），保证 OSL 稳定 → 分子稳、分桶稳。所有 spec case 都应保留。
- gen_only 已用 `TRTLLM_DISABLE_KV_CACHE_TRANSFER_OVERLAP=1` + `TLLM_BENCHMARK_REQ_QUEUES_SIZE=concurrency`（`jenkins/scripts/perf/local/submit.py:836-844`）固定稳态批次，即消掉 `gen_queue_wait` 相位噪声。e2e 目前无此保护，可考虑对齐。

### 方案 6 — 固定环境噪声相位 ✅ P2

`disagg_relay` / `*_preprocessing` 是 IPC/HTTP/网络开销。已按 GPU 类型设 `UCX_TLS`（`submit.py:846-851`）；配合 `numa_bind: true`、关 GC（`TRTLLM_SERVER_DISABLE_GC=1`，已设）可进一步压低网络/框架相位抖动。

---

## 4. 改动优先级汇总

| 优先级 | 改动 | 位置 | 稳定性收益 | 成本 |
|---|---|---|---|---|
| P0 | e2e 吞吐引入 **warmup 丢弃前 N 请求** | benchmark client 构造 `test_perf_sanity.py:1855-1870` | 高 | 低 |
| P0 | con 小的 case 调大 `multi_round` | 各 disagg yaml | 高 | 低（时间↑） |
| P1 | 回归判定改看 **引擎侧 decode 相位吞吐** 而非墙钟吞吐 | 新增 metric，复用 `test_perf_sanity.py:172-315` | 很高 | 中 |
| P1 | `prev_device_step_time` 桶内 mean → **median/trimmed-mean** | `test_perf_sanity.py:227-230` | 中 | 低 |
| P1 | e2e 对齐 gen_only 的批次/queue 固定 env | `submit.py:836` | 中 | 低 |
| P2 | 多轮吞吐取 **median** 入库 | 结果聚合处 | 中 | 低 |
| P2 | 固定 UCX/NUMA/GC 环境相位 | `submit.py:846-851` + yaml | 低-中 | 低 |

---

## 5. 核心结论

> 吞吐 = `token / dur_s`，而 `dur_s` 是一整段墙钟，把全部相位（含冷启动、排队、KV 传输、HTTP 等噪声相位）都压进了分母。想让它稳，就做**相位分解**、把噪声相位从计量里剔掉——三招：
>
> 1. **warmup 丢首请求**（去冷启动相位）
> 2. **多样本取中位**（抗尖刺）
> 3. **直接用引擎侧 step-forward 相位算吞吐**（只留计算相位）
>
> `prev_device_step_time` 本来就比吞吐稳，正因为它天生只测 step-forward 一个相位。把这套做法复制到吞吐指标上即可。

---

## 6. 待讨论 / Open Questions

- 方案 3 的 "engine-side decode throughput" 作为**主回归指标**还是**陪跑指标**？主指标需要重建历史 baseline。
- warmup 丢弃的 N 取多少？建议与 `prev_device_step_time` 的 `iter<5` 对齐（即丢前 5 个稳态请求），需在 con=1 的短 case 上验证样本是否够。
- `multi_round` 调大对总 CI 时间的影响预算？
- median vs trimmed-mean：是否统一到一种口径，避免 e2e 与 gen_only 计量方法分叉。
