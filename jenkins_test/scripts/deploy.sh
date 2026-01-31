#!/bin/bash
#
# 快速部署脚本 - 将 jenkins_test 部署到独立的 GitLab 仓库
#

set -e

echo "========================================="
echo "TensorRT-LLM 性能测试框架 - 部署脚本"
echo "========================================="
echo ""

# 检查参数
if [ $# -ne 1 ]; then
    echo "用法: $0 <GitLab 仓库地址>"
    echo ""
    echo "示例:"
    echo "  $0 https://gitlab.com/your-org/trtllm-perf-test.git"
    echo ""
    exit 1
fi

GITLAB_REPO="$1"

echo "目标仓库: $GITLAB_REPO"
echo ""

# 检查是否已经是 Git 仓库
if [ -d ".git" ]; then
    echo "警告: 当前目录已经是 Git 仓库"
    read -p "是否要重新初始化? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "取消部署"
        exit 0
    fi
    rm -rf .git
fi

# 初始化 Git 仓库
echo "1. 初始化 Git 仓库..."
git init

# 添加所有文件
echo "2. 添加文件..."
git add .

# 提交
echo "3. 创建初始提交..."
git commit -m "Initial commit: TensorRT-LLM 性能测试框架

组件:
- Perf_Test.groovy: Jenkins Pipeline 主文件
- calculate_hardware_nodes.py: 节点计算工具
- 完整的文档和使用指南

特性:
- 自动拉取 TensorRT-LLM 依赖
- 智能计算硬件节点需求
- 自动验证节点数匹配
- 复用 L0 submit.py 逻辑
"

# 添加远程仓库
echo "4. 添加远程仓库..."
git remote add origin "$GITLAB_REPO"

# 推送到 GitLab
echo "5. 推送到 GitLab..."
read -p "是否现在推送到 GitLab? (y/N): " push_now

if [ "$push_now" = "y" ] || [ "$push_now" = "Y" ]; then
    git push -u origin main
    echo ""
    echo "✓ 推送成功!"
else
    echo ""
    echo "跳过推送。你可以稍后手动推送:"
    echo "  git push -u origin main"
fi

echo ""
echo "========================================="
echo "部署完成！"
echo "========================================="
echo ""
echo "下一步:"
echo "  1. 在 Jenkins 中创建新 Pipeline"
echo "  2. 配置 SCM:"
echo "     - Repository URL: $GITLAB_REPO"
echo "     - Script Path: Perf_Test.groovy"
echo "  3. 运行 Dry Run 测试"
echo ""
echo "详细说明请查看 DEPLOYMENT.md"
echo ""
