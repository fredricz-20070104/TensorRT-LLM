# TensorRT-LLM Disaggregated Serving 实现梳理（含 Wide-EP）

> 以 `tests/scripts/perf/disaggregated/gb200_deepseek-r1-fp4_1k1k_con1_ctx1_dep4_gen1_tep8_eplb0_mtp3_ccb-NIXL.yaml` 为例，从上层用法到 C++ 内核，分层说明 disagg（单节点 + 多节点）以及与之正交的 Wide-EP 的实现。

---

## 1. 总流程图（Disagg + Wide-EP）

```text
                   ┌──────────────────────────────────────────────┐
                   │   Client (curl / disagg_client.py / bench)   │
                   └─────────────┬────────────────────────────────┘
                                 │  HTTP /v1/completions
                                 ▼
   ┌───────────────────────────────────────────────────────────┐
   │            Disagg Front Server (trtllm-serve disagg)      │  ← serve/openai_disagg_server.py
   │   ── Router (load balance)                                │  ← serve/router.py
   │   ── OpenAIDisaggregatedService (两段式编排)              │  ← serve/openai_disagg_service.py
   └─────────┬───────────────────────────────────┬─────────────┘
             │ ① ctx_only  (request_type=context_only)
             │  + 收到 first_gen_tokens & opaque_state
             │
   ┌─────────▼──────────────┐                    │ ② gen_only (request_type=generation_only)
   │   Context Worker(s)    │                    │  + 把 opaque_state 透传给 gen worker
   │  trtllm-serve 单实例   │                    │
   │   ┌──────────────────┐ │                    │
   │   │ openai_server.py │ │                    │
   │   │      ▼           │ │   远程 KV-Cache    │
   │   │   LLM API        │ │  ◀═════════════▶   │
   │   │      ▼           │ │  (NIXL/UCX/MPI)    │
   │   │   PyExecutor     │◀┼────────────────┐   │
   │   │      ▼           │ │                │   │
   │   │ KvCacheTransceiver│                 │   │
   │   │  (Python wrapper)│ │                │   │
   │   │      ▼           │ │                │   │
   │   │ C++ CacheTransceiver  ⇄ ConnectionManager (NIXL/UCX/MPI/Mooncake)
   │   │      ▼           │ │                │   │
   │   │ CacheFormatter   │ │  按 TP/PP 切片  │   │
   │   │ + cacheSplitConcat.cu (CUDA kernel) │   │
   │   └──────────────────┘ │                │   ▼
   └────────────────────────┘                ┌────────────────────────┐
                                             │ Generation Worker(s)   │
                                             │  trtllm-serve 单实例    │
                                             │ (相同的 stack，但执行   │
                                             │  generation_only 路径) │
                                             └────────────────────────┘

   ───  正交维度：Wide-EP（影响 ctx/gen worker 内部的 MoE 层）─────────
   每个 worker 内部，DeepSeek-R1 / FP4 这种 MoE 模型走 WideEPMoE：
     _torch/modules/fused_moe/fused_moe_wide_ep.py
       └─ DeepEP 跨节点 alltoall (deep_ep_utils.py)
       └─ MnnvlMoe.MoEAlltoallInfo  (单节点 NVLink alltoall, _mnnvl_utils.py)
       └─ MoeLoadBalancer (EPLB, moe_load_balancer.py) — 你的 yaml 里 eplb0=关闭
```

yaml 字段与各层的对应：

| yaml 字段 | 落点 |
|---|---|
| `cache_transceiver_config.backend: NIXL`, `max_tokens_in_buffer` | **Layer 3/4**：`KvCacheTransceiver` → C++ `CacheTransceiver` → NIXL backend |
| `worker_config.gen.tensor_parallel_size: 8`, `moe_expert_parallel_size: 8` | **Layer 2 worker**：`Mapping`/TorchLlmArgs；MoE 层选 **WideEPMoE** |
| `worker_config.ctx.enable_attention_dp: true`, `enable_lm_head_tp_in_adp: true` (dep4) | Wide-EP 在 ctx 用 attention DP 模式 |
| `speculative_config: MTP, num_nextn_predict_layers: 3` | 投机解码 MTP-3，对 ctx/gen 都生效；ctx 端会顺带把 draft tokens 通过 `DisaggregatedParams.draft_tokens` 传给 gen |
| `disable_overlap_scheduler: true` | PyExecutor 的 disagg 路径目前要求 ctx 关闭 overlap scheduler |

---

## 2. Layer 1 — 最上层：用法 & disagg 前端 server

### 2.1 用法（examples 里的对照）

**单节点（`examples/disaggregated/disagg_config.yaml`）：**
- 同一台机器、3 个进程：1×router、1×ctx-worker、1×gen-worker
- 每个 worker 是独立的 `trtllm-serve <model> --port ...`
- router 看 yaml 里的 `urls:` 字段把 ctx 和 gen 串起来

```bash
# ctx
CUDA_VISIBLE_DEVICES=0 trtllm-serve <model> --port 8001 --config ctx.yaml &
# gen
CUDA_VISIBLE_DEVICES=1 trtllm-serve <model> --port 8002 --config gen.yaml &
# router/前端
trtllm-serve disaggregated --config disagg_config.yaml
```

**多节点（`examples/disaggregated/slurm/`）：**
- 三个 sbatch 脚本：`simple_example/`、`benchmark/`、`service_discovery_example/`
- 用 SLURM 把 ctx workers / gen workers 拉到不同节点；前端 server 单独一台
- 多节点本质就是把同样的进程拓扑跨节点起，KV 通过 NIXL 走 RDMA / EFA / NVLink-fabric

### 2.2 前端 server 的代码

| 关键文件 | 作用 |
|---|---|
| [tensorrt_llm/serve/openai_disagg_server.py](tensorrt_llm/serve/openai_disagg_server.py) | FastAPI 入口，OpenAIDisaggServer，建 ctx/gen 两个 Router |
| [tensorrt_llm/serve/openai_disagg_service.py](tensorrt_llm/serve/openai_disagg_service.py) | `OpenAIDisaggregatedService`：核心两段式调度（ctx → gen） |
| [tensorrt_llm/serve/router.py](tensorrt_llm/serve/router.py) | 选 worker（round-robin / KV-cache-aware / load-balanced） |
| [tensorrt_llm/llmapi/disagg_utils.py](tensorrt_llm/llmapi/disagg_utils.py) | `DisaggServerConfig` 解析 yaml |
| [tensorrt_llm/disaggregated_params.py](tensorrt_llm/disaggregated_params.py) | `DisaggregatedParams` —— 在 ctx/gen 之间传递的元数据（first_gen_tokens、opaque_state、ctx_request_id、draft_tokens 等） |

**两段式编排的核心逻辑**（`openai_disagg_service.py`）：
1. 把客户端请求标记为 `request_type="context_only"`，`max_tokens=1`，发给 ctx worker；
2. ctx worker 返回 `first_gen_tokens` + `opaque_state`（KV cache 句柄信息）；
3. 同一请求用 `request_type="generation_only"`，附带 ctx 的 `disaggregated_params`，发给 gen worker；
4. gen worker 通过 KV transceiver **拉**远端 ctx 的 KV，然后开始正常 generation，流式返回 token。

---

## 3. Layer 2 — Worker 内部：从 trtllm-serve 到 PyExecutor 的 disagg 主循环

