#!/bin/bash
#
# Script to run single node performance tests with pytest
# Based on test_llm_perf_pytest_cluster.sh from trt_jenkins
#
# Usage: run_perf_test.sh <CLUSTER_WORKDIR> <CLUSTER_LLM_DATA> <CLUSTER_STORAGE> \
#                          <CLUSTER_PARTITION> <CLUSTER_ACCOUNT> <DOCKER_IMAGE> \
#                          <TEST_LIST> <TEST_SUITE> <INSTALL_MODE> <GPU> \
#                          <TIMEOUT> <SPLITS> <GROUP> <TEST_TIME>
#

set -e

echo "=========================================="
echo "Single Node Performance Test Runner"
echo "=========================================="

# Parse arguments
CLUSTER_WORKDIR=$1
CLUSTER_LLM_DATA=$2
CLUSTER_STORAGE=$3
CLUSTER_PARTITION=$4
CLUSTER_ACCOUNT=$5
DOCKER_IMAGE=$6
TEST_LIST=$7
TEST_SUITE=$8
INSTALL_MODE_ARG=$9
GPU=${10}
TIMEOUT=${11}
SPLITS=${12}
GROUP=${13}
TEST_TIME=${14:-4:00:00}

# Set defaults
LLM_ROOT="/code/tensorrt_llm"
LLM_MODELS_ROOT="/llm-models"

# Display configuration
echo ""
echo "Configuration:"
echo "  CLUSTER_WORKDIR:   $CLUSTER_WORKDIR"
echo "  CLUSTER_LLM_DATA:  $CLUSTER_LLM_DATA"
echo "  CLUSTER_STORAGE:   $CLUSTER_STORAGE"
echo "  CLUSTER_PARTITION: $CLUSTER_PARTITION"
echo "  CLUSTER_ACCOUNT:   $CLUSTER_ACCOUNT"
echo "  DOCKER_IMAGE:      $DOCKER_IMAGE"
echo "  TEST_LIST:         $TEST_LIST"
echo "  TEST_SUITE:        $TEST_SUITE"
echo "  INSTALL_MODE:      $INSTALL_MODE_ARG"
echo "  GPU:               $GPU"
echo "  TIMEOUT:           $TIMEOUT"
echo "  SPLITS:            $SPLITS"
echo "  GROUP:             $GROUP"
echo "  TEST_TIME:         $TEST_TIME"
echo ""

# Create output directory
TIMESTAMP=$(date +%s%N)
HOSTNAME=$(hostname)
OUTPUT="${CLUSTER_WORKDIR}/output/tmp_${TIMESTAMP}_output_perf_${HOSTNAME}"
mkdir -p "$OUTPUT"

echo "Output directory: $OUTPUT"
echo ""

# ============================================================
# Signal Handler for GitLab CI Cancel
# ============================================================
cleanup_on_cancel() {
    echo ""
    echo "=========================================="
    echo "⚠️  Cancel signal received - terminating"
    echo "=========================================="
    # Cancel any running srun jobs
    scancel -u $USER --name="${CLUSTER_ACCOUNT}-trt:perf" 2>/dev/null || true
    exit 130
}

trap cleanup_on_cancel SIGTERM SIGINT SIGHUP
echo "✓ Signal handler registered"

# ============================================================
# Build srun command
# ============================================================
echo "=== Building srun command ==="

# Container mounts
# Mount llm-models-fredricz as well for symlinks in llm-models-qa to work
LLM_MODELS_FREDRICZ="${CLUSTER_LLM_DATA%/*}/llm-models-fredricz"
CONTAINER_MOUNTS="${CLUSTER_WORKDIR}:/code,${CLUSTER_LLM_DATA}:/llm-models,${LLM_MODELS_FREDRICZ}:/llm-models-fredricz,${CLUSTER_WORKDIR}/root:/root"

# Base srun parameters
SRUN_BASE="srun --mpi=pmix -t ${TEST_TIME} -A ${CLUSTER_ACCOUNT} -N1 -p ${CLUSTER_PARTITION} -J ${CLUSTER_ACCOUNT}-trt:perf"

# Add GPU resources for GB200
if [ "$GPU" = "GB200" ]; then
    SRUN_BASE="${SRUN_BASE} --gres=gpu:4"
fi

