我已经把相关代码都看过了。这份 PDF 里的 8 个问题，本质是让我把 `Disagg_Perf_Optimization.md` 里那些结论讲透。下面逐条讲清楚，都带代码出处。

---

## 问题 1：`sum(actual_output_lens)` 是怎么算的？是数组吗？为什么这么算

**是数组。** `actual_output_lens` 是一个 **list**，长度 = 完成的请求数，每个元素是**那一个请求实际生成了多少个 output token**。

看 [benchmark_serving.py:248-249](tensorrt_llm/serve/scripts/benchmark_serving.py#L248-L249)：

```python
output_throughput      = sum(actual_output_lens) / dur_s
total_token_throughput = (total_input + sum(actual_output_lens)) / dur_s
```

举个具体数字。con=1、multi_round=10，OSL=1024 → 10 个请求串行跑完，理想情况：

```
actual_output_lens = [1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024, 1024]
sum(actual_output_lens) = 10240   # 这一整轮 benchmark 一共吐了多少 output token
```

**为什么要 sum 再除 `dur_s`**：吞吐（throughput）的定义就是"单位时间产出多少 token"。
- 分子 = 整轮所有请求吐出的 token 总数 = `sum(...)`
- 分母 = 整轮墙钟时间 `dur_s`（[benchmark_serving.py:473](tensorrt_llm/serve/scripts/benchmark_serving.py#L473)，`最后一个请求收完 - 第一个请求发出`）

**为什么用"实际"长度而不是设定的 OSL**：因为真实生成长度可能 ≠ 设定值。比如模型提前吐了 EOS 就停了，或者 spec-decode 的 accept 数影响实际步数。所以要按**引擎真正吐出来的** token 数算，不能想当然用 1024×10。这也是为什么后面问题 7 会提"分子会漂"——如果不锁 EOS/accept 数，`actual_output_lens` 里的数字会变，`sum` 就跟着变。

一句话：**它是每请求实际产出 token 的数组，sum 得到整轮总产出，除以整轮墙钟时间就是吞吐。**

### 补充 1.1：换个参数验算（input_len=8192, num_round=10, con=2, output_len=1024）

先看请求数：`num_prompts = concurrency × iterations = con × num_round = 2 × 10 = 20` 个请求。

**这里有个易错点：input 也是"每请求都算一次"，不是只算一次。** 关键在 [benchmark_serving.py:178](tensorrt_llm/serve/scripts/benchmark_serving.py#L178)：

```python
for i in range(len(outputs)):          # 遍历每一个请求
    ...
    total_input += input_requests[i].prompt_len   # 每个请求都累加它的 input_len
```

`total_input` 是在循环里**每个请求累加一次**的。所以：

```
total_input = 20 × 8192 = 163840        # ← 不是 8192！每个请求都带 8192 的 input
sum(actual_output_lens) = 20 × 1024 = 20480   # 理想值

total_token_throughput 分子 = total_input + sum(actual_output_lens)
                            = 20×8192 + 20×1024 = 163840 + 20480 = 184320
```

**记法**：input 和 output 是对称的，**都是"每请求一份"**。
- `total_input` = ∑ 每请求 input_len = 20 × 8192
- `sum(actual_output_lens)` = ∑ 每请求实际 output_len = 20 × 1024（理想值）

**关于 EOS**：`sum(actual_output_lens)` 这一项**可能比 20×1024 小**——只要某个请求提前吐 EOS 就停了，它那一格就 < 1024。看 [line 166-177](tensorrt_llm/serve/scripts/benchmark_serving.py#L166-L177)，`output_len` 取的是**引擎实际吐出来的** token 数，不是设定的 1024。

（补充：`total_input` 这一项通常**恒定**，因为 input prompt 是喂进去的、长度固定不会变；会漂的只有 output 侧。且那点 EOS 漂动相对整个分子占比很小，所以"分子在 ISL/OSL 固定时几乎是常数"仍成立。）

区分两个吞吐：
- **`output_throughput`** = `sum(actual_output_lens) / dur_s` = 只看 output → `20480 / dur_s`
- **`total_token_throughput`** = `(total_input + sum(...)) / dur_s` → `184320 / dur_s`（input+output 都算）

### 补充 1.2：`accept = mtp = 3` 是什么情况

**MTP（Multi-Token Prediction）** 是 DeepSeek 系列（R1/V3）用的一种**投机解码（speculative decoding）**：

- 普通自回归解码：一个 forward step **只产出 1 个 token**，生成 1024 个就得 1024 步，decode 阶段 memory-bound、GPU 算力大量闲置。
- MTP：模型带轻量 MTP 头，主模型跑一次的同时**一口气多猜未来几个 token**。`mtp=3` = 每步除正常 1 个 token，MTP 头再多猜 3 个"草稿 token"。

**"投机"体现在 draft + verify 两步：**

1. **Draft（猜）**：MTP 头猜出接下来 3 个 token（便宜、快）。
2. **Verify（验）**：把"当前 token + 这 3 个草稿"**一起塞进主模型跑一个 forward**，并行验证这 3 个草稿。主模型是标准答案，逐个比对，认可就**接受（accept）**，一旦不认可就从那截断，后面丢弃、用主模型自己那步的正确 token 顶上。

**accept 数 = 这一步实际被主模型认可采纳的草稿数，是动态的：**

```
mtp=3 猜了 3 个草稿 [t1, t2, t3]：
主模型验证 →  t1√ t2√ t3✗  →  accept = 2（接受 t1,t2，t3 丢掉）
主模型验证 →  t1√ t2√ t3√  →  accept = 3（全中，最理想）
主模型验证 →  t1✗          →  accept = 0（第一个就错，退化成普通解码）
```

**每步实际前进的 token 数 = 1 + accept**（1 是主模型这步的 token，accept 是被采纳的草稿数）。accept=3 → 每步走 4 个 token；accept=0 → 每步走 1 个。平均 accept 数（业界记为 **AL / acceptance length**）越高，加速比越大。decode 本来 memory-bound，一步并行验证 4 个 token 和验证 1 个的 GPU 耗时几乎相同 → 用几乎一样的 step 成本走更多 token → 吞吐上去。

**`TLLM_SPEC_DECODE_FORCE_NUM_ACCEPTED_TOKENS=3`（测试专用）**：真实推理里 accept 动态波动（0~3），会导致步数/OSL/`num_generation_tokens` 分桶都漂（见问题 7）。这个 env **强制每步恰好接受 3 个**，把 accept 锁死成常数：每步固定前进 `1+3=4` 个 token → 生成 1024 个固定 `1024/4=256` 步 → 分子稳、分桶稳。**牺牲"真实 accept 率"换"指标可复现"。**

**关键结论（呼应吞吐公式）**：MTP 在 perf 测试里**只让生成步数变少**，`total_token_throughput` / `output_throughput` 的**分子（token 个数）完全不变**——仍是 `(8192×20 + 1024×20) / dur_s`。因为分子由 ISL/OSL 锁定，MTP 改的是**分母 `dur_s`**（步数少→更快→`dur_s` 小→吞吐高）。这正好回到主线：**吞吐的抖动 ≈ 100% 来自分母，分子在 OSL 锁定下稳如磐石。**

一句话：**MTP=3 → 每步多猜 3 个草稿；accept=3 → 采纳几个（真实动态，测试用 env 锁成 3，让每步稳定前进 4 个 token，只压缩步数/分母，不改分子）。**

---

## 问题 2：warmup 在干啥？`--no-test-input` 是什么意思

**`--no-test-input` = 跳过"预热请求"。** 看 [benchmark_serving.py:321-352](tensorrt_llm/serve/scripts/benchmark_serving.py#L321-L352)：

```python
if not no_test_input:                         # 默认会跑这段
    print("Starting initial single prompt test run...")
    test_input = RequestFuncInput(...)        # 拿第 0 个请求
    test_output = await request_func(...)     # 先打一发，不计入统计
    ...
else:
    print("Skipping initial test run. ...")   # 带了 --no-test-input 就走这
```

**warmup（这一发 test 请求）到底在替你付哪些"第一次才有"的开销：**

1. **CUDA graph capture** —— 第一次跑某个 batch shape，引擎要捕获 CUDA graph，这一步很慢（几十~几百 ms），之后 replay 就快了。
2. **首个 KV cache block 分配** —— KV cache pool 首次触碰、显存分配。
3. **disagg KV transfer 建链** —— context worker → gen worker 的 NIXL/UCX 连接首次握手建链。
4. **调度器首次排队 / JIT / autotune** —— 各种 lazy 初始化在第一发请求上被触发。

这些开销**只在第一发请求上出现一次**。warmup 的作用就是：**用一发不计入统计的请求，把这些一次性冷启动开销"吃掉"**，让后面正式统计的请求都跑在"热"状态。

**问题就在这里**：测试默认带 `--no-test-input`（[test_perf_sanity.py:938](tests/integration/defs/perf/test_perf_sanity.py#L938)），**关掉了 warmup**。于是这笔冷启动开销被算进了正式统计的 `dur_s` 里 → 这是抖动的最大来源（对应 md 文档方案 1）。

---

## 问题 3：降噪聚合的实现原理（`test_perf_sanity.py:172-315`），用数字讲

这段是给 **gen_only case 的 `prev_device_step_time`** 做聚合的。分三层降噪，我用数字演示。

**背景**：gen worker 每个 decode step 都会用两个 CUDA event 量一次纯 GPU forward 耗时 `prev_device_step_time`（[py_executor.py:1682-1693](tensorrt_llm/_torch/pyexecutor/py_executor.py#L1682-L1693)），并打进日志。假设 gen 日志里有这些行：

```
iter=0  prev_device_step_time=25.0 ms  num_generation_tokens=64   # 含 KV transfer 等待
iter=1  prev_device_step_time=18.0 ms  num_generation_tokens=64   # 还在稳
iter=2..4  ~12 ms                       num_generation_tokens=64   # warmup
iter=5  prev_device_step_time=10.1 ms  num_generation_tokens=64   # 稳态开始
iter=6  prev_device_step_time=10.0 ms  num_generation_tokens=64
iter=7  prev_device_step_time=15.0 ms  num_generation_tokens=64   # 一次尖刺(graph fallback)
iter=8  prev_device_step_time=10.2 ms  num_generation_tokens=64
...
iter=30 prev_device_step_time=9.8 ms   num_generation_tokens=32   # 尾部:序列陆续结束,batch缩小
iter=31 prev_device_step_time=8.0 ms   num_generation_tokens=16   # 尾部:更小的batch
```

**第 1 层：`iter < 5` 全丢**（[test_perf_sanity.py:219](tests/integration/defs/perf/test_perf_sanity.py#L219)）
iter 0/1 含 KV cache transfer 等待，iter 2-4 是 warmup，都不是稳态，直接扔。留下 iter≥5。

**第 2 层：按 `num_generation_tokens` 分桶，只取样本最多的桶（mode）**（[test_perf_sanity.py:236-257](tests/integration/defs/perf/test_perf_sanity.py#L236-L257)）
`num_generation_tokens`（简称 ngen）= 那一步 batch 里正在生成的 token 数。分桶后：

```
ngen=64 桶: [iter5,6,7,8, ...]  假设 24 个样本   ← 稳态平台，样本最多 → 选它
ngen=32 桶: [iter30]            1 个样本         ← 尾部，丢
ngen=16 桶: [iter31]            1 个样本         ← 尾部，丢
```

**为什么这么做**：跑到后半段，序列陆续吐完 EOS 退出，batch 越来越小（ngen 64→32→16），这些 step 更快、更便宜。如果把它们混进来平均，会**把均值往下拽，让"看起来的 step 耗时"比真实稳态还低**，掩盖真实性能。用 mode（最多样本的桶）就锁定在**稳态平台**上。

代码里用 `max(by_ngen.items(), key=lambda kv: (kv[1][0], kv[0]))`——先比样本数（`kv[1][0]`），平手就取更大的 ngen（`kv[0]`，稳态平台是较高的那个）。而且注释特意说明用 **mode 而非 `== max(ngen)`**：因为偶尔某一步 ngen 会瞬间蹦高（比如某步临时多拼了一个），如果用 `== 最大 ngen`，那个桶只有 1-2 个样本，均值就塌成 1-2 个点了。

**第 3 层：桶内 Welford 均值，再跨 gen worker 求平均**（[test_perf_sanity.py:227-229](tests/integration/defs/perf/test_perf_sanity.py#L227-L229) + [253-257](tests/integration/defs/perf/test_perf_sanity.py#L253-L257)）
Welford 是"边读边算均值"的增量公式，不用把所有数存下来：

```python
count += 1
mean  += (dt - mean) / count      # 增量更新均值
```

对 ngen=64 桶算出一个 per-worker 均值。多个 gen worker 各算各的，最后 `sum(means)/len(means)` 跨 worker 平均，得到最终 `prev_device_step_time`。

> 注意：这里第 3 层用的是 **mean**，正是问题 6 吐槽的点——mean 对 iter=7 那个 15ms 尖刺是敏感的，会被拉高。文档方案 4 建议改 median/trimmed-mean。

---

## 问题 4：11 段相位，每段落在代码哪一层

一次 disagg 请求的生命周期切成很多相位。文档那张表按"根因方向 / 性质"分类，我把每段对应到代码/系统层：

| 相位 | 落在哪一层 | 代码/系统位置 | 性质 |
|---|---|---|---|
| `disagg_preprocessing` | **disagg orchestrator 前处理**（HTTP 收请求、tokenize、路由决策） | `tensorrt_llm/serve/` 的 disagg server（OpenAI 兼容层） | 噪声（框架/HTTP） |
| `ctx_queue` | **context worker 侧排队等调度** | context 引擎的 scheduler 队列 | 测试环境噪声（负载/batch波动） |
| `ctx_processing` | **context 引擎 prefill 真实计算** | context 侧 `PyExecutor` model forward（prefill kernel） | **真回归**（真 kernel） |
| `disagg_relay` | **orchestrator 把 ctx 结果转交给 gen** 的 IPC/HTTP 中继 | disagg server 内部 relay | 噪声（IPC/HTTP/网络） |
| `gen_kv_transfer` | **KV cache 从 ctx 传到 gen** | NIXL/UCX transceiver（`cacheTransceiver`），[submit.py](jenkins/scripts/perf/local/submit.py) 里设 `UCX_TLS` 等 | 半噪声（传输/网络，但也可能真慢） |
| `gen_queue_wait` | **gen worker 侧排队** | gen 引擎 scheduler 队列（gen_only 用 `TLLM_BENCHMARK_REQ_QUEUES_SIZE` 固定） | 测试环境噪声 |
| **`gen step forward`** | **gen 引擎 decode step 真实计算** | [py_executor.py:1682-1693](tensorrt_llm/_torch/pyexecutor/py_executor.py#L1682-L1693)，就是 `prev_device_step_time` 量的那段 | **真回归**（真 kernel） |
| 后续 sampling / detokenize / 回传 | 采样、detokenize、HTTP 回包 | decoder/sampler + serve 层 | 噪声 |

**核心洞察（文档 §2 的魂）**：
- **吞吐 = token / `dur_s`**，`dur_s` 是**整段墙钟**，把上面**所有相位（噪声 + 计算）全压进同一个分母**。你想测"计算性能"，但结果被 queue/relay/kv_transfer/冷启动这些噪声相位污染 → 天生不稳。
- **`prev_device_step_time` 只量 `gen step forward` 一个计算相位**，天生把噪声相位排除在外 → 所以它本来就比吞吐稳。

判定回归时：抖动落在 `*_queue`/`relay`/`preprocessing` → 大概率是**环境噪声**，别急着报回归；落在 `ctx_processing`/`step forward` → 才是**真回归**（真的 kernel 变慢了）。

---

## 问题 5：样本量太小，固定开销权重高（con=1、round=10，抖 200ms → 吞吐抖 ~2%）

"固定开销"指**每轮 benchmark 只出现一次、和请求数无关的一次性开销**（冷启动：graph capture、建链…）。

关键在于**它被摊到分母 `dur_s` 里，而分母里稳态请求越少，这笔固定开销占的比重越大**。

**数字演示。** 单请求稳态 1.0s：

- **round=10（样本少）**：稳态耗时 10×1.0 = 10.0s，固定开销 0.2s → `dur_s = 10.2s`
  固定开销权重 = 0.2 / 10.0 = **1/50 ≈ 2%**（文档说"抖 200ms 整体抖 ~2%"就是这个）
  吞吐 = 10240 / 10.2 = **1004 tok/s**（相对稳态 1024 掉了 ~2%）

- **round=50（样本多）**：稳态耗时 50×1.0 = 50.0s，同样 0.2s 固定开销 → `dur_s = 50.2s`
  固定开销权重 = 0.2 / 50.0 = **1/250 ≈ 0.4%**
  吞吐 = 51200 / 50.2 = **1020 tok/s**（只掉 ~0.4%）

**同样的 200ms 冷启动，round=10 时把吞吐带偏 2%，round=50 时只带偏 0.4%。** 因为分母变大了，那笔一次性开销被稀释。这就是文档方案 2"把 multi_round 从 10 提到 30~50，抖动约除以 5"的算术依据。

类比：10 个人 AA 一顿饭，多付了 200 块小费，每人多摊 20；50 个人 AA，每人只多摊 4。人越多，那笔固定的额外开销对"人均"影响越小。

---

## 问题 6：均值对尖刺敏感

指第 3 层用的是 **mean**（[test_perf_sanity.py:229](tests/integration/defs/perf/test_perf_sanity.py#L229)），而 mean 会被**单个异常大的值**整体拉高。

**什么尖刺**：某一个 decode step 偶发变慢——比如那一步 **CUDA graph fallback**（batch shape 没命中已捕获的 graph，退回 eager 逐 kernel launch），或 **batch 拼接**导致那步特别重。这一步的 `prev_device_step_time` 突然从 10ms 蹦到 20ms。

**数字演示。** 稳态桶里 10 个样本：

```
[10, 10, 10, 10, 10, 10, 10, 10, 10, 20]   # 最后一个是尖刺
mean   = 110/10 = 11.0 ms   ← 被那个 20 拉高了 10%
median = 10 ms              ← 完全不受影响
```

真实稳态 step 是 10ms，但 mean 报了 11ms——**一次偶发尖刺就让指标虚高 10%，可能被误判成回归**。median（或 trimmed-mean，掐掉最高 10%）对这种单点尖刺免疫。这就是文档方案 4 建议把桶内 mean 改成 median/trimmed-mean 的原因。

---

## 问题 7：分子/批次抖动 —— spec-decode 的 accept 数

**spec-decode（投机解码）**：draft 模型一次猜若干 token，target 模型验证，**接受几个（accept 数）是动态的**。accept 数直接决定两件事：

1. **实际 OSL**（每步吐几个 token）→ 影响**分子 `sum(actual_output_lens)`**
2. **`num_generation_tokens`**（每步 batch 里的 token 数）→ 影响**问题 3 的分桶**

**为什么"不锁定就漂"，数字演示。** 目标生成 1024 个 output token：

- 某轮 accept 平均 = 3 → 大约 `1024/3 ≈ 342` 个 decode step，每步 ngen 走一个分布
- 另一轮 accept 平均 = 2.5 → 大约 `1024/2.5 ≈ 410` 个 step，ngen 分布也不一样

于是 run-to-run：
- **分子漂**：实际吐的 token 数、步数都在变 → `sum(actual_output_lens)` 不是常数
- **分桶漂**：ngen 分布变了 → 问题 3 里"最多样本的桶"是哪个也在变，均值锚点跟着晃

**解法**（文档方案 5）：设 `TLLM_SPEC_DECODE_FORCE_NUM_ACCEPTED_TOKENS=3`，**强制每步固定接受 3 个**。这样 OSL 恒定、步数恒定、ngen 分布恒定 → 分子稳、分桶稳。disagg yaml 已经设了，文档建议**所有 spec case 都保留**。

---

## 问题 8：`dur_s = 10.0 → 10.3` 掉 3%，逐步拆解（你选中的那段）

这是问题 5 的"同一个固定开销"换个数字讲，重点是**分子完全没变，只有分母被冷启动带偏**。

**设定**：ISL=8192、OSL=1024、10 请求串行、单请求稳态 ≈ 1.0s。

分子恒定：`10 × 1024 = 10240` output token（10 个请求，每个吐 1024，锁死不变）。

**正常那一轮**：10 个请求各 1.0s，无异常。

```
dur_s = 10 × 1.0 = 10.0 s
output_throughput = 10240 / 10.0 = 1024 tok/s   ← 基准
```

**倒霉那一轮**：**只有首请求**多花了 0.3s，具体来自两笔一次性冷启动：
- **KV transfer 建链慢**：首请求要现场建 ctx→gen 的 NIXL/UCX 连接（第一次握手）
- **首步 graph capture**：第一个 decode step 要捕获 CUDA graph（后续 replay 就没这开销）

```
dur_s = 10.0 + 0.3 = 10.3 s          ← 分母被这 0.3s 带偏
output_throughput = 10240 / 10.3 = 994 tok/s
掉幅 = (1024 - 994) / 1024 ≈ 3%
```

**要害**：
- **分子 10240 一个 token 没变**——引擎的真实计算能力完全没退步；
- 掉的 3% **100% 来自分母** `dur_s` 被一次性冷启动 + 网络抖动多加了 0.3s；
- 而这 0.3s 只出现在 10 个请求里的**第 1 个**上（权重 1/10）。若 round=30，同样 0.3s 摊进 30s → 只掉约 1%。**样本越少，这一发冷启动抖得越狠。**

这正好把前面所有点串起来了：**warmup 该吃掉这 0.3s（问题 2）→ 没吃是因为 `--no-test-input`；样本太少放大它（问题 5）→ 该调大 round；根子上它是"冷启动 + kv_transfer 噪声相位"被压进墙钟分母（问题 4）→ 该改用引擎侧 step-forward 相位吞吐来判定回归。**

---

这 8 个点其实是同一条主线的不同侧面：**吞吐把所有相位压进一个墙钟分母，所以脏；`prev_device_step_time` 只测一个计算相位，所以干净。优化就是把噪声相位从计量里剔出去（warmup 丢首请求 / 多样本取中位 / 直接用引擎侧相位吞吐）。**

都清楚的话，我们可以开始动手了——你想先从哪个方案入手？(P0 的 warmup 丢弃 + 调大 multi_round 最快见效)
