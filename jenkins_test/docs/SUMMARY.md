# 🎉 jenkins_test 目录整理完成！

## ✅ 完成的工作

### 1. 创建独立目录结构
已将所有 Perf_Test 相关文件整理到 `jenkins_test/` 目录：

```
jenkins_test/
├── Perf_Test.groovy              # ⭐ Jenkins Pipeline（已更新：支持自动拉取依赖）
├── scripts/
│   ├── calculate_hardware_nodes.py   # ⭐ 节点计算工具
│   └── deploy.sh                     # 快速部署脚本
├── docs/
│   ├── ARCHITECTURE_FINAL.md         # 架构详解
│   ├── SOLUTION_SUMMARY.md           # 解决方案总结
│   ├── README_PERF_TESTS.md          # 性能测试指南
│   ├── QUICK_REFERENCE.md            # 快速参考
│   └── TESTLIST_EXPLANATION.md       # TestList 说明
├── README.md                      # 📖 主文档
├── DEPLOYMENT.md                  # 📖 部署指南
├── VERSION.md                     # 版本信息
├── STRUCTURE.md                   # 目录结构说明
├── .gitignore                     # Git 忽略规则
└── SUMMARY.md                     # 本文件
```

### 2. 核心改进

#### Perf_Test.groovy
✅ **新增自动拉取依赖功能**：
```groovy
stage('拉取 TensorRT-LLM 依赖') {
    steps {
        script {
            // 自动克隆或更新 TensorRT-LLM 仓库
            // 支持配置不同的仓库地址和分支
        }
    }
}
```

✅ **Pipeline 参数**：
- `TESTLIST`: TestList 名称
- `CONFIG_FILE`: 配置文件路径
- `NODE_LIST`: 节点列表（验证用）
- `TRTLLM_REPO`: TensorRT-LLM 仓库地址 ⭐ 新增
- `TRTLLM_BRANCH`: TensorRT-LLM 分支 ⭐ 新增
- `DRY_RUN`: 试运行模式

#### calculate_hardware_nodes.py
✅ **独立的节点计算工具**：
- 从 YAML 读取逻辑服务器配置
- 计算实际硬件节点需求
- 支持节点数验证
- 支持 JSON 输出

### 3. 完整文档

#### 快速上手
- ✅ **README.md** - 主文档，5分钟了解整体架构
- ✅ **DEPLOYMENT.md** - 部署指南，手把手教你部署

#### 深入理解
- ✅ **ARCHITECTURE_FINAL.md** - 详细的架构设计和节点计算逻辑
- ✅ **SOLUTION_SUMMARY.md** - 核心代码和解决方案总结

#### 详细参考
- ✅ **README_PERF_TESTS.md** - 性能测试详细使用指南
- ✅ **QUICK_REFERENCE.md** - 快速参考手册
- ✅ **TESTLIST_EXPLANATION.md** - TestList 机制详解

#### 其他
- ✅ **VERSION.md** - 版本信息和更新日志
- ✅ **STRUCTURE.md** - 目录结构详细说明

### 4. 便捷工具

✅ **deploy.sh** - 一键部署脚本：
```bash
cd jenkins_test
./scripts/deploy.sh https://gitlab.com/your-org/trtllm-perf-test.git
```

## 🎯 核心优势

### 1. 完全独立
- ✅ 可部署到独立的 GitLab 仓库
- ✅ 不依赖 TensorRT-LLM 仓库的本地副本
- ✅ 不影响 L0_Test.groovy

### 2. 自动依赖管理
```
Perf_Test.groovy
    ↓ 自动拉取
TensorRT-LLM/
    ├── tests/integration/test_lists/      # TestList 定义
    ├── tests/integration/defs/perf/       # 测试配置
    └── jenkins/scripts/perf/disaggregated/submit.py  # L0 submit
```

