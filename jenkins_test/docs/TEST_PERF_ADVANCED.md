# TEST_PERF_ADVANCED.md - 通过继承实现 Disagg 和 WideEP 双模式支持

> **目标：通过继承 test_perf_sanity.py 创建新的测试模块，支持 Disagg（NV SA benchmark）和 WideEP（标准 benchmark）两种模式**

---

## 📋 背景说明

### 问题描述

当前 `test_perf_sanity.py` 只支持一种 benchmark 模式，无法同时处理两种配置：

| 配置类型 | 路径 | Benchmark 脚本 | 数据集类型 | 关键参数 |
|---------|------|---------------|-----------|---------|
| **Disagg** | `test_configs/disagg/perf/` | `run_benchmark_nv_sa.sh` | 随机生成 | `--dataset-name random` |
| **WideEP** | `test_configs/wideep/perf/` | `run_benchmark.sh` | 真实数据集 | `--dataset-name trtllm_custom` |

### YAML 配置差异

#### Disagg 配置示例

```yaml
benchmark:
  mode: e2e
  use_nv_sa_benchmark: true  # ← 关键标志
  multi_round: 8
  benchmark_ratio: 0.8
  streaming: true
  concurrency_list: '1024'
  input_length: 1024
  output_length: 1024
  dataset_file: <dataset_file>  # ← 不使用
```

#### WideEP 配置示例

```yaml
benchmark:
  mode: gen_only
  use_nv_sa_benchmark: false  # ← 关键标志
  multi_round: 8
  benchmark_ratio: 0.8
  streaming: true
  concurrency_list: '1024'
  input_length: 1024
  output_length: 1024
  dataset_file: <dataset_file>  # ← 使用真实数据集
```

---

## 🎯 推荐方案：继承方式实现（最佳实践）✅

### 方案优势

**优点：**
- ✅ **不修改原始文件**，完全无风险
- ✅ **代码复用**，继承大部分功能
- ✅ **职责清晰**，原有测试保持不变
- ✅ **易于维护**，只需维护差异部分
- ✅ **灵活切换**，通过环境变量选择
- ✅ **向后兼容**，不影响现有 CI

**缺点：**
- ⚠️ 需要修改 Jenkins pipeline（添加参数选择）
- ⚠️ 需要理解继承机制

---

## 📝 完整实现步骤

### 步骤 1: 创建新的测试文件

**文件路径：** `tests/integration/defs/perf/test_perf_advanced.py`

或

**文件路径：** `tests/integration/defs/perf/test_perf_qa.py`

> 建议使用 `test_perf_advanced.py`，命名更清晰

---

### 文件结构

```
tests/integration/defs/perf/
├── test_perf_sanity.py          # 原始文件（不修改）
├── test_perf_advanced.py        # ✅ 新文件（继承实现）
└── __init__.py
```

---

### 步骤 2: 完整的 test_perf_advanced.py 实现

**创建文件：** `tests/integration/defs/perf/test_perf_advanced.py`

