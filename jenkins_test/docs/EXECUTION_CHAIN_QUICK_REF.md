# 执行链条快速参考

## 🔀 三种模式对比一览

### Test Case ID 格式

```bash
# Single-Agg / Multi-Agg
aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k
└─────┬────┘└──────────┬───────────┘└─────────┬──────────┘
  test_type    config_yml        server_config_name

# Disagg
disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
└─────┬─────┘└─────────────────────┬───────────────────────────────┘
  test_type           完整配置文件名（不含 .yaml）
```

---

## 📁 配置文件位置

```bash
# Agg 模式
tests/scripts/perf-sanity/
├── deepseek_r1_fp4_v2_grace_blackwell.yaml       # Single-Agg
├── deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yaml  # Multi-Agg
└── ...

# Disagg 模式
tests/integration/defs/perf/disagg/test_configs/disagg/perf/
├── deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
└── ...
```

---

## 🔑 关键区别

| 特性 | Agg (Single/Multi) | Disagg |
|------|-------------------|--------|
| **Test ID 组成** | `{test_type}-{config_yml}-{server_config_name}` | `{test_type}-{完整配置名}` |
| **server_config_name** | ✅ 有（可选） | ❌ 无 |
| **select_pattern** | ✅ 用于选择 server config | ❌ 总是 None |
| **配置文件结构** | 一个文件 = 多个 server configs | 一个文件 = 一个完整配置 |
| **client_configs** | 定义在每个 server_config 内 | 从 concurrency_list 生成 |
| **worker_config** | ❌ 无 | ✅ 分 ctx 和 gen |

---

## 📊 配置文件结构

### Agg 模式

```yaml
metadata:
  model_name: deepseek_r1_0528_fp4_v2

hardware:
  gpus_per_node: 4

server_configs:  # ← 多个 server configs
  - name: "r1_fp4_v2_tp4_mtp3_1k1k"  # ← server_config_name
    tensor_parallel_size: 4
    client_configs:  # ← client configs 在这里
      - name: "con1024"
        concurrency: 1024
  
  - name: "r1_fp4_v2_dep8_mtp1"  # ← 另一个 server config
    tensor_parallel_size: 8
    moe_expert_parallel_size: 8
    client_configs:
      - name: "con512"
        concurrency: 512
```

### Disagg 模式

```yaml
metadata:
  model_name: deepseek_r1_0528_fp4_v2

hardware:
  gpus_per_node: 4
  num_ctx_servers: 1  # ← Disagg 特有
  num_gen_servers: 1  # ← Disagg 特有

benchmark:
  concurrency_list: '512 1024'  # ← client configs 从这里生成

worker_config:  # ← Disagg 特有：分 ctx 和 gen
  ctx:
    tensor_parallel_size: 4
    moe_expert_parallel_size: 4
  
  gen:
    tensor_parallel_size: 8
    moe_expert_parallel_size: 8
```

---

## 🔄 解析流程

### Agg 模式

```python
# Test ID
"aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k"

# 解析
test_type = "aggr_upload"
config_yml = "deepseek_r1_fp4_v2_grace_blackwell"
server_config_name = "r1_fp4_v2_tp4_mtp3_1k1k"

# 配置文件
config_file = "tests/scripts/perf-sanity/deepseek_r1_fp4_v2_grace_blackwell.yaml"

# 结果
server_configs = [
    ServerConfig(name="r1_fp4_v2_tp4_mtp3_1k1k")  # ← 只运行这个
]
server_client_configs = {
    0: [ClientConfig(con=1024), ClientConfig(con=512)]  # ← 从 YAML 读取
}
```

### Disagg 模式

```python
# Test ID
"disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX"

# 解析
test_type = "disagg_upload"
config_name = "deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX"
server_config_name = None  # ← Disagg 没有

# 配置文件
config_file = "tests/integration/.../deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml"

# 结果
server_configs = [
    (  # ← 元组！
        ServerConfig(disagg_run_type="ctx", tp=4, ep=4),
        ServerConfig(disagg_run_type="gen", tp=8, ep=8),
        DisaggConfig(num_ctx_servers=1, num_gen_servers=1)
    )
]
server_client_configs = {
    0: [ClientConfig(con=512), ClientConfig(con=1024)]  # ← 从 concurrency_list 生成
}
```

---

## 💡 记忆技巧

### Agg 模式

```
一个配置文件 → 多个 server configs → 用户选择运行哪个
                                    ↓
                            通过 server_config_name
```

### Disagg 模式

```
一个配置文件 → 一个完整配置（ctx + gen）→ 无需选择
                  ↓
              文件名编码了所有信息
```

---

## 🎯 判断方法

### 如何识别 Disagg？

1. ✅ Test type 包含 "disagg"
2. ✅ 配置文件名包含 "ctx" 和 "gen"
3. ✅ YAML 中有 `num_ctx_servers` 或 `num_gen_servers`
4. ✅ YAML 中有 `worker_config.ctx` 和 `worker_config.gen`

### 如何区分 Single-Agg 和 Multi-Agg？

```python
total_gpus = TP × EP × PP × CP

if total_gpus > gpus_per_node:
    mode = "multi-agg"  # 需要多节点
else:
    mode = "single-agg"  # 单节点足够
```

---

## 📚 完整文档

详细解析请参考：`EXECUTION_CHAIN_DETAILED.md`