### 3. 智能节点计算
```python
# 逻辑服务器数 → 硬件节点数
ctx_servers = 2 (逻辑)
gen_servers = 1 (逻辑)
ctx_tp = 4, gen_tp = 8
gpus_per_node = 4

↓ calculate_hardware_nodes.py

ctx_hardware_nodes = 2
gen_hardware_nodes = 2
total_hardware_nodes = 4  # ← 实际需要的物理节点
```

### 4. 复用 L0 逻辑
- ✅ 直接调用 TensorRT-LLM 的 submit.py
- ✅ 不重新实现复杂逻辑
- ✅ L0 更新自动生效

## 🚀 快速开始

### 方式 1: 部署到独立 GitLab 仓库（推荐）

```bash
# 1. 进入 jenkins_test 目录
cd /path/to/TensorRT-LLM/jenkins_test

# 2. 运行部署脚本
./scripts/deploy.sh https://gitlab.com/your-org/trtllm-perf-test.git

# 3. 在 Jenkins 中配置 Pipeline
#    Repository URL: <your-gitlab-repo>
#    Script Path: Perf_Test.groovy

# 4. 运行测试
#    TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
#    TRTLLM_REPO: https://github.com/NVIDIA/TensorRT-LLM.git
#    TRTLLM_BRANCH: main
```

### 方式 2: 直接使用（不独立部署）

```groovy
// 在 Jenkins 中配置
Repository URL: <TensorRT-LLM repo>
Script Path: jenkins_test/Perf_Test.groovy
```

## 📊 与 L0_Test.groovy 的关系

### L0_Test.groovy（保持不变）
```groovy
// 位置: jenkins/L0_Test.groovy
// 作用: L0 所有测试（包括但不限于性能测试）
// 状态: 保持原样，不修改
```

### Perf_Test.groovy（新的独立版本）
```groovy
// 位置: jenkins_test/Perf_Test.groovy
// 作用: 专注于性能测试
// 特点: 
//   - 可独立部署
//   - 自动拉取 TensorRT-LLM 依赖
//   - 智能节点计算
//   - 复用 L0 submit.py
```

### 依赖关系
```
jenkins_test/Perf_Test.groovy (新)
    ↓ 自动拉取
TensorRT-LLM/jenkins/scripts/perf/disaggregated/submit.py (复用)
    ↓
与 L0_Test.groovy 使用相同的 submit.py，保持一致
```

## 📝 使用示例

### Jenkins Pipeline 参数

```yaml
# 使用 TestList
TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
NODE_LIST: node1,node2,node3,node4
TRTLLM_REPO: https://github.com/NVIDIA/TensorRT-LLM.git
TRTLLM_BRANCH: main
DRY_RUN: false

# 或直接使用配置文件
CONFIG_FILE: tests/.../deepseek-r1-fp4_1k1k_ctx1_gen1_dep8_bs768_eplb0_mtp0_ccb-UCX.yaml
NODE_LIST: node1,node2,node3,node4
TRTLLM_REPO: https://github.com/NVIDIA/TensorRT-LLM.git
TRTLLM_BRANCH: main
DRY_RUN: false
```

### 命令行测试节点计算

```bash
# 查看配置需要多少节点
python3 scripts/calculate_hardware_nodes.py \
    --config TensorRT-LLM/tests/.../xxx.yaml

# 验证节点数
python3 scripts/calculate_hardware_nodes.py \
    --config TensorRT-LLM/tests/.../xxx.yaml \
    --check-nodes 4

# JSON 输出
python3 scripts/calculate_hardware_nodes.py \
    --config TensorRT-LLM/tests/.../xxx.yaml \
    --json
```

## 🔍 文件详解

### 核心文件（必须）

| 文件 | 作用 | 说明 |
|------|------|------|
| `Perf_Test.groovy` | Jenkins Pipeline | 主入口，必须 |
| `scripts/calculate_hardware_nodes.py` | 节点计算 | 核心工具，必须 |

