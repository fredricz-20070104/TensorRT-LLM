#!/bin/bash
#
# Script to run disaggregated multi-node tests with failed test rerun support
#
# Usage: run_disagg_test.sh <CLUSTER_WORKDIR> <CLUSTER_LLM_DATA> <CLUSTER_STORAGE> \
#                            <CLUSTER_PARTITION> <CLUSTER_ACCOUNT> <DOCKER_IMAGE> \
#                            <TEST_MODEL> <TEST_LIST> <INSTALL_MODE> <GPU> <TRT_LLM_BRANCH> <FAILED_RERUN>
#

set -e

echo "=========================================="
echo "Disaggregated Multi-node Test Runner"
echo "=========================================="

# Parse arguments
CLUSTER_WORKDIR=$1
CLUSTER_LLM_DATA=$2
CLUSTER_STORAGE=$3
CLUSTER_PARTITION=$4
CLUSTER_ACCOUNT=$5
DOCKER_IMAGE=$6
TEST_MODEL=$7
TEST_LIST=$8
INSTALL_MODE_ARG=$9
GPU=${10}
TRT_LLM_BRANCH=${11}
FAILED_RERUN=${12:-0}  # Default to 0 if not provided

# Display configuration
echo ""
echo "Configuration:"
echo "  CLUSTER_WORKDIR:   $CLUSTER_WORKDIR"
echo "  CLUSTER_LLM_DATA:  $CLUSTER_LLM_DATA"
echo "  CLUSTER_STORAGE:   $CLUSTER_STORAGE"
echo "  CLUSTER_PARTITION: $CLUSTER_PARTITION"
echo "  CLUSTER_ACCOUNT:   $CLUSTER_ACCOUNT"
echo "  DOCKER_IMAGE:      $DOCKER_IMAGE"
echo "  TEST_MODEL:        $TEST_MODEL"
echo "  TEST_LIST:         $TEST_LIST"
echo "  INSTALL_MODE:      $INSTALL_MODE_ARG"
echo "  GPU:               $GPU"
echo "  TRT_LLM_BRANCH:    $TRT_LLM_BRANCH"
echo "  FAILED_RERUN:      $FAILED_RERUN"
echo ""

# Initialize exit code tracker
PYTEST_EXIT_CODE=0
COMPARE_EXIT_CODE=0

# ============================================================================
# Signal Handler for GitLab CI Cancel
# ============================================================================

cleanup_on_cancel() {
  echo ""
  echo "=========================================="
  echo "⚠️  Cancel signal received - terminating"
  echo "=========================================="
  
  # Step 1: Cancel SLURM jobs using the project's cleanup script
  if [ -n "$TMP_OUTPUT_DIR" ] && [ -f "$WORK_DIR/cleanup_jobs.sh" ]; then
    echo "Step 1: Canceling SLURM jobs..."
    export OUTPUT_PATH="$TMP_OUTPUT_DIR"
    bash "$WORK_DIR/cleanup_jobs.sh" || true
  else
    echo "Step 1: Skipped (cleanup_jobs.sh not found or OUTPUT_PATH not set)"
  fi
  echo "✓ Cleanup completed"
  exit 130
}

# Register signal handlers (GitLab CI sends SIGTERM on cancel)
trap cleanup_on_cancel SIGTERM SIGINT SIGHUP

echo "✓ Signal handler registered (Ctrl+C or GitLab cancel will terminate immediately)"

export PATH="$HOME/.local/bin:$PATH"
export POETRY_VIRTUALENVS_PATH="${CLUSTER_STORAGE}/poetry_packages"

WORK_DIR="${CLUSTER_WORKDIR}/tensorrt_llm/tests/integration/defs/perf/disagg"
SCRIPT_DIR="${CLUSTER_WORKDIR}/tensorrt_llm/examples/disaggregated/slurm/benchmark"

cd $WORK_DIR || exit 1

# Export environment variables
# export OPENBLAS_NUM_THREADS=4
export CONTAINER_IMAGE="$DOCKER_IMAGE"
export WORK_DIR="$WORK_DIR"
export SCRIPT_DIR="$SCRIPT_DIR"
export GPU_TYPE="$GPU"
export SLURM_PARTITION="$CLUSTER_PARTITION"
export SLURM_ACCOUNT="$CLUSTER_ACCOUNT"
export MODEL_DIR="$CLUSTER_LLM_DATA"
export DATASET_DIR="$CLUSTER_STORAGE"
export HF_HOME_DIR="${DATASET_DIR}/disagg_datasets/hf_home"
export INSTALL_MODE="$INSTALL_MODE_ARG"

