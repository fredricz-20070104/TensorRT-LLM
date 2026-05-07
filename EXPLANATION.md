# Disagg 深入问答记录

> 配套文档 [DISAGG.md](DISAGG.md) 给出 disagg + Wide-EP 的总体分层。本文档记录在那之上深入挖出来的几个具体问题，每节都给出代码定位和最小可复现的解释。

---

## 目录

1. [Disagg server 的 prompt 限制：`List[int]` 是啥意思](#1-disagg-server-的-prompt-限制listint-是啥意思)
2. [`DisaggServerConfig` 各字段含义与读取链路](#2-disaggserverconfig-各字段含义与读取链路)
3. [`gen_first` streaming 路径的 async + queue 模式与死锁规避](#3-gen_first-streaming-路径的-async--queue-模式与死锁规避)
4. ["ctx 等 gen 上线 rx 会话" 的实际语义（gen_first 协议握手）](#4-ctx-等-gen-上线-rx-会话-的实际语义gen_first-协议握手)
5. [`examples/disaggregated/slurm/benchmark` 流水线：host/port 静态生成](#5-examplesdisaggregatedslurmbenchmark-流水线hostport-静态生成)
6. [`jenkins/scripts/perf/local` 流水线：host/port 运行时生成](#6-jenkinsscriptsperflocal-流水线hostport-运行时生成)

---

## 1. Disagg server 的 prompt 限制：`List[int]` 是啥意思

### OpenAI Completions 协议下 prompt 的 4 种合法形态

[tensorrt_llm/serve/openai_protocol.py:338](tensorrt_llm/serve/openai_protocol.py#L338)：

```python
prompt: Union[List[int], List[List[int]], str, List[str]]
```

| 形态 | 语义 |
|---|---|
| `str` | 一条文本 prompt（普通用法） |
| `List[str]` | 一批文本 prompt（batched） |
| `List[int]` | **已经分好词的 token ID 序列**（绕过 tokenizer） |
| `List[List[int]]` | 一批 token ID 序列（batched + 跳 tokenizer） |

### Disagg server 主动收紧

[tensorrt_llm/serve/openai_disagg_service.py:104-113](tensorrt_llm/serve/openai_disagg_service.py#L104-L113)：

```python
if not isinstance(request.prompt, str):
    if type(request.prompt) is list and len(request.prompt) == 1:
        request.prompt = request.prompt[0]                      # 长度 1 的 list 解开
    elif not isinstance(request.prompt, list) or not all(
        isinstance(x, int) for x in request.prompt
    ):
        raise ValueError(
            "Disaggregated server currently only supports single string prompt or list of integers in request"
        )
```

只放过两种 case：
- 单条 `str`
- 一段 `List[int]` token IDs（注意：是**一条** prompt 的 token 序列，**不是** batched）
- 长度为 1 的 `List[List[int]]` / `List[str]` 会被 unwrap 后成上面之一

### 为什么收紧

Disagg 流水线是**逐请求**串起 ctx → gen 的（靠 ctx 返回的 `ContextPhaseParams.ctx_request_id` 与 gen 一一对应）。Batched prompt 在 ctx 端会一次产出 N 个 `disaggregated_params`，前端编排还没有把它们拆成 N 个独立的 gen 请求，所以协议上直接禁止。

要在生产里批量并发，只能在客户端拆成 N 个并发的单 prompt 请求。

---

## 2. `DisaggServerConfig` 各字段含义与读取链路

### 类型定义

[tensorrt_llm/llmapi/disagg_utils.py:73](tensorrt_llm/llmapi/disagg_utils.py#L73)：

```python
@dataclass
class DisaggServerConfig:
    server_configs: List[CtxGenServerConfig]
    hostname: str = "localhost"
    port: int = 8000
    ctx_router_config: Optional[RouterConfig] = None
    gen_router_config: Optional[RouterConfig] = None
    conditional_disagg_config: Optional[ConditionalDisaggConfig] = None
    otlp_config: Optional[OtlpConfig] = None
    max_retries: int = 1
    perf_metrics_max_requests: int = 0
    disagg_cluster_config: Optional[DisaggClusterConfig] = None
    node_id: int = uuid.getnode() % 1021
    schedule_style: Literal['context_first', 'generation_first'] = 'context_first'
```

### 读取链路

```text
trtllm-serve disaggregated --config server_config.yaml
        │
        ▼
parse_disagg_config_file(yaml_path)        # disagg_utils.py:114
        │  yaml.safe_load → 字典
        ▼
extract_disagg_cfg(**config)                # disagg_utils.py:125
        │  顶层公共字段下推到 ctx/gen
        │  分别构造 CtxGenServerConfig + RouterConfig
        ▼
DisaggServerConfig(...)                     # 最终对象
```

### 各字段语义

| 字段 | 含义 |
|---|---|
| `server_configs` | 所有 ctx + gen worker 的清单（每个 worker 一项） |
| `hostname` / `port` | **disagg server 自己**监听的地址 |
| `ctx_router_config` | ctx 端 router 策略（round_robin / kv_cache_aware / load_balancing） |
| `gen_router_config` | gen 端 router 策略 |
| `conditional_disagg_config.max_local_prefill_length` | 当 (`total − cached`) ≤ 此值时跳过 ctx，让 gen 直接 prefill+decode |
| `otlp_config.otlp_traces_endpoint` | OpenTelemetry tracing endpoint |
| `max_retries` | worker 失败重试次数 |
| `perf_metrics_max_requests` | 滑窗 perf metrics 容器大小 |
| `disagg_cluster_config` | 弹性集群（worker 动态加入/退出，etcd-like） |
| `node_id` | 当前 disagg-server 实例 ID（多实例下保证全局 request id 唯一），不写就 MAC 哈希 |
| `schedule_style` | 两段式调度策略（默认 context_first；gen_first 实现见 §4） |

### 嵌套类型

`CtxGenServerConfig`（[disagg_utils.py:31](tensorrt_llm/llmapi/disagg_utils.py#L31)）：

| 字段 | 含义 |
|---|---|
| `type` | `'ctx'` / `'gen'` |
| `hostname` / `port` | worker 真实地址 |
| `instance_num_ranks` | TP × PP × CP（用于 SLURM 资源分配） |
| `other_args` | 没识别的字段（`tensor_parallel_size`、`kv_cache_config` 等） |

`RouterConfig`（[disagg_utils.py:40](tensorrt_llm/llmapi/disagg_utils.py#L40)）：

| 字段 | 含义 |
|---|---|
| `type` | `round_robin` / `kv_cache_aware` / `load_balancing` |
| `args` | 路由器特有参数 |
| `server_role` | `CONTEXT` / `GENERATION`（自动设） |

### `examples/disaggregated/disagg_config.yaml` 的对照

```yaml
hostname: localhost              → DisaggServerConfig.hostname
port: 8000                       → DisaggServerConfig.port
model: TinyLlama/...             → 顶层下推到 ctx/gen 各自的 dict
free_gpu_memory_fraction: 0.25
backend: pytorch
disable_overlap_scheduler: True

context_servers:
  num_instances: 1               → 生成 1 个 CtxGenServerConfig(type='ctx')
  tensor_parallel_size: 1
  cache_transceiver_config:
    backend: DEFAULT
  urls: [localhost:8001]         → CtxGenServerConfig.hostname/port

generation_servers:
  num_instances: 1
  tensor_parallel_size: 1
  cache_transceiver_config:
    backend: DEFAULT
  urls: [localhost:8002]
```

---

## 3. `gen_first` streaming 路径的 async + queue 模式与死锁规避

代码在 [openai_disagg_service.py:531-608](tensorrt_llm/serve/openai_disagg_service.py#L531-L608)。

### 背景：为什么需要 gen_first

| 风格 | 行为 |
|---|---|
| `context_first`（默认） | 串行：先 ctx 跑完，拿到 `ContextPhaseParams`，再发 gen |
| `generation_first` | 并行：ctx 和 gen 同时开工，对 streaming 能省一个 ctx prefill 的 RTT |

### HTTP 客户端的"懒生成器"陷阱

`aiohttp` / `httpx` 的 streaming 客户端，`send_request()` 返回的不是已发的请求，而是一个 **async generator**：

```python
gen_response = await self._gen_client.send_request(gen_req, ...)
# await 完了，但 HTTP POST 还没真正发
async for chunk in gen_response:    # POST 在这里才打出去
    ...
```

### 死锁场景（如果直接 gather）

```python
# ❌ 死锁版本
ctx_response, gen_response = await asyncio.gather(
    self._ctx_client.send_request(ctx_req, ...),   # 真发 HTTP，ctx 开始 prefill
    self._gen_client.send_request(gen_req, ...),   # 只拿到 lazy generator，POST 没发
)
async for chunk in gen_response: ...               # 走不到这一步
```

时序：

```
T0  ctx HTTP POST 发出   → ctx 开始等 gen 的 rx 会话
T0  gen "send_request" 只生成 generator，POST 没发
T1  gather 等两个都返回；gen 那个 await 已 resolve；ctx 那个 hang
T∞  ctx 等 gen rx → gen 的 POST 等 generator iterate → iterate 等 gather → gather 等 ctx
    死锁
```

### 解法：create_task + asyncio.Queue

```python
# 1. 拿到 gen 的 lazy generator（HTTP 没发）
gen_response = await self._gen_client.send_request(gen_req, ...)

# 2. 排一个后台 task 立刻消费 generator —— 一旦 event loop 让出，HTTP POST 就被踹出去
queue: asyncio.Queue = asyncio.Queue()
async def _consume_gen():
    try:
        async for chunk in gen_response:
            await queue.put(chunk)
    except Exception as e:
        await queue.put(e)
    await queue.put(None)  # 结束哨兵

consume_task = asyncio.create_task(_consume_gen())

# 3. await ctx —— 这个 await 让出 event loop，consume_task 跑起来 → gen HTTP POST 真正飞出
ctx_response = await self._ctx_client.send_request(ctx_req, ...)

# 4. 把 queue 转成新的 async generator 还给 FastAPI
async def _yield_from_queue():
    while True:
        item = await queue.get()
        if item is None: break
        if isinstance(item, Exception): raise item
        yield item
```

### 关键步骤的串讲

| 步骤 | 必要性 |
|---|---|
| `gen_response = await ...` | 仅拿到 generator，HTTP 没发；不能让 gen HTTP 在 ctx 之前发 |
| `consume_task = create_task(...)` | 把 generator 消费排进 event loop，等待让出时执行 |
| `await self._ctx_client.send_request(...)` | 这个 `await` 让 consume_task 接管 → gen HTTP POST 飞出 → ctx 解套 |
| try / except: `consume_task.cancel()` | ctx 失败时清理 gen task，避免泄漏 |
| `_yield_from_queue` | 把同步 queue 包成 async generator 适配 FastAPI streaming response |

### 非 streaming 分支为什么不需要这套

[openai_disagg_service.py:609-626](tensorrt_llm/serve/openai_disagg_service.py#L609-L626)：

```python
else:
    tasks = [create_task(ctx.send()), create_task(gen.send())]
    responses = await asyncio.gather(*tasks)
```

非 streaming 的 `send_request` 是 eager 的（不返回 generator，直接 await 整个 HTTP 响应），`create_task` 排进 event loop 后第一次让出就会真正发 POST，没有"懒生成器"那一层延迟。

---

## 4. "ctx 等 gen 上线 rx 会话" 的实际语义（gen_first 协议握手）

### 简短说法

在 `generation_first` 模式下，ctx worker 收到 HTTP 请求后**不立刻** prefill。它把请求挂在 `DISAGG_CONTEXT_WAIT_SCHEDULER` 状态，**等 gen worker 通过专门的握手通道告诉 ctx "我在哪个端点收 KV"**，ctx 才把请求推进到 `CONTEXT_INIT` 开始算。

握手在 gen_first 下是**反向**的：ctx 等 gen 来登记自己。

### 时序对比

#### context_first（默认）

```
disagg_server                ctx worker                     gen worker
     │  HTTP ctx_only           │                               │
     │ ──────────────────────▶ │                                │
     │                         ├─ 立刻进 CONTEXT_INIT 开始 prefill
     │                         │  完成后把 ctx_info_endpoint 写
     │                         │  进 disaggregated_params
     │  HTTP 200 (with         │                                │
     │   ctx_info_endpoint) ◀──│                                │
     │                                                          │
     │  HTTP gen_only (携带 ctx_info_endpoint)                  │
     │ ────────────────────────────────────────────────────▶   │
     │                          ◀── ZMQ 连 ctx_info_endpoint ──┤
     │                          KV transfer                     │
     │                                                          ├─ 开始 decode
```

#### gen_first

```
disagg_server                ctx worker                     gen worker
     │  HTTP ctx_only           │                               │
     │ ──────────────────────▶ │                                │
     │  HTTP gen_only           ├─ 进 DISAGG_CONTEXT_WAIT_SCHEDULER
     │ (携带预先就知道的         │   什么也不算，等！
     │  ctx_info_endpoint) ────────────────────────────────▶   │
     │                          │                               ├─ 立刻起 rx session
     │                          │  ◀── REQUEST_DATA ───────────┤   连 ctx_info_endpoint 登记
     │                          ├─ peer info 到位 →
     │                          │   _ctx_consensus 全 rank 同步 →
     │                          │   状态切到 CONTEXT_INIT 开始 prefill
     │                          │   prefill 完 → 推 KV ────────▶│
     │                                                          ├─ 开始 decode
```

`ctx_info_endpoint` 在 gen_first 下由 disagg server 在 `_send_disagg_request_gen_first` 调 `await self._ctx_router.get_next_server(request)` 时就拿到（router 知道所有 ctx worker 的地址簿），通过 `ctx_server_info` 预填进 gen 请求 —— 见 [openai_disagg_service.py:357-367](tensorrt_llm/serve/openai_disagg_service.py#L357-L367)。

### 代码证据

#### 1) ctx 端：gen_first 请求挂起

[py_executor.py:3203-3221](tensorrt_llm/_torch/pyexecutor/py_executor.py#L3203-L3221)：

```python
def _check_disagg_ctx_schedulable_status(self, new_requests):
    """
    In context-first mode, context requests are schedulable immediately,
    otherwise, we need to check if context requests are ready to be scheduled
    by querying kv cache transceiver
    """
    gen_first_ctx_requests = [
        req for req in new_requests
        if req.is_context_only_request and req.py_disaggregated_params.
        schedule_style == DisaggScheduleStyle.GENERATION_FIRST
    ]
    self.kv_cache_transceiver.prepare_context_requests(gen_first_ctx_requests)
```

[transceiver.py](tensorrt_llm/_torch/disaggregation/transceiver.py) 里 `prepare_context_requests`：

```python
def prepare_context_requests(self, requests):
    for req in requests:
        rid = get_unique_rid(req)
        if rid not in self._send_sessions:
            self._wait_reqs[rid] = req
            req.state = LlmRequestState.DISAGG_CONTEXT_WAIT_SCHEDULER  # ← 挂起
    # ... peer info 到位后用 _ctx_consensus 做全 TP/PP 共识，再 promote
```

#### 2) gen_first 多了 aux buffer

[transfer.py:990](tensorrt_llm/_torch/disaggregation/native/transfer.py#L990) 与 [transfer.py:1507](tensorrt_llm/_torch/disaggregation/native/transfer.py#L1507)：

```python
self._need_aux = params.schedule_style == DisaggScheduleStyle.GENERATION_FIRST
```

`aux_buffer` 是 gen_first 专用的辅助元数据 buffer，承载 KV 数据流之外的小消息（gen 把 receiver 信息送给 ctx）。ctx_first 不需要，因为 ctx 算完直接把端点塞进 HTTP 响应。

### 与 streaming 死锁的关联

```
ctx 等 gen.rx_session ── gen.rx_session 等 gen.HTTP POST ── gen.HTTP POST 等 generator iterate
                                                                         ↑
                                                                被 await gather 卡死
```

`create_task(_consume_gen())` 那一招就是**强行把 gen generator 提前 iterate** → HTTP POST 飞出 → gen rx session 上线连 ctx_info_endpoint → ctx 从 `WAIT_SCHEDULER` promote 到 `CONTEXT_INIT`，整条链转起来。

### 一句话总结

- `ctx_first`：**ctx 算 → 把端点塞进 HTTP 响应 → gen 来拉**
- `gen_first`：**disagg_server 预先把 ctx 端点告诉 gen → gen 起 rx session 连过去登记 → ctx 收到登记才开始算 → 算完推过来**

---

## 5. `examples/disaggregated/slurm/benchmark` 流水线：host/port 静态生成

### 关键事实

[examples/disaggregated/slurm/benchmark/submit.py](examples/disaggregated/slurm/benchmark/submit.py) 在**登录节点**就把所有 yaml 都写好；占位符在 `disaggr_torch.slurm` 里 `sed` 替换成真实节点名。

### 关键产物

```
<log_dir>/
├── ctx_config.yaml                     ← worker_config.ctx 原样 dump（worker 的 LLM 配置）
├── gen_config.yaml                     ← worker_config.gen 原样 dump
├── allocations.json                    ← {"CTX": {0: {port: 8000, nodes: {...}}}, ...}
├── server_config_base.yaml             ← 含 <node0_placeholder>, <node1_placeholder>...
├── start_server_cmds_base.sh           ← srun ... 8000 ... ctx_config.yaml
├── client_cmds_base.sh
├── server_config.yaml                  ← SLURM 启动后才生成（占位符替换好）
├── start_server_cmds.sh                ← 同上
├── client_cmds.sh                      ← 同上
└── ...
```

注意：`ctx_config.yaml` / `gen_config.yaml` 里**没有** host/port —— 它们是 `trtllm-serve --config <这个 yaml>` 用的，host/port 走命令行 `--host` / `--port`。

### port 怎么算

[submit.py:60-115](examples/disaggregated/slurm/benchmark/submit.py#L60-L115)：

```python
def allocate_gpus(..., base_port: int = 8000):
    hostnames = [f"<node{i}_placeholder>" for i in range(total_nodes)]
    port = base_port

    def assign_servers(server_allocations, server_type, num_servers, world_size, ...):
        nonlocal port
        for i in range(num_servers):
            server_allocation = {"port": port, "nodes": {}}
            assign_server(...)
            server_allocations[server_type][i] = server_allocation
            port += 1                   # ← 每个 worker 实例 port +1

    assign_servers(allocations, "CTX", num_ctx_servers, ctx_world_size, gpus_per_node)
    assign_servers(allocations, "GEN", num_gen_servers, gen_world_size, gpus_per_node)
```

举例（`con1_ctx1_dep4_gen1_tep8`，`gpus_per_node=4`）：

```
ctx_world_size = 4，1 个 ctx 实例 → 用 1 个节点
gen_world_size = 8，1 个 gen 实例 → 跨 2 个节点
total_nodes = 3

allocations = {
  "CTX": {0: {port: 8000, nodes: {<node0_placeholder>: [0,1,2,3]}}},
  "GEN": {0: {port: 8001, nodes: {<node1_placeholder>: [0,1,2,3],
                                  <node2_placeholder>: [0,1,2,3]}}}
}
```

### server_config.yaml 拼装

[submit.py:118-153](examples/disaggregated/slurm/benchmark/submit.py#L118-L153)：

```python
def convert_allocations_to_server_config(allocations, server_port=8333, ...):
    for server_type in allocations.keys():
        urls = []
        for server_id in allocations[server_type].keys():
            instance = allocations[server_type][server_id]
            urls.append(f"{list(instance['nodes'].keys())[0]}:{instance['port']}")
        if server_type == "GEN":
            generation_servers = {'num_instances': num_servers, 'urls': urls}
            server_hostname = urls[0].split(':')[0]   # disagg-server 自己用第一个 gen 节点
        elif server_type == "CTX":
            context_servers = {...}

    server_config = {
        'backend': 'pytorch',
        'hostname': server_hostname,    # 占位符
        'port': server_port,            # 默认 8333
        'context_servers': context_servers,
        'generation_servers': generation_servers,
    }
```

dump 出的 `server_config_base.yaml`：

```yaml
backend: pytorch
hostname: <node1_placeholder>
port: 8333
context_servers:
  num_instances: 1
  urls: [<node0_placeholder>:8000]
generation_servers:
  num_instances: 1
  urls: [<node1_placeholder>:8001]
```

### 占位符替换

[disaggr_torch.slurm:60-72](examples/disaggregated/slurm/benchmark/disaggr_torch.slurm#L60-L72) + [:138-150](examples/disaggregated/slurm/benchmark/disaggr_torch.slurm#L138-L150)：

```bash
all_nodes=($(scontrol show hostname $SLURM_NODELIST | sort))
all_nodes_str=$(IFS=','; echo "${all_nodes[*]}")
# all_nodes_str = "gb200-001,gb200-002,gb200-003"

replace_placeholder server_config_base.yaml "$all_nodes_str" server_config.yaml
replace_placeholder start_server_cmds_base.sh "$all_nodes_str" start_server_cmds.sh
replace_placeholder client_cmds_base.sh "$all_nodes_str" client_cmds.sh

replace_placeholder() {
    cp "$1" "$3"
    IFS=',' read -r -a node_array <<< "$2"
    for i in "${!node_array[@]}"; do
        sed -i "s|<node${i}_placeholder>|${node_array[$i]}|g" "$3"
    done
}
```

替换后 `server_config.yaml`：

```yaml
backend: pytorch
hostname: gb200-002
port: 8333
context_servers:
  num_instances: 1
  urls: [gb200-001:8000]
generation_servers:
  num_instances: 1
  urls: [gb200-002:8001]
```

### worker 的 host/port

[start_worker.sh:46-49](examples/disaggregated/slurm/benchmark/start_worker.sh#L46-L49)：

```bash
trtllm-serve ${model_path} \
    --host $(hostname) --port ${port} \   # host=本机名（srun --nodelist 钉死节点）
                                           # port=submit.py 算好的、命令行透传进来
    --config ${config_file}                # ctx_config.yaml 或 gen_config.yaml
```

### host/port 来源汇总

| 字段 | 来源 |
|---|---|
| **worker host**（ctx/gen 监听） | `start_worker.sh` 里 `--host $(hostname)`，srun `--nodelist <真名>` 钉死节点 |
| **worker port** | `submit.py:allocate_gpus()` 从 `base_port=8000` 单调递增；命令行传给 `start_worker.sh` |
| **disagg-server host** | `submit.py:convert_allocations_to_server_config()` 选第一个 gen worker 的节点；写占位符；slurm 替换 |
| **disagg-server port** | `submit.py` 默认 `server_port=8333`（碰撞时 +1） |
| **server_configs.urls** | `host:port` 拼接 |

---

## 6. `jenkins/scripts/perf/local` 流水线：host/port 运行时生成

### 跟 examples/ 流水线的本质区别

| | examples/ submit.py | jenkins/local/ submit.py |
|---|---|---|
| ctx/gen yaml | submit.py 在登录节点写 | pytest 在 CTX_0/GEN_0 节点写 |
| host 占位 | submit.py 写占位符 → slurm 启动时 sed 替换 | pytest 用 `socket.gethostname()` 直接拿 |
| port | submit.py 用 `base_port + i` 静态分配 | pytest 用 `get_free_port()` 动态分配 |
| server_config.yaml | submit.py 写 base + slurm sed 填真名 | DISAGG_SERVER 节点的 pytest 等齐 hostname 文件再写 |
| 跨节点协调 | sed 一次性填好 | 共享文件系统轮询 |

后者更鲁棒（不依赖端口预测、节点编号顺序），代价是必须有共享 FS。

### 角色划分：环境变量 `DISAGG_SERVING_TYPE`

[jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh](jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh) 启动 5 类 srun，每类不同 `DISAGG_SERVING_TYPE`：

| `DISAGG_SERVING_TYPE` | 数量 | ntasks |
|---|---|---|
| `GEN_0`, `GEN_1`, ... | `numGenServers` | `nodesPerGenServer × gpusPerNodePerGenServer` |
| `CTX_0`, `CTX_1`, ... | `numCtxServers` | `nodesPerCtxServer × gpusPerNodePerCtxServer` |
| `DISAGG_SERVER` | 1 | 1 |
| `BENCHMARK` | 1 | 1 |

每个 srun 进入容器跑同一个 `slurm_run.sh`，里面就一行：

```bash
eval $pytestCommand     # 不同角色这个 cmd 略不同（CTX/GEN/Server/Benchmark）
```

**关键事实**：5 类进程跑的都是**同一个 pytest test case** —— `test_e2e[disagg-e2e-<config_base>]`！只是 `DISAGG_SERVING_TYPE` 不同，pytest 内部走不同分支。

### submit.py 干的 4 件事

[jenkins/scripts/perf/local/submit.py](jenkins/scripts/perf/local/submit.py) 不写任何 yaml，只生成一份 `slurm_launch.sh`：

1. `#SBATCH` 头：`hardware_config["total_nodes"]` 等
2. `export configYamlPath=<master.yaml>` —— 把 master yaml 路径塞给所有节点共享
3. `export pytestCommand{CTX,GEN,DisaggServer,Benchmark}Worker` —— 每个角色用哪条 pytest 命令
4. `export numCtxServers / numGenServers / nodesPer*Server / ...` —— 给 draft launch 脚本用

submit.py 不写 yaml 的原因：跨节点 yaml 生成依赖运行时才能拿到的两件东西 —— **节点 hostname**（要 `srun` 起来才知道）和 **空闲端口**（要 `get_free_port()` 实际 bind 才知道）。

### yaml 文件**真正**在哪儿生成 —— pytest 内部

| yaml | 由谁生成 | 何时 |
|---|---|---|
| `extra-llm-api-config.ctx.<name>.yml` | `CTX_0` worker 的 pytest 进程 | 进 `get_commands()` 时 |
| `extra-llm-api-config.gen.<name>.yml` | `GEN_0` worker 的 pytest 进程 | 进 `get_commands()` 时 |
| `server_config.<idx>.yaml` | `DISAGG_SERVER` 的 pytest 进程 | `_generate_disagg_server_config()`，发生在 disagg server 进程实际启动**之前** |

#### ctx/gen extra-llm-api-config

[test_perf_sanity.py:1463-1481](tests/integration/defs/perf/test_perf_sanity.py#L1463-L1481)：

```python
ctx_cmd = ctx_config.to_cmd(test_output_dir, numa_bind, "CTX")
if disagg_serving_type == "CTX_0":                      # ← 只有 CTX_0 写
    config_content = ctx_config.generate_extra_llm_api_config()
    config_path = os.path.join(
        test_output_dir, f"extra-llm-api-config.ctx.{ctx_config.name}.yml"
    )
    with open(config_path, "w") as f:
        f.write(config_content)

gen_cmd = gen_config.to_cmd(test_output_dir, numa_bind, "GEN")
if disagg_serving_type == "GEN_0":                      # ← 只有 GEN_0 写
    config_content = gen_config.generate_extra_llm_api_config()
    config_path = os.path.join(
        test_output_dir, f"extra-llm-api-config.gen.{gen_config.name}.yml"
    )
    with open(config_path, "w") as f:
        f.write(config_content)
```

#### host/port 接力 —— hostnames 文件夹

每个 worker 启动 `trtllm-serve` 之前 [test_perf_sanity.py:884-902](tests/integration/defs/perf/test_perf_sanity.py#L884-L902)：

```python
if "CTX" in self.disagg_serving_type or "GEN" in self.disagg_serving_type:
    port = get_free_port()
    self._generate_hostname_file(server_idx, port)   # 写 hostnames-<idx>/{CTX_n|GEN_n}.txt

    is_ctx = "CTX" in self.disagg_serving_type
    server_cmd = ctx_cmd if is_ctx else gen_cmd

    # 非 _0 worker 等 _0 把 yaml 写好
    if self.disagg_serving_type not in ("CTX_0", "GEN_0"):
        config_idx = server_cmd.index("--config") + 1
        self._wait_for_config_file(server_cmd[config_idx])

    server_cmd = add_host_port_to_cmd(server_cmd, self.hostname, port)
    server_proc = subprocess.Popen(server_cmd, ...)
```

#### server_config.yaml —— DISAGG_SERVER 等齐再生成

[test_perf_sanity.py:754-814](tests/integration/defs/perf/test_perf_sanity.py#L754-L814)：

```python
def _generate_disagg_server_config(self, server_idx):
    hostnames_folder = f"{test_output_dir}/hostnames-{server_idx}"
    expected_count = self.num_ctx_servers + self.num_gen_servers

    while True:
        hostnames = os.listdir(hostnames_folder)
        if len(hostnames) >= expected_count:
            break
        time.sleep(10)

    ctx_hostnames, gen_hostnames = [], []
    for hostname_file in hostnames:
        with open(...) as f:
            hp = f.read().strip()
        if hostname_file.startswith("CTX"): ctx_hostnames.append(hp)
        elif hostname_file.startswith("GEN"): gen_hostnames.append(hp)

    disagg_server_port = get_free_port()

    server_config = {
        "hostname": self.hostname,
        "port": disagg_server_port,
        "backend": "pytorch",
        "context_servers": {"num_instances": self.num_ctx_servers, "urls": ctx_hostnames},
        "generation_servers": {"num_instances": self.num_gen_servers, "urls": gen_hostnames},
    }
    with open(f"{test_output_dir}/server_config.{server_idx}.yaml", "w") as f:
        yaml.dump(server_config, f)
```

### 完整时序图

```text
登录节点
  jenkins/scripts/perf/local/submit.py
        │  读 master yaml；算 #SBATCH 资源
        │  导出 configYamlPath、各角色 pytestCommand、numCtx/numGenServers
        │  把 slurm_launch_draft.sh 追加进去
        ▼
  slurm_launch.sh 生成完毕（还没写过任何 yaml）

──────────────── sbatch 提交后 ────────────────

各计算节点（每条 srun 是一个角色）
  CTX_0    ─┐    GEN_0    ─┐    CTX_n   ─┐    DISAGG_SERVER   BENCHMARK
            │              │              │
  共享挂载的 test_output_dir（NFS / pyxis bind mount）
            │              │              │
  pytest test_e2e[disagg-e2e-<cfg>]  在每个角色都跑一份
            │              │              │
T0   CTX_0  写 extra-llm-api-config.ctx.<name>.yml
     GEN_0  写 extra-llm-api-config.gen.<name>.yml
T1   CTX_n  _wait_for_config_file 等 CTX_0 写完
     GEN_n  _wait_for_config_file 等 GEN_0 写完
T2   每个 worker:
        port = get_free_port()
        写 hostnames-<idx>/{CTX_n|GEN_n}.txt = "<hostname>:<port>"
        起 trtllm-serve <model> --host <hostname> --port <port>
                       --config extra-llm-api-config.{ctx,gen}.<name>.yml
T3   DISAGG_SERVER:
        _generate_disagg_server_config()
          ├── 等 hostnames-<idx>/ 文件数 == num_ctx + num_gen
          ├── 读所有 *.txt → ctx_hostnames / gen_hostnames
          ├── port = get_free_port()
          └── 写 server_config.<idx>.yaml      ◀── 这里才生成
        起 trtllm-serve disaggregated -c server_config.<idx>.yaml
T4   BENCHMARK:
        读 server_config.<idx>.yaml 拿到 disagg server host:port
        跑 benchmark
T5   benchmark 完成 → 写 benchmark_status.<idx>.txt → CTX/GEN/SERVER 看到这个文件就退出
```

### worker 配置如何"透传"到 disagg server

**短答：不透传。** `worker_config.ctx` / `worker_config.gen` 那些字段（max_batch_size / TP / KV / MoE / cache_transceiver_config 等）**只给 ctx/gen worker 自己的 trtllm-serve 用**，写在它们各自的 `extra-llm-api-config.{ctx,gen}.<name>.yml`，由 worker 进程的 LLM API + PyExecutor 消费。

disagg server 完全不需要知道 worker 的 LLM 配置。它只需要 worker 暴露在哪个 `host:port` 上 —— 这两个值通过 `hostnames-<idx>/{CTX_n,GEN_n}.txt` 文件接力给 DISAGG_SERVER 进程，最后落到 `server_config.<idx>.yaml` 的 `context_servers.urls` / `generation_servers.urls` 字段。

disagg server 启动后读这份 yaml，按 `parse_disagg_config_file → DisaggServerConfig` 链路解析（见 §2），传给 `OpenAIDisaggregatedService` —— **整个流水线唯一进 disagg service 的 worker 信息就是 URL**。

### 阶段性总结

| 文件 | 生成时机 | 谁 |
|---|---|---|
| `extra-llm-api-config.ctx.<name>.yml` | CTX_0 进 `get_commands()` 时 | `CTX_0` 写；`CTX_n` 等读 |
| `extra-llm-api-config.gen.<name>.yml` | GEN_0 进 `get_commands()` 时 | `GEN_0` 写；`GEN_n` 等读 |
| `hostnames-<idx>/CTX_n.txt` / `GEN_n.txt` | 每个 worker `run_cmd()` 起 trtllm-serve **之前** | 各自写自己那份 |
| `server_config.<idx>.yaml` | DISAGG_SERVER `run_cmd()` 起 disagg server **之前**（先等齐 hostname） | 只有 `DISAGG_SERVER` 写 |
