#!/bin/bash
# 从 GitHub 获取 Docker 镜像地址
# 使用方法: ./get_docker_image.sh --repo owner/repo --branch main --arch x86_64

REPO="NVIDIA/TensorRT-LLM"  # 默认仓库
BRANCH="main"
ARCH=$(arch)  # 默认使用当前系统架构

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)
            REPO="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1" >&2
            echo "Usage: $0 [--repo <owner/repo>] [--branch <branch_name>] [--arch <x86_64|aarch64>]" >&2
            exit 1
            ;;
    esac
done

echo "Repository: ${REPO}" >&2
echo "Branch: ${BRANCH}" >&2
echo "Architecture: ${ARCH}" >&2

# 构建 GitHub raw 文件 URL
GITHUB_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/jenkins/current_image_tags.properties"

echo "Fetching from: ${GITHUB_URL}" >&2

# 下载文件
response=$(curl -s -f ${GITHUB_URL})

# 检查是否成功获取
if [[ -z "${response}" ]]; then
    echo "Error: Failed to fetch file from GitHub." >&2
    echo "Please check if the repository '${REPO}' and branch '${BRANCH}' exist and the file is accessible." >&2
    exit 1
fi

# 根据架构选择对应的变量名
if [ "$ARCH" = "aarch64" ]; then
    IMAGE_VAR="LLM_SBSA_DOCKER_IMAGE"
else
    IMAGE_VAR="LLM_DOCKER_IMAGE"
fi

echo "Looking for: ${IMAGE_VAR}" >&2

# 从文件内容中提取对应的镜像地址
docker_image=$(echo "${response}" | grep "^${IMAGE_VAR}=" | cut -d'=' -f2)

# 检查是否找到镜像
if [[ -z "${docker_image}" ]]; then
    echo "Error: Could not find ${IMAGE_VAR} in the properties file." >&2
    exit 1
fi

echo "" >&2
echo "✓ Found Docker image:" >&2
echo "${docker_image}" >&2

# 将结果保存到文件
echo "${docker_image}" > docker_image.txt
echo "" >&2
echo "✓ Image URL saved to: docker_image.txt" >&2

# Output the image to stdout (for capture)
echo "${docker_image}"

