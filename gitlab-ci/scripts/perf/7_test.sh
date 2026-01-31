#!/bin/bash
#
# Perf Step 7: Test - Run Single Node Performance Tests
# Execute pytest-based performance test suite
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

# Save environment variables before sourcing config (parallel: matrix sets these)
ENV_SPLITS="${SPLITS:-}"
ENV_GROUP="${GROUP:-}"

source "$CONFIG_FILE"

# Override with environment variables if set (parallel: matrix takes precedence)
# Config file values are from init stage which doesn't have parallel: matrix
if [ -n "$ENV_SPLITS" ]; then
    SPLITS="$ENV_SPLITS"
fi
if [ -n "$ENV_GROUP" ]; then
    GROUP="$ENV_GROUP"
fi

echo "SPLITS=$SPLITS, GROUP=$GROUP"

# ============================================================
# Main Logic
# ============================================================
echo "=== Running single node performance tests (${GPU}) ==="

remote_mkdir "${CLUSTER_WORKDIR}/scripts"

# Upload test scripts
remote_copy "$SCRIPT_DIR/../utilities/run_perf_test.sh" \
            "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"

remote_exec "chmod +x ${CLUSTER_WORKDIR}/scripts/run_perf_test.sh"

# Run single node performance tests
remote_script "${CLUSTER_WORKDIR}/scripts/run_perf_test.sh" \
    "${CLUSTER_WORKDIR}" \
    "${CLUSTER_LLM_DATA}" \
    "${CLUSTER_STORAGE}" \
    "${CLUSTER_PARTITION}" \
    "${CLUSTER_ACCOUNT}" \
    "${DOCKER_IMAGE}" \
    "${TEST_LIST:-qa/perf}" \
    "${TEST_SUITE:-}" \
    "${INSTALL_MODE}" \
    "${GPU}" \
    "${TIMEOUT:-7200}" \
    "${SPLITS:-0}" \
    "${GROUP:-0}" \
    "${TEST_TIME:-4:00:00}"

echo "✓ Single node performance test execution completed"