### 文档文件（推荐保留）

| 文件 | 作用 | 读者 |
|------|------|------|
| `README.md` | 主文档 | 所有人 |
| `DEPLOYMENT.md` | 部署指南 | DevOps/管理员 |
| `docs/ARCHITECTURE_FINAL.md` | 架构详解 | 开发者 |
| `docs/SOLUTION_SUMMARY.md` | 解决方案总结 | 开发者 |
| `docs/README_PERF_TESTS.md` | 使用指南 | 测试人员 |
| `docs/QUICK_REFERENCE.md` | 快速参考 | 测试人员 |
| `docs/TESTLIST_EXPLANATION.md` | TestList 说明 | 测试人员 |

### 辅助文件（可选）

| 文件 | 作用 | 说明 |
|------|------|------|
| `scripts/deploy.sh` | 部署脚本 | 自动化部署 |
| `VERSION.md` | 版本信息 | 版本管理 |
| `STRUCTURE.md` | 目录结构 | 快速了解 |
| `.gitignore` | Git 忽略 | 版本控制 |

## 📦 迁移到独立仓库

### 步骤 1: 复制目录

```bash
# 方式 A: 直接复制
cp -r /path/to/TensorRT-LLM/jenkins_test /path/to/new-repo/

# 方式 B: 使用部署脚本
cd /path/to/TensorRT-LLM/jenkins_test
./scripts/deploy.sh https://gitlab.com/your-org/trtllm-perf-test.git
```

### 步骤 2: 配置 Jenkins

```
Jenkins Job 配置:
  Pipeline from SCM:
    SCM: Git
    Repository URL: https://gitlab.com/your-org/trtllm-perf-test.git
    Branch: main
    Script Path: Perf_Test.groovy
```

### 步骤 3: 测试运行

```
首次运行使用 Dry Run:
  TESTLIST: l0_gb200_multi_nodes_disagg_perf_sanity_3_nodes
  DRY_RUN: true
```

## 🎓 学习路径

### 新手（15分钟）
1. 阅读 `README.md` （5分钟）
2. 阅读 `DEPLOYMENT.md` （5分钟）
3. 运行 Dry Run 测试（5分钟）

### 进阶（1小时）
1. 阅读 `docs/ARCHITECTURE_FINAL.md`（30分钟）
2. 阅读 `docs/SOLUTION_SUMMARY.md`（15分钟）
3. 手动测试节点计算工具（15分钟）

### 专家（按需）
- `docs/README_PERF_TESTS.md` - 详细使用
- `docs/TESTLIST_EXPLANATION.md` - TestList 机制
- 源码阅读 - 深入理解

## ✅ 检查清单

部署前检查：
- [ ] 已阅读 README.md
- [ ] 已阅读 DEPLOYMENT.md
- [ ] GitLab 仓库已创建
- [ ] Python 环境已准备
- [ ] PyYAML 已安装

部署后检查：
- [ ] 代码已推送到 GitLab
- [ ] Jenkins Job 已创建
- [ ] Pipeline 配置正确
- [ ] Dry Run 测试通过
- [ ] 实际运行测试通过

## 🎉 总结

### 实现的目标
✅ **独立目录结构** - 所有文件整理到 `jenkins_test/`  
✅ **自动依赖管理** - 自动拉取 TensorRT-LLM  
✅ **智能节点计算** - 区分逻辑/硬件节点  
✅ **复用 L0 逻辑** - 调用现有 submit.py  
✅ **完整文档** - 从快速上手到深入理解  
✅ **便捷工具** - 一键部署脚本  

### 下一步
1. **阅读 README.md** 了解整体架构
2. **运行 deploy.sh** 部署到 GitLab
3. **配置 Jenkins** 创建 Pipeline
4. **开始测试** 运行性能测试

---

**准备就绪！** 🚀

所有文件已整理完毕，可以随时部署到独立的 GitLab 仓库了！
