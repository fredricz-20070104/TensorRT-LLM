# 使用 trt_perf_parser.py 向 perf_db 上传 Disagg 性能数据

> 完整指南：在集群内使用 trt_perf_parser.py 上传 disagg 测试性能数据到 TRT_perf 数据库

---

## 📋 概述

### 当前状态 vs 目标状态

| 维度 | 当前 Disagg 测试 | 使用 trt_perf_parser.py |
|------|------------------|------------------------|
| **数据存储** | ✅ OpenSearch（通过 test_perf_sanity.py） | ✅ MySQL TRT_perf 数据库 |
| **数据格式** | JSON (直接 POST) | CSV → 解析 → 插入 |
| **查看方式** | OpenSearch 查询 | TRTPerf 网页 |
| **适用场景** | 自动化测试、回归检测 | 历史追踪、性能对比 |

**结论：两个系统可以并存！**
- ✅ **OpenSearch**: 已经集成在 `test_perf_sanity.py` 中（无需修改）
- ✅ **TRT_perf DB**: 需要额外调用 `trt_perf_parser.py`（本文档说明如何集成）

---

## 🎯 trt_perf_parser.py 工作原理

### 输入要求

```python
# 必需输入
--source-metric-csv          # CSV 文件路径，包含性能指标
                            # 例如：perf_script_test_results.csv

# 可选但推荐输入
--source-properties         # Session 属性 CSV（系统信息）
--source-gpu-monitoring     # GPU 监控数据 CSV
--junit-xml                 # JUnit XML 文件（用于提取日志）

# 系统信息（必需）
--tensorrt      # TensorRT 版本
--trtllm        # TensorRT-LLM 版本
--driver        # GPU 驱动版本
--gpu           # GPU 型号
--cuda          # CUDA 版本
--os            # 操作系统

# 测试元数据（推荐）
--start-time    # 开始时间 "YYYY-MM-DD HH:MM:SS"
--end-time      # 结束时间 "YYYY-MM-DD HH:MM:SS"
--commit        # Git commit hash
--link          # Jenkins 作业链接
--notes         # 备注信息

# 数据库配置（可选，有默认值）
--DB-host       # 默认：dlswqa-nas.nvidia.com
--DB-port       # 默认：13306
--DB-user       # 默认：swqa
--DB-password   # 默认：labuser
--DB-schema     # 默认：TRT_perf

# 控制参数
--write-db      # 是否写入数据库（yes/no，默认 yes）
--verbose       # 详细输出
```

### 输出

1. **数据库表：`TRT_perf.runs`**
   - 记录测试运行的系统信息
   - 返回 `run_id`

2. **数据库表：`TRT_perf.cases`**
   - 记录测试用例（network, batch_size, precision 等）
   - 返回 `case_id`

3. **数据库表：`TRT_perf.perf_result`**
   - 记录性能结果（throughput, latency, 等）
   - 关联 `run_id` 和 `case_id`

4. **TRTPerf 网页链接**
   ```
   http://dlswqa.nvidia.com/trtperf?req=get_html&run_ids=<run_id>&baseline=--&target=--&drop_limit=5&time_limit=0.0&gap_limit=-999.9&only_show_drop=true
   ```

---

## ❌ 问题：Disagg 测试不生成 CSV 文件

### 当前 Disagg 测试流程

```python
# test_perf_sanity.py (1491-1520 行)
def test_e2e(output_dir, perf_sanity_test_case):
    config = PerfSanityTestConfig(perf_sanity_test_case, output_dir)
    config.parse_config_file()
    commands = config.get_commands()
    outputs = config.run_ex(commands)
    
    # 只有 BENCHMARK 节点处理结果
    if config.runtime == "multi_node_disagg_server":
        disagg_config = config.server_configs[0][2]
        if disagg_config.disagg_serving_type != "BENCHMARK":
            return  # GEN/CTX/DISAGG_SERVER 直接返回
    
    # 解析性能结果（存储在内存中）
    config.get_perf_result(outputs)
    
    # 检查测试失败
    config.check_test_failure()
    
    # ❌ 直接上传到 OpenSearch，没有生成 CSV
    config.upload_test_results_to_database()
```

