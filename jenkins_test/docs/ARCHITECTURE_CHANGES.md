# 架构变更总结

## 📋 变更概述

本次重构解决了以下核心问题：
1. **虚拟环境管理混乱**：统一在 Cluster 上管理 Python 虚拟环境
2. **执行环境不清晰**：明确中转机和 Cluster 的职责边界
3. **Git 克隆限制**：改为完整克隆以支持所有框架功能
4. **文件传递机制**：通过 `sync_and_run.sh` 统一文件同步和远程执行

---

## 🏗️ 新架构

```
Jenkins Pipeline (中转机)
    │
    ├─ [Stage 1] 验证参数和配置
    │   └─ 使用 python3 加载 load_cluster_config.py（标准库，无需虚拟环境）
    │
    ├─ [Stage 2] 准备工作环境
    │   └─ git clone --branch <branch> <repo> (完整克隆，移除 --depth 1)
    │
    └─ [Stage 4] 运行测试
        └─ 调用 sync_and_run.sh
            │
            ├─ SCP scripts/ → Cluster
            ├─ SCP testlists/ → Cluster
            ├─ SCP TensorRT-LLM/ → Cluster
            │
            └─ SSH 到 Cluster 执行
                │
                run_perf_tests.sh (Cluster login node)
                    │
                    ├─ [步骤 0] 创建 Python 虚拟环境
                    │   ├─ python3 -m venv .venv
                    │   └─ pip install pyyaml
                    │
                    ├─ [步骤 1] 解析 YAML testlist
                    │   └─ .venv/bin/python parse_unified_testlist.py
                    │
                    └─ [步骤 2] 执行测试
                        └─ 调用 run_*_test.sh (Cluster)
                            └─ srun + Docker (Cluster compute nodes)
```

---

## 🔑 关键变更

### 1. Git 克隆策略

**变更前**：
```groovy
git clone --depth 1 --branch ${TRTLLM_BRANCH} ${TRTLLM_REPO} ${TRTLLM_DIR}
```

**变更后**：
```groovy
git clone --branch ${TRTLLM_BRANCH} ${TRTLLM_REPO} ${TRTLLM_DIR}
```

**原因**：某些框架不支持浅克隆（sparse/partial clone），需要完整的 Git 历史。

---

### 2. 虚拟环境管理

#### **变更前**：
- Jenkins 在中转机创建 `.venv`
- `run_perf_tests.sh` 在中转机激活 `.venv`
- 子脚本在 Cluster 上执行（无法访问中转机的虚拟环境）❌

#### **变更后**：
- **中转机**：
  - `load_cluster_config.py` 使用系统 `python3`（只用标准库）
  
- **Cluster**：
  - `run_perf_tests.sh` 创建并使用 `.venv`
  - 安装 `pyyaml` 依赖
  - 所有 Python 脚本使用虚拟环境

**代码示例（run_perf_tests.sh）**：
```bash
# 步骤 0: 准备 Python 虚拟环境
VENV_DIR="$SCRIPT_DIR/.venv"

if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
    source "$VENV_DIR/bin/activate"
    pip install --quiet pyyaml
else
    source "$VENV_DIR/bin/activate"
fi

# 使用虚拟环境中的 Python
TESTLIST_JSON=$(python "$SCRIPT_DIR/parse_unified_testlist.py" "$TESTLIST")
```

---

### 3. 文件传递机制

#### **sync_and_run.sh 增强**

新增同步内容：
- ✅ `parse_unified_testlist.py` - YAML 解析脚本
- ✅ `testlists/` - 测试列表目录
- ✅ 智能路径转换（`testlists/xxx.yml` → `${CLUSTER_WORKDIR}/testlists/xxx.yml`）

**代码示例（sync_and_run.sh）**：
```bash
# 上传 parse_unified_testlist.py
if [[ -f "$SCRIPT_DIR/parse_unified_testlist.py" ]]; then
    remote_copy "$SCRIPT_DIR/parse_unified_testlist.py" "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"
    echo "✓ 已上传: parse_unified_testlist.py"
fi

# 上传 testlists 目录
TESTLISTS_DIR="$SCRIPT_DIR/../testlists"
if [[ -d "$TESTLISTS_DIR" ]]; then
    remote_mkdir "${CLUSTER_WORKDIR}/testlists"
    remote_copy "$TESTLISTS_DIR/" "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/testlists/"
    echo "✓ 已上传: testlists/"
fi

# 智能路径转换
for arg in "${SCRIPT_ARGS[@]:-}"; do
    if [[ "$arg" == testlists/* ]]; then
        # 将相对路径转换为 Cluster 上的绝对路径
        escaped_arg="${CLUSTER_WORKDIR}/${arg}"
    else
        escaped_arg=$(printf '%q' "$arg")
    fi
    REMOTE_CMD+=" $escaped_arg"
done
```

---

### 4. Jenkins Pipeline 简化

#### **变更前**：
```groovy
// 创建虚拟环境（中转机）
sh """
    if [ ! -d ${SCRIPTS_DIR}/.venv ]; then
        python3 -m venv ${SCRIPTS_DIR}/.venv
    fi
"""

// 直接调用脚本（中转机）
sh "${SCRIPTS_DIR}/run_perf_tests.sh --testlist ${TESTLIST_FILE}"
```

