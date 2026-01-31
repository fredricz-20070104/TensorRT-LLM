#!/bin/bash
#
# 完整性检查脚本
# 验证所有必要文件是否存在
#

echo "========================================="
echo "jenkins_test 目录完整性检查"
echo "========================================="
echo ""

PASS=0
FAIL=0

check_file() {
    if [ -f "$1" ]; then
        echo "✓ $1"
        ((PASS++))
    else
        echo "✗ $1 (缺失)"
        ((FAIL++))
    fi
}

check_executable() {
    if [ -x "$1" ]; then
        echo "✓ $1 (可执行)"
        ((PASS++))
    else
        echo "✗ $1 (不可执行)"
        ((FAIL++))
    fi
}

echo "检查核心文件..."
echo "-------------------"
check_file "Perf_Test.groovy"
check_file "scripts/calculate_hardware_nodes.py"
check_executable "scripts/calculate_hardware_nodes.py"
check_executable "scripts/deploy.sh"

echo ""
echo "检查主要文档..."
echo "-------------------"
check_file "README.md"
check_file "DEPLOYMENT.md"
check_file "VERSION.md"
check_file "STRUCTURE.md"
check_file "SUMMARY.md"

echo ""
echo "检查详细文档..."
echo "-------------------"
check_file "docs/ARCHITECTURE_FINAL.md"
check_file "docs/SOLUTION_SUMMARY.md"
check_file "docs/README_PERF_TESTS.md"
check_file "docs/QUICK_REFERENCE.md"
check_file "docs/TESTLIST_EXPLANATION.md"

echo ""
echo "检查其他文件..."
echo "-------------------"
check_file ".gitignore"

echo ""
echo "========================================="
echo "检查结果"
echo "========================================="
echo "通过: $PASS"
echo "失败: $FAIL"
echo ""

if [ $FAIL -eq 0 ]; then
    echo "✓ 所有文件检查通过！"
    echo ""
    echo "下一步:"
    echo "  1. 阅读 README.md"
    echo "  2. 运行 ./scripts/deploy.sh <GitLab 仓库地址>"
    echo "  3. 在 Jenkins 中配置 Pipeline"
    echo ""
    exit 0
else
    echo "✗ 有 $FAIL 个文件缺失或权限不正确"
    echo "请检查并修复"
    echo ""
    exit 1
fi
