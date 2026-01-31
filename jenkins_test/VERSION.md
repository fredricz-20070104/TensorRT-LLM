# 版本信息

## 当前版本
**v1.0.0** (2026-01-30)

## 版本历史

### v1.0.0 (2026-01-30)
**首次发布**

#### 核心功能
- ✅ Jenkins Pipeline (Perf_Test.groovy)
- ✅ 节点计算工具 (calculate_hardware_nodes.py)
- ✅ 自动拉取 TensorRT-LLM 依赖
- ✅ TestList 支持
- ✅ 节点数验证
- ✅ Dry Run 模式

#### 文档
- ✅ README.md - 主文档
- ✅ DEPLOYMENT.md - 部署指南
- ✅ ARCHITECTURE_FINAL.md - 架构详解
- ✅ SOLUTION_SUMMARY.md - 解决方案总结
- ✅ README_PERF_TESTS.md - 使用指南
- ✅ QUICK_REFERENCE.md - 快速参考
- ✅ TESTLIST_EXPLANATION.md - TestList 说明

#### 工具脚本
- ✅ deploy.sh - 快速部署脚本

## 兼容性

### TensorRT-LLM 版本
- **推荐**: main 分支
- **兼容**: 所有包含 `jenkins/scripts/perf/disaggregated/submit.py` 的分支

### Jenkins 版本
- **最低要求**: Jenkins 2.300+
- **推荐**: Jenkins 2.400+

### Python 版本
- **最低要求**: Python 3.6+
- **推荐**: Python 3.8+

### 依赖包
- PyYAML >= 5.1

## 升级说明

### 从初始版本升级
这是初始版本，无需升级步骤。

## 路线图

### v1.1.0 (计划中)
- [ ] 支持多个 TestList 批量运行
- [ ] 增加测试结果收集
- [ ] 添加性能指标对比
- [ ] 支持自定义 submit.py 参数

### v1.2.0 (计划中)
- [ ] 增加 WebUI 界面
- [ ] 支持测试结果可视化
- [ ] 添加自动化报告生成

## 已知问题

### 当前版本无已知严重问题

如发现问题，请联系维护团队。

## 贡献指南

### 报告问题
请提供以下信息：
- 版本号
- 错误信息
- 重现步骤
- Jenkins Console Output

### 提交改进
欢迎提交 Merge Request！

## 维护团队
TensorRT-LLM 性能测试团队

## 许可证
与 TensorRT-LLM 主仓库保持一致