```python
"""
Advanced performance test with support for both Disagg and WideEP benchmark modes.

This module extends test_perf_sanity.py to support:
- NV SA Benchmark mode (random dataset) - for Disagg configs
- Standard Benchmark mode (real dataset) - for WideEP configs

Usage:
    # Use via environment variable
    export PERF_TEST_MODULE="perf/test_perf_advanced.py"
    
    # Or specify in pytest command
    pytest perf/test_perf_advanced.py::test_e2e[test_case_name]
"""

import os
import sys
from typing import List, Dict

# 导入原始类和函数
from .test_perf_sanity import (
    PerfSanityTestConfig,
    ClientConfig as BaseClientConfig,
    ServerConfig,
    AggrTestCmds,
    DisaggTestCmds,
    DisaggConfig,
    get_model_dir,
    get_dataset_path,
    print_info,
    to_env_dict,
)


# ============================================
# 继承并扩展 ClientConfig
# ============================================
class AdvancedClientConfig(BaseClientConfig):
    """
    Enhanced client config with dual benchmark mode support.
    
    Extends the base ClientConfig to support both:
    - NV SA benchmark (random dataset)
    - Standard benchmark (real dataset from file)
    """
    
    def __init__(
        self, 
        client_config_data: dict, 
        model_name: str, 
        env_vars: str = "",
        use_nv_sa_benchmark: bool = True  # 新增参数
    ):
        """
        Initialize advanced client config.
        
        Args:
            client_config_data: Client configuration dict from YAML
            model_name: Model name
            env_vars: Environment variables string
            use_nv_sa_benchmark: If True, use NV SA benchmark (random);
                               If False, use standard benchmark (dataset file)
        """
        # 调用父类构造函数
        super().__init__(client_config_data, model_name, env_vars)
        
        # 新增属性
        self.use_nv_sa_benchmark = use_nv_sa_benchmark
        
        print_info(
            f"[Advanced] Client initialized with benchmark mode: "
            f"{'NV SA (random)' if use_nv_sa_benchmark else 'Standard (dataset)'}"
        )
    
    def to_cmd(self) -> List[str]:
        """
        Generate benchmark command with dual mode support.
        
        Returns:
            List[str]: Benchmark command arguments
        """
        model_dir = get_model_dir(self.model_name)
        self.model_path = model_dir if os.path.exists(model_dir) else self.model_name
        dataset_path = get_dataset_path()
        
        # 基础命令
        benchmark_cmd = [
            "python",
            "-m",
            "tensorrt_llm.serve.scripts.benchmark_serving",
            "--model",
            self.model_path,
            "--tokenizer",
            self.model_path,
        ]
        
        # ========================================
        # 根据模式选择数据集配置
        # ========================================
        if self.use_nv_sa_benchmark:
            # ========================================
            # NV SA Benchmark 模式（Disagg）
            # ========================================
            # 使用随机生成的数据，不依赖真实数据集文件
            # 对应 examples/disaggregated/slurm/benchmark/run_benchmark_nv_sa.sh
            benchmark_cmd.extend([
                "--dataset-name",
                "random",
                "--random-ids",
                "--random-input-len",
                str(self.isl),
                "--random-output-len",
                str(self.osl),
                "--random-range-ratio",
                str(self.random_range_ratio),
            ])
            print_info(
                f"[Advanced] Using NV SA benchmark mode:\n"
                f"  - Dataset: random\n"
                f"  - Input length: {self.isl}\n"
                f"  - Output length: {self.osl}\n"
                f"  - Range ratio: {self.random_range_ratio}"
            )
        else:
            # ========================================
            # 标准 Benchmark 模式（WideEP）
            # ========================================
            # 使用真实数据集文件
            # 对应 examples/disaggregated/slurm/benchmark/run_benchmark.sh
            benchmark_cmd.extend([
                "--dataset-name",
                "trtllm_custom",
            ])
            
            if dataset_path and os.path.exists(dataset_path):
                benchmark_cmd.extend([
                    "--dataset-path",
                    dataset_path,
                ])
                print_info(
                    f"[Advanced] Using standard benchmark mode:\n"
                    f"  - Dataset: trtllm_custom\n"
                    f"  - Dataset path: {dataset_path}"
                )
            else:
                print(
                    f"[Advanced WARNING] Dataset path not found or invalid: {dataset_path}\n"
                    f"Falling back to random mode with specified lengths",
                    file=sys.stderr
                )
                # 回退到随机模式（保持 trtllm_custom 但添加随机参数）
                benchmark_cmd.extend([
                    "--random-input-len",
                    str(self.isl),
                    "--random-output-len",
                    str(self.osl),
                ])
        
        # ========================================
        # 共同参数（两种模式都需要）
        # ========================================
        benchmark_cmd.extend([
            "--num-prompts",
            str(self.concurrency * self.iterations),
            "--max-concurrency",
            str(self.concurrency),
            "--ignore-eos",
            "--percentile-metrics",
            "ttft,tpot,itl,e2el",
        ])
        
        # 可选参数
        if self.backend:
            benchmark_cmd.extend(["--backend", self.backend])
        if self.use_chat_template:
            benchmark_cmd.append("--use-chat-template")
        if not self.streaming:
            benchmark_cmd.append("--non-streaming")
        if self.trust_remote_code:
            benchmark_cmd.append("--trust-remote-code")
        
        return benchmark_cmd


# ============================================
# 继承并扩展 PerfSanityTestConfig
# ============================================
class AdvancedPerfTestConfig(PerfSanityTestConfig):
    """
    Enhanced performance test config with dual mode support.
    
    Extends PerfSanityTestConfig to create AdvancedClientConfig instances
    instead of base ClientConfig instances.
    """
    
    def _parse_disagg_config_file(self, config_file_path: str, config_file: str):
        """
        Parse YAML config file for disaggregated server with enhanced benchmark support.
        
        This method overrides the parent to:
        1. Read the use_nv_sa_benchmark flag from YAML
        2. Create AdvancedClientConfig instances instead of base ClientConfig
        3. Pass the benchmark mode flag to clients
        """
        import yaml
        import socket
        
        disagg_serving_type = os.environ.get("DISAGG_SERVING_TYPE", "BENCHMARK")
        
        with open(config_file_path) as f:
            config = yaml.safe_load(f)
        
        # 提取各部分配置
        metadata = config.get("metadata", {})
        hardware = config.get("hardware", {})
        benchmark = config.get("benchmark", {})
        environment = config.get("environment", {})
        worker_config = config.get("worker_config", {})
        
        # ✅ 关键：读取 use_nv_sa_benchmark 标志
        use_nv_sa_benchmark = benchmark.get("use_nv_sa_benchmark", True)  # 默认 True（向后兼容）
        
        print_info(
            f"[Advanced] Disagg config parsed:\n"
            f"  - Config file: {config_file}\n"
            f"  - Benchmark mode: {'NV SA (random)' if use_nv_sa_benchmark else 'Standard (dataset)'}\n"
            f"  - Serving type: {disagg_serving_type}"
        )
        
        # 提取其他配置
        model_name = metadata.get("model_name", "")
        gpus_per_node = hardware.get("gpus_per_node", 0)
        
        worker_env_var = environment.get("worker_env_var", "")
        server_env_var = environment.get("server_env_var", "")
        client_env_var = environment.get("client_env_var", "")
        
        # 解析 concurrency_list
        concurrency_str = benchmark.get("concurrency_list", "1")
        if isinstance(concurrency_str, str):
            concurrency_values = [int(x) for x in concurrency_str.split()]
        elif isinstance(concurrency_str, list):
            concurrency_values = [int(x) for x in concurrency_str]
        else:
            concurrency_values = [int(concurrency_str)]
        
        # 创建 server configs（复用父类逻辑）
        config_file_base_name = os.path.splitext(os.path.basename(config_file))[0]
        
        ctx_server_config_data = {
            "concurrency": max(concurrency_values),
            "name": config_file_base_name,
            "model_name": model_name,
            "gpus_per_node": gpus_per_node,
            "disagg_run_type": "ctx",
            **worker_config.get("ctx", {}),
        }
        
        gen_server_config_data = {
            "concurrency": max(concurrency_values),
            "name": config_file_base_name,
            "model_name": model_name,
            "gpus_per_node": gpus_per_node,
            "disagg_run_type": "gen",
            **worker_config.get("gen", {}),
        }
        
        ctx_server_config = ServerConfig(ctx_server_config_data, worker_env_var)
        gen_server_config = ServerConfig(gen_server_config_data, worker_env_var)
        
        # ✅ 创建 client configs（使用增强版）
        client_configs = []
        for concurrency in concurrency_values:
            client_config_data = {
                "concurrency": concurrency,
                "iterations": benchmark.get("multi_round", 8),
                "isl": benchmark.get("input_length", 1024),
                "osl": benchmark.get("output_length", 1024),
                "random_range_ratio": benchmark.get("benchmark_ratio", 0.8),
                "backend": "openai",
                "use_chat_template": False,
                "streaming": benchmark.get("streaming", True),
                "trust_remote_code": True,
            }
            
            # ✅ 使用 AdvancedClientConfig 并传递 use_nv_sa_benchmark
            client_config = AdvancedClientConfig(
                client_config_data,
                model_name,
                client_env_var,
                use_nv_sa_benchmark=use_nv_sa_benchmark  # ← 传递标志
            )
            client_configs.append(client_config)
        
        # 创建 disagg config
        disagg_config = DisaggConfig(
            name=config_file_base_name,
            disagg_serving_type=disagg_serving_type,
            hostname=socket.gethostname(),
            numa_bind=benchmark.get("numa_bind", False),
            timeout=benchmark.get("timeout", 600),
            benchmark_mode=benchmark.get("mode", "e2e"),
            model_name=model_name,
            hardware=hardware,
            server_env_var=server_env_var,
        )
        
        # 创建命令元组列表
        server_cmds = []
        client_cmds = {}
        
        for server_idx in range(1):  # 简化：只支持单个 server 组合
            ctx_cmd = ctx_server_config.to_cmd(self.perf_sanity_output_dir, benchmark.get("numa_bind", False), "CTX")
            gen_cmd = gen_server_config.to_cmd(self.perf_sanity_output_dir, benchmark.get("numa_bind", False), "GEN")
            
            # Disagg coordinator 命令
            disagg_cmd = [
                "trtllm-serve-coordinator",
                "--config", os.path.join(self.perf_sanity_output_dir, f"server_config.{server_idx}.yaml"),
            ]
            
            server_cmds.append((ctx_cmd, gen_cmd, disagg_cmd))
            client_cmds[server_idx] = [client.to_cmd() for client in client_configs]
        
        return DisaggTestCmds(
            server_cmds=server_cmds,
            client_cmds=client_cmds,
            timeout=disagg_config.timeout,
            hostname=disagg_config.hostname,
            disagg_serving_type=disagg_config.disagg_serving_type,
            num_ctx_servers=hardware.get("num_ctx_servers", 1),
            num_gen_servers=hardware.get("num_gen_servers", 1),
            output_dir=self.perf_sanity_output_dir,
        )
    
    def _parse_aggr_config_file(self, config_file_path: str, config_file: str, selected_server_names=None):
        """
        Parse YAML config file for aggregated server with enhanced benchmark support.
        
        Overrides parent method to use AdvancedClientConfig.
        """
        import yaml
        
        with open(config_file_path) as f:
            config = yaml.safe_load(f)
        
        # 提取配置
        metadata = config.get("metadata", {})
        hardware = config.get("hardware", {})
        benchmark = config.get("benchmark", {})
        environment = config.get("environment", {})
        
        # ✅ 读取 use_nv_sa_benchmark 标志
        use_nv_sa_benchmark = benchmark.get("use_nv_sa_benchmark", True)
        
        print_info(
            f"[Advanced] Aggr config parsed:\n"
            f"  - Config file: {config_file}\n"
            f"  - Benchmark mode: {'NV SA (random)' if use_nv_sa_benchmark else 'Standard (dataset)'}"
        )
        
        model_name = metadata.get("model_name", "")
        gpus_per_node = hardware.get("gpus_per_node", 0)
        server_env_var = environment.get("server_env_var", "")
        client_env_var = environment.get("client_env_var", "")
        
        # 创建 server configs
        server_configs = []
        server_client_configs = {}
        
        for server_idx, server_config_data in enumerate(config["server_configs"]):
            # 检查是否应该包含此 server
            if (
                selected_server_names is not None
                and server_config_data.get("name") not in selected_server_names
            ):
                continue
            
            server_config_data["model_name"] = (
                model_name
                if "model_name" not in server_config_data
                else server_config_data["model_name"]
            )
            server_config_data["gpus_per_node"] = gpus_per_node
            
            server_config = ServerConfig(server_config_data, server_env_var)
            server_id = len(server_configs)
            server_configs.append(server_config)
            
            # ✅ 创建 client configs（使用增强版）
            client_configs = []
            for client_config_data in server_config_data["client_configs"]:
                client_config = AdvancedClientConfig(
                    client_config_data,
                    server_config_data["model_name"],
                    client_env_var,
                    use_nv_sa_benchmark=use_nv_sa_benchmark  # ← 传递标志
                )
                client_configs.append(client_config)
            
            server_client_configs[server_id] = client_configs
        
        self.server_configs = server_configs
        self.server_client_configs = server_client_configs


# ============================================
# Pytest 入口函数
# ============================================
def test_e2e(test_case_name, request):
    """
    Advanced E2E performance test with dual benchmark mode support.
    
    This test function uses AdvancedPerfTestConfig which automatically
    selects the appropriate benchmark mode based on YAML configuration.
    
    Args:
        test_case_name: Test case name in format "prefix-config_name"
        request: Pytest request fixture
    """
    print_info(
        f"========================================\n"
        f"[Advanced] Starting enhanced performance test\n"
        f"  Test case: {test_case_name}\n"
        f"========================================"
    )
    
    # 使用增强版配置
    config = AdvancedPerfTestConfig(
        test_case_name=test_case_name,
        output_dir=request.config.getoption("--output-dir"),
        perf_sanity_test_prefix=request.config.getoption("--test-prefix"),
    )
    
    # 执行测试（复用父类逻辑）
    config.parse_config_file()
    commands = config.get_commands()
    outputs = config.run_ex(commands)
    
    # 只有 BENCHMARK 节点才收集性能数据
    disagg_serving_type = os.environ.get("DISAGG_SERVING_TYPE", "BENCHMARK")
    if disagg_serving_type == "BENCHMARK":
        config.get_perf_result(outputs)
        config.upload_test_results_to_database()
    
    print_info(
        f"========================================\n"
        f"[Advanced] Performance test completed\n"
        f"  Test case: {test_case_name}\n"
        f"========================================"
    )
```