# ============================================================================
# Set REPO_DIR and TRTLLM_WHEEL_PATH based on install mode and branch
# ============================================================================
# Check if branch is a release branch
if [[ "$TRT_LLM_BRANCH" == *"release"* ]]; then
  IS_RELEASE_BRANCH=true
else
  IS_RELEASE_BRANCH=false
fi

# Set paths based on install mode
if [ "$INSTALL_MODE_ARG" = "none" ]; then
  # No installation needed
  TRTLLM_WHEEL_PATH=""
  if [ "$IS_RELEASE_BRANCH" = true ]; then
    REPO_DIR=""
  else
    REPO_DIR="${CLUSTER_WORKDIR}/tensorrt_llm"
  fi
elif [ "$INSTALL_MODE_ARG" = "wheel" ]; then
  # Use wheel installation
  TRTLLM_WHEEL_PATH=$(find "${CLUSTER_WORKDIR}/tensorrt_llm/build/" -name "*.whl" -type f | head -1)
  if [ -z "$TRTLLM_WHEEL_PATH" ]; then
    echo "Warning: No .whl file found in ${CLUSTER_WORKDIR}/tensorrt_llm/build/"
  else
    echo "Found wheel: $TRTLLM_WHEEL_PATH"
  fi
  if [ "$IS_RELEASE_BRANCH" = true ]; then
    REPO_DIR=""
  else
    REPO_DIR="${CLUSTER_WORKDIR}/tensorrt_llm"
  fi
else
  # Source installation
  TRTLLM_WHEEL_PATH=""
  REPO_DIR="${CLUSTER_WORKDIR}/tensorrt_llm"
fi

export REPO_DIR
export TRTLLM_WHEEL_PATH

# Create output directory
TIMESTAMP=$(date +%s%N)
HOSTNAME=$(hostname)
TMP_OUTPUT_DIR="${CLUSTER_WORKDIR}/output/tmp_${TIMESTAMP}_output_disagg_${GPU}_${HOSTNAME}"
export OUTPUT_PATH="$TMP_OUTPUT_DIR"
mkdir -p "$TMP_OUTPUT_DIR"

# Set cache directories for pip and poetry
export XDG_CACHE_HOME="${CLUSTER_STORAGE}"
export PIP_CACHE_DIR="${XDG_CACHE_HOME}/pip"

# Install dependencies
echo "=== Setting up Poetry environment ==="
echo "Executing commands:"
echo "  poetry env use /usr/bin/python3"
echo "  poetry lock"
echo "  poetry install --no-root -v"
echo ""

poetry env use /usr/bin/python3
poetry lock
poetry install --no-root -v

echo ""
echo "✓ Poetry environment ready"

# Function to parse failed tests from results.xml
parse_failed_tests() {
  local xml_file=$1
  local output_file=$2
  
  echo "=== Parsing failed tests ==="
  echo "  XML file: $xml_file"
  echo "  Output to: $output_file"
  
  if [ ! -f "$xml_file" ]; then
    echo "❌ Error: XML file not found at $xml_file"
    return 1
  fi
  
  # Extract failed test cases from JUnit XML
  # Format: <testcase classname="test_disagg.TestDisaggBenchmark" name="test_benchmark[...]">
  # with child element <failure> or <error>
  grep -B 1 -E '<failure|<error' "$xml_file" | \
    grep '<testcase' | \
    sed -n 's/.*classname="\([^"]*\)" name="\([^"]*\)".*/\1::\2/p' | \
    sed 's/test_disagg\.TestDisaggBenchmark/test_disagg.py::TestDisaggBenchmark/g' > "$output_file"
  
  local failed_count=$(cat "$output_file" 2>/dev/null | wc -l)
  
  if [ $failed_count -gt 0 ]; then
    echo "✓ Found $failed_count failed test(s):"
    echo "----------------------------------------"
    cat "$output_file" | nl -w2 -s'. '
    echo "----------------------------------------"
    return 0
  else
    echo "✓ No failed tests found (all passed or skipped)"
    return 1
  fi
}