**问题：**
- ✅ 性能数据在内存中（`config._perf_results`）
- ❌ 没有导出为 CSV 文件
- ❌ `trt_perf_parser.py` 需要 CSV 输入

---

## ✅ 解决方案：三种集成方式

### 方案 1: 修改 test_perf_sanity.py 导出 CSV（推荐）⭐

**优点：**
- ✅ 一次运行，两个数据库都更新
- ✅ 数据一致性最好
- ✅ 自动化程度高

**缺点：**
- ❌ 需要修改 test_perf_sanity.py
- ❌ 需要理解代码结构

#### 实施步骤

**步骤 1: 在 test_perf_sanity.py 添加 CSV 导出功能**

在 `PerfSanityTestConfig` 类中添加方法（建议在 1520 行之后）：

```python
# tests/integration/defs/perf/test_perf_sanity.py

def export_results_to_csv(self, csv_path: str):
    """Export performance results to CSV for trt_perf_parser.py"""
    import csv
    
    if not self._perf_results:
        print_info("No performance results to export")
        return
    
    csv_rows = []
    
    if self.runtime == "multi_node_disagg_server":
        # Only BENCHMARK node exports
        if self.server_configs[0][2].disagg_serving_type != "BENCHMARK":
            return
        
        for server_idx, (ctx_config, gen_config, disagg_config) in enumerate(self.server_configs):
            client_configs = self.server_client_configs[server_idx]
            server_perf_results = self._perf_results.get(server_idx, [])
            
            for client_idx, client_config in enumerate(client_configs):
                if client_idx >= len(server_perf_results) or server_perf_results[client_idx] is None:
                    continue
                
                perf_data = server_perf_results[client_idx]
                
                # Build CSV row
                row = {
                    'network': disagg_config.name,
                    'batchsize': client_config.concurrency,
                    'precision': gen_config.dtype,
                    'framework': 'TensorRT-LLM',
                    'command': f"disagg_{ctx_config.name}_{gen_config.name}",
                }
                
                # Add performance metrics
                for metric_name, metric_value in perf_data.items():
                    # Convert metric names to trt_perf_parser format
                    # e.g., "mean_ttft" -> "mean_ttft__ms"
                    if metric_name in ['mean_ttft', 'median_ttft', 'p99_ttft']:
                        row[f'{metric_name}__ms'] = metric_value
                    elif metric_name in ['mean_e2el', 'median_e2el', 'p99_e2el']:
                        row[f'{metric_name}__ms'] = metric_value
                    elif metric_name == 'token_throughput':
                        row['throughput__qps'] = metric_value
                    elif metric_name == 'seq_throughput':
                        row['tokens_per__sec'] = metric_value
                    else:
                        row[metric_name] = metric_value
                
                csv_rows.append(row)
    
    elif self.runtime == "aggr_server":
        # Aggregated server export logic
        for server_idx, client_configs in self.server_client_configs.items():
            server_config = self.server_configs[server_idx]
            server_perf_results = self._perf_results.get(server_idx, [])
            
            for client_idx, client_config in enumerate(client_configs):
                if client_idx >= len(server_perf_results) or server_perf_results[client_idx] is None:
                    continue
                
                perf_data = server_perf_results[client_idx]
                row = {
                    'network': server_config.name,
                    'batchsize': client_config.concurrency,
                    'precision': server_config.dtype,
                    'framework': 'TensorRT-LLM',
                    'command': f"aggr_{server_config.name}_{client_config.name}",
                }
                
                for metric_name, metric_value in perf_data.items():
                    if metric_name in ['mean_ttft', 'median_ttft', 'p99_ttft']:
                        row[f'{metric_name}__ms'] = metric_value
                    elif metric_name in ['mean_e2el', 'median_e2el', 'p99_e2el']:
                        row[f'{metric_name}__ms'] = metric_value
                    elif metric_name == 'token_throughput':
                        row['throughput__qps'] = metric_value
                    elif metric_name == 'seq_throughput':
                        row['tokens_per__sec'] = metric_value
                    else:
                        row[metric_name] = metric_value
                
                csv_rows.append(row)
    
    # Write to CSV
    if csv_rows:
        fieldnames = list(csv_rows[0].keys())
        with open(csv_path, 'w', newline='') as csvfile:
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(csv_rows)
        print_info(f"Exported {len(csv_rows)} results to {csv_path}")
    else:
        print_info("No results to export")
```

