# 使用自定义 test_perf_enhanced.py 替代 test_perf_sanity.py

> 完整指南：如何让 CI 使用自定义的性能测试文件，支持 single-agg、multi-agg、multi-disagg 所有模式

---

## 📋 概述

### 当前架构

```
Jenkins Pipeline (Perf_Test.groovy)
    ↓
run_*_test.sh (run_disagg_test.sh / run_single_agg_test.sh / run_multi_agg_test.sh)
    ↓
submit.py (仅 disagg 模式) 或直接 pytest (agg 模式)
    ↓
pytest tests/integration/defs/perf/test_perf_sanity.py  ← 固定路径
```

### 目标架构

```
Jenkins Pipeline (Perf_Test.groovy)
    ↓
run_*_test.sh (支持自定义测试文件路径)
    ↓
submit.py (支持自定义测试文件) 或直接 pytest
    ↓
pytest tests/integration/defs/perf/test_perf_enhanced.py  ← 可配置路径
```

---

## 🎯 设计方案

### 方案 1: 环境变量控制（推荐）⭐

**优点：**
- ✅ 不修改现有脚本的主逻辑
- ✅ 保持向后兼容
- ✅ 灵活切换
- ✅ 易于调试

**实现：**

通过环境变量 `PERF_TEST_MODULE` 指定测试文件路径。

---

## 📝 详细实施方案

### 步骤 1: 创建自定义测试文件

**文件路径：**
```
tests/integration/defs/perf/test_perf_enhanced.py
```

**基础结构（基于 test_perf_sanity.py）：**

```python
#!/usr/bin/env python3
"""
TensorRT-LLM Enhanced Performance Tests
基于 test_perf_sanity.py，添加自定义功能
"""

# 导入原始 test_perf_sanity 的所有功能
from test_perf_sanity import (
    PerfSanityTestConfig,
    MODEL_PATH_DICT,
    PERF_METRIC_LOG_QUERIES,
    get_model_dir,
    get_dataset_path,
    # ... 其他需要的导入
)

# 可选：添加自己的模型路径映射
ENHANCED_MODEL_PATH_DICT = {
    **MODEL_PATH_DICT,  # 继承原始映射
    "my_custom_model": "path/to/my/model",  # 添加自定义模型
}

# 可选：扩展配置类
class EnhancedPerfTestConfig(PerfSanityTestConfig):
    """增强版性能测试配置"""
    
    def __init__(self, test_case_name: str, output_dir: str):
        super().__init__(test_case_name, output_dir)
        # 添加自定义初始化
        self._load_custom_settings()
    
    def _load_custom_settings(self):
        """加载自定义设置"""
        # 例如：读取额外的配置文件
        # 例如：设置自定义的默认值
        pass
    
    def export_results_to_csv(self, csv_path: str):
        """导出结果到 CSV（支持 trt_perf_parser.py）"""
        # 自定义 CSV 导出逻辑
        pass
    
    def upload_to_custom_db(self):
        """上传到自定义数据库"""
        # 自定义数据库上传逻辑
        pass

# 主测试函数（pytest 入口）
@pytest.fixture
def perf_enhanced_test_case(request):
    """Enhanced test case fixture"""
    return request.param

def test_e2e(output_dir, perf_enhanced_test_case):
    """端到端性能测试（增强版）"""
    # 创建配置
    config = EnhancedPerfTestConfig(perf_enhanced_test_case, output_dir)
    
    # 解析配置文件
    config.parse_config_file()
    
    # 获取命令
    commands = config.get_commands()
    
    # 运行命令并收集输出
    outputs = config.run_ex(commands)
    
    # 分流：只有 BENCHMARK 节点处理结果
    if config.runtime == "multi_node_disagg_server":
        disagg_config = config.server_configs[0][2]
        if disagg_config.disagg_serving_type != "BENCHMARK":
            print_info(
                f"Disagg serving type is {disagg_config.disagg_serving_type}, "
                f"skipping perf result parsing and upload."
            )
            return
    
    # 解析性能结果
    config.get_perf_result(outputs)
    
    # 检查测试失败
    config.check_test_failure()
    
    # ✅ 自定义功能 1: 导出 CSV
    csv_output_path = os.path.join(
        config.perf_sanity_output_dir,
        "perf_script_test_results.csv"
    )
    config.export_results_to_csv(csv_output_path)
    
    # ✅ 自定义功能 2: 上传到 OpenSearch（原始功能）
    config.upload_test_results_to_database()
    
    # ✅ 自定义功能 3: 上传到自定义数据库
    config.upload_to_custom_db()
    
    # ✅ 自定义功能 4: 其他定制逻辑
    # ...

if __name__ == "__main__":
    pytest.main([__file__])
```

