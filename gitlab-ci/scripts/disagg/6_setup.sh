#!/bin/bash
#
# Disagg Step 6: Setup - Setup Poetry Environment
# Install dependencies and prepare test environment
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
echo "=== Setting up disagg environment (poetry) on ${GPU} ==="

remote_mkdir "${CLUSTER_WORKDIR}/scripts"
remote_copy "$SCRIPT_DIR/../utilities/setup_poetry.sh" \
            "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"

remote_script "${CLUSTER_WORKDIR}/scripts/setup_poetry.sh"

echo "✓ Setup completed"
