#!/bin/bash
#
# Disagg Step 7: Test - Run Disaggregated Multi-node Tests
# Execute the main test suite
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
echo "=== Running disaggregated multi-node tests (${GPU}) ==="

remote_mkdir "${CLUSTER_WORKDIR}/scripts"

# Upload test scripts
remote_copy "$SCRIPT_DIR/../utilities/run_disagg_test.sh" \
            "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"
remote_copy "$SCRIPT_DIR/../utilities/merge_junit_xml.py" \
            "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/scripts/"

remote_exec "chmod +x ${CLUSTER_WORKDIR}/scripts/run_disagg_test.sh"

# Handle TEST_LIST: Save to file if it's multiline or contains nodeIds
if [ -n "${DISAGG_MULTI_NODE_TEST_LIST}" ]; then
    # Check if it's already a file path (ends with .txt)
    if [[ "${DISAGG_MULTI_NODE_TEST_LIST}" == *.txt ]]; then
        # It's a testlist file, pass as-is
        TEST_LIST_ARG="${DISAGG_MULTI_NODE_TEST_LIST}"
    else
        # It's nodeIds (single or multiline), save to temp file
        echo "=== Saving TEST_LIST to file (multiline nodeIds detected) ==="
        TEST_LIST_FILE="test_list_${GPU}.txt"
        echo "${DISAGG_MULTI_NODE_TEST_LIST}" > "${TEST_LIST_FILE}"
        echo "Saved to: ${TEST_LIST_FILE}"
        echo "Content:"
        cat "${TEST_LIST_FILE}"
        echo ""
        
        # Upload to cluster
        remote_copy "${TEST_LIST_FILE}" "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/test_list.txt"
        TEST_LIST_ARG="${CLUSTER_WORKDIR}/test_list.txt"
    fi
else
    TEST_LIST_ARG=""
fi

# Run tests
remote_script "${CLUSTER_WORKDIR}/scripts/run_disagg_test.sh" \
    "${CLUSTER_WORKDIR}" \
    "${CLUSTER_LLM_DATA}" \
    "${CLUSTER_STORAGE}" \
    "${CLUSTER_PARTITION}" \
    "${CLUSTER_ACCOUNT}" \
    "${DOCKER_IMAGE}" \
    "${TEST_MODEL}" \
    "${TEST_LIST_ARG}" \
    "${INSTALL_MODE}" \
    "${GPU}" \
    "${TRT_LLM_BRANCH}" \
    "${FAILED_RERUN}"

echo "✓ Test execution completed"