---

### 步骤 2: 修改脚本支持自定义测试路径

#### 2.1 修改 run_disagg_test.sh

**当前代码（257 行和 284 行）：**

```bash
# 步骤 2.1: 创建 test list 文件
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}]
EOF

# 步骤 4.2: 创建 script prefix 文件
export pytestCommand="pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
```

**修改为（支持自定义）：**

```bash
# ============================================
# 步骤 0: 确定测试模块路径
# ============================================

# 从环境变量读取自定义测试模块（默认使用 test_perf_sanity.py）
PERF_TEST_MODULE="${PERF_TEST_MODULE:-perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"
PERF_TEST_PREFIX="${PERF_TEST_PREFIX:-disagg_upload}"

echo "[步骤 0] 测试模块配置:"
echo "  测试模块: $PERF_TEST_MODULE"
echo "  测试函数: $PERF_TEST_FUNCTION"
echo "  测试前缀: $PERF_TEST_PREFIX"

# ============================================
# 步骤 2.1: 创建 test list 文件
# ============================================
TEST_LIST_FILE="$WORKSPACE/test_list_disagg.txt"
cat > "$TEST_LIST_FILE" << EOF
${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}]
EOF
echo "✓ 生成 test list: $TEST_LIST_FILE"

# ============================================
# 步骤 4.2: 创建 script prefix 文件
# ============================================
SCRIPT_PREFIX_FILE="$WORKSPACE/slurm_launch_prefix.sh"
cat > "$SCRIPT_PREFIX_FILE" << EOFPREFIX
#!/bin/bash
#SBATCH --output=$WORKSPACE/slurm_%j.log
#SBATCH --nodes=$TOTAL_NODES
#SBATCH --ntasks=$TOTAL_GPUS
#SBATCH --ntasks-per-node=$GPUS_PER_NODE
#SBATCH --gpus-per-node=$GPUS_PER_NODE
#SBATCH --partition=$CLUSTER_PARTITION
#SBATCH --account=$CLUSTER_ACCOUNT
#SBATCH --job-name=disagg_perf_test
#SBATCH --time=04:00:00

set -xEeuo pipefail

export pytestCommand="pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-${CONFIG_NAME}] -vv --junit-xml=$WORKSPACE/results.xml"
export jobWorkspace=$WORKSPACE/disagg_workspace
export llmSrcNode=$TRTLLM_DIR
export stageName="disagg_perf_test_${CONFIG_NAME}"
export perfMode=true
export resourcePathNode=$TRTLLM_DIR
export coverageConfigFile=$WORKSPACE/coverage_config.json
EOFPREFIX
```

**关键修改：**

1. ✅ 添加环境变量 `PERF_TEST_MODULE`（默认 `perf/test_perf_sanity.py`）
2. ✅ 添加环境变量 `PERF_TEST_FUNCTION`（默认 `test_e2e`）
3. ✅ 添加环境变量 `PERF_TEST_PREFIX`（默认 `disagg_upload`）
4. ✅ 使用变量构造测试路径

---

#### 2.2 修改 run_single_agg_test.sh

**当前代码（131 行）：**

```bash
PYTEST_CMD+=" tests/integration/defs/perf/test_perf_sanity.py::test_e2e"
```

**修改为：**

```bash
# 确定测试模块路径
PERF_TEST_MODULE="${PERF_TEST_MODULE:-tests/integration/defs/perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"

echo "测试模块: $PERF_TEST_MODULE"
echo "测试函数: $PERF_TEST_FUNCTION"

PYTEST_CMD+=" ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}"
```

---

#### 2.3 修改 run_multi_agg_test.sh

**当前代码（201 行）：**