**步骤 2: 在 test_e2e() 中调用导出**

修改 `test_e2e()` 函数（1491-1520 行）：

```python
def test_e2e(output_dir, perf_sanity_test_case):
    # ... 现有代码 ...
    
    # Parse performance results
    config.get_perf_result(outputs)
    
    # Check for test failures
    config.check_test_failure()
    
    # ✅ 新增：导出 CSV 供 trt_perf_parser.py 使用
    csv_output_path = os.path.join(
        config.perf_sanity_output_dir,
        "perf_script_test_results.csv"
    )
    config.export_results_to_csv(csv_output_path)
    
    # Upload results to database (OpenSearch)
    config.upload_test_results_to_database()
```

**步骤 3: 在 slurm_run.sh 中调用 trt_perf_parser.py**

在 `slurm_run.sh` 的性能报告部分之后添加（约 154 行之后）：

```bash
# 在 slurm_run.sh 中添加（154 行之后）
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ] && [ "$USE_TRT_PERF_DB" = "true" ]; then
    echo "Uploading to TRT_perf database..."
    
    # 检查 CSV 文件是否存在
    CSV_FILE="$stageName/perf_script_test_results.csv"
    if [ ! -f "$CSV_FILE" ]; then
        echo "Warning: CSV file not found: $CSV_FILE"
    else
        # 获取系统信息
        DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
        CUDA_VERSION=$(nvcc --version | grep "release" | awk '{print $5}' | sed 's/,//')
        
        # 调用 trt_perf_parser.py
        python3 "$llmSrcNode/../jenkins_test/trt_perf_parser.py" \
            --source-metric-csv "$CSV_FILE" \
            --tensorrt "${TRT_VERSION:-unknown}" \
            --trtllm "${TRTLLM_VERSION:-unknown}" \
            --driver "$DRIVER_VERSION" \
            --gpu "$GPU_NAME" \
            --cuda "$CUDA_VERSION" \
            --os "$(cat /etc/os-release | grep PRETTY_NAME | cut -d '=' -f2 | tr -d '\"')" \
            --start-time "${TEST_START_TIME:-$(date '+%Y-%m-%d %H:%M:%S')}" \
            --end-time "$(date '+%Y-%m-%d %H:%M:%S')" \
            --commit "${GIT_COMMIT:-unknown}" \
            --link "${BUILD_URL:-}" \
            --notes "Disagg test: $stageName" \
            --write-db yes \
            --verbose
    fi
fi
```

---

### 方案 2: 后处理脚本（无需修改 test_perf_sanity.py）

**优点：**
- ✅ 不修改现有代码
- ✅ 灵活控制

**缺点：**
- ❌ 需要从 results.xml 或日志中提取性能数据
- ❌ 数据解析复杂

#### 实施步骤

**步骤 1: 创建性能数据提取脚本**

`jenkins_test/scripts/extract_perf_from_junit.py`:

```python
#!/usr/bin/env python3
"""Extract performance data from JUnit XML and generate CSV for trt_perf_parser.py"""

import xml.etree.ElementTree as ET
import csv
import re
import argparse
import sys

# Performance metric patterns (from test_perf_sanity.py)
PERF_METRIC_PATTERNS = {
    "seq_throughput": re.compile(r"Request throughput \(req\/s\):\s+(-?[\d\.]+)"),
    "token_throughput": re.compile(r"Output token throughput \(tok\/s\):\s+(-?[\d\.]+)"),
    "total_token_throughput": re.compile(r"Total Token throughput \(tok\/s\):\s+(-?[\d\.]+)"),
    "mean_ttft": re.compile(r"Mean TTFT \(ms\):\s+(-?[\d\.]+)"),
    "median_ttft": re.compile(r"Median TTFT \(ms\):\s+(-?[\d\.]+)"),
    "p99_ttft": re.compile(r"P99 TTFT \(ms\):\s+(-?[\d\.]+)"),
    "mean_e2el": re.compile(r"Mean E2EL \(ms\):\s+(-?[\d\.]+)"),
    "median_e2el": re.compile(r"Median E2EL \(ms\):\s+(-?[\d\.]+)"),
    "p99_e2el": re.compile(r"P99 E2EL \(ms\):\s+(-?[\d\.]+)"),
}

def extract_perf_from_junit(junit_xml_path):
    """Extract performance metrics from JUnit XML file"""
    tree = ET.parse(junit_xml_path)
    root = tree.getroot()
    
    results = []
    
    for testcase in root.findall('.//testcase'):
        test_name = testcase.get('name', '')
        
        # Find system-out or system-err with performance data
        output = ""
        for elem in testcase.findall('.//system-out'):
            output += elem.text or ""
        for elem in testcase.findall('.//system-err'):
            output += elem.text or ""
        
        if not output:
            continue
        
        # Extract test case info from name
        # Format: test_e2e[disagg_upload-deepseek-r1-fp4_...]
        match = re.search(r'\[disagg_upload-(.+)\]', test_name)
        if not match:
            continue
        
        config_name = match.group(1)
        
        # Extract metrics from output
        metrics = {'network': config_name, 'framework': 'TensorRT-LLM'}
        
        for metric_name, pattern in PERF_METRIC_PATTERNS.items():
            match = pattern.search(output)
            if match:
                value = match.group(1)
                # Convert metric names to CSV format
                if metric_name in ['mean_ttft', 'median_ttft', 'p99_ttft']:
                    metrics[f'{metric_name}__ms'] = value
                elif metric_name in ['mean_e2el', 'median_e2el', 'p99_e2el']:
                    metrics[f'{metric_name}__ms'] = value
                elif metric_name == 'token_throughput':
                    metrics['throughput__qps'] = value
                elif metric_name == 'seq_throughput':
                    metrics['tokens_per__sec'] = value
                else:
                    metrics[metric_name] = value
        
        if len(metrics) > 2:  # Has more than just network and framework
            results.append(metrics)
    
    return results

def write_csv(results, output_csv):
    """Write results to CSV file"""
    if not results:
        print("No results to write")
        return
    
    fieldnames = list(results[0].keys())
    with open(output_csv, 'w', newline='') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)
    
    print(f"Wrote {len(results)} results to {output_csv}")

def main():
    parser = argparse.ArgumentParser(description="Extract perf data from JUnit XML to CSV")
    parser.add_argument("--junit-xml", required=True, help="JUnit XML file path")
    parser.add_argument("--output-csv", required=True, help="Output CSV file path")
    
    args = parser.parse_args()
    
    results = extract_perf_from_junit(args.junit_xml)
    write_csv(results, args.output_csv)

if __name__ == "__main__":
    main()
```

**步骤 2: 在 slurm_run.sh 或 Jenkins 中调用**

```bash
# 在测试完成后
python3 $llmSrcNode/../jenkins_test/scripts/extract_perf_from_junit.py \
    --junit-xml "$jobWorkspace/results.xml" \
    --output-csv "$jobWorkspace/perf_script_test_results.csv"

# 然后调用 trt_perf_parser.py
python3 $llmSrcNode/../jenkins_test/trt_perf_parser.py \
    --source-metric-csv "$jobWorkspace/perf_script_test_results.csv" \
    --tensorrt "..." \
    --trtllm "..." \
    # ... 其他参数
```

---

### 方案 3: Jenkins Pipeline 后处理（最灵活）

**优点：**
- ✅ 完全不修改测试代码
- ✅ 可以批量处理多个测试
- ✅ 易于调试和维护