# Container parameters
CONTAINER_PARAMS="--container-image=${DOCKER_IMAGE} --container-remap-root --container-mounts=${CONTAINER_MOUNTS} --container-writable"

# ============================================================
# Create inner test script to run inside container
# ============================================================
mkdir -p "${CLUSTER_WORKDIR}/scripts"
INNER_SCRIPT="${CLUSTER_WORKDIR}/scripts/inner_perf_test.sh"

cat > "$INNER_SCRIPT" << 'INNER_EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "Running inside container"
echo "=========================================="

# Arguments passed from outer script
LLM_ROOT="$1"
LLM_MODELS_ROOT="$2"
OUTPUT="$3"
TEST_LIST="$4"
TEST_SUITE="$5"
INSTALL_MODE_ARG="$6"
TIMEOUT="$7"
SPLITS="$8"
GROUP="$9"
CLUSTER_WORKDIR="${10}"

echo "LLM_ROOT: $LLM_ROOT"
echo "LLM_MODELS_ROOT: $LLM_MODELS_ROOT"
echo "OUTPUT: $OUTPUT"

# Unset SLURM variables for single node test
echo "Unsetting SLURM_, PMI_, PMIX_ variables"
for i in $(env | grep ^SLURM_ | cut -d"=" -f 1); do unset -v $i; done
for i in $(env | grep ^PMI_ | cut -d"=" -f 1); do unset -v $i; done
for i in $(env | grep ^PMIX_ | cut -d"=" -f 1); do unset -v $i; done

# Install dependencies
cd ${LLM_ROOT}
echo "Installing dependencies from requirements-dev.txt..."
if [ -f "requirements-dev.txt" ]; then
    pip3 install -r requirements-dev.txt || { echo "Warning: pip install failed"; sleep 5; }
else
    echo "Warning: requirements-dev.txt not found at ${LLM_ROOT}"
    ls -la ${LLM_ROOT}/ | head -20
fi

# Install wheel if in wheel mode
if [ "$INSTALL_MODE_ARG" = "wheel" ]; then
    TRTLLM_WHEEL=$(find "${CLUSTER_WORKDIR}/tensorrt_llm/build/" -name "*.whl" -type f 2>/dev/null | head -1)
    if [ -z "$TRTLLM_WHEEL" ]; then
        TRTLLM_WHEEL=$(find "/code/tensorrt_llm/build/" -name "*.whl" -type f 2>/dev/null | head -1)
    fi
    if [ -n "$TRTLLM_WHEEL" ]; then
        echo "Installing wheel: $TRTLLM_WHEEL"
        pip3 install "$TRTLLM_WHEEL" || sleep 5 || true
    else
        echo "Warning: No wheel found"
    fi
fi

# Install trt-test-db for test list rendering
pip3 install --extra-index-url https://urm-rn.nvidia.com/artifactory/api/pypi/sw-tensorrt-pypi/simple --ignore-installed trt-test-db==1.8.5+bc6df7 || true

# Prepare test command
waive_args="--waives-file=${LLM_ROOT}/tests/integration/test_lists/waives.txt"

model_args=""
if [[ -n "${TEST_SUITE}" && "${TEST_SUITE}" != '' ]]; then
    model_args=" --test-model-suites='${TEST_SUITE}'"
fi
if [[ "${SPLITS}" != "0" ]]; then
    model_args="${model_args} --splits ${SPLITS} --group ${GROUP}"
fi

# Get GPU name
gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader -i 0 2>/dev/null | sed 's/ /_/g' || echo "unknown")

echo "GPU Name: $gpu_name"
echo "TEST_LIST: ${TEST_LIST}"

