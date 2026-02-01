# 完整运行链条解析：parse_unified_testlist.py → test_perf_sanity.py

## 📋 概览

本文档详细解析从 `parse_unified_testlist.py` 解析测试列表，到 `test_perf_sanity.py` 执行测试的完整链条。

**⚠️ 重要说明：不指定 server_config_name 的行为**

当不指定 `server_config_name` 时：
- ✅ **parse_unified_testlist.py**: 会检查**所有** `server_configs`，只要有一个是 multi-agg 就返回 multi-agg
- ✅ **test_perf_sanity.py**: 会运行配置文件中的**所有** `server_configs`

详细分析请参考：`docs/SERVER_CONFIG_NAME_ANALYSIS.md`

---

## 🔄 三种测试模式的完整流程

### 1️⃣ Single-Agg / Multi-Agg 模式

#### Test Case 格式

```
test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]
                             └─────┬─────┘└──────────────────┬───────────────────────┘└─────────┬──────────┘
                                test_type              config_yml                        server_config_name
```

**组成部分：**
- `test_type`: `aggr` 或 `aggr_upload`（upload 表示上传到数据库）
- `config_yml`: YAML 配置文件名（不含 .yaml 扩展名）
- `server_config_name`: 可选，指定具体的 server config

#### 配置文件位置

```bash
tests/scripts/perf-sanity/
├── deepseek_r1_fp4_v2_grace_blackwell.yaml          # Single-Agg (4 GPUs)
├── deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yaml  # Multi-Agg (8 GPUs, 2 nodes)
├── k2_thinking_fp4_grace_blackwell.yaml
└── ...
```

#### YAML 配置文件结构（Agg 模式）

```yaml
metadata:
  model_name: deepseek_r1_0528_fp4_v2
  supported_gpus:
  - GB200

hardware:
  gpus_per_node: 4  # 每个节点的 GPU 数量

server_configs:
  # 一个配置文件可以包含多个 server config
  - name: "r1_fp4_v2_dep8_mtp1_1k1k"  # <-- server_config_name
    model_name: "deepseek_r1_0528_fp4_v2"
    tensor_parallel_size: 8
    moe_expert_parallel_size: 8
    pipeline_parallel_size: 1
    max_batch_size: 512
    max_num_tokens: 8192
    
    # 每个 server config 可以有多个 client config
    client_configs:
      - name: "con1024_iter10_1k1k"
        concurrency: 1024
        iterations: 10
        isl: 1024
        osl: 1024
        backend: "openai"
      
      - name: "con512_iter10_1k1k"
        concurrency: 512
        iterations: 10
        isl: 1024
        osl: 1024
  
  - name: "r1_fp4_v2_tep8_mtp3"  # 另一个 server config
    tensor_parallel_size: 8
    moe_expert_parallel_size: 8
    # ...
```

#### 解析流程（parse_unified_testlist.py）

```python
# 步骤 1: 解析 test_id
test_id = "aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k"

parts = test_id.split('-')
# parts = ['aggr_upload', 'deepseek_r1_fp4_v2_2_nodes_grace_blackwell', 'r1_fp4_v2_dep8_mtp1_1k1k']

test_type = parts[0]  # "aggr_upload"
config_yml = parts[1]  # "deepseek_r1_fp4_v2_2_nodes_grace_blackwell"
server_config_name = '-'.join(parts[2:])  # "r1_fp4_v2_dep8_mtp1_1k1k"

# 步骤 2: 加载配置文件
config_file = f"tests/scripts/perf-sanity/{config_yml}.yaml"
config = yaml.safe_load(open(config_file))

# 步骤 3: 计算 GPU 需求判断 single-agg 或 multi-agg
hardware = config['hardware']
gpus_per_node = hardware['gpus_per_node']  # 4

for server_config in config['server_configs']:
    if server_config['name'] == server_config_name:
        tp = server_config['tensor_parallel_size']  # 8
        ep = server_config['moe_expert_parallel_size']  # 8
        pp = server_config['pipeline_parallel_size']  # 1
        cp = server_config.get('context_parallel_size', 1)  # 1
        
        total_gpus = tp * ep * pp * cp  # 8 * 8 * 1 * 1 = 64
        
        if total_gpus > gpus_per_node:
            test_mode = 'multi-agg'  # 64 > 4 → multi-agg
        else:
            test_mode = 'single-agg'
```

#### 执行流程（test_perf_sanity.py）