```bash
PYTEST_CMD+=" tests/integration/defs/perf/test_perf_sanity.py::test_e2e"
```

**修改为：**

```bash
# 确定测试模块路径
PERF_TEST_MODULE="${PERF_TEST_MODULE:-tests/integration/defs/perf/test_perf_sanity.py}"
PERF_TEST_FUNCTION="${PERF_TEST_FUNCTION:-test_e2e}"

echo "测试模块: $PERF_TEST_MODULE"
echo "测试函数: $PERF_TEST_FUNCTION"

PYTEST_CMD+=" ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}"
```

---

### 步骤 3: 修改 Jenkins Pipeline（Perf_Test.groovy）

**添加新的参数（在 15-111 行的 parameters 部分）：**

```groovy
properties([
    parameters([
        // ... 现有参数 ...
        
        // ✅ 新增：自定义测试模块参数
        string(
            name: 'PERF_TEST_MODULE',
            defaultValue: 'perf/test_perf_sanity.py',
            description: '''性能测试模块路径（相对于 tests/integration/defs/）
默认: perf/test_perf_sanity.py
自定义: perf/test_perf_enhanced.py
完整路径示例: tests/integration/defs/perf/test_perf_enhanced.py'''
        ),
        string(
            name: 'PERF_TEST_FUNCTION',
            defaultValue: 'test_e2e',
            description: '''性能测试函数名
默认: test_e2e
自定义: test_e2e_enhanced'''
        ),
        string(
            name: 'PERF_TEST_PREFIX',
            defaultValue: '',
            description: '''测试名称前缀（仅 disagg 模式）
默认: disagg_upload (不填则使用默认值)
自定义: disagg_custom'''
        ),
        
        // ... 其他参数 ...
    ])
])
```

**在 environment 部分添加环境变量（124-148 行）：**

```groovy
environment {
    // ... 现有环境变量 ...
    
    // ✅ 新增：自定义测试模块环境变量
    PERF_TEST_MODULE = "${params.PERF_TEST_MODULE ?: 'perf/test_perf_sanity.py'}"
    PERF_TEST_FUNCTION = "${params.PERF_TEST_FUNCTION ?: 'test_e2e'}"
    PERF_TEST_PREFIX = "${params.PERF_TEST_PREFIX ?: 'disagg_upload'}"
}
```

**在执行测试时导出环境变量（382-404 行）：**

```groovy
// 执行 sync_and_run.sh
def result = sh(
    script: """
        # 导出集群配置环境变量
        export CLUSTER_ACCOUNT='${env.CLUSTER_ACCOUNT}'
        export CLUSTER_PARTITION='${env.CLUSTER_PARTITION}'
        export CLUSTER_LLM_DATA='${env.CLUSTER_LLM_DATA}'
        export DOCKER_IMAGE='${env.DOCKER_IMAGE}'
        export MPI_TYPE='${env.MPI_TYPE}'
        export CLUSTER_HOST='${env.CLUSTER_HOST}'
        export CLUSTER_USER='${env.CLUSTER_USER}'
        export CLUSTER_TYPE='${env.CLUSTER_TYPE}'
        export CLUSTER_NAME='${env.CLUSTER_NAME}'
        export CLUSTER_WORKDIR='${env.CLUSTER_WORKDIR}'
        
        # ✅ 新增：导出自定义测试模块环境变量
        export PERF_TEST_MODULE='${env.PERF_TEST_MODULE}'
        export PERF_TEST_FUNCTION='${env.PERF_TEST_FUNCTION}'
        export PERF_TEST_PREFIX='${env.PERF_TEST_PREFIX}'
        
        # 调用 sync_and_run.sh
        ${SCRIPTS_DIR}/sync_and_run.sh \\
            --trtllm-dir ${TRTLLM_DIR} \\
            --workspace ${OUTPUT_DIR} \\
            --remote-script ${remoteScript} \\
            ${remoteScriptArgs.join(' ')}
    """,
    returnStatus: true
)
```

---

### 步骤 4: 修改 sync_and_run.sh（传递环境变量）

**在 SSH 执行部分添加环境变量：**