# Function to get Mako options
getMakoOpts() {
    local get_mako_script="${LLM_ROOT}/tests/integration/defs/sysinfo/get_sysinfo.py"
    local gpu_chip_mapping="gpu_mapping.json"
    
    local list_mako_cmd="python3 ${get_mako_script} --device 0 --chip-mapping-file ${gpu_chip_mapping}"
    
    echo "Scripts to get Mako list, cmd: ${list_mako_cmd}"
    
    turtle_output=$(timeout 30m ${list_mako_cmd} 2>&1) || true
    
    if [[ -z "$turtle_output" ]]; then
        echo "Warning: Mako opts not found"
        MAKO_OPTS="{}"
        return
    fi
    
    local started_mako_opts=false
    local temp_json=$(mktemp)
    echo "{" > $temp_json
    
    local first_item=true
    
    while IFS= read -r line; do
        if $started_mako_opts; then
            if [[ -z "$line" ]]; then
                continue
            fi
            
            if [[ "$line" == *"="* ]]; then
                local param=$(echo "$line" | cut -d'=' -f1)
                local value=$(echo "$line" | cut -d'=' -f2-)
                value=$(echo "$value" | xargs)
                
                if [[ "$value" == "None" || "$value" == "none" ]]; then
                    value="null"
                elif [[ "$value" == "True" || "$value" == "true" ]]; then
                    value="true"
                elif [[ "$value" == "False" || "$value" == "false" ]]; then
                    value="false"
                elif [[ "$value" =~ ^[0-9]+$ ]]; then
                    value=$value
                elif [[ "$value" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    value=$value
                else
                    value="\"$value\""
                fi
                
                if ! $first_item; then
                    echo "," >> $temp_json
                else
                    first_item=false
                fi
                
                echo "\"$param\": $value" >> $temp_json
            fi
        fi
        
        if [[ "$line" == "Mako options:" ]]; then
            started_mako_opts=true
        fi
    done <<< "$turtle_output"
    
    echo "}" >> $temp_json
    
    MAKO_OPTS=$(cat $temp_json)
    rm $temp_json
    
    echo "Test DB Mako opts: ${MAKO_OPTS}"
}

# Function to render test DB (matches original test_llm_perf_pytest_cluster.sh)
renderTestDB() {
    local work_dir=$1
    local test_db_path=$2
    local test_context=$3
    local mako_opts=$4
    
    if [[ "$test_context" == *".yml" || ! "$test_context" == *"."* ]]; then
        test_context=${test_context%%.*}
    fi
    
    if [[ -z "$mako_opts" ]]; then
        echo "Using calculated Mako options"
    else
        echo "Using provided Mako options: ${mako_opts}"
    fi
    
    if [[ -z "$test_db_path" ]]; then
        test_db_path="${work_dir}/tests/integration/test_lists/test-db"
    fi
    
    # Output to OUTPUT directory (writable), not to test_lists directory
    local test_list_output="${OUTPUT}/${test_context}.txt"
    
    local test_db_query_cmd="trt-test-db -d ${test_db_path} --context ${test_context} --test-names --output ${test_list_output} --match-exact '${mako_opts}'"
    
    echo "Render test list from test-db: ${test_db_query_cmd}"
    
    eval $test_db_query_cmd || true
    
    if [ -f "${test_list_output}" ]; then
        echo "Rendered test list:"
        cat ${test_list_output}
    fi
    
    # Set global variable for rendered test list
    TEST_LIST_RENDERED=${test_list_output}
}

# Determine running tests (matches original test_llm_perf_pytest_cluster.sh)
echo "TEST_LIST: ${TEST_LIST}"
if [[ "$TEST_LIST" == *".txt" ]]; then
    # customized test case ending with txt
    running_tests="${TEST_LIST}"
else
    # qa yml test case
    # Parse the test path if it contains a "/" separator
    if [[ "$TEST_LIST" == *"/"* ]]; then
        test_db_path="${LLM_ROOT}/tests/integration/test_lists/${TEST_LIST%%/*}"
        test_db_context="${TEST_LIST#*/}"
    else
        test_db_path="${LLM_ROOT}/tests/integration/test_lists/qa"
        test_db_context="${TEST_LIST}"
    fi
    
    # Get makoOpts and render test DB
    getMakoOpts
    renderTestDB "${LLM_ROOT}" "${test_db_path}" "${test_db_context}" "${MAKO_OPTS}"
    running_tests=${TEST_LIST_RENDERED}
    echo "Using rendered test list: ${running_tests}"
    cat ${running_tests} || true
fi

if [[ "${WORLD_SIZE}" != "" ]]; then
    unset WORLD_SIZE
fi

cd ${LLM_ROOT}/tests/integration/defs

# Add tests directory to PYTHONPATH for test_common module
export PYTHONPATH="${LLM_ROOT}/tests:${PYTHONPATH:-}"

python3 -c "import tensorrt_llm" || (sleep 10 && python3 -c "import tensorrt_llm") || true
python3 -c "import tensorrt_llm" > ${OUTPUT}/trtllm_version.txt 2>&1 || true

echo "********** start to run test suite: $TEST_SUITE"

# pytest command - explicitly specify perf/test_perf.py to override pytest.ini --ignore-glob
# pytest.ini ignores perf/test_perf.py by default, so we must specify it explicitly
test_cmd="pytest perf/test_perf.py -v \
          --test-prefix=${gpu_name} \
          --test-list=${running_tests} \
          ${waive_args} \
          ${model_args} \
          --junit-xml=${OUTPUT}/results.xml \
          --output-dir=${OUTPUT} \
          --perf \
          --perf-log-formats=csv \
          --timeout=${TIMEOUT} \
          -o junit_logging=out-err"

echo "Test command: ${test_cmd}"

export LLM_ROOT=$LLM_ROOT
export LLM_MODELS_ROOT=$LLM_MODELS_ROOT
export SKIP_GPU_CHECK=true

eval ${test_cmd} || true

# Collect system info
echo "Collecting system information..."

# GPU info - try multiple methods
gpu_info=$(nvidia-smi --query-gpu=name --format=csv,noheader -i 0 2>/dev/null | head -1 | sed 's/_/ /g')
if [ -z "$gpu_info" ]; then
    gpu_info="${gpu_name:-unknown}"
fi
echo "$gpu_info" > ${OUTPUT}/gpu.txt
echo "  GPU: $gpu_info"

# CPU info - handle both x86 and ARM architectures
cpu_info=$(lscpu 2>/dev/null | grep -E "Model name:" | sed -r 's/Model name:\s*//' | head -1)
if [ -z "$cpu_info" ]; then
    # Try ARM-specific fields
    cpu_info=$(lscpu 2>/dev/null | grep -E "^CPU:" | sed 's/CPU:\s*//' | head -1)
fi
if [ -z "$cpu_info" ]; then
    # Fallback to /proc/cpuinfo
    cpu_info=$(cat /proc/cpuinfo 2>/dev/null | grep -E "model name|Hardware" | head -1 | cut -d: -f2 | xargs)
fi
if [ -z "$cpu_info" ]; then
    cpu_info="unknown"
fi
echo "$cpu_info" > ${OUTPUT}/cpu.txt
echo "  CPU: $cpu_info"

# Driver info
driver_info=$(nvidia-smi -q 2>/dev/null | grep -i "Driver Version" | awk '{print $4}' | head -1)
if [ -z "$driver_info" ]; then
    driver_info=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader -i 0 2>/dev/null | head -1)
fi
if [ -z "$driver_info" ]; then
    driver_info="unknown"
fi
echo "$driver_info" > ${OUTPUT}/driver.txt
echo "  Driver: $driver_info"

echo "System info collected to ${OUTPUT}/"

echo ""
echo "=== Test execution completed ==="
echo "Output directory: $OUTPUT"
INNER_EOF

chmod +x "$INNER_SCRIPT"

# ============================================================
# Execute test inside container via srun
# ============================================================
echo ""
echo "=== Launching srun job ==="

# Container path mapping: ${CLUSTER_WORKDIR} -> /code
INNER_SCRIPT_CONTAINER="/code/scripts/inner_perf_test.sh"
OUTPUT_CONTAINER="/code/output/$(basename $OUTPUT)"

echo "Command: ${SRUN_BASE} ${CONTAINER_PARAMS} bash ${INNER_SCRIPT_CONTAINER} ..."
echo ""

${SRUN_BASE} ${CONTAINER_PARAMS} \
    bash "$INNER_SCRIPT_CONTAINER" \
    "$LLM_ROOT" \
    "$LLM_MODELS_ROOT" \
    "$OUTPUT_CONTAINER" \
    "$TEST_LIST" \
    "$TEST_SUITE" \
    "$INSTALL_MODE_ARG" \
    "$TIMEOUT" \
    "$SPLITS" \
    "$GROUP" \
    "/code"

SRUN_EXIT_CODE=$?

echo ""
echo "=========================================="
if [ $SRUN_EXIT_CODE -eq 0 ]; then
    echo "✅ Single Node Performance Test Complete"
else
    echo "❌ Test finished with exit code: $SRUN_EXIT_CODE"
fi
echo "=========================================="
echo "Output: $OUTPUT"

exit $SRUN_EXIT_CODE