**缺点：**
- ❌ 需要在 Jenkins 中配置
- ❌ 与测试执行分离

#### 实施步骤

在 `Perf_Test.groovy` 中添加：

```groovy
stage('Upload to TRT_perf DB') {
    when {
        expression { params.UPLOAD_TO_TRTPERF == true }
    }
    steps {
        script {
            // 提取性能数据
            sh """
                python3 jenkins_test/scripts/extract_perf_from_junit.py \\
                    --junit-xml ${WORKSPACE}/disagg_workspace/results.xml \\
                    --output-csv ${WORKSPACE}/perf_results.csv
            """
            
            // 获取系统信息
            def driverVersion = sh(returnStdout: true, script: 'nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1').trim()
            def gpuName = sh(returnStdout: true, script: 'nvidia-smi --query-gpu=name --format=csv,noheader | head -1').trim()
            def cudaVersion = sh(returnStdout: true, script: 'nvcc --version | grep "release" | awk \'{print \$5}\' | sed \'s/,//\'').trim()
            def trtllmVersion = sh(returnStdout: true, script: 'cd TensorRT-LLM && git describe --tags').trim()
            
            // 上传到 TRT_perf 数据库
            sh """
                python3 jenkins_test/trt_perf_parser.py \\
                    --source-metric-csv ${WORKSPACE}/perf_results.csv \\
                    --tensorrt "${TRT_VERSION}" \\
                    --trtllm "${trtllmVersion}" \\
                    --driver "${driverVersion}" \\
                    --gpu "${gpuName}" \\
                    --cuda "${cudaVersion}" \\
                    --os "${OS_VERSION}" \\
                    --start-time "${TEST_START_TIME}" \\
                    --end-time "\$(date '+%Y-%m-%d %H:%M:%S')" \\
                    --commit "${GIT_COMMIT}" \\
                    --link "${BUILD_URL}" \\
                    --notes "Disagg perf test - ${CONFIG_NAME}" \\
                    --write-db yes \\
                    --verbose
            """
        }
    }
}
```

---

## 📊 方案对比总结

| 方案 | 代码修改 | 数据质量 | 自动化 | 灵活性 | 推荐度 |
|------|----------|---------|--------|--------|--------|
| **方案 1: 修改 test_perf_sanity.py** | 中等（一次性） | ⭐⭐⭐ 最好 | ⭐⭐⭐ 自动 | ⭐⭐ 中等 | ⭐⭐⭐ 推荐 |
| **方案 2: 后处理脚本** | 小（新增脚本） | ⭐⭐ 好 | ⭐⭐ 半自动 | ⭐⭐⭐ 高 | ⭐⭐ 可用 |
| **方案 3: Jenkins Pipeline** | 无（仅 Groovy） | ⭐⭐ 好 | ⭐ 手动触发 | ⭐⭐⭐ 最高 | ⭐⭐ 灵活 |

---

## 🔧 完整集成示例（推荐方案 1）

### 步骤 1: 修改 test_perf_sanity.py

添加 `export_results_to_csv()` 方法（见上文"方案 1"）

### 步骤 2: 修改 slurm_run.sh

在 154 行之后添加：

