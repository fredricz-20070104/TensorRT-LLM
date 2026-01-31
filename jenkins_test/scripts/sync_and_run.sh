#!/bin/bash
#
# 通用的同步和远程执行脚本
# 在中转机上运行，负责将代码同步到 cluster 并执行测试
#

set -euo pipefail

# ============================================
# 加载库
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/remote.sh"

# ============================================
# 参数
# ============================================
TRTLLM_DIR=""
WORKSPACE=""
REMOTE_SCRIPT=""
SCRIPT_ARGS=()

usage() {
    cat << EOF
Usage: $0 --trtllm-dir DIR --workspace DIR --remote-script SCRIPT [SCRIPT_ARGS...]

Options:
    --trtllm-dir DIR        本地 TensorRT-LLM 目录
    --workspace DIR         本地工作目录
    --remote-script SCRIPT  要在远程执行的脚本名称
    其他参数                传递给远程脚本的参数

环境变量要求:
    CLUSTER_NAME            Cluster 名称
    CLUSTER_HOST            Cluster 主机
    CLUSTER_USER            Cluster 用户
    CLUSTER_TYPE            Cluster 类型 (ssh/local)
    CLUSTER_WORKDIR         Cluster 工作目录
    CLUSTER_STORAGE         Cluster 存储路径
    
示例:
    $0 --trtllm-dir ~/TensorRT-LLM \\
       --workspace /tmp/test \\
       --remote-script run_disagg_test.sh \\
       --testlist xxx --config-file yyy
EOF
    exit 1
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --trtllm-dir)
            TRTLLM_DIR="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE="$2"
            shift 2
            ;;
        --remote-script)
            REMOTE_SCRIPT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            # 收集剩余参数传递给远程脚本
            SCRIPT_ARGS+=("$1")
            shift
            ;;
    esac
done

# 验证参数
if [[ -z "$TRTLLM_DIR" || -z "$WORKSPACE" || -z "$REMOTE_SCRIPT" ]]; then
    echo "错误：缺少必需参数"
    usage
fi

# 验证环境变量
for var in CLUSTER_NAME CLUSTER_HOST CLUSTER_USER CLUSTER_TYPE CLUSTER_WORKDIR; do
    if [[ -z "${!var:-}" ]]; then
        echo "错误：环境变量 $var 未设置"
        exit 1
    fi
done

# 创建本地工作目录
mkdir -p "$WORKSPACE"

echo "========================================"
echo "远程执行配置"
echo "========================================"
echo "Cluster: $CLUSTER_NAME"
echo "Host: $CLUSTER_HOST"
echo "User: $CLUSTER_USER"
echo "Type: $CLUSTER_TYPE"
echo "Remote workdir: $CLUSTER_WORKDIR"
echo "Local TensorRT-LLM: $TRTLLM_DIR"
echo "Local workspace: $WORKSPACE"
echo "Remote script: $REMOTE_SCRIPT"
echo "Script args: ${SCRIPT_ARGS[*]:-无}"
echo "========================================"

# ============================================
# 步骤 1: 创建远程工作目录
# ============================================
echo ""
echo "[步骤 1] 创建远程工作目录..."
remote_mkdir "$CLUSTER_WORKDIR"
remote_mkdir "$CLUSTER_WORKDIR/scripts"
remote_mkdir "$CLUSTER_WORKDIR/workspace"

# ============================================
# 步骤 2: 同步 TensorRT-LLM 到 cluster
# ============================================
echo ""
echo "[步骤 2] 同步 TensorRT-LLM 到 cluster..."

if [[ ! -d "$TRTLLM_DIR" ]]; then
    echo "错误：TensorRT-LLM 目录不存在: $TRTLLM_DIR"
    exit 1
fi

echo "同步: $TRTLLM_DIR -> ${REMOTE_PREFIX}${CLUSTER_WORKDIR}/TensorRT-LLM"
remote_copy "$TRTLLM_DIR/" "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/TensorRT-LLM/"

echo "✓ TensorRT-LLM 已同步"

# ============================================
# 步骤 3: 上传测试脚本和库
# ============================================
echo ""
echo "[步骤 3] 上传测试脚本和库..."