---

### 步骤 3: 修改 run_disagg_test.sh 支持模块选择

**文件：** `jenkins_test/scripts/run_disagg_test.sh`

**修改位置：** 步骤 4（约 250 行）

**已经完成的修改：**

```bash
# 从环境变量读取自定义测试模块配置（可选）
PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"

echo "测试模块配置:"
echo "  测试模块: $PERF_TEST_MODULE"
echo "  测试函数: $PERF_TEST_FUNCTION"
echo "  测试前缀: $PERF_TEST_PREFIX"
```

**✅ 无需额外修改**，因为模块路径会自动传递给 pytest。

---

### 步骤 4: 修改 Jenkins Pipeline 添加模块选择

**文件：** `jenkins_test/Perf_Test.groovy`

**添加参数选择：**

```groovy
parameters {
    // ... 其他现有参数 ...
    
    choice(
        name: 'PERF_TEST_MODULE',
        choices: [
            'perf/test_perf_sanity.py',     // 默认：原始实现
            'perf/test_perf_advanced.py',   // 增强：支持双模式
            'perf/test_perf_qa.py'          // QA：可选的另一个实现
        ],
        description: '性能测试模块选择（advanced 支持 Disagg 和 WideEP 双模式）'
    )
    
    string(
        name: 'PERF_TEST_FUNCTION',
        defaultValue: 'test_e2e',
        description: '性能测试函数名'
    )
    
    string(
        name: 'PERF_TEST_PREFIX',
        defaultValue: 'disagg_upload',
        description: '测试名称前缀'
    )
}

environment {
    // ... 其他环境变量 ...
    
    PERF_TEST_MODULE = "${params.PERF_TEST_MODULE ?: 'perf/test_perf_sanity.py'}"
    PERF_TEST_FUNCTION = "${params.PERF_TEST_FUNCTION ?: 'test_e2e'}"
    PERF_TEST_PREFIX = "${params.PERF_TEST_PREFIX ?: 'disagg_upload'}"
}

// 在执行阶段导出环境变量（sync_and_run.sh 部分）
stage('Run Tests') {
    steps {
        script {
            sh """
                export PERF_TEST_MODULE='${env.PERF_TEST_MODULE}'
                export PERF_TEST_FUNCTION='${env.PERF_TEST_FUNCTION}'
                export PERF_TEST_PREFIX='${env.PERF_TEST_PREFIX}'
                
                # 调用 sync_and_run.sh
                ${WORKSPACE}/jenkins_test/scripts/sync_and_run.sh \\
                    --cluster ${CLUSTER} \\
                    --trtllm-dir ${TRTLLM_DIR} \\
                    --testlist ${TESTLIST}
            """
        }
    }
}
```