每个 ctx/gen worker 都是一个普通的 `trtllm-serve`：
- HTTP 入口 [tensorrt_llm/serve/openai_server.py](tensorrt_llm/serve/openai_server.py)
- LLM API：[tensorrt_llm/llmapi/llm.py](tensorrt_llm/llmapi/llm.py)，吃 `TorchLlmArgs`
- 真正干活的执行器：[tensorrt_llm/_torch/pyexecutor/py_executor.py](tensorrt_llm/_torch/pyexecutor/py_executor.py)

**触发 disagg 模式的开关**：`TorchLlmArgs.cache_transceiver_config != None`。这条件下，[py_executor.py:557](tensorrt_llm/_torch/pyexecutor/py_executor.py#L557) 会持有一个 `kv_cache_transceiver` 对象。

PyExecutor 主循环（`_executor_loop` / `_executor_loop_pp`）每个 iteration 多出 4 个 disagg-only 步骤（[py_executor.py:1509-1551](tensorrt_llm/_torch/pyexecutor/py_executor.py#L1509-L1551)）：

| 方法 | 谁调用 | 干什么 |
|---|---|---|
| `_check_disagg_ctx_schedulable_status(new_reqs)` | 两端都调 | 把 ctx-only 请求标进可调度集合 |
| `_check_disagg_gen_transfer_status` | gen worker | 轮询 C++ 层 KV 接收是否完成；完成后状态切到 GENERATION_IN_PROGRESS |
| `_prepare_disagg_gen_init(fitting_reqs)` | gen worker | 给"已经能装下"的 gen 请求分配 KV 块、开始拉远端 KV |
| `_check_disagg_ctx_cache_transfer_status(at_least)` | ctx worker | 轮询 C++ 层 KV 发送是否完成；完成后释放 ctx 端 KV |

请求状态机（核心两个新状态）：
- `DISAGG_CONTEXT_TRANS_IN_PROGRESS`（ctx 算完，正在把 KV 推/被拉走）
- `DISAGG_GENERATION_TRANS_IN_PROGRESS`（gen 端正在等远端 KV 到位）

---

## 4. Layer 3 — KV cache transceiver 的 Python 包装层

入口：[tensorrt_llm/_torch/pyexecutor/kv_cache_transceiver.py](tensorrt_llm/_torch/pyexecutor/kv_cache_transceiver.py)

`create_kv_cache_transceiver()` 是工厂函数，根据 `cache_transceiver_config` 选实现：

- **CPP 路径（默认）**：`KvCacheTransceiver` → 直接调 `tensorrt_llm.bindings.internal.batch_manager.CacheTransceiver`（C++ 通过 nanobind 暴露）
- **Python 路径**（`transceiver_runtime: "PYTHON"`，新版，只支持 NIXL）：`KvCacheTransceiverV2`，实现在 [tensorrt_llm/_torch/disaggregation/transceiver.py](tensorrt_llm/_torch/disaggregation/transceiver.py)
  - 子目录组织：
    - `base/transfer.py` — 抽象接口（`TxSessionBase`、`RxSessionBase`）
    - `native/transfer.py` — `TransferWorker` 主循环
    - `nixl/` — Python 直接调 NIXL agent
    - `resource/` — KV 块 → 物理页面映射

CPP 路径下 backend 还能选 `NIXL` / `UCX` / `MOONCAKE` / `MPI`（你 yaml 里 `backend: NIXL`）。

---

## 5. Layer 4 — C++ 核心（`CacheTransceiver`）

头文件：[cpp/include/tensorrt_llm/batch_manager/cacheTransceiver.h](cpp/include/tensorrt_llm/batch_manager/cacheTransceiver.h)

类层次：
```
BaseCacheTransceiver  (抽象接口)
    └─ CacheTransceiver  (实现)
            ├─ CacheSender    ── ctx 端：回应 + 发 KV
            ├─ CacheReceiver  ── gen 端：发请求 + 收 KV
            └─ CacheTransceiverComm (MPI 或 c10d ProcessGroup 通信句柄)
```

四个核心 API（参考 `cacheTransceiver.h:203` 起的 `BaseCacheTransceiver`）：
- `respondAndSendAsync(req)` —— ctx 端调用，把这个 req 的 KV 标记为待发送
- `requestAndReceiveAsync(req)` —— gen 端调用，开始向 ctx 拉 KV
- `checkContextTransferStatus(...)` —— ctx 端轮询，返回完成/失败的请求集合
- `checkGenTransferStatus(...)` —— gen 端轮询接收进度

实现文件:
- [cpp/tensorrt_llm/batch_manager/cacheTransceiver.cpp](cpp/tensorrt_llm/batch_manager/cacheTransceiver.cpp) —— 主调度 + 状态机
- [cpp/tensorrt_llm/batch_manager/dataTransceiver.h/.cpp](cpp/tensorrt_llm/batch_manager/dataTransceiver.cpp) —— `TransferSession`：把每条 request 的 KV 拆成多次实际传输
- [cpp/tensorrt_llm/batch_manager/cacheFormatter.h/.cpp](cpp/tensorrt_llm/batch_manager/cacheFormatter.cpp) —— **核心难点**：`CacheFormatter` 在不同 TP/PP/CP 拓扑之间切片/重组 KV
- [cpp/tensorrt_llm/batch_manager/mlaCacheFormatter.cpp](cpp/tensorrt_llm/batch_manager/mlaCacheFormatter.cpp) —— **MLA 版**（DeepSeek 走这条路！）
- [cpp/tensorrt_llm/batch_manager/rnnCacheFormatter.cpp](cpp/tensorrt_llm/batch_manager/rnnCacheFormatter.cpp) —— Mamba/RNN 版
- [cpp/tensorrt_llm/batch_manager/cacheTransBuffer.h/.cpp](cpp/tensorrt_llm/batch_manager/cacheTransBuffer.cpp) —— 预分配的中转 buffer（你 yaml 里的 `max_tokens_in_buffer: 16384` 直接落到这里）

CUDA kernel：
- [cpp/tensorrt_llm/executor/cache_transmission/cacheSplitConcat.cu](cpp/tensorrt_llm/executor/cache_transmission/cacheSplitConcat.cu) —— 跨 TP rank 的 KV split/concat 是用专门的 CUDA kernel 做的（不是普通 cudaMemcpy），这样能在 send/recv 之前在 GPU 上一次性把布局对齐。

---

## 6. Layer 5 — 传输 backend（NIXL/UCX/...）

抽象接口：[cpp/include/tensorrt_llm/executor/cacheCommunicator.h](cpp/include/tensorrt_llm/executor/cacheCommunicator.h)
- `Connection` —— 一条点对点连接
- `ConnectionManager` —— 连接池
- `DataContext` —— 数据上下文（device id、stream 等）

各 backend 的实现：[cpp/tensorrt_llm/executor/cache_transmission/](cpp/tensorrt_llm/executor/cache_transmission/)

| 子目录 | backend | 说明 |
|---|---|---|
| `nixl_utils/` | **NIXL** | 默认；底下还能选 UCX (默认) / LIBFABRIC（EFA），通过 `TRTLLM_NIXL_KVCACHE_BACKEND` 选 |
| `ucx_utils/` | UCX | 老路径，仍然可用 |
| `mooncake_utils/` | MOONCAKE | 月之暗面的方案 |
| `mpi_utils/` | MPI | 已 deprecated |
| `agent_utils/` | 通用 | NIXL 的 transferAgent 抽象 |

[cpp/include/tensorrt_llm/executor/transferAgent.h](cpp/include/tensorrt_llm/executor/transferAgent.h) 是 NIXL 这层的抽象 agent 接口。

**多节点本质**就是这一层：NIXL 在节点内走 NVLink/IPC，跨节点走 RDMA/EFA。Python/调度层完全不感知"几台机"。

---

## 7. Layer 6 — Wide-EP（与 disagg 正交的另一条线）

注意：**Wide-EP 不是 disagg 的一部分**，它是 MoE 在大规模 EP（>1 节点 worth of GPU）下的 MoE 层实现。两者在你这条 yaml 里**同时启用**，但代码路径独立。

入口：[tensorrt_llm/_torch/modules/fused_moe/fused_moe_wide_ep.py](tensorrt_llm/_torch/modules/fused_moe/fused_moe_wide_ep.py)

```
class WideEPMoE(MoE):                  # ← yaml 里 moe_expert_parallel_size 触发
   forward 流程:
     1. routing → top-k gates
     2. permute by expert
     3. all-to-all（核心）：
        - 单节点 NVLink:  MnnvlMoe.MoEAlltoallInfo  (_mnnvl_utils.py)
        - 跨节点:          DeepEP buffer (deep_ep_utils.py)
     4. expert grouped GEMM (Cutlass / DeepGemm / TRTLLMGen)
     5. all-to-all 反向回流
     6. (可选) MoeLoadBalancer 重排专家  ← yaml eplb0=禁用
```

相关文件：

| 文件 | 作用 |
|---|---|
| [tensorrt_llm/_torch/modules/fused_moe/fused_moe_wide_ep.py](tensorrt_llm/_torch/modules/fused_moe/fused_moe_wide_ep.py) | `WideEPMoE` 主类 |
| [tensorrt_llm/_torch/modules/fused_moe/create_moe.py](tensorrt_llm/_torch/modules/fused_moe/create_moe.py) | 工厂：根据 EP/TP/模型自动选 WideEPMoE / CutlassFusedMoE / TRTLLMGenFusedMoE |
| [tensorrt_llm/_torch/modules/fused_moe/moe_load_balancer.py](tensorrt_llm/_torch/modules/fused_moe/moe_load_balancer.py) | **EPLB**（你 yaml 里 `eplb0` 是关闭，没冗余专家） |
| [tensorrt_llm/_torch/modules/fused_moe/deep_ep_utils.py](tensorrt_llm/_torch/modules/fused_moe/deep_ep_utils.py) | DeepEP 跨节点 alltoall 通讯库封装 |
| [tensorrt_llm/_mnnvl_utils.py](tensorrt_llm/_mnnvl_utils.py) | NVLink 域内 alltoall（GB200 一柜内 NVL72） |
| [tensorrt_llm/_torch/models/modeling_deepseekv3.py](tensorrt_llm/_torch/models/modeling_deepseekv3.py) | DeepSeek V3/R1 模型，组装 WideEPMoE |

---

## 8. 把这些拼回到示例 yaml

`gb200_deepseek-r1-fp4_1k1k_con1_ctx1_dep4_gen1_tep8_eplb0_mtp3_ccb-NIXL.yaml`：

- **ctx server**（1 个，TP=4，EP=4，attention_dp=on）：跑 DeepSeek-R1 FP4，prefill 1024 tokens
  - MoE 层 → `WideEPMoE`（EP=4 在单节点 NVLink alltoall）
  - 算完后，C++ `CacheSender` 把这条请求的 MLA KV 通过 **NIXL** 推给 gen
- **gen server**（1 个，TP=8，EP=8，attention_dp=off，CUDA Graph 开 padding）
  - `_prepare_disagg_gen_init` 拉 KV → 进入 GEN-only 主路径
  - MTP-3 投机解码 + Wide-EP MoE，输出 1024 tokens
- **disagg 前端**：把 client 的请求拆成 ctx_only → gen_only 串起来

---

## 9. 多 worker 多节点的 HTTP + NIXL 全图通信

> 单 worker 多节点的 MPI/ZMQ 协调见 [EXPLANATION.md §6](EXPLANATION.md#6-jenkinsscriptsperflocal-流水线hostport-运行时生成)。本节专讲**多个 worker 之间**怎么通信。

### 9.1 配置示例（让两端都跨多 worker 多节点）

```yaml
hardware:
  num_ctx_servers: 2
  num_gen_servers: 1
  gpus_per_node: 4

worker_config:
  ctx:
    tensor_parallel_size: 4   # 每个 ctx worker 4 GPU = 1 节点
  gen:
    tensor_parallel_size: 8   # gen worker 8 GPU = 2 节点
  cache_transceiver_config:
    backend: NIXL
```

物理拓扑（4 个节点）：

```text
gb200-001 (node A)         gb200-002 (node B)         gb200-003 (node C)         gb200-004 (node D)
┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐       ┌──────────────────┐
│ ctx-worker-0     │       │ ctx-worker-1     │       │ gen-worker-0     │       │ gen-worker-0     │
│ TP=4 (rank 0..3) │       │ TP=4 (rank 0..3) │       │ TP=8 (rank 0..3) │       │ TP=8 (rank 4..7) │
│                  │       │                  │       │                  │       │                  │
│ rank 0 起:       │       │ rank 0 起:       │       │ rank 0 起:       │       │ rank 4..7:       │
│   trtllm-serve   │       │   trtllm-serve   │       │   trtllm-serve   │       │   只跑 mgmn      │
│   :8001          │       │   :8002          │       │   :8003          │       │   _worker_node   │
│   mgmn_leader    │       │   mgmn_leader    │       │   mgmn_leader    │       │                  │
│ rank 1..3:       │       │ rank 1..3:       │       │   ┌────────────┐ │       │                  │
│   mgmn_worker    │       │   mgmn_worker    │       │   │disagg-srv  │ │       │                  │
│                  │       │                  │       │   │ :8000      │ │       │                  │
│                  │       │                  │       │   └────────────┘ │       │                  │
└──────────────────┘       └──────────────────┘       └──────────────────┘       └──────────────────┘
        │                          │                          │                          │
        └──────────────────────────┴── IB / RDMA / NVLink ────┴──────────────────────────┘
```

关键事实：
- **每个 worker 是独立 srun，独立 MPI 世界**。ctx-worker-0 / ctx-worker-1 / gen-worker-0 三条 MPI_COMM_WORLD 互不重叠。
- **disagg-server** 跟 gen-worker-0 的 rank 0 同节点（`convert_allocations_to_server_config` 默认选第一个 gen worker 的节点），但它们是**两个独立进程**，只通过 HTTP 通信。
- 节点 D 上**只有** gen worker 的 rank 4..7（mgmn_worker_node），没有 trtllm-serve / disagg-server / mgmn_leader。

### 9.2 通信分两层

整个调用链有**两个完全不同的通信层**：

| 层 | 协议 | 谁参与 | 干啥 |
|---|---|---|---|
| **控制面（control plane）** | HTTP | 客户端 ↔ disagg-server ↔ ctx/gen worker 的 **rank 0** | 派活：发请求、传 first_gen_token、流式回 token |
| **数据面（data plane）** | NIXL（底层 RDMA） | ctx worker **每个 rank** ↔ gen worker **每个 rank** | 搬 KV cache 实际字节 |

### 9.3 控制面：HTTP 串联（只跟 rank 0 打交道）

```text
T0  Client: curl POST gb200-003:8000/v1/completions  -d '{"prompt":"hello",...}'
        │
        ▼
T1  disagg-server (gb200-003) 收到
    │ ctx_router.get_next_server() → 比如 round_robin 选中 ctx-worker-0
    │ 构造 ctx_req: request_type="context_only"
    │
    ▼  HTTP POST gb200-001:8001/v1/completions
T2  ctx-worker-0 的 trtllm-serve（rank 0 在 gb200-001）收到
    │ HTTP 进 OpenAIServer.openai_completion()
    │ → LLM API 触发 forward
    │ → ZMQ 派给本机 mgmn_leader_node
    │ → MPI broadcast 给 ctx-worker-0 的 rank 0..3（都在 gb200-001 内）
    │ → 4 个 rank 同时算 prefill（节点内 NVLink + NCCL）
    │ → prefill 算完，每个 rank 把自己那 1/4 KV 写进自己 GPU 的 KV cache buffer
    │ → rank 0 返回 HTTP 200，body 含 first_gen_token + ContextPhaseParams
    │   ContextPhaseParams = {ctx_request_id, opaque_state, ctx_info_endpoint, ...}
    │
    │ ⚠️ ctx-worker-1 这次完全没参与
    │ ⚠️ gen-worker-0 这时候也还没收到任何请求
    │
    ▼  HTTP 200
T3  disagg-server 收到 ctx 的回复
    │ 提取 disaggregated_params
    │ gen_router.get_next_server() → 选中 gen-worker-0
    │ 构造 gen_req: request_type="generation_only", 带上 disaggregated_params
    │
    ▼  HTTP POST gb200-003:8003/v1/completions
T4  gen-worker-0 的 trtllm-serve（rank 0 在 gb200-003）收到
    │ HTTP 进 OpenAIServer
    │ → LLM API → PyExecutor 把请求标成 GENERATION_ONLY
    │ → ZMQ → MPI broadcast → gen-worker-0 的 rank 0..7（跨 gb200-003 + gb200-004）
    │ → 每个 rank 调 kv_cache_transceiver.request_and_receive_async(req)
    │ → 触发 NIXL 拉 KV ──── 这一刻才进入数据面 ──────┐
    │                                                │
    ▼                                                ▼ (见 §9.4)
```

⚠️ **HTTP 通信的对象永远只是 rank 0** —— ctx-worker-0 的 rank 1/2/3 从不直接接 HTTP；gen-worker-0 的 rank 4..7（在 gb200-004）连 HTTP 端口都没监听。每个 worker 内部用 MPI 把 rank 0 收到的请求广播给其它 rank（具体见 EXPLANATION.md §6 的 trtllm-llmapi-launch 机制）。

### 9.4 数据面：NIXL 直连（rank 跟 rank 之间）

NIXL 这一层**绕过 disagg-server**，**绕过 HTTP**，**绕过 worker 之间的 MPI**，直接 ctx 的 rank ↔ gen 的 rank 之间走 RDMA。

#### 9.4.1 谁连谁：跨 TP 拓扑的 rank 映射

ctx-worker-0 是 TP=4，每个 rank 持完整 KV 的 1/4；gen-worker-0 是 TP=8，每个 rank 需要完整 KV 的 1/8。**两者拓扑不一样** —— 这就是 `MLACacheFormatter` 要解决的问题（见 §5）。

简化的对应关系（实际由 `TargetRanksInfo` 算）：

```text
ctx-worker-0 (TP=4, gb200-001)              gen-worker-0 (TP=8, gb200-003 + gb200-004)

ctx rank 0 持 KV[0:1/4]   ──┬──▶ gen rank 0 (gb200-003) 需要 KV[0:1/8]
                           └──▶ gen rank 1 (gb200-003) 需要 KV[1/8:2/8]
ctx rank 1 持 KV[1/4:2/4]  ──┬──▶ gen rank 2 (gb200-003) 需要 KV[2/8:3/8]
                           └──▶ gen rank 3 (gb200-003) 需要 KV[3/8:4/8]
ctx rank 2 持 KV[2/4:3/4]  ──┬──▶ gen rank 4 (gb200-004) 需要 KV[4/8:5/8]
                           └──▶ gen rank 5 (gb200-004) 需要 KV[5/8:6/8]
ctx rank 3 持 KV[3/4:4/4]  ──┬──▶ gen rank 6 (gb200-004) 需要 KV[6/8:7/8]
                           └──▶ gen rank 7 (gb200-004) 需要 KV[7/8:8/8]
```

每个 ctx rank 把自己那 1/4 切成 2 半，**分别**送给两个 gen rank（因 gen 比 ctx 多一倍）。

#### 9.4.2 NIXL 实际握手 + 传输（举 ctx rank 0 → gen rank 0 这一对）

```text
建链阶段（ctx 启动时就建好）：
  ctx-worker-0 rank 0 启动时：
    创建 NIXL agent，本地 ZMQ 端点 = "tcp://gb200-001:<rank0_zmq_port>"
    把 KV cache buffer 注册给 NIXL（让 NIXL 知道这块内存在哪、多大）
    通过 ZMQ 暴露 agent metadata（地址簿）

  ctx_info_endpoint = "tcp://gb200-001:<rank0_zmq_port>"
    会在 ctx 返回 HTTP 200 时塞进 ContextPhaseParams
    传给 disagg-server，再传给 gen-worker-0 rank 0


传输阶段（gen 收到 generation_only 请求后）：

  T4.1  gen-worker-0 rank 0 (gb200-003) 调 request_and_receive_async(req)
        从 req.disaggregated_params 读到:
          ctx_request_id   = 123
          ctx_info_endpoint = "tcp://gb200-001:<rank0_zmq_port>"

  T4.2  gen rank 0 通过 ZMQ 连到 ctx rank 0 的 endpoint
        发 REQUEST_DATA: "我是 gen rank 0，要请求 123 的 KV[0:1/8]"
        附上 gen rank 0 自己的 NIXL agent metadata

  T4.3  ctx rank 0 收到 REQUEST_DATA
        在 NIXL agent 注册这个 peer
        准备 KV 块（这条 req 的 KV[0:1/4] 切成 2 半）

  T4.4  NIXL 触发 RDMA write/read，从 ctx rank 0 的 GPU 内存
        直接搬到 gen rank 0 的 GPU 内存
        路径: gb200-001 GPU 0 → IB/RDMA → gb200-003 GPU 0
        ⚠️ 绕过 CPU、NCCL、MPI，绕过 disagg-server

  T4.5  传完后，NIXL 在 gen 那边触发回调
        gen rank 0 状态切到 DISAGG_GENERATION_TRANS_COMPLETE

  上面 T4.1..T4.5 在每对 (ctx_rank, gen_rank) 上独立并发发生：
    ctx0→gen0/1, ctx1→gen2/3, ctx2→gen4/5, ctx3→gen6/7
  ⚠️ 8 条 NIXL 通道里有 4 条跨节点 (gb200-001 ↔ gb200-004)，走 IB/RDMA
```

#### 9.4.3 PyExecutor 怎么知道 KV 全部到了

每个 gen rank 的 PyExecutor 主循环每个 iter 调 [`_check_disagg_gen_transfer_status`](tensorrt_llm/_torch/pyexecutor/py_executor.py#L3153)：

```python
if all(rank's NIXL transfer completed for req 123):
    req.state = LlmRequestState.DISAGG_GENERATION_TRANS_COMPLETE
    # 进入正常 GENERATION_IN_PROGRESS，开始 decode
```

8 个 gen rank 通过 worker 内部的 MPI（gen-worker-0 的 MPI_COMM_WORLD）协调，确认所有 rank ready 后才统一开始 decode。

### 9.5 后续 streaming：还是 HTTP

```text
T5  gen-worker-0 rank 0 开始 decode
    每个 token 算完，rank 0 通过 MPI 收齐 8 个 rank 的结果
    流式 yield 给 HTTP 客户端（disagg-server）

T6  disagg-server 把每个 chunk 转发回原始 client
```

### 9.6 一条 NIXL 路径上的完整技术栈

以 `ctx-worker-0 rank 3 (gb200-001) → gen-worker-0 rank 7 (gb200-004)` 为例：

```text
┌─ 应用层 ───────────────────────────────────────────────────┐
│ ctx side: cacheTransceiver.cpp::CacheSender                │
│ gen side: cacheTransceiver.cpp::CacheReceiver              │
│ 控制消息走 ZMQ TCP（注册 peer / 协商 buffer 地址）          │
└──────────────────────────────────────────────────────────┘
                            │
┌─ NIXL 抽象层 ─────────────────────────────────────────────┐
│ TransferAgent  (cpp/.../cache_transmission/nixl_utils/)    │
│   - register_memory: GPU buffer 注册给 NIXL               │
│   - transfer: 触发 RDMA write/read                        │
└──────────────────────────────────────────────────────────┘
                            │
┌─ NIXL 后端（默认 UCX）─────────────────────────────────────┐
│ TRTLLM_NIXL_KVCACHE_BACKEND=UCX (默认) 或 LIBFABRIC        │
└──────────────────────────────────────────────────────────┘
                            │
┌─ 网络硬件 ────────────────────────────────────────────────┐
│ GPU3 (gb200-001) ──HCA──▶ IB switch ──HCA──▶ GPU3 (gb200-004) │
│ GPUDirect RDMA: GPU 内存 → NIC → 跨节点 → NIC → GPU 内存  │
│                  整个传输 CPU 不参与，零拷贝               │
└──────────────────────────────────────────────────────────┘
```

### 9.7 几个关键对比要点

#### ctx-worker-1 这次干啥了

**啥也没干**。它的 4 个 rank 安静守 GPU，没收到 HTTP，没参与 NIXL，没参与 MPI。下一次请求 round-robin 才轮到它。

#### 多 ctx worker 之间是否要通信

**不需要**。ctx-worker-0 和 ctx-worker-1 之间没有任何通信通道：
- 没有 HTTP（disagg-server 一次只跟一个 ctx 说话）
- 没有 MPI（两个 worker 是两条独立 srun）
- 没有 NIXL（NIXL 只在 ctx ↔ gen 之间用）

#### 比喻：连锁餐厅 + 冷链卡车

| 角色 | 现实 |
|---|---|
| 客户 | Client |
| 总店调度（中央派单台） | disagg-server |
| 备料厨房 1 / 2 | ctx-worker-0 / ctx-worker-1 |
| 出菜厨房（跨两仓库） | gen-worker-0（gb200-003 + gb200-004）|
| **调度员的电话** | **HTTP 控制面** |
| **餐厅之间专用冷链卡车（GPUDirect RDMA）** | **NIXL 数据面** |

流程：
1. 客户打电话给调度 → 让备料厨房 1 开工（HTTP 1）
2. 备料厨房 1 内部 4 个厨师一起备料（MPI + NCCL），备完后老板回电："料备好了，在库房 A 门牌 123"（HTTP 2 + ctx_info_endpoint）
3. 调度叫出菜厨房接单（HTTP 3）
4. 出菜厨房 8 个厨师**直接开冷链卡车**从备料厨房 1 拉料（NIXL/RDMA，绕过调度员）
5. 料齐了 → 8 个人合作做菜 → 老板把菜传回调度 → 转给客户（HTTP streaming）

调度员**从不亲自搬料**；料从备料厨房直送出菜厨房。

### 9.8 一句话总结

> 多 worker 多节点下的 disagg 通信分**两层完全不同**的路径：
>
> - **HTTP 控制面只走 rank 0** —— disagg-server 通过 HTTP 跟 ctx/gen 各 worker 的 rank 0 打交道，告诉它们要做什么；每个 worker 内部用 MPI 把任务广播给自己的所有 rank；不同 worker 之间**没有共享的 MPI**。
> - **NIXL 数据面走 rank 跟 rank** —— 每个 ctx rank 跟它对应的 gen rank（按 TP 拓扑映射）直接走 RDMA，绕过 disagg-server，绕过 MPI；跨节点用 IB，节点内可走 NVLink/IPC。控制元信息（ctx_info_endpoint、ctx_request_id）通过 HTTP 一次性带过去，握手用 ZMQ TCP，真正搬数据用 RDMA。
> - **不参与的 worker（如另一个 ctx）完全静默**，不消耗任何通信带宽。

---

## 10. CTX / GEN 配置参数详解

### 10.1 设计哲学：两个性格不同的厨房

| | CTX（备料厨房） | GEN（出餐窗口） |
|---|---|---|
| 干嘛 | prefill：一次性吃下整段 prompt | decode：一次只产 1 个 token |
| 计算瓶颈 | **算力受限**（compute-bound） | **带宽受限**（memory-bound） |
| 一次干多少 | 少 batch（16）+ 长 seq（16384 tok） | 多 batch（128）+ 短 step（4 tok = 1+MTP3） |
| KV 占用 | 算完就推走 | 全程持有到生成结束 |

→ ctx 像中央备料工厂（大批量、加工时间长但发完即清仓）；gen 像快餐窗口（128 单同时上、每 4 秒出菜，每单需保留半成品）。

### 10.2 yaml → 代码的完整消费链路

```text
worker_config.ctx / .gen
  ⑴ submit.py 拆出来 dump → extra-llm-api-config.{ctx,gen}.<name>.yml
  ⑵ trtllm-serve --config <这个 yaml>
  ⑶ serve.py: yaml.safe_load → update_llm_args_with_extra_dict()
        ↓
  TorchLlmArgs(...) (Pydantic, llm_args.py)
        ↓
  PyTorchLLM(**llm_args) → executor → worker_main → 各 rank 独立构建：
    ┌─────────────────────────────────────────────────┐
    │ Mapping            ← tensor_parallel_size 等    │
    │ KVCacheManager     ← kv_cache_config            │
    │ PyTorchModelEngine ← max_batch_size/num_tokens  │
    │   └─ Model         ← moe_config 选 backend      │
    │ KvCacheTransceiver ← cache_transceiver_config   │
    │ SpecConfig         ← speculative_config         │
    │ Sampler            ← stream_interval            │
    │ PyExecutor         ← disable_overlap_scheduler  │
    └─────────────────────────────────────────────────┘
```

### 10.3 参数完整对照（按用途分组）

| 参数 | ctx | gen | 这么配的原因 |
|---|---|---|---|
| **资源容量** | | | |
| `max_batch_size` | 16 | **128** | ctx 长 seq 少并发；gen 短 step 大并发 |
| `max_num_tokens` | **16384** | 512 | ctx 一次吃整段 prompt；gen 每步 batch×4 |
| `kv_cache_config.free_gpu_memory_fraction` | 0.6 | 0.9 | gen 长持 KV 要榨干；ctx 留 cache_transceiver buffer |
| `kv_cache_config.dtype` | fp8 | fp8 | KV 量化，省一半显存 |
| `kv_cache_config.enable_block_reuse` | false | false | disagg 下 ctx 推走即释放，复用窗口几乎不存在 |
| **并行** | | | |
| `tensor_parallel_size` | 4 | 8 | gen 带宽 bound，多 GPU 摊薄读权重时间 |
| `moe_expert_parallel_size` | 4 | 8 | 跟 TP 同步切（DeepSeek MoE 设定）|
| `enable_attention_dp` | true | false | 详见 §11 |
| `enable_lm_head_tp_in_adp` | true | (默认) | ADP 下 lm_head 单独走 TP，避免 4 rank 各跑 vocab projection |
| **CUDA Graph** | | | |
| `cuda_graph_config` | null | enable_padding=true, max_batch_size=128 | 详见 §12 |
| **MoE backend** | | | |
| `moe_config.backend` | CUTEDSL | TRTLLM | 按 token 规模选最优 kernel |
| `moe_config.use_low_precision_moe_combine` | true | (默认 false) | ctx combine 通信量大，量化省带宽 |
| **KV 跨进程传输** | | | |
| `cache_transceiver_config.backend` | NIXL | NIXL | 跨节点 RDMA 传 KV |
| `cache_transceiver_config.max_tokens_in_buffer` | 16384 | 16384 | ≥ 最大 ISL，详见 §13 |
| **调度** | | | |
| `disable_overlap_scheduler` | true | true | disagg + overlap 不兼容 |
| `speculative_config` (MTP-3) | 共用 | 共用 | 两端必须一致，否则状态对不上 |
| `num_postprocess_workers` | (默认 0) | 4 | gen 流式 detok 重，需异步 |
| `stream_interval` | (默认 1) | 20 | gen 每 20 token flush 一次 SSE，省 HTTP 开销 |
| **通信** | | | |
| `allreduce_strategy` | (默认 NCCL) | MNNVL | gen 跨节点用 NVL72 专用通道 |

---

## 11. 并行模式深入：TP / DP / ADP

### 11.1 一句话区分

| | 切**模型**还是切**数据** | 各 rank 在干啥 |
|---|---|---|
| **TP** | 切模型（每 rank 持 1/N 权重） | 同一批数据，**一起**算 |
| **DP** | 切数据（每 rank 持完整模型） | 不同的数据，**各自**算 |
| **ADP**（attention DP） | **混合**：attention 走 DP，MLP/MoE 还是 TP | attention 各算各的请求；MLP 协作 |

记忆口诀：TP = "分工合作"，DP = "各干各的"。

### 11.2 ADP 的细节（为什么 ctx 能用，gen 不用）

**ADP 不是纯 DP**，是 **attention DP + MLP/MoE TP** 的混合。所以：
- attention 权重在每 rank 复制（占模型 ~5%，**显存代价小**）
- MLP/MoE 权重还是 TP 切（占模型 ~95%，**没多花显存**）

ctx 单卡显存对比（DeepSeek-R1 FP4 ≈ 350 GB）：

| 模式 | 单卡占用 |
|---|---|
| 纯 TP (TP=4) | 87 GB |
| **ADP (TP=4, attn DP)** | **100 GB**（多 13 GB attention 复制）|
| 纯 DP | 350 GB ❌ 装不下 |

→ 13 GB 显存换 attention 内部 all-reduce 消失，prefill 大赚。

### 11.3 为什么 prefill 喜欢 ADP，decode 不喜欢

```
普通 TP attention 每层 all-reduce 量：
  prefill 1024 token: 14 MB / 层 → 60 层 = 840 MB / 请求  ← 大
  decode 1 token   : 14 KB / 层 → 60 层 = 840 KB / step  ← 小

ADP 省掉 attention all-reduce，但代价是边界 all-gather/scatter:
  prefill: 摊到 1024 token，每 token 占比小  → 净赚
  decode : 摊到 1 个 token，all-gather 反而被放大 → 净亏
```

加上 decode 还有：负载不均衡（continuous batching 下 ADP straggler 严重）+ batch 拆碎（128 → 16/rank，arithmetic intensity 下降）。

→ **ctx (prefill) 开 ADP 大赚；gen (decode) 不开**。

### 11.4 ADP 必须的两个通信：all-gather 和 scatter

attention(DP) 输出形状 ≠ MLP(TP) 期待形状，中间必须做集合通信：

```
attention DP 输出：每 rank 自己请求的 hidden state [1024, 7168]
                      │
                      ▼ all-gather（每 rank 发 1/N，收 (N-1)/N，按 rank 拼接）
MLP TP 输入：每 rank 看到全部请求 hidden state [4096, 7168]
                      │
                      ▼ MLP 内部 TP（自带 all-reduce）
MLP TP 输出：每 rank 都有完整 [4096, 7168]
                      │
                      ▼ reduce-scatter（all-reduce + scatter 合并优化）
下层 attention DP 输入：每 rank 只剩自己的 [1024, 7168]
```

关键集合通信原语：

| 操作 | 输入 | 输出 |
|---|---|---|
| **all-reduce** | 每 rank 各持完整数据 | 每 rank 拿到 sum |
| **all-gather** | 每 rank 各持 1/N | 每 rank 拿到完整拼接 |
| **scatter** | rank 0 持完整 | 每 rank 拿到 1/N |
| **reduce-scatter** | 每 rank 各持完整 | 每 rank 拿到 sum 的 1/N（少走一次网络）|

代码定位：[tensorrt_llm/_torch/distributed/ops.py](tensorrt_llm/_torch/distributed/ops.py)。

---

## 12. CUDA Graph 工作原理

### 12.1 核心问题：kernel launch 开销

GPU 每次执行 kernel，CPU 都要：
1. 准备参数（指针、shape、stride...）
2. 通过 driver 提交给 GPU 队列
3. GPU 调度上 SM
4. CPU 等待返回

每次 launch ≈ 5-50 μs。DeepSeek-R1 一次 forward 约 **2700 个 kernel** → 27 ms 纯 CPU 启动开销。

| 场景 | GPU 计算 | CPU launch | launch 占比 |
|---|---|---|---|
| prefill 1024 tok | ~200 ms | ~27 ms | 12% |
| decode 1 step | **~5 ms** | **~27 ms** | **85%** ⚠️ |

→ decode 90% 时间在等 CPU 派单，GPU 空转！

### 12.2 CUDA Graph：录像 + 重放

```
没 Graph：CPU 每步喊 2700 次 "做这个 kernel"
有 Graph：CPU 喊 1 句 "重放 graph"，GPU 自己跑完 2700 步

decode 一步: 32 ms → 5 ms（6 倍加速）
```

### 12.3 重要：录的是什么

**CUDA Graph 录的不仅是"做什么"，还有"在哪里做"（GPU 内存地址）**：

```text
graph[i]: kernel="layer0_qkv_matmul"
          args = [
              ptr=0x7f12_3400_0000   ← input tensor 的 GPU 地址（绑死！）
              ptr=0x7f12_3500_0000   ← weight tensor 地址
              ptr=0x7f12_3600_0000   ← output tensor 地址
              int=4096               ← M
              ...
          ]
```

→ **不能直接换实参**，只能用"固定 buffer + 覆写内容"绕过：

```text
启动: malloc 固定 buffer 0xAAAA, 0xBBBB → capture graph
运行: memcpy 新数据 → 0xAAAA → cudaGraphLaunch → 从 0xBBBB 取结果

shape 不变 = 同一个固定 buffer 装得下 ✓
shape 变大 = 装不下 = 崩
shape 变小 = padding 凑数 = 浪费但能跑
```

### 12.4 为什么 ctx 关 / gen 开

```
ctx (prefill):
  shape 千变万化（100 / 1024 / 8000 / 16384 token）
  录不胜录；padding 浪费 30-40% 算力
  launch 开销只占 12% → 省了也没多少
  → 关掉

gen (decode):
  shape 只有 batch_size 变（1, 2, 4, 8, ..., 128，~8 张 graph 就够）
  enable_padding=true：把真实 batch 凑到最近预录 size
  padding 浪费 ~20%，但省 22 ms/step，净赚 5-6 倍
  → 开启
```

**预录 size**自动生成：[llm_args.py:160-191](tensorrt_llm/llmapi/llm_args.py#L160-L191) `_generate_cuda_graph_batch_sizes`。

---

## 13. KV cache 与 cache_transceiver buffer

### 13.1 KV cache 缓存的是 K 和 V，**不是 Q**

回顾 attention 数学：

```
attention(X) = softmax(Q · K^T / sqrt(d)) · V
  Q = X · W_Q     ← 当前 token 在"问"
  K = X · W_K     ← 历史 token 的"标签"
  V = X · W_V     ← 历史 token 的"内容"
```

decode 第 t 步：
- **Q**：只需要新这 1 个 token 的（Q_new），算完即弃
- **K, V**：必须有完整 1..t 的（要跟所有历史做 softmax）

所以缓存 K 和 V，不缓存 Q。

类比图书馆：你的问题 (Q) 现想现问；图书的标签 (K) 和正文 (V) 永远在那里。

### 13.2 prefix cache（`enable_block_reuse`）

**相同 prefix** = 两条请求开头若干 token 一致 → 那段 K 和 V 块复用。

常见场景：
- **系统 prompt 共享**（聊天机器人统一前缀）
- **Few-shot 示例**（多个请求带相同示例）
- **多轮对话**（每轮把前面整段当 prefix）
- **RAG / 长文档**（同一 100k 文档，多个用户问不同问题）

disagg 默认关，因为 ctx 算完即推走、本地立刻释放，复用窗口几乎不存在。

### 13.3 cache_transceiver buffer（`max_tokens_in_buffer`）

**KV cache 跨 worker 传输的"装卸货月台"** —— 一块**预分配的连续 GPU 显存**。

为什么需要？
1. **paged KV 是分散的**：单条 req 的 KV 散在 N 个非连续块上，NIXL/RDMA 想要连续内存
2. **跨 TP 拓扑要重新切片**：ctx TP=4 → gen TP=8，需 split-concat kernel 把布局对齐
3. **异步流水线**：buffer 让 send/recv 跟 forward 重叠

工作流：

```
CTX 端（CacheSender）：
  paged KV → cacheSplitConcat.cu → 中转 buffer 连续区段 → NIXL 推走 → 释放槽位

GEN 端（CacheReceiver）：
  NIXL 收 → 中转 buffer → cacheSplitConcat.cu 反向 → 写进本地 paged KV → 释放槽位
```

`max_tokens_in_buffer: 16384` = 单个 buffer 槽位能装 16384 token 的 KV 字节数（应当 ≥ 最大 ISL）。

---

## 14. batch_size 与 concurrency 的关系（容易混淆）

### 14.1 定义

| | 含义 |
|---|---|
| `max_batch_size` | 服务端**单次 forward step**最多并行的请求数 |
| `concurrency`（benchmark 字段）| 客户端**同时维持的 in-flight** 请求数 |
| `max_num_tokens` | 单次 forward step 总 token 上限 |

⚠️ batch_size 是**请求数**，不是 token 数！

### 14.2 三个数的约束关系

```
gen 端一次 step：
  active_requests ≤ max_batch_size       (请求数上限)
  total_tokens    ≤ max_num_tokens       (token 数上限)
  total_tokens    = active_requests × tokens_per_req_per_step
                    （decode：1 主 + 3 MTP draft = 4 token/req）

batch=128, MTP-3 → total_tokens=512，正好顶 max_num_tokens=512 ✓
```

### 14.3 concurrency 不是除 batch_size

❌ 错：concurrency=1024, batch_size=128 → "1024/128 = 8 次运行"
✓ 对：每条请求要走 ~1024 个 decode step（每 token 1 步）

实际过程（continuous batching）：
- 客户端永远维持 1024 in-flight；服务端 128 桌座位永远满
- 队列里 896 在排队，每空一个位置立刻补
- 总 forward step 数（10 round 1024 个请求）≈ **8 万次**，不是 8 次

### 14.4 为什么 perf 测试 concurrency 远大于 batch_size

```
concurrency = batch_size：刚好够，但请求做完瞬间桌空，损失瞬时吞吐
concurrency >> batch_size（如 1024 vs 128）：队列足够长，桌子永远满 → 测出吞吐上限
concurrency 太大：吞吐饱和但每条延迟变大（队首效应）
```

→ concurrency=1024 是为了**逼出 throughput 极限**，不是要服务端"分 8 波处理"。

---

## 15. 几个关键概念深入

### 15.1 MoE Grouped GEMM

每个 MoE 层有 256 个"专家"（DeepSeek-R1）。每个 token 经 router 选 top-8 专家处理，结果加权求和。

routing 后的局面：每个专家拿到不同数量的 token：

```
E0:    87 tokens
E1:   142 tokens
...
E89:  398 tokens   ← 热门专家
...
E255:  29 tokens
```

每个专家算 `output = tokens_for_expert @ W_expert`。这就是 256 个**不同 shape** 的矩阵乘。

```
朴素：256 次单独 cuBLAS 调用
      256 × ~20 μs = 5 ms 纯 launch 开销

Grouped GEMM：1 次 kernel launch，内部并行/流水 256 个矩阵乘
```

形象：256 个厨师各自要炒不同分量的菜。朴素版要排队用 1 个灶台；Grouped GEMM 是一个超大灶台 256 口锅同时受热。

backend 选择按 token 规模：

| backend | 擅长 | 为什么 |
|---|---|---|
| CUTEDSL | 大 token 数 (prefill) | kernel 高 occupancy，每专家 token 多时打满 SM |
| TRTLLM | 小 token 数 (decode) | 调度延迟优化好 |
| CUTLASS | 折中 | 通用 |
| DEEPGEMM | 跨节点 | 跟 DeepEP 协同的特殊布局 |

→ ctx (CUTEDSL) 走大 token 路径；gen (TRTLLM) 走小 token 路径。

### 15.2 MoE combine 与 use_low_precision_moe_combine

#### MoE 一层完整流程（Wide-EP）

EP=8 时，256 专家分到 8 GPU，每 rank 持 32 个专家：

```
[1] router 给每个 token 打分，选 top-8 专家
       ↓
[2] dispatch (alltoall #1)：
       token 搬到所选专家所在的 rank
       一个 token 选了 8 专家 → 复制 8 份发出去
       ↓
[3] compute (Grouped GEMM)：每 rank 在自己的 32 专家上算
       ↓
[4] combine (alltoall #2 + 加权求和)：
       专家结果回送到 token 原 rank
       原 rank 把 8 个专家的输出按 router score 加权求和：
       t_output = 0.20 × E3 + 0.18 × E89 + 0.15 × E155 + ...
```

#### combine 不是普通 all-reduce

- **all-reduce**：每 rank 算同样的事，结果求和
- **combine**：每 rank 算**不同 token 的不同部分**，需要按 token 归集 + 加权求和

通信特征跟 all-reduce 类似（每 rank 既发又收），所以代码里有时也叫 "combine reduction"。

#### 为什么 ctx 开 fp8 combine

```
ctx 一次 prefill 1024 token，alltoall 通信量：
  1024 × top-8 × 7168 × 2 (bf16) ≈ 117 MB / 层 × 60 层 = 7 GB
  开 fp8: 砍一半 → 3.5 GB

gen 一步 128 token：
  128 × 8 × 7168 × 2 ≈ 14.6 MB / 层
  量化收益小 + dequant 开销每步都付 → 不开
```

形象：ctx 把"专家评分单"从 A4 纸（bf16）换成 IC 卡（fp8），快递成本砍半；gen 因为 step 短，IC 卡的读卡开销反而更高。

### 15.3 Cache Transceiver 完整工作流

涉及组件：

```
ctx 端                        gen 端
────                          ────
CacheSender                   CacheReceiver
CacheTransBufferManager       同上
MLACacheFormatter             同上
cacheSplitConcat.cu (kernel)  同上
NIXL agent                    同上
ZMQ socket                    同上
```

#### 阶段 A：worker 启动（一次性）

```
每个 rank：
  ① 创建 NIXL agent，绑本地 ZMQ 端点（如 tcp://gb200-001:43210）
  ② 把 KV pool + 中转 buffer 注册给 NIXL（让它知道这些 GPU memory region）
  ③ 通过 ZMQ 暴露 agent metadata
ctx_info_endpoint = ctx rank 0 的 ZMQ 端点字符串
```

#### 阶段 B：ctx 收 ctx_only 请求

```
T1  HTTP POST → trtllm-serve → PyExecutor 排上 prefill
T2  prefill 算完，每 ctx rank 把自己 1/4 KV 写进 paged 块
T3  PyExecutor 调 cacheTransceiver.respondAndSendAsync(req)
    → C++ 标记"等 gen 来取"
T4  HTTP 200，body 含 {ctx_request_id, ctx_info_endpoint, first_gen_token, ...}
```

#### 阶段 C：gen 收 gen_only 请求 → 触发 NIXL 拉取

```
T5  HTTP POST 进 gen rank 0
T6  ZMQ→MPI 广播给 gen rank 0..7
T7  每个 gen rank 调 requestAndReceiveAsync(req)：
    → 通过 ZMQ 连 ctx_info_endpoint
    → 发 REQUEST_DATA: "我是 gen rank X，要 ctx_request_id=123 的 KV[X/8]"
       附上自己的 NIXL agent metadata
    （哪个 gen rank 跟哪个 ctx rank 通信，由 MLACacheFormatter 算）
T8  ctx 这边的 dataResponder 收到 REQUEST_DATA → NIXL 注册 peer
```

#### 阶段 D：实际 RDMA 传输（举 ctx rank 0 → gen rank 0）

```
T9  ctx rank 0 sender：
    ① computeTargetRanksInfo：算"我这 1/4 切 2 半，第 1 半给 gen rank 0"
    ② cacheSplitConcat.cu kernel：
       paged blocks gather + TP 切片 → 中转 buffer 连续区段
       (这是一次 GPU kernel 完成的 gather + reshape)
    ③ NIXL transfer：buffer → gen rank 0 的 buffer（地址在 REQUEST_DATA 里）
T10 RDMA 走 IB/NVLink: gb200-001 GPU0 → HCA → switch → HCA → gb200-003 GPU0
    GPUDirect RDMA: CPU 不参与，零拷贝
T11 数据落 gen rank 0 中转 buffer
T12 gen rank 0 receiver：
    ① cacheSplitConcat.cu 反向：buffer → 本地 paged blocks
    ② 释放 buffer 槽位
T13 ctx rank 0：
    ① 释放 buffer 槽位
    ② 释放 paged KV blocks（gen 已拿到，ctx 不用留）
```

#### 阶段 E：所有 rank ready → 开始 decode

```
T14 PyExecutor _check_disagg_gen_transfer_status() 轮询 → 8 对通道全完成
    → req.state = DISAGG_GENERATION_TRANS_COMPLETE
T15 normal decode 开始
```

#### 控制面 vs 数据面

```
ZMQ TCP   小消息：peer 注册、ack、握手
NIXL/RDMA 大数据：KV 字节流，跨节点 IB / 节点内 NVLink/IPC
```

中转 buffer 大小由 `max_tokens_in_buffer` 决定，**必须 ≥ 最大 ISL**，否则单条长 prompt 装不下。

### 15.4 MTP 投机解码（修正常见误解）

#### 常见误解

❌ "MTP 在位置 t 给出 4 个候选词，从中选 1 个填 t+1"

✓ "MTP 在位置 t 同时预测 4 个**连续位置** t+1, t+2, t+3, t+4"

#### 准确工作流

```
Step 1 (draft 阶段)：
  输入: [..., t]
  主模型 forward 一次：
    主 head     ──▶ t+1 = "我"
    MTP head 1  ──▶ t+2 = "爱"
    MTP head 2  ──▶ t+3 = "北"
    MTP head 3  ──▶ t+4 = "京"
  → 一次产出 4 个 draft token

Step 2 (verify 阶段)：
  输入: [..., t, "我", "爱", "北", "京"]
                  ↑    ↑    ↑    ↑
               draft draft draft draft
  主模型 forward 一次（同时 verify 4 个位置）：
    位置 t+1 主 head 预测 "我"  ── draft 一致 ✓ 接受
    位置 t+2 主 head 预测 "爱"  ── 一致 ✓ 接受
    位置 t+3 主 head 预测 "上"  ── ✗ 不一致，停！把 "北" 改成 "上"
    位置 t+4 之后丢弃（前面改了，后面不一定对）
  
  净产出: ["我", "爱", "上"] = 3 个 token
        ↑ 2 个 draft 接受 + 1 个主 head 在不一致位置的真实输出

Step 3：从 ["我", "爱", "上"] 之后继续
```

#### 关键事实

```
每 step 净产 token = 1 (主 head 永远产 1) + 0..3 (MTP draft 接受数)
                  = 1 ~ 4

DeepSeek-R1 实测接受率 ~80%-90%
平均每步产 ~3 token → 相比纯 decode 加速 ~3 倍
```

#### 准确比喻：速记员 + 校对员

```
速记员（draft heads）：抢先草拟 4 字 "我爱北京"
校对员（主模型 verify）：逐字核对：
  "我" ✓ 通过
  "爱" ✓ 通过
  "北" ✗ 应该是"上"，停止；把 "北" 改成 "上"
  "京" ── 前一字改了，丢掉
净产出: "我爱上" 3 个字
```

❌ 别想成"输入法 4 候选选 1"——**那是给同一位置的多选**，MTP 是**给连续 4 个位置的预测**。

#### 为什么 ctx/gen 必须共用 spec 配置（yaml `*id001`）

```
ctx 端 prefill 时：
  主模型每层算完，MTP head 1/2/3 也跑
  产生它们的中间状态 → 写进 KV cache

gen 端 decode 时：
  从 ctx 接来的 KV 必须含主 + 3 MTP head 全套状态
  才能继续算 MTP draft

如果两端 spec 配置不一致：
  ctx 给 4 套 KV，gen 期待 2 套 → 形状不匹配崩溃
```

---

## 16. 推荐的深入顺序

1. **C++ `CacheSender`/`CacheReceiver` 的实际数据流和状态机**（最能解释"远程 KV 到底怎么搬过来的"）
2. **`MLACacheFormatter` 怎么处理 DeepSeek MLA 在不同 TP 之间的切片**（示例 yaml 是 ctx tp4 → gen tp8，正好是非对称转换）
3. **PyExecutor 主循环里 disagg 的状态机和调度细节**
4. **`OpenAIDisaggregatedService` 的两段式 HTTP 编排**（包含 first-token 优化、流式回包）
5. **`WideEPMoE` 的 forward + alltoall 细节**
6. **NIXL 这层是如何被 wrap 的（`transferAgent.cpp` + `nixl_utils/`）**
