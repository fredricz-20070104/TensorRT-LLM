#!/bin/bash
#
# Disagg Step 8: Artifacts - Collect Test Artifacts
# Download results and package them
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
echo "=== Collecting artifacts (${GPU}) ==="

rm -rf "${REPORT_DIR:-output}"
mkdir -p "${REPORT_DIR:-output}"

# Download artifacts from remote cluster
if remote_copy "${REMOTE_PREFIX}${CLUSTER_WORKDIR}/${REPORT_DIR:-output}/" ./ 2>&1; then
    echo "✓ SCP download succeeded"
    file_count=$(find "${REPORT_DIR:-output}/" -type f 2>/dev/null | wc -l)
    echo "Downloaded files: $file_count"
    
    # Merge results if there are multiple output directories (parallel runs)
    echo ""
    echo "=== Merging performance test results ==="
    MERGE_SCRIPT="$SCRIPT_DIR/../utilities/merge_perf_results.sh"
    if [ -f "$MERGE_SCRIPT" ]; then
        chmod +x "$MERGE_SCRIPT"
        bash "$MERGE_SCRIPT" "${REPORT_DIR:-output}" || echo "Warning: Merge script returned non-zero"
    else
        echo "Warning: merge_perf_results.sh not found, skipping merge"
    fi
    
    # Only cleanup if download succeeded
    echo "Cleaning up remote directory..."
    remote_exec "rm -rf ${CLUSTER_WORKDIR}" || true
    echo "✓ Remote directory cleaned"
else
    echo "✗ SCP download failed"
    echo "⚠️  Remote directory preserved for debugging: ${CLUSTER_WORKDIR}"
    remote_exec "ls -laR ${CLUSTER_WORKDIR}/${REPORT_DIR:-output}/ | head -50" || true
fi

# Package results
tar -czf "perf_results_csv_${GPU}.tar.gz" "${REPORT_DIR:-output}"/tmp*/perf_*.csv 2>/dev/null || true
tar -czf "slurm_test_logs_${GPU}.tar.gz" "${REPORT_DIR:-output}"/tmp*/slurm_logs/ 2>/dev/null || true

echo "✓ Artifacts collected successfully"

# ============================================================
# Upload to Artifactory (optional)
# ============================================================
if [ "${UPLOAD_TO_ARTIFACT:-false}" = "true" ]; then
    echo ""
    echo "================================================"
    echo "📤 Uploading artifacts to Artifactory (${GPU})"
    echo "================================================"
    
    ARTIFACTORY_SCRIPT="$SCRIPT_DIR/../utilities/artifactory_manager.sh"
    chmod +x "$ARTIFACTORY_SCRIPT"
    
    # Build metadata
    PROPS="gpu=${GPU};pipeline_id=${CI_PIPELINE_ID};commit=${COMMIT_HASH:-unknown}"
    PROPS="${PROPS};branch=${TRT_LLM_BRANCH};test_model=${TEST_MODEL// /_}"
    PROPS="${PROPS};trtllm_version=${TRT_LLM_VERSION:-unknown}"
    PROPS="${PROPS};cuda=${CUDA_VERSION};tensorrt=${TENSORRT_VERSION}"
    
    ARTIFACT_PATH="trtllm/disagg_test/${GPU}/${CI_PIPELINE_ID}"
    
    echo "Target: ${ARTIFACT_PATH}"
    echo ""
    
    # Upload files
    [ -f "perf_results_csv_${GPU}.tar.gz" ] && \
        "$ARTIFACTORY_SCRIPT" upload "perf_results_csv_${GPU}.tar.gz" "${ARTIFACT_PATH}/results" "${PROPS};type=perf_csv" || true
    
    [ -f "slurm_test_logs_${GPU}.tar.gz" ] && \
        "$ARTIFACTORY_SCRIPT" upload "slurm_test_logs_${GPU}.tar.gz" "${ARTIFACT_PATH}/logs" "${PROPS};type=slurm_logs" || true
    
    junit_xml=$(find "${REPORT_DIR:-output}/" -name "results.xml" 2>/dev/null | head -1)
    if [ -f "$junit_xml" ]; then
        cp "$junit_xml" "junit_results_${GPU}.xml"
        "$ARTIFACTORY_SCRIPT" upload "junit_results_${GPU}.xml" "${ARTIFACT_PATH}/results" "${PROPS};type=junit_xml" || true
    fi
    
    [ -f "config_final_${GPU}.env" ] && \
        "$ARTIFACTORY_SCRIPT" upload "config_final_${GPU}.env" "${ARTIFACT_PATH}/config" "${PROPS};type=config" || true
    
    echo ""
    echo "✓ Upload complete"
    echo "🔗 Browse: https://artifactory.nvidia.com/ui/repos/tree/General/${REPO_NAME:-sw-tensorrt-llm-qa-generic-local}/${ARTIFACT_PATH}"
else
    echo ""
    echo "⚠ Artifactory upload skipped (UPLOAD_TO_ARTIFACT=${UPLOAD_TO_ARTIFACT:-false})"
fi