# Function to run pytest with optional test list
run_pytest() {
  local test_list_file=$1
  local output_suffix=$2
  local exit_code=0
  
  local xml_output="$TMP_OUTPUT_DIR/results${output_suffix}.xml"
  
  echo "=== Running pytest${output_suffix} ==="
  
  if [ -n "$test_list_file" ] && [ -f "$test_list_file" ]; then
    echo "Using test list from: $test_list_file"
    echo "Test cases to run:"
    cat "$test_list_file"
    echo ""
    # Read test cases from file and pass them directly to pytest
    test_cases=$(cat "$test_list_file" | tr '\n' ' ')
    
    # Print the actual command
    echo "Executing command:"
    echo "poetry run pytest $test_cases --disagg -vv \\"
    echo "  --junit-xml=\"$xml_output\" \\"
    echo "  -o junit_logging=all --log-cli-level=INFO --capture=no"
    echo ""
    
    # NOTE: No -k filter when using explicit test case list (for reruns)
    poetry run pytest $test_cases --disagg -vv \
      --junit-xml="$xml_output" \
      -o junit_logging=all --log-cli-level=INFO --capture=no || exit_code=$?
  elif [ -n "$TEST_LIST" ]; then
    echo "Using test list: $TEST_LIST"
    echo "Test model filter (-k): $TEST_MODEL"
    echo ""
    echo "Executing command:"
    echo "poetry run pytest test_disagg.py --disagg --disagg-test-list=$TEST_LIST -vv \\"
    echo "  --junit-xml=\"$xml_output\" -k \"$TEST_MODEL\" \\"
    echo "  -o junit_logging=all --log-cli-level=INFO --capture=no"
    echo ""
    
    poetry run pytest test_disagg.py --disagg --disagg-test-list=$TEST_LIST -vv \
      --junit-xml="$xml_output" -k "$TEST_MODEL" \
      -o junit_logging=all --log-cli-level=INFO --capture=no || exit_code=$?
  else
    echo "Running all tests"
    echo "Test model filter (-k): $TEST_MODEL"
    echo ""
    echo "Executing command:"
    echo "poetry run pytest test_disagg.py --disagg -vv \\"
    echo "  --junit-xml=\"$xml_output\" -k \"$TEST_MODEL\" \\"
    echo "  -o junit_logging=all --log-cli-level=INFO --capture=no"
    echo ""
    
    poetry run pytest test_disagg.py --disagg -vv \
      --junit-xml="$xml_output" -k "$TEST_MODEL" \
      -o junit_logging=all --log-cli-level=INFO --capture=no || exit_code=$?
  fi
  
  echo ""
  echo "Pytest exit code: $exit_code"
  return $exit_code
}

# Run initial pytest (capture exit code but continue)
echo "=== Initial Test Run ==="
echo "Configuration:"
echo "  - FAILED_RERUN: $FAILED_RERUN"
echo "  - TEST_MODEL: $TEST_MODEL"
echo "  - TEST_LIST: $TEST_LIST"
echo "  - OUTPUT_PATH: $TMP_OUTPUT_DIR"
echo ""

run_pytest "" "" || PYTEST_EXIT_CODE=$?

# ============================================================================
# Always generate failed_rerun.txt if tests failed (for manual rerun)
# ============================================================================
FAILED_LIST_FILE="$TMP_OUTPUT_DIR/failed_rerun.txt"

if [ $PYTEST_EXIT_CODE -ne 0 ]; then
  echo ""
  echo "=========================================="
  echo "⚠️  Tests failed (exit code: $PYTEST_EXIT_CODE)"
  echo "   Parsing failed tests..."
  echo "=========================================="
  
  # Parse and save failed tests (regardless of FAILED_RERUN setting)
  if parse_failed_tests "$TMP_OUTPUT_DIR/results.xml" "$FAILED_LIST_FILE"; then
    echo ""
    echo "=========================================="
    echo "📋 Failed tests saved to: $FAILED_LIST_FILE"
    echo "=========================================="
    echo ""
    echo "Failed test list (for manual rerun):"
    echo "--- Copy below this line ---"
    cat "$FAILED_LIST_FILE"
    echo "--- Copy above this line ---"
    echo ""
    echo "💡 Rerun options:"
    echo "   Option 1: Set FAILED_RERUN=1+ for automatic rerun"
    echo "   Option 2: Copy content above to DISAGG_MULTI_NODE_TEST_LIST variable"
    echo "   Option 3: Download failed_rerun.txt from artifacts after job completes"
    echo ""
    
    # Create a backup copy with GPU type for easier identification
    BACKUP_FILE="$TMP_OUTPUT_DIR/failed_rerun_${GPU}.txt"
    cp "$FAILED_LIST_FILE" "$BACKUP_FILE"
    echo "✓ Backup saved to: $BACKUP_FILE"
    echo ""
  else
    echo "⚠️  Could not parse failed tests from results.xml"
  fi
