#!/bin/bash
#
# Disagg Step 5: Build - Build Wheel from Source
# Only runs if INSTALL_MODE=source
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
CONFIG_FILE="${2:-config_final_${GPU}.env}"

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
if [ "$INSTALL_MODE" = "source" ]; then
    echo "=== Building wheel from source on ${GPU} ==="
    
    SRUN_CMD="${BASE_SRUN} ${BASE_DOCKER},${CCACHE_DIR}:/ccache"
    BUILD_CMD="${SRUN_CMD} --overlap --cpu-bind=none --container-writable bash -c 'export CCACHE_DIR=/ccache; python3 /code/tensorrt_llm/scripts/build_wheel.py --trt_root /usr/local/tensorrt --use_ccache --benchmarks --clean'"
    
    remote_exec "$BUILD_CMD"
else
    echo "Skipping build (install_mode: $INSTALL_MODE)"
fi