```bash
# 在 SSH 命令中添加环境变量
ssh ${CLUSTER_USER}@${CLUSTER_HOST} "
    export CLUSTER_ACCOUNT='${CLUSTER_ACCOUNT}'
    export CLUSTER_PARTITION='${CLUSTER_PARTITION}'
    export CLUSTER_LLM_DATA='${CLUSTER_LLM_DATA}'
    export DOCKER_IMAGE='${DOCKER_IMAGE}'
    export MPI_TYPE='${MPI_TYPE}'
    
    # ✅ 新增：传递自定义测试模块环境变量
    export PERF_TEST_MODULE='${PERF_TEST_MODULE}'
    export PERF_TEST_FUNCTION='${PERF_TEST_FUNCTION}'
    export PERF_TEST_PREFIX='${PERF_TEST_PREFIX}'
    
    cd ${REMOTE_WORKSPACE} && bash ${REMOTE_SCRIPT_PATH} ${SCRIPT_ARGS}
"
```

---

## 📊 使用示例

### 示例 1: 使用默认 test_perf_sanity.py（保持现状）

**Jenkins 参数：**
```
PERF_TEST_MODULE: perf/test_perf_sanity.py  (默认)
PERF_TEST_FUNCTION: test_e2e                (默认)
PERF_TEST_PREFIX: disagg_upload             (默认)
```

**实际执行：**
```bash
pytest perf/test_perf_sanity.py::test_e2e[disagg_upload-deepseek-r1-fp4_...]
```

**效果：** ✅ 完全兼容现有流程

---

### 示例 2: 使用自定义 test_perf_enhanced.py

**Jenkins 参数：**
```
PERF_TEST_MODULE: perf/test_perf_enhanced.py
PERF_TEST_FUNCTION: test_e2e
PERF_TEST_PREFIX: disagg_custom
```

**实际执行：**
```bash
pytest perf/test_perf_enhanced.py::test_e2e[disagg_custom-deepseek-r1-fp4_...]
```

**效果：** ✅ 使用自定义测试文件

---

### 示例 3: 使用完全自定义的函数

**Jenkins 参数：**
```
PERF_TEST_MODULE: perf/my_custom_tests.py
PERF_TEST_FUNCTION: test_custom_benchmark
PERF_TEST_PREFIX: custom_test
```

**实际执行：**
```bash
pytest perf/my_custom_tests.py::test_custom_benchmark[custom_test-deepseek-r1-fp4_...]
```

**效果：** ✅ 完全自定义测试

---

## 🔍 支持的三种模式

### 1. Single-Agg 模式

**调用链：**
```
Perf_Test.groovy
  → run_single_agg_test.sh
    → pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[config-name]
```

**修改点：**
- ✅ `run_single_agg_test.sh` 使用 `PERF_TEST_MODULE` 环境变量

---

### 2. Multi-Agg 模式

**调用链：**
```
Perf_Test.groovy
  → run_multi_agg_test.sh
    → pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[config-name]
```

**修改点：**
- ✅ `run_multi_agg_test.sh` 使用 `PERF_TEST_MODULE` 环境变量

---

### 3. Disagg 模式

**调用链：**
```
Perf_Test.groovy
  → run_disagg_test.sh
    → submit.py
      → slurm_launch_draft.sh
        → slurm_run.sh
          → pytest ${PERF_TEST_MODULE}::${PERF_TEST_FUNCTION}[${PERF_TEST_PREFIX}-config-name]
```

**修改点：**
- ✅ `run_disagg_test.sh` 使用 `PERF_TEST_MODULE`、`PERF_TEST_FUNCTION`、`PERF_TEST_PREFIX` 环境变量
- ✅ 通过 `slurm_launch_prefix.sh` 传递给 pytest

---

## 📝 自定义功能示例

### 功能 1: 导出 CSV 供 trt_perf_parser.py 使用