```python
# test_perf_sanity.py::test_e2e[aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k]

class PerfSanityTestConfig:
    def parse_test_case_name(self, test_case_name):
        labels = test_case_name.split("-")
        # labels = ['aggr_upload', 'deepseek_r1_fp4_v2_2_nodes_grace_blackwell', 'r1_fp4_v2_dep8_mtp1_1k1k']
        
        is_disagg = "disagg" in labels[0]  # False
        self.upload_to_db = "upload" in labels[0]  # True
        
        if not is_disagg:
            # Agg 模式
            self.runtime = "aggr_server"
            self.config_dir = "tests/scripts/perf-sanity"
            
            config_base = labels[1]  # "deepseek_r1_fp4_v2_2_nodes_grace_blackwell"
            self.config_file = f"{config_base}.yaml"
            
            # select_pattern 是 server_config_name
            self.select_pattern = "-".join(labels[2:])  # "r1_fp4_v2_dep8_mtp1_1k1k"
    
    def _parse_aggr_config_file(self, config_file_path):
        with open(config_file_path, "r") as f:
            config = yaml.safe_load(f)
        
        # 解析 select_pattern（哪些 server configs 要运行）
        if self.select_pattern:
            selected_server_names = [self.select_pattern]
            # 只运行 "r1_fp4_v2_dep8_mtp1_1k1k" 这个 server config
        else:
            selected_server_names = None
            # 运行所有 server configs
        
        # 过滤 server_configs
        for server_config_data in config['server_configs']:
            if selected_server_names is None or server_config_data['name'] in selected_server_names:
                server_config = ServerConfig(server_config_data, ...)
                self.server_configs.append(server_config)
                
                # 每个 server config 有多个 client configs
                client_configs = []
                for client_config_data in server_config_data['client_configs']:
                    client_config = ClientConfig(client_config_data, ...)
                    client_configs.append(client_config)
                
                # 存储 server_idx -> client_configs 映射
                self.server_client_configs[len(self.server_configs)-1] = client_configs

# 结果：
# - self.server_configs = [ServerConfig("r1_fp4_v2_dep8_mtp1_1k1k")]
# - self.server_client_configs = {
#     0: [ClientConfig("con1024_iter10_1k1k"), ClientConfig("con512_iter10_1k1k")]
#   }
```

---

### 2️⃣ Disagg 模式

#### Test Case 格式

```
test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX]
                             └─────┬──────┘└──────────────────────────┬──────────────────────────────────┘
                               test_type                        完整的 config 名称（带 .yaml）
```

**组成部分：**
- `test_type`: `disagg` 或 `disagg_upload`
- 剩余部分：完整的配置文件名（不含 .yaml）

#### ⚠️ 关键区别：Disagg 没有 server_config_name

```
Agg 格式:     aggr_upload-{config_yml}-{server_config_name}
                         └────┬────┘  └─────┬──────┘
                         配置文件    具体 server config

Disagg 格式:  disagg_upload-{完整配置名称}
                           └──────┬───────┘
                           整个都是配置文件名
```

#### 配置文件位置

```bash
tests/integration/defs/perf/disagg/test_configs/disagg/perf/
├── deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
├── deepseek-r1-fp4_1k1k_ctx1_gen1_dep32_bs32_eplb0_mtp0_ccb-UCX.yaml
├── Qwen3-235B-A22B-FP4_1k1k_ctx1_gen1_dep32_bs16_eplb0_mtp3_ccb-UCX.yaml
└── ...
```

**文件名编码了所有配置信息：**
```
deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
└───┬────┘│ │└┬┘└┬┘└┬┘└┬┘└─┬─┘└─┬┘└─┬┘└─┬┘└┬┘
  model  │ │ │  │  │  │    │    │   │   │  通信后端
       精度│ │  │  │  │    │    │   │   MTP设置
       benchmark│ │  │    │    │   │
       类型    │ │  │    │    │   Expert Parallel
            ctx │  │    │    Batch Size
            数量 │  │    Expert Parallel Load Balance
              gen│  DEP (Dynamic Expert Parallel)
              数量 Mode (CCB = ...)
```

#### YAML 配置文件结构（Disagg 模式）

