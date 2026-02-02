# Disagg 调用链条快速参考

## ❌ 当前 Jenkins 调用链条有严重问题！

```
Jenkins
  → run_perf_tests.sh
    → run_disagg_test.sh
      → sbatch (提交到 SLURM)
        → python3 submit.py --run-ci ...  ❌ 缺少必需参数，会失败！
```

**问题：**
- ❌ `submit.py` 缺少必需的 `--test-list` 参数
- ❌ `submit.py` 只生成脚本，不执行测试
- ❌ 参数 `--config` 不存在（应该是 `--config-yaml`）

## ✅ 正确的调用链条（GitLab CI 方式）

```
GitLab CI
  → gitlab-ci/scripts/utilities/run_disagg_test.sh
    → cd tests/integration/defs/perf/disagg
    → poetry run pytest test_disagg.py --disagg --disagg-test-list=$TEST_LIST
      → test_disagg.py 内部提交 sbatch 作业
        → 启动多个 srun pytorch 进程
```

**关键点：**
- ✅ 不使用 `submit.py`
- ✅ 使用 `test_disagg.py`（不是 `test_perf_sanity.py`）
- ✅ 使用 Poetry 管理依赖
- ✅ pytest 内部处理 Slurm 提交

---

## 📂 日志文件位置

```
$jobWorkspace/  (由 slurm_launch_draft.sh 设置)
├── install.log
├── gen_server_0.log      ← pytest 输出
├── gen_server_1.log
├── ctx_server_0.log
├── ctx_server_1.log
├── disagg_server.log
└── benchmark.log         ← 包含性能数据
```

---

## 🔄 数据上传

### OpenSearch（当前）

```python
# test_perf_sanity.py (BENCHMARK 节点执行)

config.upload_test_result()
  └─ post_new_perf_data()  # ← 自动上传
```

- ✅ **无需 Jenkins 额外操作**
- ✅ pytest 内部自动完成

### Perf DB（待实现）

**需要修改：**

```python
# test_perf_sanity.py::upload_test_result()

def upload_test_result(self):
    # 1. OpenSearch（现有）
    post_new_perf_data(new_data_dict)
    
    # 2. Perf DB（新增）
    if os.getenv("UPLOAD_TO_PERFDB", "true") == "true":
        upload_to_perfdb(new_data_dict)
```

---

## 📦 日志打包方案

### 实现位置

修改 `jenkins/scripts/perf/disaggregated/slurm_launch_draft.sh`

### 关键函数

```bash
package_logs_for_diagnosis() {
    local STATUS=$1  # "success" or "failure"
    
    # 1. 收集所有日志
    # 2. 生成故障总结
    # 3. 收集系统信息
    # 4. 打包为 tar.gz
}

cleanup_on_failure() {
    echo "Error: $1"
    package_logs_for_diagnosis "failure"  # ← 新增
    scancel ${SLURM_JOB_ID}
    exit 1
}
```

### 归档内容

```
job_${SLURM_JOB_ID}_failure_20260201.tar.gz
├── summary.txt                  ← 📝 首先查看
├── *.log                        ← 所有组件日志
├── nvidia_smi.txt
├── processes.txt
└── disk_usage.txt
```

---

## 🛠️ 实施步骤

### Phase 1: 日志打包（优先）

1. ✅ 修改 `slurm_launch_draft.sh`
2. ✅ 添加 `package_logs_for_diagnosis()`
3. ✅ 修改 `cleanup_on_failure()` 
4. ✅ 修改 `Perf_Test.groovy` 归档 artifacts

### Phase 2: Perf DB 上传（次优先）

1. ✅ 创建 `opensearch_to_perfdb_adapter.py`
2. ✅ 创建 `perfdb_utils.py`
3. ✅ 修改 `test_perf_sanity.py`
4. ✅ 添加环境变量 `UPLOAD_TO_PERFDB`

---

## 📚 相关文档

- **完整方案**：`DISAGG_REAL_CALL_CHAIN_FINAL.md`
- **原始分析**：`DISAGG_LOGGING_AND_UPLOAD_PLAN.md`

---

**准备好实施了吗？从哪个阶段开始？**