---

### 步骤 5: 测试和验证

#### 5.1 本地测试

**测试 Disagg 配置（NV SA 模式）：**

```bash
# 设置环境变量使用增强版
export PERF_TEST_MODULE="perf/test_perf_advanced.py"
export PERF_TEST_FUNCTION="test_e2e"
export PERF_TEST_PREFIX="disagg_upload"

# 运行 Disagg 配置
pytest tests/integration/defs/perf/test_perf_advanced.py::test_e2e \
    -k "disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX" \
    -vv

# 检查日志，应该看到：
# [Advanced] Benchmark mode: NV SA (random)
# [Advanced] Using NV SA benchmark mode:
#   - Dataset: random
#   - Input length: 1024
#   - Output length: 1024
```

**测试 WideEP 配置（标准模式）：**

```bash
# 运行 WideEP 配置
pytest tests/integration/defs/perf/test_perf_advanced.py::test_e2e \
    -k "disagg_upload-deepseek-r1-fp4_1k1k_ctx1_gen1_dep32_bs32_eplb288_mtp0_ccb-UCX" \
    -vv

# 检查日志，应该看到：
# [Advanced] Benchmark mode: Standard (dataset)
# [Advanced] Using standard benchmark mode:
#   - Dataset: trtllm_custom
#   - Dataset path: /path/to/dataset.json
```

