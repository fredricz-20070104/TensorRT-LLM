# 🎉 自动识别测试类型功能 - 改进完成

## 问题

之前的实现要求用户在 `debug_cases.txt` 中手动添加 `# mode:multi-agg` 或 `# mode:disagg` 标记，这很**傻叉**！

```txt
# ❌ 之前需要这样（太蠢了）
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]  # mode:multi-agg
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]  # mode:disagg
```

## 解决方案

现在 `parse_unified_testlist.py` 会**自动读取配置文件**并智能推断测试类型！

```txt
# ✅ 现在只需要直接粘贴（完美！）
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_tp4]      # 自动识别为 multi-agg
test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]   # 自动识别为 disagg
```

## 实现细节

### 1. 多层识别机制

```python
def infer_test_mode_from_config(test_id):
    # 优先级 1: 命名规则快速识别（disagg）
    if '_disagg' in test_id or 'disagg' in test_id:
        return 'disagg'
    
    # 优先级 2: 读取配置文件分析
    config = load_yaml_config(f"{config_yml}.yaml", AGGR_CONFIG_DIR)
    
    # 计算总 GPU 数 = TP * EP * PP * CP
    total_gpus = tp * max(ep, 1) * pp * cp
    
    # 如果总 GPU 数 > gpus_per_node，说明需要多节点
    if total_gpus > gpus_per_node:
        return 'multi-agg'
    
    # 优先级 3: 命名规则推断（multi-agg）
    if '_2_nodes' in config_yml or 'multi_node' in config_yml:
        return 'multi-agg'
    
    # 默认 single-agg
    return 'single-agg'
```

### 2. 识别示例

| Test ID | 识别方法 | 结果 |
|---------|---------|------|
| `profiling-deepseek_r1_fp4_v2_blackwell` | 配置文件: TP=4, gpus_per_node=4 | single-agg |
| `benchmark-deepseek_r1_fp4_v2_2_nodes_grace_blackwell` | 配置文件: TP=8, gpus_per_node=4 | multi-agg ✅ |
| `benchmark-llama3_70b_disagg` | 命名规则: 包含 `_disagg` | disagg ✅ |
| `profiling-llama3_405b_2_nodes` | 命名规则: 包含 `_2_nodes` | multi-agg ✅ |

## 测试结果

```bash
$ cd jenkins_test/scripts && python3 test_auto_inference.py

================================================================================
测试自动推断功能
================================================================================

✅ PASS | DeepSeek R1 FP4 V2 单节点
✅ PASS | 指定 server config
✅ PASS | DeepSeek R1 2 节点（配置文件）
✅ PASS | K2 Thinking 2 节点（配置文件）
✅ PASS | 命名包含 2_nodes
✅ PASS | 包含 _disagg 后缀
✅ PASS | 包含 disagg
✅ PASS | disagg 类型前缀

================================================================================
测试结果: 8 通过, 0 失败
================================================================================
```

## 用户体验提升

### Before（改进前）

```bash
# 1. 从 CI 日志复制失败的测试
FAILED test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_2_nodes_grace_blackwell]

# 2. 打开配置文件查看是否多节点 😤
$ cat tests/scripts/perf-sanity/deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yaml
# ... 分析 TP, EP, PP, gpus_per_node ...

# 3. 手动添加标记 😤
test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_2_nodes_grace_blackwell]  # mode:multi-agg
```

### After（改进后）

```bash
# 1. 从 CI 日志复制失败的测试
FAILED test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_2_nodes_grace_blackwell]

# 2. 直接粘贴到 debug_cases.txt 😎
test_perf_sanity.py::test_e2e[benchmark-deepseek_r1_fp4_v2_2_nodes_grace_blackwell]

# 3. 运行！自动识别为 multi-agg 😎
```

## 文件变更

### 修改的文件
1. ✅ `jenkins_test/scripts/parse_unified_testlist.py` - 添加自动识别逻辑
2. ✅ `jenkins_test/testlists/debug_cases.txt` - 更新文档说明
3. ✅ `jenkins_test/docs/TESTLIST_FORMAT_GUIDE.md` - 更新格式说明

### 新增的文件
1. ✅ `jenkins_test/scripts/test_auto_inference.py` - 测试脚本
2. ✅ `jenkins_test/docs/AUTO_INFERENCE.md` - 详细说明文档

## 兼容性

- ✅ **完全向后兼容**：手动标记 `# mode:xxx` 仍然有效，优先级最高
- ✅ **YAML 格式不受影响**：继续使用现有的 `nodes` 字段识别
- ✅ **性能开销小**：只在需要时读取配置文件

## 手动覆盖（可选）

如果自动识别不准确，仍然可以手动标记覆盖：

```txt
# 自动识别可能不准确的特殊情况
test_perf_sanity.py::test_e2e[custom_special_case]  # mode:multi-agg
```

## 总结

不再需要手动添加傻叉的 `# mode:xxx` 标记了！🎉

从 CI 日志直接复制粘贴测试用例到 `debug_cases.txt`，系统会自动识别测试类型并路由到正确的执行脚本。

---

**日期**: 2026-02-01  
**改进**: 自动识别测试类型，无需手动标记  
**状态**: ✅ 完成并测试通过
