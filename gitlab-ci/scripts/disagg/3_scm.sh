#!/bin/bash
#
# Disagg Step 3: SCM - Clone Repositories
# Clone forest repository and update install mode if needed
#

set -eo pipefail

# ============================================================
# Script Directory
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
echo "=== Cloning repositories for ${GPU} ==="

# Clone forest repository
git clone --depth 1 --branch main \
    "https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab-master.nvidia.com/dlswqa/tensorrt/forest.git" \
    "forest_${GPU}"

# Update install mode if wheel URL is provided
if [ -n "${WHEEL_URL:-}" ]; then
    echo "INSTALL_MODE=wheel" >> "$CONFIG_FILE"
fi

echo "✓ SCM step completed"