#### **变更后**：
```groovy
// 使用 sync_and_run.sh 同步并远程执行
sh """
    export CLUSTER_WORKDIR='${env.CLUSTER_WORKDIR}'
    
    ${SCRIPTS_DIR}/sync_and_run.sh \\
        --trtllm-dir ${TRTLLM_DIR} \\
        --workspace ${OUTPUT_DIR} \\
        --remote-script run_perf_tests.sh \\
        --testlist testlists/${TESTLIST}.yml \\
        ${FILTER_MODE != 'all' ? '--mode ' + FILTER_MODE : ''}
"""
```

---

### 5. 集群配置新增字段

**clusters.conf 新增**：
```ini
[gb200]
CLUSTER_WORKDIR=/home/fredricz/jenkins_trtllm_perf  # 新增！
```

**用途**：
- `sync_and_run.sh` 同步文件的目标目录
- 所有脚本和测试在此目录下执行
- 隔离不同构建的工作空间

---

## 📂 文件依赖关系

### 中转机（Jenkins）
```
Perf_Test.groovy
    └─ load_cluster_config.py (使用系统 python3)
    └─ sync_and_run.sh
        ├─ 同步 scripts/
        ├─ 同步 testlists/
        └─ 同步 TensorRT-LLM/
```

### Cluster（远程执行）
```
run_perf_tests.sh (创建 .venv)
    └─ parse_unified_testlist.py (使用 .venv/bin/python)
    └─ run_single_agg_test.sh
    └─ run_multi_agg_test.sh
    └─ run_disagg_test.sh
        └─ calculate_hardware_nodes.py (使用 .venv/bin/python)
```

---

## 🧪 测试验证

### 手动测试步骤

1. **验证虚拟环境创建**：
```bash
# 在 Cluster 上
ssh cluster
cd ~/jenkins_trtllm_perf/scripts
./run_perf_tests.sh --testlist ../testlists/gb200_unified_suite.yml

# 检查虚拟环境
ls -la .venv/
.venv/bin/python --version
.venv/bin/pip list | grep pyyaml
```

2. **验证 YAML 解析**：
```bash
# 在 Cluster 上
source .venv/bin/activate
python parse_unified_testlist.py ../testlists/gb200_unified_suite.yml --summary
```

3. **验证完整流程**：
```bash
# 在中转机
cd jenkins_test
./scripts/sync_and_run.sh \
    --trtllm-dir /path/to/TensorRT-LLM \
    --workspace /tmp/test_output \
    --remote-script run_perf_tests.sh \
    --testlist testlists/gb200_unified_suite.yml \
    --mode single-agg
```

---

## 🐛 已知问题和解决方案

### 问题 1：虚拟环境在并发构建中冲突

**症状**：多个 Jenkins job 同时运行时，`.venv` 创建冲突

**解决方案**：
- 方案 A：使用文件锁保护 `.venv` 创建
- 方案 B：每个 job 使用独立的 `CLUSTER_WORKDIR`（推荐）

```groovy
// 在 Jenkins Pipeline 中
env.CLUSTER_WORKDIR = "${env.CLUSTER_WORKDIR_BASE}/${BUILD_NUMBER}"
```

### 问题 2：YAML 文件路径解析错误

**症状**：`parse_unified_testlist.py` 找不到 YAML 文件

**调试方法**：
```bash
# 在 Cluster 上
echo "CLUSTER_WORKDIR: $CLUSTER_WORKDIR"
ls -la $CLUSTER_WORKDIR/testlists/
python parse_unified_testlist.py $CLUSTER_WORKDIR/testlists/gb200_unified_suite.yml
```

---

## 📚 相关文档

- [QUICK_START.md](./QUICK_START.md) - 快速开始指南
- [DEPENDENCIES.md](./DEPENDENCIES.md) - 依赖文件清单
- [TEST_PROCESS.md](./TEST_PROCESS.md) - 测试流程说明
- [CLUSTER_CONFIG_GUIDE.md](./docs/CLUSTER_CONFIG_GUIDE.md) - 集群配置指南

---

## ✅ 变更清单

- [x] 移除 Git 浅克隆（`--depth 1`）
- [x] 删除 Jenkins Pipeline 中的虚拟环境创建
- [x] 在 `run_perf_tests.sh` 中添加虚拟环境管理
- [x] 创建 `parse_unified_testlist.py` 脚本
- [x] 增强 `sync_and_run.sh` 同步 `testlists/` 和 `parse_unified_testlist.py`
- [x] 在 `clusters.conf` 中添加 `CLUSTER_WORKDIR` 配置
- [x] 更新 Jenkins Pipeline 使用 `sync_and_run.sh`
- [x] 智能路径转换（testlists 相对路径 → Cluster 绝对路径）
- [x] 更新文档（本文档）

---

## 🎯 后续优化建议

1. **虚拟环境缓存**：
   - 在 Cluster 上预创建虚拟环境模板
   - 使用 `--system-site-packages` 复用系统包

2. **并行构建隔离**：
   - 每个构建使用独立的 `CLUSTER_WORKDIR`
   - 自动清理旧构建目录

3. **依赖管理**：
   - 创建 `requirements.txt`
   - 版本锁定（`pyyaml==6.0.1`）

4. **错误处理**：
   - 虚拟环境创建失败时的回退机制
   - 更详细的日志输出

---

**变更日期**: 2026-01-31  
**作者**: AI Assistant  
**审核状态**: 待审核