---

#### 5.2 通过 run_disagg_test.sh 测试

```bash
# 测试 Disagg 配置
export PERF_TEST_MODULE="perf/test_perf_advanced.py"

./jenkins_test/scripts/run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX \
    --workspace /tmp/test_disagg \
    --dry-run

# 检查生成的命令
cat /tmp/test_disagg/slurm_launch_prefix.sh | grep pytestCommand
# 应该包含 perf/test_perf_advanced.py
```

```bash
# 测试 WideEP 配置
export PERF_TEST_MODULE="perf/test_perf_advanced.py"

./jenkins_test/scripts/run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek-r1-fp4_1k1k_ctx1_gen1_dep32_bs32_eplb288_mtp0_ccb-UCX \
    --workspace /tmp/test_wideep \
    --dry-run

# 检查生成的命令
cat /tmp/test_wideep/slurm_launch_prefix.sh | grep pytestCommand
```

---

#### 5.3 CI 环境测试

**在 Jenkins 中选择参数：**

| 参数 | 值 | 说明 |
|------|-----|------|
| `PERF_TEST_MODULE` | `perf/test_perf_advanced.py` | 使用增强版 |
| `PERF_TEST_FUNCTION` | `test_e2e` | 测试函数 |
| `PERF_TEST_PREFIX` | `disagg_upload` | 测试前缀 |
| `TESTLIST` | 你的 testlist 名称 | 测试列表 |

