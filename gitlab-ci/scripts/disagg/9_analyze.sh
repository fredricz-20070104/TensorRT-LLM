#!/bin/bash
#
# Disagg Step 9: Analyze - Analyze Performance Results
# Parse results and upload to database
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
echo "=== Analyzing performance results (${GPU}) ==="

FOREST_DIR="forest_${GPU}"
OUTPUT_DIR="${REPORT_DIR:-output}"

if [ ! -d "$FOREST_DIR" ]; then
    echo "ERROR: $FOREST_DIR directory not found!"
    exit 1
fi

# Determine TRT-LLM version
if [ -n "${TRT_LLM_VERSION:-}" ]; then
    echo "✓ Using version from config: $TRT_LLM_VERSION"
else
    # Fallback to trtllm_version.txt
    version_file=$(find "${CI_PROJECT_DIR:-.}" -name 'trtllm_version.txt' -type f | head -1)
    if [ -n "$version_file" ]; then
        version_content=$(cat "$version_file")
        TRT_LLM_VERSION=$(echo "$version_content" | grep -oP 'version:\s*\K[\d.]+[\w\-]*' | head -1 || echo "${LLM_VERSION}")
        echo "✓ Found version from trtllm_version.txt: $TRT_LLM_VERSION"
    else
        TRT_LLM_VERSION="${LLM_VERSION}"
        echo "✓ Using default LLM_VERSION: $TRT_LLM_VERSION"
    fi
fi
echo "TRT-LLM Version: $TRT_LLM_VERSION"

# Setup Python virtual environment
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install pandas pymysql pyyaml requests

# Upload to database if enabled
if [ "${WRITE_PERF_DB}" = "true" ]; then
    echo "=== Uploading performance data to database ==="
    
    # Use merged directory if exists (parallel runs), otherwise use single output
    if [ -d "${OUTPUT_DIR}/merged" ]; then
        echo "Using merged files from parallel runs..."
        RESULT_DIR="${OUTPUT_DIR}/merged"
        result_csv="${RESULT_DIR}/merged_perf_results.csv"
        properties="${RESULT_DIR}/merged_properties.csv"
        junit_xml="${RESULT_DIR}/merged_results.xml"
    else
        echo "Using single case files from output directory..."
        RESULT_DIR="${OUTPUT_DIR}"
        result_csv=$(find "${OUTPUT_DIR}/" -name "perf_script_test_results.csv" | tail -1)
        properties=$(find "${OUTPUT_DIR}/" -name "session_properties.csv" | tail -1)
        junit_xml=$(find "${OUTPUT_DIR}/" -name "results.xml" | tail -1)
    fi
    
    # System info files - check merged directory first, then individual tmp_* directories
    if [ -f "${RESULT_DIR}/gpu.txt" ]; then
        gpu_txt="${RESULT_DIR}/gpu.txt"
    else
        gpu_txt=$(find "${OUTPUT_DIR}/" -name "gpu.txt" -type f 2>/dev/null | head -1)
    fi
    
    if [ -f "${RESULT_DIR}/cpu.txt" ]; then
        cpu_txt="${RESULT_DIR}/cpu.txt"
    else
        cpu_txt=$(find "${OUTPUT_DIR}/" -name "cpu.txt" -type f 2>/dev/null | head -1)
    fi
    
    if [ -f "${RESULT_DIR}/driver.txt" ]; then
        driver_txt="${RESULT_DIR}/driver.txt"
    else
        driver_txt=$(find "${OUTPUT_DIR}/" -name "driver.txt" -type f 2>/dev/null | head -1)
    fi
    
    # Display found files
    echo "Searching for result files in: ${OUTPUT_DIR}/"
    echo "  - Result CSV: ${result_csv:-NOT FOUND}"
    echo "  - Properties: ${properties:-NOT FOUND}"
    echo "  - JUnit XML: ${junit_xml:-NOT FOUND}"
    echo "  - GPU info: ${gpu_txt:-NOT FOUND}"
    echo "  - CPU info: ${cpu_txt:-NOT FOUND}"
    echo "  - Driver info: ${driver_txt:-NOT FOUND}"
    
    if [ -f "$result_csv" ]; then
        echo "✓ Found performance results, uploading to database..."
        
        gpu_name=$(cat "$gpu_txt")
        cpu_name=$(cat "$cpu_txt")
        driver_version=$(cat "$driver_txt")
        
        echo ""
        echo "=== trt_perf_parser.py parameters ==="
        echo "  --source-metric-csv=$result_csv"
        echo "  --source-properties=$properties"
        echo "  --junit-xml=$junit_xml"
        echo "  --gpu=$gpu_name"
        echo "  --cpu=$cpu_name"
        echo "  --driver=$driver_version"
        echo "  --cuda=${CUDA_VERSION}"
        echo "  --tensorrt=${TENSORRT_VERSION}"
        echo "  --trtllm=$TRT_LLM_VERSION"
        echo "  --commit=${COMMIT_HASH}"
        echo "  --commit-time=${COMMIT_TIME}"
        echo "  --notes=Test:${GPU}-${TRT_LLM_BRANCH}-${TEST_MODEL}"
        echo "  --link=${CI_PIPELINE_URL}"
        echo "======================================"
        echo ""
        
        .venv/bin/python "$FOREST_DIR/scripts/trt_perf_parser.py" \
            --source-metric-csv="$result_csv" \
            --source-properties="$properties" \
            --junit-xml="$junit_xml" \
            --gpu="$gpu_name" \
            --cpu="$cpu_name" \
            --driver="$driver_version" \
            --cuda="${CUDA_VERSION}" \
            --tensorrt="${TENSORRT_VERSION}" \
            --trtllm="$TRT_LLM_VERSION" \
            --commit="${COMMIT_HASH}" \
            --commit-time="${COMMIT_TIME}" \
            --notes="Test:${GPU}-${TRT_LLM_BRANCH}-${TEST_MODEL}" \
            --link="${CI_PIPELINE_URL}"
        
        echo "✓ Performance data uploaded to database"
    else
        echo "⚠ Warning: Performance CSV not found, skipping database upload"
        echo "  This may be because:"
        echo "  - Tests failed before generating results"
        echo "  - Output directory is incorrect"
        echo "  - Results were not collected properly"
        
        # Show what's actually in the output directory
        echo ""
        echo "Files in output directory:"
        find "${OUTPUT_DIR}/" -type f 2>/dev/null | head -20 || echo "  (empty or not accessible)"
    fi
else
    echo "⚠ Skipping database upload (WRITE_PERF_DB=${WRITE_PERF_DB})"
fi