```yaml
metadata:
  model_name: deepseek_r1_0528_fp4_v2
  precision: fp4
  benchmark_type: 1k1k

hardware:
  gpus_per_node: 4
  num_ctx_servers: 1    # ← Disagg 特有：context server 数量
  num_gen_servers: 1    # ← Disagg 特有：generation server 数量

benchmark:
  mode: e2e
  multi_round: 8
  concurrency_list: '1024'  # 可以是 "512 1024 2048"（多个并发）
  input_length: 1024
  output_length: 1024
  streaming: true

# ⚠️ 关键：Disagg 配置分为 ctx 和 gen 两部分
worker_config:
  gen:  # Generation server 配置
    tensor_parallel_size: 8
    moe_expert_parallel_size: 8
    max_batch_size: 768
    max_num_tokens: 768
    cache_transceiver_config:
      backend: UCX  # ← 通信后端
    # ... 其他配置
  
  ctx:  # Context server 配置
    tensor_parallel_size: 4
    moe_expert_parallel_size: 4
    max_batch_size: 16
    max_num_tokens: 16896
    cache_transceiver_config:
      backend: UCX
    # ... 其他配置
```

#### 解析流程（parse_unified_testlist.py）

```python
# 步骤 1: 解析 test_id
test_id = "disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX"

# 步骤 2: 识别为 disagg
if 'disagg' in test_id.split('-')[0]:
    test_mode = 'disagg'  # 立即返回，无需读取配置文件

# 如果需要读取配置文件验证：
parts = test_id.split('-')
test_type = parts[0]  # "disagg_upload"
config_name = '-'.join(parts[1:])  # "deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX"

config_file = f"tests/integration/defs/perf/disagg/test_configs/disagg/perf/{config_name}.yaml"
config = yaml.safe_load(open(config_file))

# 验证 disagg 特征
hardware = config['hardware']
if 'num_ctx_servers' in hardware or 'num_gen_servers' in hardware:
    test_mode = 'disagg'  # ✅ 确认是 disagg
```

#### 执行流程（test_perf_sanity.py）

```python
# test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX]

class PerfSanityTestConfig:
    def parse_test_case_name(self, test_case_name):
        labels = test_case_name.split("-")
        # labels = ['disagg_upload', 'deepseek', 'r1', 'fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb', 'UCX']
        
        is_disagg = "disagg" in labels[0]  # True
        self.upload_to_db = "upload" in labels[0]  # True
        
        if is_disagg:
            # Disagg 模式
            self.runtime = "multi_node_disagg_server"
            self.config_dir = "tests/integration/defs/perf/disagg/test_configs/disagg/perf"
            
            # ⚠️ 关键：剩余所有部分都是配置文件名
            config_base = "-".join(labels[1:])
            # config_base = "deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX"
            
            self.config_file = f"{config_base}.yaml"
            self.select_pattern = None  # ← Disagg 没有 select_pattern
    
    def _parse_disagg_config_file(self, config_file_path, config_file):
        with open(config_file_path, "r") as f:
            config = yaml.safe_load(f)
        
        metadata = config['metadata']
        hardware = config['hardware']
        benchmark = config['benchmark']
        worker_config = config['worker_config']
        
        # 获取配置文件基础名（不含扩展名）
        config_file_base_name = os.path.splitext(config_file)[0]
        # "deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX"
        
        # 创建 ctx server config
        ctx_server_config_data = {
            "name": config_file_base_name,
            "model_name": metadata['model_name'],
            "gpus_per_node": hardware['gpus_per_node'],
            "disagg_run_type": "ctx",  # ← 标记为 context server
            **worker_config['ctx']  # 合并 ctx 配置
        }
        ctx_server_config = ServerConfig(ctx_server_config_data, ...)
        
        # 创建 gen server config
        gen_server_config_data = {
            "name": config_file_base_name,
            "model_name": metadata['model_name'],
            "gpus_per_node": hardware['gpus_per_node'],
            "disagg_run_type": "gen",  # ← 标记为 generation server
            **worker_config['gen']  # 合并 gen 配置
        }
        gen_server_config = ServerConfig(gen_server_config_data, ...)
        
        # 创建 disagg 配置对象
        disagg_config = DisaggConfig(
            name=config_file_base_name,
            hardware=hardware,  # 包含 num_ctx_servers, num_gen_servers
            benchmark_mode=benchmark['mode'],
            # ...
        )
        
        # ⚠️ 关键：server_configs 是一个包含 (ctx, gen, disagg_config) 的列表
        self.server_configs = [(ctx_server_config, gen_server_config, disagg_config)]
        
        # 创建 client configs（基于 concurrency_list）
        concurrency_values = parse_concurrency(benchmark['concurrency_list'])
        # 例如 "512 1024 2048" → [512, 1024, 2048]
        
        client_configs = []
        for concurrency in concurrency_values:
            client_config_data = {
                "concurrency": concurrency,
                "iterations": benchmark['multi_round'],
                "isl": benchmark['input_length'],
                "osl": benchmark['output_length'],
                "backend": "openai",
            }
            client_config = ClientConfig(client_config_data, ...)
            client_configs.append(client_config)
        
        # ⚠️ Disagg 只有一个 "server config"（实际是 ctx + gen + disagg_config 的组合）
        self.server_client_configs = {0: client_configs}

# 结果：
# - self.server_configs = [(ctx_ServerConfig, gen_ServerConfig, DisaggConfig)]
# - self.server_client_configs = {
#    =5 0: [ClientConfig(con12), ClientConfig(con=1024), ClientConfig(con=2048)]
#   }
```