# 上传远程执行脚本
if [[ -f "$SCRIPT_DIR/$REMOTE_SCRIPT" ]]; then
    remote_copy "$SCRIPT_DIR/$REMOTE_SCRIPT" "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"
    remote_exec "chmod +x ${CLUSTER_WORKDIR}/scripts/$REMOTE_SCRIPT"
    echo "✓ 已上传: $REMOTE_SCRIPT"
else
    echo "错误：找不到脚本: $SCRIPT_DIR/$REMOTE_SCRIPT"
    exit 1
fi

# 上传 calculate_hardware_nodes.py (disagg 需要)
if [[ -f "$SCRIPT_DIR/calculate_hardware_nodes.py" ]]; then
    remote_copy "$SCRIPT_DIR/calculate_hardware_nodes.py" "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"
    echo "✓ 已上传: calculate_hardware_nodes.py"
fi

# 上传 lib 目录
if [[ -d "$SCRIPT_DIR/lib" ]]; then
    remote_mkdir "${CLUSTER_WORKDIR}/scripts/lib"
    remote_copy "$SCRIPT_DIR/lib/" "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/lib/"
    echo "✓ 已上传: lib/"
fi

echo "✓ 所有脚本已上传"

# ============================================
# 步骤 4: 远程执行测试
# ============================================
echo ""
echo "[步骤 4] 在 cluster 上执行测试..."

# 构造远程脚本的完整参数
REMOTE_CMD="${CLUSTER_WORKDIR}/scripts/$REMOTE_SCRIPT"
REMOTE_CMD+=" --trtllm-dir ${CLUSTER_WORKDIR}/TensorRT-LLM"
REMOTE_CMD+=" --workspace ${CLUSTER_WORKDIR}/workspace"

# 添加传递的参数
for arg in "${SCRIPT_ARGS[@]:-}"; do
    # 转义特殊字符
    escaped_arg=$(printf '%q' "$arg")
    REMOTE_CMD+=" $escaped_arg"
done

echo "执行命令:"
echo "  $REMOTE_CMD"
echo ""

# 执行远程脚本
if remote_exec "$REMOTE_CMD"; then
    echo ""
    echo "✓ 测试执行成功"
    TEST_SUCCESS=true
else
    echo ""
    echo "✗ 测试执行失败"
    TEST_SUCCESS=false
fi

# ============================================
# 步骤 5: 拉取测试结果
# ============================================
echo ""
echo "[步骤 5] 拉取测试结果..."

# 创建本地结果目录
mkdir -p "$WORKSPACE/output"

# 拉取结果
if remote_exec "test -d ${CLUSTER_WORKDIR}/workspace/output"; then
    remote_copy "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/workspace/output/" "$WORKSPACE/output/"
    echo "✓ 测试结果已拉取到: $WORKSPACE/output/"
else
    echo "⚠ 警告：远程没有找到 output 目录"
fi

# 拉取日志
if remote_exec "test -d ${CLUSTER_WORKDIR}/workspace"; then
    # 拉取所有 .log 文件
    if [[ "$REMOTE_MODE" = "local" ]]; then
        find "${CLUSTER_WORKDIR}/workspace" -name "*.log" -exec cp {} "$WORKSPACE/" \; 2>/dev/null || true
    else
        ssh "${CLUSTER_USER}@${CLUSTER_HOST}" "find ${CLUSTER_WORKDIR}/workspace -name '*.log' 2>/dev/null" | while read log_file; do
            log_name=$(basename "$log_file")
            remote_copy "${REMOTE_PREFIX}${log_file}" "$WORKSPACE/${log_name}" 2>/dev/null || true
        done
    fi
    echo "✓ 日志文件已拉取到: $WORKSPACE/"
fi

# ============================================
# 清理（可选）
# ============================================
if [[ "${CLEANUP_REMOTE:-false}" = "true" ]]; then
    echo ""
    echo "[清理] 删除远程工作目录..."
    remote_exec "rm -rf ${CLUSTER_WORKDIR}"
    echo "✓ 远程工作目录已清理"
fi

# ============================================
# 总结
# ============================================
echo ""
echo "========================================"
echo "执行完成"
echo "========================================"
echo "本地结果: $WORKSPACE/output/"
echo "本地日志: $WORKSPACE/*.log"
if [[ "$TEST_SUCCESS" = true ]]; then
    echo "状态: ✓ 成功"
    exit 0
else
    echo "状态: ✗ 失败"
    exit 1
fi