fi

# Handle automatic failed test reruns (only if FAILED_RERUN > 0)
if [ "$FAILED_RERUN" -gt 0 ] && [ $PYTEST_EXIT_CODE -ne 0 ]; then
  echo ""
  echo "=========================================="
  echo "⚠️  Initial run failed (exit code: $PYTEST_EXIT_CODE)"
  echo "   Starting failed test rerun process..."
  echo "=========================================="
  
  # Failed tests already parsed above, just use the file (defined at L278)
  if [ -f "$FAILED_LIST_FILE" ] && [ -s "$FAILED_LIST_FILE" ]; then
    echo "✓ Using failed test list for automatic rerun"
    echo ""
    
    # Rerun failed tests up to FAILED_RERUN times
    for rerun_count in $(seq 1 $FAILED_RERUN); do
      echo ""
      echo "=========================================="
      echo "🔄 Rerun attempt $rerun_count of $FAILED_RERUN"
      echo "=========================================="
      
      # Run failed tests and capture exit code
      run_pytest "$FAILED_LIST_FILE" "_rerun${rerun_count}"
      RERUN_EXIT_CODE=$?
      
      echo ""
      echo "Rerun $rerun_count exit code: $RERUN_EXIT_CODE"
      
      # If rerun succeeded, update exit code
      if [ $RERUN_EXIT_CODE -eq 0 ]; then
        echo ""
        echo "=========================================="
        echo "✓ All failed tests passed on rerun $rerun_count"
        echo "=========================================="
        PYTEST_EXIT_CODE=0
        break
      fi
      
      # Parse failed tests from this rerun for next iteration
      if [ $rerun_count -lt $FAILED_RERUN ]; then
        echo "Some tests still failing, analyzing for next rerun..."
        RERUN_FAILED_LIST="$TMP_OUTPUT_DIR/failed_rerun_${rerun_count}.txt"
        if ! parse_failed_tests "$TMP_OUTPUT_DIR/results_rerun${rerun_count}.xml" "$RERUN_FAILED_LIST"; then
          echo ""
          echo "=========================================="
          echo "✓ No more failed tests after rerun $rerun_count"
          echo "=========================================="
          PYTEST_EXIT_CODE=0
          break
        fi
        # Update failed list for next rerun
        mv "$RERUN_FAILED_LIST" "$FAILED_LIST_FILE"
        echo "Updated failed test list for rerun $(($rerun_count + 1))"
      else
        echo ""
        echo "=========================================="
        echo "❌ All $FAILED_RERUN rerun attempts exhausted"
        echo "=========================================="
        # Update failed_rerun.txt with the latest failures for manual rerun
        echo "Updating failed_rerun.txt with latest failures..."
        parse_failed_tests "$TMP_OUTPUT_DIR/results_rerun${rerun_count}.xml" "$FAILED_LIST_FILE" || true
      fi
    done
  else
    echo "❌ No failed tests file found or file is empty, skipping rerun"
  fi
elif [ $PYTEST_EXIT_CODE -eq 0 ]; then
  echo ""
  echo "=========================================="
  echo "✓ All tests passed on initial run"
  echo "=========================================="
elif [ $PYTEST_EXIT_CODE -ne 0 ]; then
  # FAILED_RERUN <= 0 and tests failed
  echo ""
  echo "=========================================="
  echo "ℹ️  Automatic rerun disabled (FAILED_RERUN=$FAILED_RERUN)"
  echo "   Use failed_rerun.txt for manual rerun (see above)"
  echo "=========================================="
fi

# Merge all JUnit XML files into a single results.xml
echo ""
echo "=== Merging JUnit XML results ==="

# Dynamically find all results*.xml files
shopt -s nullglob  # Handle case when no rerun files exist
RERUN_FILES=("$TMP_OUTPUT_DIR"/results_rerun*.xml)
shopt -u nullglob