---

## 📊 三种模式对比

### 配置文件结构对比

| 特性 | Single-Agg | Multi-Agg | Disagg |
|------|-----------|-----------|--------|
| 配置文件目录 | `tests/scripts/perf-sanity/` | 同 Single-Agg | `tests/integration/defs/perf/disagg/test_configs/disagg/perf/` |
| 文件名格式 | `{model}_{precision}_{hardware}.yaml` | `{model}_2_nodes_{hardware}.yaml` | `{model}_{benchmark}_ctx{n}_gen{m}_{config}-{backend}.yaml` |
| `server_configs` 数量 | **多个** | **多个** | **1个**（组合 ctx+gen） |
| `server_config_name` | ✅ 支持 | ✅ 支持 | ❌ 无此概念 |
| `select_pattern` | ✅ 用于选择 server config | ✅ 用于选择 server config | ❌ 总是 None |
| `client_configs` 位置 | 在每个 `server_config` 内 | 在每个 `server_config` 内 | 从 `benchmark.concurrency_list` 生成 |

### Test Case ID 格式对比

```
Single-Agg:
  aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k
              └────────┬────────┘                └──────┬───────┘
                 config_yml                   server_config_name (可选)

Multi-Agg:
  aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k
              └────────────┬──────────────┘                └──────┬───────┘
                     config_yml                          server_config_name (可选)

Disagg:
  disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
                └───────────────────────┬────────────────────────────────┘
                              完整的配置文件名
```

### 解析结果对比

#### Single-Agg 示例

```python
config_file: "deepseek_r1_fp4_v2_grace_blackwell.yaml"
select_pattern: "r1_fp4_v2_tp4_mtp3_1k1k"

# 解析后：
server_configs = [
    ServerConfig(name="r1_fp4_v2_tp4_mtp3_1k1k", tp=4, ep=1, ...)
]

server_client_configs = {
    0: [  # server_configs[0] 的 client configs
        ClientConfig(con=1024, iter=10, isl=1024, osl=1024),
        ClientConfig(con=512, iter=10, isl=1024, osl=1024),
    ]
}
```

#### Multi-Agg 示例

```python
config_file: "deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yaml"
select_pattern: "r1_fp4_v2_dep8_mtp1_1k1k"

# 解析后：
server_configs = [
    ServerConfig(name="r1_fp4_v2_dep8_mtp1_1k1k", tp=8, ep=8, ...)
]

server_client_configs = {
    0: [  # server_configs[0] 的 client configs
        ClientConfig(con=1024, iter=10, isl=1024, osl=1024),
    ]
}

# GPU 计算：
# total_gpus = tp(8) × ep(8) × pp(1) × cp(1) = 64
# 64 > gpus_per_node(4) → multi-agg
```

#### Disagg 示例

```python
config_file: "deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml"
select_pattern: None  # ← 关键：Disagg 没有 select_pattern

# 解析后：
server_configs = [
    (  # ← 元组！包含三个对象
        ServerConfig(name="...", disagg_run_type="ctx", tp=4, ep=4, ...),
        ServerConfig(name="...", disagg_run_type="gen", tp=8, ep=8, ...),
        DisaggConfig(num_ctx_servers=1, num_gen_servers=1, ...)
    )
]

server_client_configs = {
    0: [  # 从 concurrency_list 生成
        ClientConfig(con=1024, iter=8, isl=1024, osl=1024),
    ]
}
```

---

## 🔍 关键代码片段

### parse_unified_testlist.py