```python
# test_perf_enhanced.py

def export_results_to_csv(self, csv_path: str):
    """导出结果到 CSV 供 trt_perf_parser.py 使用"""
    import csv
    
    if not self._perf_results:
        return
    
    csv_rows = []
    
    for server_idx, (ctx_config, gen_config, disagg_config) in enumerate(self.server_configs):
        client_configs = self.server_client_configs[server_idx]
        server_perf_results = self._perf_results.get(server_idx, [])
        
        for client_idx, client_config in enumerate(client_configs):
            if client_idx >= len(server_perf_results) or server_perf_results[client_idx] is None:
                continue
            
            perf_data = server_perf_results[client_idx]
            
            row = {
                'network': disagg_config.name,
                'batchsize': client_config.concurrency,
                'precision': gen_config.dtype,
                'framework': 'TensorRT-LLM',
                'command': f"disagg_{ctx_config.name}_{gen_config.name}",
            }
            
            # 添加性能指标
            for metric_name, metric_value in perf_data.items():
                if metric_name in ['mean_ttft', 'median_ttft', 'p99_ttft']:
                    row[f'{metric_name}__ms'] = metric_value
                elif metric_name in ['mean_e2el', 'median_e2el', 'p99_e2el']:
                    row[f'{metric_name}__ms'] = metric_value
                elif metric_name == 'token_throughput':
                    row['throughput__qps'] = metric_value
                else:
                    row[metric_name] = metric_value
            
            csv_rows.append(row)
    
    # 写入 CSV
    if csv_rows:
        fieldnames = list(csv_rows[0].keys())
        with open(csv_path, 'w', newline='') as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(csv_rows)
        print_info(f"Exported {len(csv_rows)} results to {csv_path}")
```

---

### 功能 2: 自定义日志收集

```python
# test_perf_enhanced.py

def collect_detailed_logs(self, log_dir: str):
    """收集详细的日志文件"""
    import shutil
    
    os.makedirs(log_dir, exist_ok=True)
    
    # 收集所有日志
    log_patterns = [
        (f"{self.output_dir}/*.log", "server_logs"),
        (f"{self.output_dir}/*_server_*.log", "component_logs"),
        (f"{self.output_dir}/benchmark*.log", "benchmark_logs"),
    ]
    
    for pattern, subdir in log_patterns:
        dest = os.path.join(log_dir, subdir)
        os.makedirs(dest, exist_ok=True)
        
        for log_file in glob.glob(pattern):
            shutil.copy(log_file, dest)
            print_info(f"Collected log: {log_file} → {dest}")
```

---

### 功能 3: 自定义性能指标

```python
# test_perf_enhanced.py

CUSTOM_PERF_METRICS = {
    **PERF_METRIC_LOG_QUERIES,  # 继承原始指标
    
    # 添加自定义指标
    "custom_metric_1": re.compile(r"My Metric 1 \(units\):\s+(-?[\d\.]+)"),
    "custom_metric_2": re.compile(r"My Metric 2 \(units\):\s+(-?[\d\.]+)"),
}

def get_perf_result(self, outputs: Dict[int, List[str]]):
    """解析性能结果（支持自定义指标）"""
    # 使用自定义指标解析
    for metric_name, pattern in CUSTOM_PERF_METRICS.items():
        # 解析逻辑
        pass
```

---

## 🎯 完整修改清单

### 必须修改的文件

| 文件 | 修改内容 | 行号参考 |
|------|---------|---------|
| **run_disagg_test.sh** | 添加 `PERF_TEST_MODULE`、`PERF_TEST_FUNCTION`、`PERF_TEST_PREFIX` 支持 | 257, 284 |
| **run_single_agg_test.sh** | 添加 `PERF_TEST_MODULE`、`PERF_TEST_FUNCTION` 支持 | 131 |
| **run_multi_agg_test.sh** | 添加 `PERF_TEST_MODULE`、`PERF_TEST_FUNCTION` 支持 | 201 |
| **Perf_Test.groovy** | 添加参数和环境变量 | 15-111 (参数), 124-148 (环境变量), 382-404 (导出) |
| **sync_and_run.sh** | 传递环境变量到远程执行 | SSH 命令部分 |

### 可选修改的文件

| 文件 | 修改内容 |
|------|---------|
| **parse_unified_testlist.py** | 支持自定义测试前缀解析 (如果使用 TestList 模式) |

---

## 📚 测试验证

### 验证步骤 1: 本地测试

```bash
# 设置环境变量
export PERF_TEST_MODULE="perf/test_perf_enhanced.py"
export PERF_TEST_FUNCTION="test_e2e"
export PERF_TEST_PREFIX="custom_test"

# 运行单个测试
bash jenkins_test/scripts/run_disagg_test.sh deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX
```