```bash
# 上传到 TRT_perf 数据库（可选）
if [ $SLURM_PROCID -eq 0 ] && [ "$perfMode" = "true" ] && [ "${USE_TRT_PERF_DB:-false}" = "true" ]; then
    echo "Uploading to TRT_perf database..."
    
    CSV_FILE="$stageName/perf_script_test_results.csv"
    if [ -f "$CSV_FILE" ]; then
        # 获取系统信息
        DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
        CUDA_VERSION=$(nvcc --version | grep "release" | awk '{print $5}' | sed 's/,//')
        OS_INFO=$(cat /etc/os-release | grep PRETTY_NAME | cut -d '=' -f2 | tr -d '"')
        TRTLLM_VERSION=$(cd $llmSrcNode && git describe --tags 2>/dev/null || echo "unknown")
        
        # 调用 trt_perf_parser.py
        python3 "$llmSrcNode/../jenkins_test/trt_perf_parser.py" \
            --source-metric-csv "$CSV_FILE" \
            --tensorrt "${TRT_VERSION:-unknown}" \
            --trtllm "$TRTLLM_VERSION" \
            --driver "$DRIVER_VERSION" \
            --gpu "$GPU_NAME" \
            --cuda "$CUDA_VERSION" \
            --os "$OS_INFO" \
            --start-time "${TEST_START_TIME:-$(date '+%Y-%m-%d %H:%M:%S')}" \
            --end-time "$(date '+%Y-%m-%d %H:%M:%S')" \
            --commit "${GIT_COMMIT:-unknown}" \
            --link "${BUILD_URL:-}" \
            --hostname "$(hostname)" \
            --notes "Disagg test: $stageName, Config: ${CONFIG_NAME:-unknown}" \
            --write-db yes \
            --verbose || echo "Warning: Failed to upload to TRT_perf DB"
    else
        echo "Warning: CSV file not found: $CSV_FILE, skipping TRT_perf upload"
    fi
fi
```

### 步骤 3: 修改 run_disagg_test.sh

在步骤 4.2 的 `slurm_launch_prefix.sh` 中添加环境变量：

```bash
# 在 slurm_launch_prefix.sh 中添加
export USE_TRT_PERF_DB=${USE_TRT_PERF_DB:-false}  # 控制是否上传到 TRT_perf
export TEST_START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
export GIT_COMMIT=$(cd $TRTLLM_DIR && git rev-parse HEAD)
export CONFIG_NAME="${CONFIG_NAME}"
```

### 步骤 4: 使用方式

```bash
# 不上传到 TRT_perf（默认，只上传到 OpenSearch）
bash jenkins_test/scripts/run_disagg_test.sh deepseek-r1-fp4_...

# 同时上传到 TRT_perf 和 OpenSearch
export USE_TRT_PERF_DB=true
bash jenkins_test/scripts/run_disagg_test.sh deepseek-r1-fp4_...
```

---

## 📝 集群内所需前置条件

### 1. Python 依赖

```bash
pip install pymysql pandas
```

### 2. 数据库访问权限

```bash
# 测试数据库连接
python3 -c "
import pymysql
db = pymysql.connect(
    host='dlswqa-nas.nvidia.com',
    port=13306,
    user='swqa',
    password='labuser',
    database='TRT_perf'
)
print('Database connection successful!')
db.close()
"
```

如果连接失败：
- 检查防火墙规则
- 检查网络连通性：`ping dlswqa-nas.nvidia.com`
- 检查端口开放：`telnet dlswqa-nas.nvidia.com 13306`
- 联系 DLS QA 团队获取访问权限

### 3. 环境变量（在 Jenkins 或 slurm_launch_prefix.sh 中设置）

```bash
# 必需
export TRT_VERSION="10.0.0"          # TensorRT 版本
export TRTLLM_VERSION="0.14.0"       # TensorRT-LLM 版本（或从 git describe 获取）
export GIT_COMMIT="abc123..."        # Git commit hash
export BUILD_URL="http://jenkins..." # Jenkins 作业链接

# 可选（会自动检测）
export DRIVER_VERSION="550.54.15"
export GPU_NAME="NVIDIA H200"
export CUDA_VERSION="12.4"
export OS_VERSION="Ubuntu 22.04"
```

---

## 🎯 验证和测试

### 测试 trt_perf_parser.py

```bash
# 创建测试 CSV
cat > /tmp/test_perf.csv << 'EOF'
network,batchsize,precision,framework,throughput__qps,mean_ttft__ms,mean_e2el__ms
deepseek-r1-fp4,768,fp4,TensorRT-LLM,1234.56,15.2,123.4
EOF

# 运行 trt_perf_parser.py（dry-run）
python3 jenkins_test/trt_perf_parser.py \
    --source-metric-csv /tmp/test_perf.csv \
    --tensorrt "10.0.0" \
    --trtllm "0.14.0" \
    --driver "550.54.15" \
    --gpu "H200" \
    --cuda "12.4" \
    --os "Ubuntu 22.04" \
    --start-time "2025-02-02 10:00:00" \
    --end-time "2025-02-02 11:00:00" \
    --commit "abc123" \
    --notes "Test run" \
    --write-db no \
    --verbose

# 检查输出
# 应该看到解析的数据和 SQL 语句
```