```python
def infer_test_mode_from_config(test_id):
    """从 test_id 推断测试模式"""
    
    # 1. 优先检查 disagg
    if '_disagg' in test_id or 'disagg' in test_id.split('-')[0]:
        return 'disagg'
    
    # 2. 解析 test_id
    parts = test_id.split('-')
    test_type = parts[0]  # aggr_upload / disagg_upload
    config_yml = parts[1]  # 配置文件名
    server_config_name = '-'.join(parts[2:]) if len(parts) > 2 else None
    
    # 3. 加载配置文件
    if 'disagg' in test_type:
        # Disagg: 完整文件名在 parts[1:]
        config_file = f"{'-'.join(parts[1:])}.yaml"
        config_dir = DISAGG_CONFIG_DIR
    else:
        # Agg: 文件名只在 parts[1]
        config_file = f"{config_yml}.yaml"
        config_dir = AGGR_CONFIG_DIR
    
    config = load_yaml_config(config_file, config_dir)
    
    # 4. 判断 single-agg 或 multi-agg
    if config and 'disagg' not in test_type:
        hardware = config.get('hardware', {})
        gpus_per_node = hardware.get('gpus_per_node', 0)
        
        for server_config in config.get('server_configs', []):
            if server_config_name and server_config.get('name') != server_config_name:
                continue
            
            total_gpus = (
                server_config.get('tensor_parallel_size', 1) *
                server_config.get('moe_expert_parallel_size', 1) *
                server_config.get('pipeline_parallel_size', 1) *
                server_config.get('context_parallel_size', 1)
            )
            
            if total_gpus > gpus_per_node:
                return 'multi-agg'
        
        return 'single-agg'
    
    return 'disagg' if 'disagg' in test_type else 'single-agg'
```

### test_perf_sanity.py

```python
class PerfSanityTestConfig:
    def parse_test_case_name(self, test_case_name):
        labels = test_case_name.split("-")
        is_disagg = "disagg" in labels[0]
        
        if is_disagg:
            # Disagg 模式
            self.runtime = "multi_node_disagg_server"
            self.config_dir = "tests/integration/defs/perf/disagg/test_configs/disagg/perf"
            config_base = "-".join(labels[1:])  # 剩余所有部分
            self.config_file = f"{config_base}.yaml"
            self.select_pattern = None  # ← 关键：Disagg 无 select_pattern
        else:
            # Agg 模式
            self.runtime = "aggr_server"
            self.config_dir = "tests/scripts/perf-sanity"
            config_base = labels[1]  # 只有第二部分
            self.config_file = f"{config_base}.yaml"
            self.select_pattern = "-".join(labels[2:]) if len(labels) > 2 else None
    
    def _parse_aggr_config_file(self, config_file_path):
        """解析 Agg 配置文件"""
        with open(config_file_path, "r") as f:
            config = yaml.safe_load(f)
        
        # 过滤 server_configs
        for server_config_data in config['server_configs']:
            if self.select_pattern:
                # 如果指定了 server_config_name，只运行匹配的
                if server_config_data['name'] != self.select_pattern:
                    continue
            
            # 创建 server config 和对应的 client configs
            server_config = ServerConfig(server_config_data, ...)
            self.server_configs.append(server_config)
            
            client_configs = [
                ClientConfig(cc, ...) 
                for cc in server_config_data['client_configs']
            ]
            self.server_client_configs[idx] = client_configs
    
    def _parse_disagg_config_file(self, config_file_path, config_file):
        """解析 Disagg 配置文件"""
        with open(config_file_path, "r") as f:
            config = yaml.safe_load(f)
        
        config_name = os.path.splitext(config_file)[0]
        worker_config = config['worker_config']
        
        # 创建 ctx 和 gen server configs
        ctx_config = ServerConfig({
            "name": config_name,
            "disagg_run_type": "ctx",
            **worker_config['ctx']
        }, ...)
        
        gen_config = ServerConfig({
            "name": config_name,
            "disagg_run_type": "gen",
            **worker_config['gen']
        }, ...)
        
        disagg_config = DisaggConfig(
            name=config_name,
            hardware=config['hardware'],
            ...
        )
        
        # ⚠️ 关键：返回元组
        self.server_configs = [(ctx_config, gen_config, disagg_config)]
        
        # 从 concurrency_list 生成 client configs
        concurrency_values = parse_concurrency(config['benchmark']['concurrency_list'])
        client_configs = [
            ClientConfig({"concurrency": c, ...}, ...)
            for c in concurrency_values
        ]
        self.server_client_configs = {0: client_configs}
```