### 验证步骤 2: Jenkins 测试

**在 Jenkins 中设置参数：**
- PERF_TEST_MODULE: `perf/test_perf_enhanced.py`
- PERF_TEST_FUNCTION: `test_e2e`
- PERF_TEST_PREFIX: `custom_test`
- TESTLIST: `manual`
- CONFIG_FILE: `deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX`
- MANUAL_TEST_MODE: `disagg`

**检查日志输出：**
```
[步骤 0] 测试模块配置:
  测试模块: perf/test_perf_enhanced.py
  测试函数: test_e2e
  测试前缀: custom_test
```

### 验证步骤 3: 检查生成的命令

**查看 slurm_launch_prefix.sh：**
```bash
cat $WORKSPACE/slurm_launch_prefix.sh | grep pytestCommand
```

**应该看到：**
```bash
export pytestCommand="pytest perf/test_perf_enhanced.py::test_e2e[custom_test-deepseek-r1-fp4_...] -vv --junit-xml=$WORKSPACE/results.xml"
```

---

## 🔧 常见问题

### Q1: 如何快速切换回原始 test_perf_sanity.py？

**A:** 只需将 Jenkins 参数设置为默认值或留空即可：
```
PERF_TEST_MODULE: perf/test_perf_sanity.py (或留空)
PERF_TEST_FUNCTION: test_e2e (或留空)
PERF_TEST_PREFIX: disagg_upload (或留空)
```

---

### Q2: test_perf_enhanced.py 需要放在哪里？

**A:** 建议放在与 test_perf_sanity.py 相同的目录：
```
tests/integration/defs/perf/test_perf_enhanced.py
```

这样可以直接使用相对路径 `perf/test_perf_enhanced.py`。

---

### Q3: 如何确保 test_perf_enhanced.py 与现有系统兼容？

**A:** 遵循以下原则：

1. ✅ **继承原始类**：
   ```python
   from test_perf_sanity import PerfSanityTestConfig
   
   class EnhancedPerfTestConfig(PerfSanityTestConfig):
       pass
   ```

2. ✅ **保持相同的测试函数签名**：
   ```python
   def test_e2e(output_dir, perf_test_case):
       # 参数名称和数量必须相同
       pass
   ```

3. ✅ **支持相同的 YAML 配置格式**

4. ✅ **返回相同的性能指标格式**

---

### Q4: 是否会影响现有的测试？

**A:** 不会！
- ✅ 默认值使用原始 `test_perf_sanity.py`
- ✅ 所有修改都是**向后兼容**的
- ✅ 只有明确指定自定义模块时才会使用

---

### Q5: 如何在自定义测试中复用原始功能？

**A:** 通过导入和继承：

```python
# 导入所有原始功能
from test_perf_sanity import *

# 扩展配置类
class EnhancedPerfTestConfig(PerfSanityTestConfig):
    def upload_test_results_to_database(self):
        # 调用原始功能
        super().upload_test_results_to_database()
        
        # 添加自定义功能
        self._upload_to_custom_db()
```

---

## ✅ 总结

### 关键优势

1. ✅ **完全兼容**：不破坏现有流程
2. ✅ **灵活切换**：通过环境变量控制
3. ✅ **统一架构**：single-agg、multi-agg、disagg 都支持
4. ✅ **易于扩展**：可以添加任意自定义功能
5. ✅ **易于调试**：可以本地测试

### 实施步骤总结

1. ✅ 创建 `test_perf_enhanced.py`
2. ✅ 修改 `run_disagg_test.sh`、`run_single_agg_test.sh`、`run_multi_agg_test.sh`
3. ✅ 修改 `Perf_Test.groovy` 添加参数
4. ✅ 修改 `sync_and_run.sh` 传递环境变量
5. ✅ 测试验证

### 使用建议

- 🔸 **开发阶段**：使用 `test_perf_enhanced.py` 添加新功能
- 🔸 **稳定后**：考虑合并到 `test_perf_sanity.py`
- 🔸 **特殊需求**：保持独立的 `test_perf_enhanced.py`

---

**现在你有了完整的定制方案！需要我帮你实际修改这些文件吗？** 🚀