### 完整集成测试

```bash
# 1. 运行 disagg 测试（带 CSV 导出）
export USE_TRT_PERF_DB=true
bash jenkins_test/scripts/run_disagg_test.sh deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX

# 2. 检查 CSV 是否生成
ls -lh $WORKSPACE/disagg_logs/deepseek-r1-fp4_*/perf_script_test_results.csv

# 3. 检查 TRTPerf 网页
# 在 slurm_run.sh 的输出中会打印类似链接：
# http://dlswqa.nvidia.com/trtperf?req=get_html&run_ids=12345&...

# 4. 验证数据库中的数据
python3 -c "
import pymysql
db = pymysql.connect(host='dlswqa-nas.nvidia.com', port=13306, user='swqa', password='labuser', database='TRT_perf')
cursor = db.cursor()
cursor.execute('SELECT id, trtllm, notes FROM runs ORDER BY id DESC LIMIT 5')
for row in cursor.fetchall():
    print(row)
db.close()
"
```

---

## 📚 相关文档

1. **trt_perf_parser.py 源码**: `jenkins_test/trt_perf_parser.py`
2. **test_perf_sanity.py 源码**: `tests/integration/defs/perf/test_perf_sanity.py`
3. **TRTPerf 网页**: http://dlswqa.nvidia.com/trtperf
4. **数据库 schema**: 见 `trt_perf_parser.py` 开头的注释（20-74 行）

---

## 🔍 常见问题

### Q1: 为什么需要两个数据库（OpenSearch 和 TRT_perf）？

**A:** 
- **OpenSearch**: 新系统，功能丰富，自动回归检测
- **TRT_perf**: 历史系统，已有大量历史数据，用于长期追踪

两者可以并存，不冲突。

### Q2: CSV 文件格式要求？

**A:** 必须包含以下字段：
- `network`: 测试模型名称
- `framework`: 框架名称（通常是 "TensorRT-LLM"）
- 至少一个性能指标，例如：
  - `throughput__qps`: 吞吐量（QPS）
  - `mean_ttft__ms`: 平均首 token 时间
  - `mean_e2el__ms`: 平均端到端延迟

### Q3: 如何查看上传的数据？

**A:** 通过 TRTPerf 网页：
```
http://dlswqa.nvidia.com/trtperf?req=get_html&run_ids=<你的run_id>
```

`run_id` 会在 `trt_perf_parser.py` 的输出中打印。

### Q4: 数据库连接失败怎么办？

**A:** 
1. 检查是否在 NVIDIA 内网
2. 测试连接：`telnet dlswqa-nas.nvidia.com 13306`
3. 联系 DLS QA 团队申请访问权限

### Q5: 如何批量上传多个测试的结果？

**A:** 有两种方式：
1. 每个测试生成独立的 CSV，分别调用 `trt_perf_parser.py`
2. 合并多个 CSV 文件，一次性上传（需要确保字段一致）

---

## ✅ 实施建议

### 最小化实施（快速验证）

1. ✅ 使用**方案 2**（后处理脚本）
2. ✅ 只在 Jenkins Pipeline 最后添加一个 stage
3. ✅ 先手动运行验证，再自动化

### 完整实施（生产环境）

1. ✅ 使用**方案 1**（修改 test_perf_sanity.py）
2. ✅ 在 `slurm_run.sh` 中集成
3. ✅ 添加 `USE_TRT_PERF_DB` 环境变量控制
4. ✅ 添加错误处理和日志

---

**现在你可以根据需求选择合适的方案开始实施！需要我帮你实际修改代码吗？** 🚀