---

### 步骤 6: 验证清单

#### 功能验证

- [ ] **Disagg 配置**使用 `--dataset-name random`
- [ ] **WideEP 配置**使用 `--dataset-name trtllm_custom`
- [ ] 日志正确显示使用的 benchmark 模式
- [ ] 两种模式都能正确收集性能数据
- [ ] 性能数据正确上传到 OpenSearch

#### 向后兼容验证

- [ ] 不设置 `PERF_TEST_MODULE` 时，默认使用 `test_perf_sanity.py`
- [ ] 原有的 CI 作业不受影响
- [ ] 现有的 Disagg 测试仍然正常工作

#### 错误处理

- [ ] WideEP 配置缺少数据集文件时有清晰提示
- [ ] 自动回退到随机模式（如果配置）
- [ ] YAML 配置缺少 `use_nv_sa_benchmark` 时使用默认值（True）

---

## 📊 继承方案 vs 直接修改对比

| 对比项 | 继承方案（本方案）✅ | 直接修改 test_perf_sanity.py |
|--------|-------------------|----------------------------|
| **修改原文件** | ❌ 不修改 | ✅ 需要修改 |
| **风险** | ✅ 低（完全独立） | ⚠️ 中（可能影响现有功能） |
| **代码复用** | ✅ 高（继承大部分） | ✅ 高（共享代码） |
| **维护成本** | ⚠️ 中（两个文件） | ✅ 低（一个文件） |
| **灵活性** | ✅ 高（可并存） | ⚠️ 中（必须兼容所有） |
| **测试复杂度** | ✅ 低（独立测试） | ⚠️ 高（需要全面回归） |
| **Jenkins 修改** | ⚠️ 需要（添加参数） | ✅ 不需要 |
| **推荐度** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |

---

## 🎯 实施路线图

### 阶段 1: 创建新文件（1 天）

1. ✅ 创建 `test_perf_advanced.py`
2. ✅ 实现 `AdvancedClientConfig` 类
3. ✅ 实现 `AdvancedPerfTestConfig` 类
4. ✅ 实现 `test_e2e()` 函数
5. ✅ 本地单元测试

### 阶段 2: 集成测试（1 天）

1. ✅ 修改 `run_disagg_test.sh` 支持模块选择（已完成）
2. ✅ 测试 Disagg 配置
3. ✅ 测试 WideEP 配置
4. ✅ 验证向后兼容性

### 阶段 3: Jenkins 集成（0.5 天）

1. ✅ 修改 `Perf_Test.groovy` 添加参数
2. ✅ 测试 Jenkins 作业
3. ✅ 验证环境变量传递

### 阶段 4: 文档和部署（0.5 天）

1. ✅ 更新使用文档
2. ✅ 创建示例配置
3. ✅ 培训团队成员

**总时间：** 约 3 天

---

## 📚 使用指南

### 场景 1: 使用原始实现（默认）

```bash
# 不设置任何环境变量，默认使用 test_perf_sanity.py
./jenkins_test/scripts/run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file your-config \
    --workspace /tmp/test
```

### 场景 2: 使用增强版（Disagg 配置）

```bash
# 设置环境变量使用 test_perf_advanced.py
export PERF_TEST_MODULE="perf/test_perf_advanced.py"

./jenkins_test/scripts/run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX \
    --workspace /tmp/test

# YAML 配置中 use_nv_sa_benchmark: true
# 自动使用随机数据集
```

### 场景 3: 使用增强版（WideEP 配置）

```bash
# 设置环境变量使用 test_perf_advanced.py
export PERF_TEST_MODULE="perf/test_perf_advanced.py"

./jenkins_test/scripts/run_disagg_test.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --config-file deepseek-r1-fp4_1k1k_ctx1_gen1_dep32_bs32_eplb288_mtp0_ccb-UCX \
    --workspace /tmp/test

# YAML 配置中 use_nv_sa_benchmark: false
# 自动使用真实数据集
```

