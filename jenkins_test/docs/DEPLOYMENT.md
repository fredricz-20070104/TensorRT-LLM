# 部署指南 - 独立 GitLab 仓库

## 🎯 目标

将 `jenkins_test/` 目录部署到独立的 GitLab 仓库，用于性能测试。

## 📋 前置条件

- GitLab 账号和权限
- Git 命令行工具
- Jenkins 访问权限

## 🚀 部署步骤

### 步骤 1: 创建 GitLab 仓库

1. 登录 GitLab
2. 创建新仓库（例如：`trtllm-perf-test`）
3. 记录仓库地址：`https://gitlab.com/your-org/trtllm-perf-test.git`

### 步骤 2: 初始化本地仓库

```bash
# 进入 jenkins_test 目录
cd /path/to/TensorRT-LLM/jenkins_test

# 初始化 Git 仓库
git init

# 添加所有文件
git add .

# 提交
git commit -m "Initial commit: TensorRT-LLM 性能测试框架

- Perf_Test.groovy: Jenkins Pipeline
- calculate_hardware_nodes.py: 节点计算工具
- 完整文档和使用指南
"

# 添加远程仓库
git remote add origin https://gitlab.com/your-org/trtllm-perf-test.git

# 推送到 GitLab
git push -u origin main
```

### 步骤 3: 配置 Jenkins Pipeline

#### 3.1 创建新 Jenkins Job

1. 打开 Jenkins
2. 点击 "New Item"
3. 输入名称：`TensorRT-LLM-Perf-Test`
4. 选择 "Pipeline"
5. 点击 "OK"

#### 3.2 配置 Pipeline

在 "Pipeline" 部分配置：

```
Definition: Pipeline script from SCM
SCM: Git
Repository URL: https://gitlab.com/your-org/trtllm-perf-test.git
Credentials: (选择你的 GitLab 凭证)
Branch Specifier: */main
Script Path: Perf_Test.groovy
```

点击 "Save"。

### 步骤 4: 测试运行

#### 4.1 Dry Run 测试

第一次运行使用 Dry Run 模式：

```
参数设置:
  TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
  TRTLLM_REPO: https://github.com/NVIDIA/TensorRT-LLM.git
  TRTLLM_BRANCH: main
  DRY_RUN: true
```

点击 "Build with Parameters"。

#### 4.2 查看输出

检查 Console Output：
- ✓ TensorRT-LLM 是否成功拉取
- ✓ 节点计算是否正确
- ✓ 配置文件是否找到

#### 4.3 实际运行

确认 Dry Run 正常后，设置 `DRY_RUN: false` 实际运行。

## 🔧 自定义配置

### 配置私有 TensorRT-LLM 仓库

如果使用私有仓库：

```groovy
// 在 Jenkins Credentials 中添加 Git 凭证
// ID: trtllm-git-credentials

// 修改 Perf_Test.groovy 的拉取阶段:
stage('拉取 TensorRT-LLM 依赖') {
    steps {
        script {
            checkout([
                $class: 'GitSCM',
                branches: [[name: "${TRTLLM_BRANCH}"]],
                userRemoteConfigs: [[
                    url: "${TRTLLM_REPO}",
                    credentialsId: 'trtllm-git-credentials'
                ]],
                extensions: [[$class: 'CloneOption', depth: 1, shallow: true]]
            ])
        }
    }
}
```

### 配置默认参数

在 `Perf_Test.groovy` 中修改默认参数：

```groovy
string(
    name: 'TRTLLM_REPO',
    defaultValue: 'https://your-internal-gitlab.com/nvidia/TensorRT-LLM.git',
    description: 'TensorRT-LLM 仓库地址'
),
string(
    name: 'TRTLLM_BRANCH',
    defaultValue: 'your-internal-branch',
    description: 'TensorRT-LLM 分支名称'
),
```

## 📁 目录结构说明

部署后的仓库结构：

```
trtllm-perf-test/          # 你的 GitLab 仓库
├── .git/
├── Perf_Test.groovy       # Jenkins Pipeline 入口
├── README.md              # 主文档
├── DEPLOYMENT.md          # 本文件
├── scripts/
│   └── calculate_hardware_nodes.py
└── docs/
    ├── ARCHITECTURE_FINAL.md
    ├── SOLUTION_SUMMARY.md
    ├── README_PERF_TESTS.md
    ├── QUICK_REFERENCE.md
    └── TESTLIST_EXPLANATION.md
```