# Only merge if there are rerun files
if [ ${#RERUN_FILES[@]} -gt 0 ]; then
  echo "Found ${#RERUN_FILES[@]} rerun XML file(s) to merge with initial results"
  echo "Files to merge:"
  echo "  - $TMP_OUTPUT_DIR/results.xml (initial)"
  for f in "${RERUN_FILES[@]}"; do
    echo "  - $f"
  done
  echo ""
  
  # Backup original results.xml
  cp "$TMP_OUTPUT_DIR/results.xml" "$TMP_OUTPUT_DIR/results_original.xml"
  echo "✓ Backed up original results.xml"
  
  # Get the merge script from the repo
  MERGE_SCRIPT="${CLUSTER_WORKDIR}/scripts/merge_junit_xml.py"
  if [ -f "$MERGE_SCRIPT" ]; then
    # Build the list of all XML files: initial + reruns
    ALL_XMLS=("$TMP_OUTPUT_DIR/results.xml" "${RERUN_FILES[@]}")
    
    # Print the merge command
    echo "Executing command:"
    echo "poetry run python \"$MERGE_SCRIPT\" \"$TMP_OUTPUT_DIR/results.xml\" \\"
    for xml in "${ALL_XMLS[@]}"; do
      echo "  \"$xml\" \\"
    done | sed '$ s/ \\$//'
    echo ""
    
    # Merge XMLs: later results override earlier ones
    poetry run python "$MERGE_SCRIPT" "$TMP_OUTPUT_DIR/results.xml" "${ALL_XMLS[@]}"
    echo "✓ Merged XML saved to results.xml (original backed up as results_original.xml)"
  else
    echo "⚠️  Warning: merge_junit_xml.py not found at $MERGE_SCRIPT"
    echo "   Keeping separate XML files"
  fi
else
  echo "No rerun files found, keeping original results.xml"
fi

# Run compare backends (always run, even if pytest failed)
echo ""
echo "=== Running compare backends ==="
echo "Executing command:"
echo "poetry run python compare_backends.py \\"
echo "  --csv-path \"$TMP_OUTPUT_DIR/perf_script_test_results.csv\" \\"
echo "  --threshold 5.0 \\"
echo "  --output \"$TMP_OUTPUT_DIR/disagg_backend_results.csv\" \\"
echo "  --html \"$TMP_OUTPUT_DIR/disagg_backend_results.html\""
echo ""

poetry run python compare_backends.py \
  --csv-path "$TMP_OUTPUT_DIR/perf_script_test_results.csv" \
  --threshold 5.0 \
  --output "$TMP_OUTPUT_DIR/disagg_backend_results.csv" \
  --html "$TMP_OUTPUT_DIR/disagg_backend_results.html" || COMPARE_EXIT_CODE=$?

echo ""
echo "Compare backends exit code: $COMPARE_EXIT_CODE"

# Verify Slurm logs were collected
echo ""
echo "=== Verifying Slurm logs ==="
SLURM_LOG_DIR="$TMP_OUTPUT_DIR/slurm_logs"
if [ -d "$SLURM_LOG_DIR" ]; then
  log_count=$(find "$SLURM_LOG_DIR" -type f 2>/dev/null | wc -l)
  echo "✓ Found $log_count Slurm log file(s) in: $SLURM_LOG_DIR"
  if [ $log_count -gt 0 ]; then
    echo "Sample logs:"
    find "$SLURM_LOG_DIR" -type f 2>/dev/null | head -5
  fi
else
  echo "⚠ Warning: No slurm_logs directory found at $SLURM_LOG_DIR"
fi

# Final summary
echo ""
echo "=========================================="
echo "Test Execution Summary"
echo "=========================================="
echo "Exit Codes:"
echo "  - Pytest:          $PYTEST_EXIT_CODE"
echo "  - Compare backends: $COMPARE_EXIT_CODE"
echo ""

# Exit with failure if tests or compare failed
if [ $PYTEST_EXIT_CODE -ne 0 ] || [ $COMPARE_EXIT_CODE -ne 0 ]; then
  echo "Result: ❌ FAILED"
  echo ""
  echo "Details:"
  [ $PYTEST_EXIT_CODE -ne 0 ] && echo "  - Pytest failed (exit code: $PYTEST_EXIT_CODE)"
  [ $COMPARE_EXIT_CODE -ne 0 ] && echo "  - Compare backends failed (exit code: $COMPARE_EXIT_CODE)"
  echo ""
  echo "Output directory: $TMP_OUTPUT_DIR"
  echo "=========================================="
  exit 1
fi

echo "Result: ✅ SUCCESS"
echo ""
echo "Output directory: $TMP_OUTPUT_DIR"
echo "=========================================="
exit 0

