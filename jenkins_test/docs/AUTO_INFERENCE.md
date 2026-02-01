# 🎯 自动识别测试类型 - 功能说明

## 概述

新版本的 `parse_unified_testlist.py` 现在可以**自动识别**测试类型（single-agg, multi-agg, disagg），无需手动添加 `# mode:xxx` 标记！

## 改进前 vs 改进后

### ❌ 改进前（需要手动标记）

```txt
# 需要手动标记每个 multi-agg 和 disagg 测试
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]  # mode:multi-agg  ← 傻叉！
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]  # mode:disagg   ← 傻叉！
```

### ✅ 改进后（自动识别）

```txt
# 直接粘贴，自动识别类型
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]      # ← 自动识别为 multi-agg
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]   # ← 自动识别为 disagg
```

## 工作原理

### 1. 配置文件分析（优先级最高）

读取 `tests/scripts/perf-sanity/{config_yml}.yaml`，分析：

- **Multi-Agg 识别**：
  ```yaml
  # 如果 gpus > gpus_per_node，说明是多节点
  server_configs:
    - name: "llama3_70b_tp4"
      gpus: 8               # 总 GPU 数
      gpus_per_node: 4      # 每节点 GPU 数
      # → 8 > 4，自动识别为 multi-agg
  ```

- **Disagg 识别**：
  ```yaml
  # 检查 disagg 相关字段
  server_configs:
    - disagg_run_type: "ctx"  # 或 "gen"
      # → 自动识别为 disagg
  
  hardware:
    num_ctx_servers: 1
    num_gen_servers: 3
    # → 自动识别为 disagg
  ```

### 2. 命名规则推断（回退机制）

如果配置文件不存在或无法判断，使用命名规则：

```python
# Disagg 识别
if '_disagg' in test_id or 'disagg' in test_id:
    return 'disagg'

if 'ctx' in test_id and 'gen' in test_id:
    return 'disagg'

# Multi-Agg 识别
if any(pattern in test_id for pattern in [
    '_2_nodes', '_3_nodes', '_4_nodes',
    'multi_node', 'multinode'
]):
    return 'multi-agg'
```

### 3. 手动标记覆盖（可选）

如果自动识别不准确，仍然可以手动标记：

```txt
test_perf_sanity.py::test_e2e[custom_case]  # mode:multi-agg
```

## 使用示例

### 示例 1：从 CI 日志复制失败测试

```bash
# CI 日志显示：
FAILED test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_blackwell]

# 直接粘贴到 debug_cases.txt：
test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_blackwell]

# ✅ 自动识别：读取配置文件 → single-agg（因为 gpus == gpus_per_node）
```

### 示例 2：Multi-Agg 测试

```bash
# 粘贴到 debug_cases.txt：
test_perf_sanity.py::test_e2e[benchmark-llama3_405b_tp8]

# ✅ 自动识别：读取配置文件
# - gpus: 16
# - gpus_per_node: 8
# - 16 > 8 → multi-agg
```

### 示例 3：Disagg 测试

```bash
# 粘贴到 debug_cases.txt：
test_perf_sanity.py::test_e2e[disagg-deepseek-r1-fp4_8k1k_ctx1_gen3]

# ✅ 自动识别：
# - 方法 1：test_id 包含 'disagg' → disagg
# - 方法 2：配置文件路径在 disagg 目录 → disagg
# - 方法 3：test_id 同时包含 'ctx' 和 'gen' → disagg
```

## 测试自动识别

运行测试脚本验证功能：

```bash
cd jenkins_test/scripts
python3 test_auto_inference.py
```

预期输出：

```
================================================================================
测试自动推断功能
================================================================================

✅ PASS | DeepSeek R1 FP4 V2 单节点
      Test ID: profiling-deepseek_r1_fp4_v2_blackwell
      Expected: single-agg, Actual: single-agg

✅ PASS | Llama3.1 70B TP4 多节点
      Test ID: benchmark-llama3_70b_tp4
      Expected: multi-agg, Actual: multi-agg

✅ PASS | 包含 _disagg 后缀
      Test ID: benchmark-llama3_70b_disagg
      Expected: disagg, Actual: disagg

================================================================================
测试结果: 8 通过, 0 失败
================================================================================
```

## 兼容性

- ✅ **完全向后兼容**：手动标记仍然有效
- ✅ **YAML 格式不受影响**：继续使用现有逻辑
- ✅ **性能开销最小**：配置文件缓存（TODO）

## 优势

1. **用户体验提升**：从 CI 日志直接复制粘贴，无需手动分析
2. **减少错误**：不会因为忘记标记或标记错误导致测试路由错误
3. **维护简单**：不需要维护额外的标记规则文档
4. **灵活性**：支持手动覆盖，应对特殊情况

## 未来优化（可选）

- [ ] 配置文件缓存机制，避免重复读取
- [ ] 支持更多命名规则
- [ ] 提供详细的识别日志（debug 模式）
- [ ] 配置文件不存在时的警告提示

---

**最后更新**: 2026-02-01  
**作者**: TensorRT-LLM Performance Team