运行时会自动创建：

```
Jenkins Workspace/
├── trtllm-perf-test/      # 你的仓库
└── TensorRT-LLM/          # 自动拉取的依赖
    ├── tests/
    └── jenkins/scripts/
```

## 🔄 更新流程

### 更新性能测试框架

```bash
cd /path/to/trtllm-perf-test

# 修改文件
vim Perf_Test.groovy

# 提交
git add .
git commit -m "Update: xxx"
git push origin main
```

Jenkins 会自动使用最新版本。

### 更新 TensorRT-LLM 依赖

只需在 Jenkins 参数中修改 `TRTLLM_BRANCH`：

```
TRTLLM_BRANCH: release/v0.10  # 切换到其他分支
```

Pipeline 会自动拉取新分支的文件。

## 🐛 故障排查

### 问题 1: 拉取 TensorRT-LLM 失败

**错误**: `fatal: unable to access 'https://github.com/NVIDIA/TensorRT-LLM.git/'`

**解决**:
- 检查网络连接
- 检查 Git 凭证配置
- 尝试使用 SSH URL

### 问题 2: 找不到 Python 模块

**错误**: `ModuleNotFoundError: No module named 'yaml'`

**解决**:
```bash
# 在 Jenkins 节点上安装
pip3 install pyyaml
```

或在 Pipeline 中添加：

```groovy
stage('准备环境') {
    steps {
        sh 'pip3 install pyyaml'
    }
}
```

### 问题 3: 权限问题

**错误**: `Permission denied`

**解决**:
```bash
# 确保脚本有执行权限
chmod +x scripts/calculate_hardware_nodes.py
git add scripts/calculate_hardware_nodes.py
git commit -m "Fix: add execute permission"
git push
```

## 🔐 安全建议

### 1. 使用 Jenkins Credentials

不要在代码中硬编码敏感信息：

```groovy
// ✗ 不好
TRTLLM_REPO = 'https://username:password@gitlab.com/repo.git'

// ✓ 好
// 在 Jenkins Credentials 中配置，然后:
checkout([
    $class: 'GitSCM',
    userRemoteConfigs: [[
        url: "${TRTLLM_REPO}",
        credentialsId: 'my-git-credentials'
    ]]
])
```

### 2. 限制分支访问

在 Jenkins Job 配置中限制可用的分支：

```
Branch Specifier: */main
```

### 3. 审查权限

确保只有授权用户可以：
- 修改 Pipeline 代码
- 运行 Jenkins Job
- 访问 GitLab 仓库

## 📊 监控和日志

### Jenkins 构建历史

在 Jenkins Job 页面查看：
- 构建历史
- 成功/失败统计
- Console Output

### 节点计算日志

Pipeline 会输出详细的节点计算信息：

```
节点计算结果:
  逻辑 CTX servers: 2
  逻辑 GEN servers: 1
  CTX world size: 4
  GEN world size: 8
  CTX 硬件节点: 2
  GEN 硬件节点: 2
  总硬件节点: 4
  总 GPU 数: 16
```

## 🎓 团队培训

### 新成员上手

1. 阅读 `README.md` 了解整体架构
2. 阅读 `docs/QUICK_REFERENCE.md` 快速上手
3. 运行一次 Dry Run 测试
4. 查看 `docs/ARCHITECTURE_FINAL.md` 深入理解

### 常用命令

```bash
# 测试节点计算
python3 scripts/calculate_hardware_nodes.py --config xxx.yaml

# 查看 TestList
cat TensorRT-LLM/tests/integration/test_lists/test-db/xxx.yml

# 手动运行 submit.py
python3 TensorRT-LLM/jenkins/scripts/perf/disaggregated/submit.py --config xxx.yaml
```

## ✅ 部署检查清单

- [ ] GitLab 仓库已创建
- [ ] 代码已推送到 GitLab
- [ ] Jenkins Job 已创建
- [ ] Pipeline 配置正确
- [ ] Git 凭证已配置
- [ ] Python 环境已准备
- [ ] Dry Run 测试通过
- [ ] 实际运行测试通过
- [ ] 文档已阅读
- [ ] 团队已培训

## 📞 支持

如遇到问题：
1. 查看 Console Output
2. 阅读相关文档
3. 联系性能测试团队

---

**祝部署顺利！** 🚀
