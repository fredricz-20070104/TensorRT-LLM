#!/bin/bash
#
# Disagg Step 4: Sync - Sync Data to Cluster
# Clone TensorRT-LLM, download wheel, convert Docker to .sqsh
#

set -eo pipefail

# ============================================================
# Script Directory & Load Remote Library
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/remote.sh"

# ============================================================
# Parameters
# ============================================================
GPU="${1:-$GPU}"
CONFIG_FILE="${2:-config_${GPU}.env}"

# ============================================================
# Load Configuration
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

# ============================================================
# Main Logic
# ============================================================
echo "=== Syncing data to remote cluster (${GPU}) ==="

# Step 1: Create directories
remote_mkdir "${CLUSTER_WORKDIR}/root"
remote_mkdir "${CCACHE_DIR}"

# Step 2: Clone TensorRT-LLM
if [ "${FORK_GITHUB}" = "true" ]; then
    GIT_URL="git@github.com:${TRT_LLM_REPO}"
else
    GIT_URL="ssh://git@gitlab-master.nvidia.com:12051/${TRT_LLM_REPO}"
fi

if [ "$INSTALL_MODE" = "none" ] || [ "$INSTALL_MODE" = "wheel" ]; then
    CLONE_MODE='sparse'
else
    CLONE_MODE='full'
fi

remote_mkdir "${CLUSTER_WORKDIR}/scripts"
remote_copy "$SCRIPT_DIR/../utilities/clone_tensorrt_llm.sh" \
            "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"

remote_script "${CLUSTER_WORKDIR}/scripts/clone_tensorrt_llm.sh" \
              "${CLUSTER_WORKDIR}" "${GIT_URL}" "${TRT_LLM_BRANCH}" "${CLONE_MODE}"

# Extract commit info
COMMIT_HASH=$(remote_exec "cd ${CLUSTER_WORKDIR}/tensorrt_llm && git rev-parse --short HEAD")
echo "COMMIT_HASH=\"${COMMIT_HASH}\"" >> "$CONFIG_FILE"

COMMIT_TIME=$(remote_exec "cd ${CLUSTER_WORKDIR}/tensorrt_llm && git show -s --date=format:'%Y-%m-%d %H:%M:%S' --format=%cd || echo 'unknown'")
echo "COMMIT_TIME=\"${COMMIT_TIME}\"" >> "$CONFIG_FILE"

TRT_LLM_VERSION=$(remote_exec "cd ${CLUSTER_WORKDIR}/tensorrt_llm && grep -oP '__version__\s*=\s*\\\"\\K[^\\\"]+' tensorrt_llm/version.py || echo ''")
if [ -n "$TRT_LLM_VERSION" ]; then
    echo "TRT_LLM_VERSION=\"${TRT_LLM_VERSION}\"" >> "$CONFIG_FILE"
    echo "✓ Found TRT-LLM version from version.py: ${TRT_LLM_VERSION}"
else
    echo "⚠ Could not extract version from version.py"
fi

# Step 3: Download wheel if needed
if [ "$INSTALL_MODE" = "wheel" ]; then
    if [ -n "${WHEEL_URL:-}" ] && [ "$WHEEL_URL" != "" ]; then
        remote_copy "$SCRIPT_DIR/../utilities/download_wheel.sh" \
                    "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"
        remote_script "${CLUSTER_WORKDIR}/scripts/download_wheel.sh" \
                      "${CLUSTER_WORKDIR}" "${WHEEL_URL}"
    fi
fi

# Step 4: Convert Docker image to .sqsh if needed
if [[ "$DOCKER_IMAGE" != *.sqsh ]]; then
    # Try to extract timestamp pattern (e.g., 202601011103-9818)
    IMAGE_TAG=$(echo "$DOCKER_IMAGE" | grep -oP '\d{12,14}-\d{4}' | tail -1 || echo "")
    
    # If not found, try to extract release pattern (e.g., b979a02-release_1.2-1492)
    if [ -z "$IMAGE_TAG" ]; then
        IMAGE_TAG=$(echo "$DOCKER_IMAGE" | grep -oP '[a-z0-9]+-release_[\d.]+-\d+' | tail -1 || echo "")
    fi
    
    # If still not found, use CI_PIPELINE_ID as fallback
    if [ -z "$IMAGE_TAG" ]; then
        IMAGE_TAG="${CI_PIPELINE_ID}"
    fi
    
    SQSH_FILENAME="tensorrt-llm-${IMAGE_TAG}.sqsh"
    SQSH_PATH="${CLUSTER_STORAGE}/${SQSH_FILENAME}"
    
    if remote_file_exists "${SQSH_PATH}"; then
        echo "✓ .sqsh file already exists"
    else
        # Determine enroot partition
        if [ "${GPU}" = "GB200" ]; then
            ENROOT_PARTITION="cpu_datamover"
        elif [ "${GPU}" = "GB200_LYRIS" ]; then
            ENROOT_PARTITION="gb200"
        elif [ "${GPU}" = "GB300" ]; then
            ENROOT_PARTITION="gb300"
        fi
        
        # Upload and run enroot-import
        ENROOT_SCRIPT="${CLUSTER_WORKDIR}/enroot-import"
        if ! remote_file_exists "${ENROOT_SCRIPT}"; then
            remote_copy "enroot-import" "${REMOTE_PREFIX}${ENROOT_SCRIPT}"
        fi
        remote_exec "chmod +x ${ENROOT_SCRIPT}"
        
        JOB_ID=$(remote_exec "cd ${CLUSTER_STORAGE} && ${ENROOT_SCRIPT} --partition ${ENROOT_PARTITION} -o ${SQSH_FILENAME} ${DOCKER_IMAGE}")
        
        if [ -n "$JOB_ID" ] && [[ "$JOB_ID" =~ ^[0-9]+$ ]]; then
            echo "Waiting for enroot job ${JOB_ID} to complete..."
            while remote_exec "squeue -j ${JOB_ID} 2>/dev/null | grep -q ${JOB_ID}"; do
                sleep 180  # 3 minutes
            done
        fi
    fi
    
    DOCKER_IMAGE="$SQSH_PATH"
    echo "DOCKER_IMAGE=\"${DOCKER_IMAGE}\"" >> "$CONFIG_FILE"
fi

# Step 5: Generate final configuration
export BASE_DOCKER="--container-image=${DOCKER_IMAGE} --container-remap-root --container-mounts=${CLUSTER_WORKDIR}:/code,${CLUSTER_LLM_DATA}:/llm-models,${CLUSTER_WORKDIR}/root:/root"
echo "BASE_DOCKER=\"${BASE_DOCKER}\"" >> "$CONFIG_FILE"

cp "$CONFIG_FILE" "config_final_${GPU}.env"
echo "✓ Created config_final_${GPU}.env with all variables"
