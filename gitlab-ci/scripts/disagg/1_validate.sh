#!/bin/bash
#
# Disagg Step 1: Validate Configuration
# Display all configuration variables for the current GPU
#

set -eo pipefail

# ============================================================
# Parameters
# ============================================================
GPU="${1:-$GPU}"

# ============================================================
# Main Logic
# ============================================================
echo "=== ${GPU} Configuration ==="
echo ""
echo "--- Basic Info ---"
echo "GPU=$GPU"
echo "RUNNER_TAG=${RUNNER_TAG:-}"
echo "HOST=${HOST:-}"
echo "Pipeline ID=${CI_PIPELINE_ID:-}"
echo ""
echo "--- User Info ---"
echo "GITLAB_USER_LOGIN=${GITLAB_USER_LOGIN:-}"
echo "GITLAB_USER_NAME=${GITLAB_USER_NAME:-}"
echo "GITLAB_USER_EMAIL=${GITLAB_USER_EMAIL:-}"
echo "USER=${USER:-}"
echo "CLUSTER_USERNAME=${CLUSTER_USERNAME:-}"
echo ""
echo "--- Code & Branch ---"
echo "TRT_LLM_BRANCH=${TRT_LLM_BRANCH:-}"
echo "TRT_LLM_REPO=${TRT_LLM_REPO:-}"
echo "FORK_GITHUB=${FORK_GITHUB:-}"
echo ""
echo "--- Test Configuration ---"
echo "INSTALL_MODE=${INSTALL_MODE:-}"
echo "TEST_MODEL=${TEST_MODEL:-}"
echo "DISAGG_MULTI_NODE_TEST_LIST=${DISAGG_MULTI_NODE_TEST_LIST:-}"
echo "FAILED_RERUN=${FAILED_RERUN:-}"
echo ""
echo "--- Versions ---"
echo "LLM_VERSION=${LLM_VERSION:-}"
echo "TENSORRT_VERSION=${TENSORRT_VERSION:-}"
echo "CUDA_VERSION=${CUDA_VERSION:-}"
echo ""
echo "--- Resources ---"
echo "CLUSTER_PARTITION=${CLUSTER_PARTITION:-}"
echo "CLUSTER_ACCOUNT=${CLUSTER_ACCOUNT:-}"
echo "CLUSTER_STORAGE=${CLUSTER_STORAGE:-}"
echo "CLUSTER_LLM_DATA=${CLUSTER_LLM_DATA:-}"
echo "CLUSTER_WORKDIR=${CLUSTER_WORKDIR:-}"
echo "CCACHE_DIR=${CCACHE_DIR:-}"
echo ""
echo "--- Docker & Wheel ---"
echo "DOCKER_IMAGE=${DOCKER_IMAGE:-<auto-fetch>}"
echo "WHEEL_URL=${WHEEL_URL:-<auto-fetch>}"
echo ""
echo "--- Execution Control ---"
echo "RUN_GB200=${RUN_GB200:-}"
echo "RUN_GB300=${RUN_GB300:-}"
echo "WRITE_PERF_DB=${WRITE_PERF_DB:-}"
echo "TEST_TIME=${TEST_TIME:-}"
echo "TIMEOUT=${TIMEOUT:-}"