---

## 📈 完整流程图

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 用户输入 Test Case ID                                      │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ├─→ aggr_upload-config_yml-server_config_name
                     │   (Single/Multi-Agg)
                     │
                     └─→ disagg_upload-complete_config_name
                         (Disagg)
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. parse_unified_testlist.py 解析                            │
├─────────────────────────────────────────────────────────────┤
│ • 拆分 test_id 提取组件                                       │
│ • 识别 test_type (aggr/disagg)                               │
│ • 加载对应的配置文件                                          │
│ • 计算 GPU 需求判断 single/multi                              │
│ • 输出分类结果                                                │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Jenkins 调用对应脚本                                       │
├─────────────────────────────────────────────────────────────┤
│ single-agg  → run_single_agg_test.sh                         │
│ multi-agg   → run_multi_agg_test.sh                          │
│ disagg      → run_disagg_test.sh                             │
└────────────────────┬────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. pytest 执行 test_perf_sanity.py::test_e2e                 │
├─────────────────────────────────────────────────────────────┤
│ def test_e2e(test_case_id):                                  │
│     config = PerfSanityTestConfig(test_case_id)              │
│     config.parse_config_file()                               │
│     ...                                                      │
└────────────────────┬────────────────────────────────────────┘
                     │
       ┌─────────────┴──────────────┐
       │                            │
       ▼                            ▼
┌──────────────┐            ┌───────────────┐
│ Agg 模式      │            │ Disagg 模式    │
├──────────────┤            ├───────────────┤
│ parse_test_  │            │ parse_test_   │
│ case_name()  │            │ case_name()   │
│   ↓          │            │   ↓           │
│ config_yml   │            │ complete_name │
│ + server_    │            │   ↓           │
│   config_    │            │ config_file = │
│   name       │            │ "deepseek-... │
│   ↓          │            │  UCX.yaml"    │
│ _parse_aggr_ │            │   ↓           │
│ config_file()│            │ _parse_disagg_│
│   ↓          │            │ config_file() │
│ 过滤 server_  │            │   ↓           │
│ configs     │            │ 创建 ctx+gen   │
│   ↓          │            │ ServerConfig  │
│ 提取 client_ │            │   ↓           │
│ configs     │            │ 生成 client_  │
│              │            │ configs       │
└──────────────┘            └───────────────┘
       │                            │
       └─────────────┬──────────────┘
                     ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. 执行测试                                                   │
├─────────────────────────────────────────────────────────────┤
│ for server_config in self.server_configs:                    │
│     client_configs = self.server_client_configs[idx]         │
│     for client_config in client_configs:                     │
│         run_test(server_config, client_config)               │
└─────────────────────────────────────────────────────────────┘
```

---

## 🎯 关键要点总结

### ✅ Single-Agg / Multi-Agg

1. **Test Case ID 格式**: `{test_type}-{config_yml}-{server_config_name}`
2. **配置文件**: 一个 YAML 包含**多个** `server_configs`
3. **select_pattern**: 用于选择哪些 `server_config` 要运行
4. **client_configs**: 定义在每个 `server_config` 内部

### ✅ Disagg

1. **Test Case ID 格式**: `{test_type}-{complete_config_name}`
2. **配置文件**: 一个 YAML = **一个完整配置**（ctx + gen）
3. **select_pattern**: 总是 `None`，无此概念
4. **client_configs**: 从 `benchmark.concurrency_list` 动态生成

### ⚠️ 最大区别

```
Agg:    一个配置文件 → 多个 server configs → 用户选择运行哪个
Disagg: 一个配置文件 → 一个完整配置 → 无需选择
```

---

## 📚 相关文件索引

| 文件 | 说明 |
|------|------|
| `jenkins_test/scripts/parse_unified_testlist.py` | 解析 testlist，识别测试类型 |
| `jenkins_test/testlists/debug_cases.txt` | TXT 格式测试列表 |
| `tests/integration/defs/perf/test_perf_sanity.py` | pytest 测试入口 |
| `tests/scripts/perf-sanity/*.yaml` | Agg 模式配置文件 |
| `tests/integration/defs/perf/disagg/test_configs/disagg/perf/*.yaml` | Disagg 模式配置文件 |

---

**完成！** 🎉 现在你应该完全理解了从 `parse_unified_testlist.py` 到 `test_perf_sanity.py` 的完整运行链条！