### 场景 4: Jenkins Pipeline 使用

在 Jenkins 构建时选择参数：

1. 选择 `PERF_TEST_MODULE` = `perf/test_perf_advanced.py`
2. 选择你的 `TESTLIST`
3. 点击构建

Jenkins 会自动设置环境变量并调用正确的测试模块。

---

## 🔍 常见问题

### Q1: 为什么选择继承而不是直接修改？

**A:** 继承方案有以下优势：
- ✅ 零风险：不影响现有功能
- ✅ 灵活：可以同时保留两种实现
- ✅ 渐进：可以逐步迁移测试
- ✅ 清晰：职责分离，代码易读

### Q2: test_perf_advanced.py 和 test_perf_sanity.py 可以并存吗？

**A:** 可以！这是继承方案的优势：
- 原有测试继续使用 `test_perf_sanity.py`
- 新测试或需要双模式的测试使用 `test_perf_advanced.py`
- 通过环境变量或 Jenkins 参数选择

### Q3: 如何确保 test_perf_advanced.py 与 test_perf_sanity.py 保持同步？

**A:** 由于使用继承，大部分代码自动同步：
- ✅ 只重写了 2 个方法：`to_cmd()` 和配置解析
- ✅ 其他功能（服务器启动、性能收集、上传等）完全复用父类
- ✅ 父类更新自动生效

### Q4: 如果 YAML 配置缺少 `use_nv_sa_benchmark`，会怎样？

**A:** 默认使用 NV SA 模式（向后兼容）：
```python
use_nv_sa_benchmark = benchmark.get("use_nv_sa_benchmark", True)  # 默认 True
```

### Q5: 可以创建 test_perf_qa.py 吗？

**A:** 可以！继承方案支持多个实现：
```python
# tests/integration/defs/perf/test_perf_qa.py
from .test_perf_advanced import AdvancedClientConfig, AdvancedPerfTestConfig

class QAClientConfig(AdvancedClientConfig):
    # QA 特定的扩展
    pass

class QAPerfTestConfig(AdvancedPerfTestConfig):
    # QA 特定的扩展
    pass
```

---

## 📝 相关文档

1. **差异分析**: `jenkins_test/docs/DISAGG_VS_WIDEEP_ANALYSIS.md`
2. **run_disagg_test.sh 更新**: `jenkins_test/docs/RUN_DISAGG_TEST_UPDATE.md`
3. **自定义测试模块指南**: `jenkins_test/docs/CUSTOM_PERF_TEST_GUIDE.md`
4. **原始测试实现**: `tests/integration/defs/perf/test_perf_sanity.py`

---

## ✅ 总结

### 核心优势

1. ✅ **零风险**：不修改原文件，完全独立
2. ✅ **高复用**：继承大部分代码，只重写差异部分
3. ✅ **易维护**：清晰的职责分离
4. ✅ **灵活切换**：通过环境变量或 Jenkins 参数选择
5. ✅ **向后兼容**：不影响现有 CI 作业

### 关键文件

| 文件 | 作用 | 是否修改 |
|------|------|---------|
| `test_perf_sanity.py` | 原始实现 | ❌ 不修改 |
| `test_perf_advanced.py` | 增强实现（新建） | ✅ 创建 |
| `run_disagg_test.sh` | 测试脚本 | ✅ 小修改（已完成） |
| `Perf_Test.groovy` | Jenkins pipeline | ✅ 添加参数 |

### 实施建议

**推荐路线：**
1. 创建 `test_perf_advanced.py`（1 天）
2. 本地测试验证（0.5 天）
3. Jenkins 集成（0.5 天）
4. 文档和培训（0.5 天）

**总时间：** 2-3 天即可完成

---

**现在你有完整的实现方案了！需要我帮你实际创建 `test_perf_advanced.py` 文件吗？** 🚀
