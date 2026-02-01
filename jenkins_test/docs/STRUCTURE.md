# 目录结构

```
jenkins_test/
├── README.md                          # 主文档 - 从这里开始
├── DEPLOYMENT.md                      # 部署指南 - 如何部署到 GitLab
├── VERSION.md                         # 版本信息和更新日志
├── .gitignore                         # Git 忽略规则
│
├── Perf_Test.groovy                   # ⭐ Jenkins Pipeline 主文件
│
├── scripts/                           # 工具脚本目录
│   ├── calculate_hardware_nodes.py    # ⭐ 节点计算工具
│   └── deploy.sh                      # 快速部署脚本
│
└── docs/                              # 文档目录
    ├── ARCHITECTURE_FINAL.md          # 架构详解 - 深入理解节点计算
    ├── SOLUTION_SUMMARY.md            # 解决方案总结 - 核心代码和逻辑
    ├── README_PERF_TESTS.md           # 性能测试使用指南
    ├── QUICK_REFERENCE.md             # 快速参考手册
    └── TESTLIST_EXPLANATION.md        # TestList 机制详解
```

## 📖 文档阅读顺序

### 1️⃣ 快速上手（5分钟）
```
README.md → DEPLOYMENT.md
```

### 2️⃣ 深入理解（30分钟）
```
docs/ARCHITECTURE_FINAL.md → docs/SOLUTION_SUMMARY.md
```

### 3️⃣ 详细使用（按需查阅）
```
docs/README_PERF_TESTS.md
docs/QUICK_REFERENCE.md
docs/TESTLIST_EXPLANATION.md
```

## 🔧 核心文件说明

### Perf_Test.groovy
**作用**: Jenkins Pipeline 主文件  
**功能**:
- 接收用户参数（TestList, Config, Nodes）
- 自动拉取 TensorRT-LLM 依赖
- 调用节点计算工具
- 验证节点数匹配
- 提交 Slurm 任务

**使用**: 在 Jenkins 中配置为 Pipeline Script Path

### scripts/calculate_hardware_nodes.py
**作用**: 节点计算工具  
**功能**:
- 从 YAML 配置读取逻辑服务器数
- 计算实际需要的硬件节点数
- 验证节点数是否匹配
- 支持 JSON 输出

**使用**:
```bash
python3 scripts/calculate_hardware_nodes.py --config xxx.yaml
```

### scripts/deploy.sh
**作用**: 快速部署脚本  
**功能**:
- 初始化 Git 仓库
- 创建初始提交
- 推送到 GitLab

**使用**:
```bash
cd jenkins_test
./scripts/deploy.sh https://gitlab.com/your-org/trtllm-perf-test.git
```

## 📚 文档详解

### README.md
主文档，包含：
- 目录结构
- 核心特性
- 快速开始
- 架构原理
- 工具使用
- Pipeline 参数说明

### DEPLOYMENT.md
部署指南，包含：
- 部署步骤
- Jenkins 配置
- 测试流程
- 故障排查
- 安全建议

### docs/ARCHITECTURE_FINAL.md
架构详解，包含：
- 节点计算逻辑
- 调用链条
- 示例配置
- 详细公式

### docs/SOLUTION_SUMMARY.md
解决方案总结，包含：
- 核心代码
- 计算示例
- 优势分析

### docs/README_PERF_TESTS.md
性能测试使用指南（原有文档）

### docs/QUICK_REFERENCE.md
快速参考手册（原有文档）

### docs/TESTLIST_EXPLANATION.md
TestList 机制详解（原有文档）

## 🔗 依赖关系

### 内部依赖
```
Perf_Test.groovy
    ↓ 调用
scripts/calculate_hardware_nodes.py
```

### 外部依赖（自动拉取）
```
Perf_Test.groovy
    ↓ 拉取
TensorRT-LLM/
    ├── tests/integration/test_lists/      # TestList 定义
    ├── tests/integration/defs/perf/       # 测试配置
    └── jenkins/scripts/perf/disaggregated/submit.py  # L0 submit
```

## 📦 完整性检查

运行以下命令检查所有文件是否存在：

```bash
cd jenkins_test

# 检查核心文件
test -f Perf_Test.groovy && echo "✓ Perf_Test.groovy"
test -f scripts/calculate_hardware_nodes.py && echo "✓ calculate_hardware_nodes.py"
test -f scripts/deploy.sh && echo "✓ deploy.sh"

# 检查文档
test -f README.md && echo "✓ README.md"
test -f DEPLOYMENT.md && echo "✓ DEPLOYMENT.md"
test -f VERSION.md && echo "✓ VERSION.md"

# 检查详细文档
test -f docs/ARCHITECTURE_FINAL.md && echo "✓ ARCHITECTURE_FINAL.md"
test -f docs/SOLUTION_SUMMARY.md && echo "✓ SOLUTION_SUMMARY.md"
test -f docs/README_PERF_TESTS.md && echo "✓ README_PERF_TESTS.md"
test -f docs/QUICK_REFERENCE.md && echo "✓ QUICK_REFERENCE.md"
test -f docs/TESTLIST_EXPLANATION.md && echo "✓ TESTLIST_EXPLANATION.md"

echo ""
echo "所有文件检查完成！"
```

## 🎯 与原仓库的关系

### 原 TensorRT-LLM 仓库
```
TensorRT-LLM/
├── jenkins/
│   ├── L0_Test.groovy               # L0 测试（保持不变）
│   ├── scripts/
│   │   └── perf/disaggregated/
│   │       └── submit.py            # L0 submit（继续使用）
│   └── ...
├── tests/
│   └── integration/
│       ├── test_lists/              # TestList 定义
│       └── defs/perf/               # 测试配置
└── ...
```

### 独立仓库（本目录）
```
trtllm-perf-test/      # 新的独立仓库
├── jenkins_test/      # 从这里复制
│   ├── Perf_Test.groovy
│   ├── scripts/
│   └── docs/
└── ...
```

### 关系
- ✅ **完全独立**: 可以单独部署
- ✅ **自动依赖**: 自动拉取 TensorRT-LLM
- ✅ **不影响主仓库**: 不修改 L0_Test.groovy
- ✅ **复用逻辑**: 直接调用 L0 submit.py

## 📝 更新流程

### 更新本仓库
```bash
cd jenkins_test
vim Perf_Test.groovy
git commit -am "Update: xxx"
git push
```

### 更新 TensorRT-LLM 依赖
在 Jenkins 参数中修改 `TRTLLM_BRANCH` 即可，Pipeline 会自动拉取。

## ✅ 部署后验证

部署完成后，运行以下检查：

1. **Git 检查**
   ```bash
   git remote -v  # 应该显示你的 GitLab 仓库
   git log        # 应该有初始提交
   ```

2. **文件检查**
   ```bash
   ls -la         # 查看所有文件
   file scripts/* # 检查脚本权限
   ```

3. **Jenkins 检查**
   - Pipeline 配置正确
   - 参数显示正常
   - Dry Run 通过

## 🚀 准备就绪！

所有文件已准备完毕，可以开始部署了！

按照以下步骤：
1. 阅读 `DEPLOYMENT.md`
2. 运行 `scripts/deploy.sh`
3. 在 Jenkins 中配置 Pipeline
4. 运行 Dry Run 测试
5. 开始使用！
