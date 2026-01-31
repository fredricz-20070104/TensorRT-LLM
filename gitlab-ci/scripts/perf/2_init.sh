#!/bin/bash
#
# Perf Step 2: Initialize Configuration
# Auto-fetch Docker image and wheel URL if not provided
#

set -eo pipefail

# ============================================================
# Script Directory
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ============================================================
# Parameters
# ============================================================
GPU="${1:-$GPU}"

# ============================================================
# Main Logic
# ============================================================
export ARCH="aarch64"

# Auto-fetch Docker image if not provided
if [ -z "${DOCKER_IMAGE:-}" ] || [ "$DOCKER_IMAGE" = "" ]; then
    echo "=== Auto-fetching Docker image from GitHub ==="
    chmod +x "$SCRIPT_DIR/../utilities/get_docker_image.sh"
    "$SCRIPT_DIR/../utilities/get_docker_image.sh" --repo "${TRT_LLM_REPO}" --branch "${TRT_LLM_BRANCH}" --arch "${ARCH}"
    
    if [ -f "docker_image.txt" ]; then
        DOCKER_IMAGE=$(cat docker_image.txt)
        mv docker_image.txt "docker_image_${GPU}.txt"
        echo "✓ Docker image: $DOCKER_IMAGE"
    else
        echo "ERROR: Failed to fetch Docker image"
        exit 1
    fi
else
    echo "Using provided DOCKER_IMAGE: $DOCKER_IMAGE"
    echo "$DOCKER_IMAGE" > "docker_image_${GPU}.txt"
fi

# Auto-fetch wheel URL if install mode is wheel and not provided
if [ "${INSTALL_MODE}" = "wheel" ]; then
    if [ -z "${WHEEL_URL:-}" ] || [ "$WHEEL_URL" = "" ]; then
        echo "=== Auto-fetching wheel URL from Artifactory ==="
        
        if [[ "$TRT_LLM_BRANCH" == *"release"* ]]; then
            ARTIFACTORY_BRANCH="release"
        else
            ARTIFACTORY_BRANCH="main"
        fi
        
        chmod +x "$SCRIPT_DIR/../utilities/install_trtllm.sh"
        "$SCRIPT_DIR/../utilities/install_trtllm.sh" --branch "${ARTIFACTORY_BRANCH}" --arch "${ARCH}"
        
        if [ -f "download_url.txt" ]; then
            WHEEL_URL=$(cat download_url.txt)
            mv download_url.txt "download_url_${GPU}.txt"
            echo "✓ Wheel URL: $WHEEL_URL"
        else
            echo "ERROR: Failed to fetch wheel URL"
            exit 1
        fi
    else
        echo "Using provided WHEEL_URL: $WHEEL_URL"
        echo "$WHEEL_URL" > "download_url_${GPU}.txt"
    fi
fi

# Create config file
export CONFIG_FILE="config_${GPU}.env"
echo "GPU=\"${GPU}\"" > "$CONFIG_FILE"
echo "CLUSTER_WORKDIR=\"${CLUSTER_WORKDIR}\"" >> "$CONFIG_FILE"
echo "CLUSTER_ACCOUNT=\"${CLUSTER_ACCOUNT}\"" >> "$CONFIG_FILE"
echo "CLUSTER_PARTITION=\"${CLUSTER_PARTITION}\"" >> "$CONFIG_FILE"
echo "CLUSTER_STORAGE=\"${CLUSTER_STORAGE}\"" >> "$CONFIG_FILE"
echo "CLUSTER_LLM_DATA=\"${CLUSTER_LLM_DATA}\"" >> "$CONFIG_FILE"
echo "CCACHE_DIR=\"${CCACHE_DIR}\"" >> "$CONFIG_FILE"
echo "HOST=\"${HOST}\"" >> "$CONFIG_FILE"
echo "BASE_SRUN=\"${BASE_SRUN}\"" >> "$CONFIG_FILE"
echo "MPI_TYPE=\"${MPI_TYPE}\"" >> "$CONFIG_FILE"
echo "ARCH=\"${ARCH}\"" >> "$CONFIG_FILE"
echo "DOCKER_IMAGE=\"${DOCKER_IMAGE}\"" >> "$CONFIG_FILE"
echo "WHEEL_URL=\"${WHEEL_URL:-}\"" >> "$CONFIG_FILE"
echo "INSTALL_MODE=\"${INSTALL_MODE}\"" >> "$CONFIG_FILE"
# Perf test specific config
echo "TEST_LIST=\"${TEST_LIST:-}\"" >> "$CONFIG_FILE"
echo "TEST_SUITE=\"${TEST_SUITE:-}\"" >> "$CONFIG_FILE"
echo "SPLITS=\"${SPLITS:-0}\"" >> "$CONFIG_FILE"
echo "GROUP=\"${GROUP:-0}\"" >> "$CONFIG_FILE"
echo "TIMEOUT=\"${TIMEOUT:-7200}\"" >> "$CONFIG_FILE"

cat "$CONFIG_FILE"
