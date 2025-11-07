#!/bin/bash
# Interactive Memory Leak Debugging Session
# Provides step-by-step control over the testing process

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
USER_NAME="${USER:-$(whoami)}"
export WORK_DIR="/lustre/fsw/portfolios/coreai/users/${USER_NAME}/tensorrt_llm/tests/integration/defs/perf/disagg"
export SCRIPT_DIR="/lustre/fsw/portfolios/coreai/users/${USER_NAME}/tensorrt_llm/examples/disaggregated/slurm/benchmark"
export MODEL_DIR="/lustre/fs1/portfolios/coreai/projects/coreai_comparch_trtllm/common"
export OUTPUT_PATH="/lustre/fsw/portfolios/coreai/users/${USER_NAME}/output"
export CONTAINER_IMAGE="/lustre/fsw/portfolios/coreai/users/deemod/TRTLLM-7952/deemod+trtllm-2956978da3bf-aarch64-20251023.sqsh"

cat << 'EOF'
============================================================================
              Interactive Memory Leak Debugging Session
============================================================================

This script will:
  1. Start an interactive container with 4 GPUs
  2. Provide helper commands for testing
  3. Allow you to control each step manually

You will be able to:
  - Install dependencies (valgrind, sglang)
  - Start trtllm-serve with valgrind in a screen session
  - Run benchmark tests
  - Monitor GPU memory
  - Analyze results

Press Enter to continue...
EOF

read

echo "Starting interactive container..."
echo ""

# ============================================================================
# Start Interactive Container with Helper Functions
# ============================================================================
srun -N1 -n4 --ntasks-per-node=4 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=04:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-memory-interactive \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${SCRIPT_DIR}:${SCRIPT_DIR},${MODEL_DIR}:${MODEL_DIR},${OUTPUT_PATH}:${OUTPUT_PATH} \
    --mpi=pmix \
    --pty bash --rcfile <(cat <<'RCFILE'

# ============================================================================
# Welcome Banner
# ============================================================================
cat << 'EOF'

╔════════════════════════════════════════════════════════════════════════════╗
║                  Interactive Debugging Environment                         ║
╚════════════════════════════════════════════════════════════════════════════╝

Available Commands:
  setup_deps     - Install valgrind and sglang
  start_server   - Start trtllm-serve with valgrind (in screen)
  run_benchmark  - Run sglang benchmark test
  check_gpu      - Check GPU memory usage
  check_logs     - View valgrind logs summary
  stop_server    - Stop the server
  help           - Show detailed help

Environment Variables:
  WORK_DIR:    /lustre/fsw/.../perf/disagg
  MODEL_DIR:   /lustre/fs1/.../common
  OUTPUT_PATH: /lustre/fsw/.../output

Quick Start:
  1. Run: setup_deps
  2. Run: start_server
  3. Wait for "Server is ready!"
  4. Run: run_benchmark
  5. Run: check_logs

Type 'help' for detailed instructions.

EOF

# ============================================================================
# Helper Functions
# ============================================================================

setup_deps() {
    echo "============================================================================"
    echo "Installing Dependencies"
    echo "============================================================================"
    echo ""
    
    echo "📦 Step 1: Installing valgrind..."
    if apt-get update -qq && apt-get install -y -qq valgrind screen; then
        echo "✅ valgrind and screen installed"
        valgrind --version
    else
        echo "❌ Failed to install valgrind"
        return 1
    fi
    
    echo ""
    echo "📦 Step 2: Installing sglang..."
    if pip install --no-cache-dir sglang; then
        echo "✅ sglang installed"
        python3 -c 'import sglang; print("sglang imported successfully")'
    else
        echo "❌ Failed to install sglang"
        echo "Trying minimal installation..."
        pip install --no-deps sglang
        pip install requests aiohttp fastapi uvicorn
    fi
    
    echo ""
    echo "============================================================================"
    echo "✅ Dependencies installed successfully"
    echo "============================================================================"
    echo ""
    echo "Next step: run 'start_server'"
}

start_server() {
    echo "============================================================================"
    echo "Starting TensorRT-LLM Server with Valgrind"
    echo "============================================================================"
    echo ""
    
    # Create log directory
    export LOG_DIR="${OUTPUT_PATH}/interactive_debug_$(date +%Y%m%d_%H%M%S)"
    mkdir -p ${LOG_DIR}
    
    echo "📁 Log directory: ${LOG_DIR}"
    echo ""
    
    # Check if server is already running
    if screen -list | grep -q trtllm-server; then
        echo "⚠️  Server screen session already exists"
        echo "To view: screen -r trtllm-server"
        echo "To kill: stop_server"
        return 1
    fi
    
    echo "🚀 Starting server in screen session..."
    echo "⚠️  This will take 2-5 minutes to initialize under valgrind"
    echo ""
    
    # Start server in screen
    screen -dmS trtllm-server bash -c "
        cd ${WORK_DIR}
        
        echo '============================================================================'
        echo 'TensorRT-LLM Server with Valgrind Monitoring'
        echo '============================================================================'
        echo 'Log directory: ${LOG_DIR}'
        echo 'Starting at: \$(date)'
        echo ''
        
        valgrind --leak-check=full \
          --show-leak-kinds=definite,possible \
          --track-origins=yes \
          --log-file=${LOG_DIR}/valgrind-%p.log \
          python3 -u \$(which trtllm-serve) ${MODEL_DIR}/gpt-oss-120b \
            --trust_remote_code \
            --tp_size 4 \
            --ep_size 1 \
            --kv_cache_free_gpu_memory_fraction 0.9 \
            --backend pytorch \
            --max_num_tokens 20000 \
            2>&1 | tee ${LOG_DIR}/server.log
    "
    
    echo "✅ Server started in screen session 'trtllm-server'"
    echo ""
    echo "To view server output:"
    echo "  screen -r trtllm-server"
    echo "  (Press Ctrl+A, then D to detach)"
    echo ""
    echo "Checking if server becomes ready..."
    echo "(This may take 2-5 minutes under valgrind)"
    echo ""
    
    # Wait for server to be ready
    local max_wait=600
    local count=0
    
    while [ $count -lt $max_wait ]; do
        if curl -s http://localhost:8000/health > /dev/null 2>&1; then
            echo ""
            echo "============================================================================"
            echo "✅ Server is ready!"
            echo "============================================================================"
            echo ""
            echo "Next step: run 'run_benchmark'"
            return 0
        fi
        
        # Show progress every 30 seconds
        if [ $((count % 30)) -eq 0 ] && [ $count -gt 0 ]; then
            echo "Still waiting... ($count/$max_wait seconds)"
        fi
        
        sleep 5
        count=$((count + 5))
    done
    
    echo ""
    echo "⚠️  Server did not respond within $max_wait seconds"
    echo "Check server output: screen -r trtllm-server"
    echo "Or check logs: tail -f ${LOG_DIR}/server.log"
}

run_benchmark() {
    echo "============================================================================"
    echo "Running SGLang Benchmark"
    echo "============================================================================"
    echo ""
    
    if [ -z "${LOG_DIR:-}" ]; then
        export LOG_DIR="${OUTPUT_PATH}/interactive_debug_$(date +%Y%m%d_%H%M%S)"
        mkdir -p ${LOG_DIR}
        echo "📁 Log directory: ${LOG_DIR}"
        echo ""
    fi
    
    # Check if server is running
    if ! curl -s http://localhost:8000/health > /dev/null 2>&1; then
        echo "❌ Server is not responding"
        echo "Please start the server first: start_server"
        return 1
    fi
    
    echo "Test configuration:"
    echo "  - Total requests: 40980"
    echo "  - Max concurrency: 8196"
    echo "  - Input tokens: 1024"
    echo "  - Output tokens: 1024"
    echo ""
    echo "📊 Starting benchmark (this will take a while)..."
    echo ""
    
    cd ${WORK_DIR}
    
    python3 -m sglang.bench_serving \
      --dataset-name random-ids \
      --backend vllm \
      --base-url http://localhost:8000 \
      --model gpt-oss-120b \
      --random-range-ratio 1 \
      --num-prompt 40980 \
      --random-input 1024 \
      --random-output 1024 \
      --max-concurrency 8196 \
      2>&1 | tee ${LOG_DIR}/benchmark.log
    
    local status=$?
    
    echo ""
    if [ $status -eq 0 ]; then
        echo "============================================================================"
        echo "✅ Benchmark completed successfully"
        echo "============================================================================"
    else
        echo "============================================================================"
        echo "⚠️  Benchmark completed with errors"
        echo "============================================================================"
    fi
    
    echo ""
    echo "Results saved to: ${LOG_DIR}/benchmark.log"
    echo ""
    echo "Next step: run 'check_logs' to analyze results"
    
    return $status
}

check_gpu() {
    echo "============================================================================"
    echo "GPU Memory Usage"
    echo "============================================================================"
    echo ""
    nvidia-smi
    echo ""
    echo "============================================================================"
    echo "Process Memory"
    echo "============================================================================"
    echo ""
    ps aux | grep -E 'USER|python|trtllm|valgrind' | grep -v grep | head -15
}

check_logs() {
    echo "============================================================================"
    echo "Log Analysis"
    echo "============================================================================"
    echo ""
    
    if [ -z "${LOG_DIR:-}" ]; then
        echo "❌ LOG_DIR not set"
        echo "Please start the server first: start_server"
        return 1
    fi
    
    echo "📁 Log directory: ${LOG_DIR}"
    echo ""
    
    if [ ! -d "${LOG_DIR}" ]; then
        echo "❌ Log directory does not exist"
        return 1
    fi
    
    echo "Files:"
    ls -lh ${LOG_DIR}/
    echo ""
    
    echo "============================================================================"
    echo "Valgrind Leak Summary"
    echo "============================================================================"
    
    if ls ${LOG_DIR}/valgrind-*.log 1> /dev/null 2>&1; then
        for log in ${LOG_DIR}/valgrind-*.log; do
            echo ""
            echo "File: $(basename $log)"
            echo "------------------------------------------------------------------------"
            grep -A 5 "LEAK SUMMARY" $log 2>/dev/null || echo "No leak summary found yet"
        done
    else
        echo "No valgrind logs found"
    fi
    
    echo ""
    echo "============================================================================"
    echo "Quick Analysis Commands"
    echo "============================================================================"
    echo ""
    echo "View detailed valgrind output:"
    echo "  less ${LOG_DIR}/valgrind-*.log"
    echo ""
    echo "Search for definite leaks:"
    echo "  grep 'definitely lost' ${LOG_DIR}/valgrind-*.log"
    echo ""
    echo "View server output:"
    echo "  tail -f ${LOG_DIR}/server.log"
    echo ""
    echo "View benchmark results:"
    echo "  tail -50 ${LOG_DIR}/benchmark.log"
}

stop_server() {
    echo "============================================================================"
    echo "Stopping Server"
    echo "============================================================================"
    echo ""
    
    if screen -list | grep -q trtllm-server; then
        echo "Stopping server screen session..."
        screen -X -S trtllm-server quit
        echo "✅ Server stopped"
    else
        echo "⚠️  No server screen session found"
    fi
    
    # Also kill any remaining processes
    pkill -f trtllm-serve || true
    echo "✅ Cleanup complete"
}

help() {
    cat << 'HELP_EOF'

============================================================================
                        Detailed Usage Guide
============================================================================

WORKFLOW
--------
The typical workflow for memory leak testing:

1. Setup Environment
   $ setup_deps
   
   This installs valgrind and sglang in the container.

2. Start Server
   $ start_server
   
   This starts trtllm-serve under valgrind monitoring in a screen session.
   The server runs in the background, allowing you to continue working.
   
   Wait for "Server is ready!" message (2-5 minutes).

3. Run Benchmark
   $ run_benchmark
   
   This runs the sglang benchmark to stress test the server.
   Results are logged to ${LOG_DIR}/benchmark.log

4. Check Results
   $ check_logs
   
   This shows a summary of valgrind output and log locations.

5. Stop Server
   $ stop_server
   
   Cleanly stops the server when done.

COMMANDS
--------

setup_deps
  Installs valgrind and sglang.
  Run this first before any testing.

start_server
  Starts trtllm-serve with valgrind monitoring in a screen session.
  The server runs in the background.
  Automatically checks if server becomes ready.

run_benchmark
  Runs sglang benchmark against the server.
  Requires server to be running and ready.
  Test parameters:
    - 40,980 requests total
    - 8,196 max concurrency
    - 1024 input tokens
    - 1024 output tokens

check_gpu
  Shows current GPU memory usage and process information.
  Useful for monitoring during tests.

check_logs
  Displays summary of valgrind logs and results.
  Shows leak summaries if available.

stop_server
  Stops the server screen session.
  Run this when finished testing.

help
  Shows this detailed help message.

SCREEN COMMANDS
---------------

View server output in real-time:
  $ screen -r trtllm-server

Detach from screen (server keeps running):
  Press: Ctrl+A, then D

List all screen sessions:
  $ screen -ls

Kill server session manually:
  $ screen -X -S trtllm-server quit

MULTIPLE TERMINALS
------------------

You can open multiple terminals to the same container:

Terminal 1: Main control
  $ start_server
  $ run_benchmark

Terminal 2: Monitor GPU
  $ watch -n 1 check_gpu

Terminal 3: View logs
  $ screen -r trtllm-server
  (or)
  $ tail -f ${LOG_DIR}/server.log

To open additional terminals, from your local machine:
  $ srun --jobid=<JOBID> --overlap --pty bash

LOGS
----

All logs are saved in:
  ${OUTPUT_PATH}/interactive_debug_<timestamp>/

Files:
  - valgrind-*.log : Valgrind memory analysis
  - server.log     : Server output
  - benchmark.log  : Benchmark results

TROUBLESHOOTING
---------------

Problem: Server won't start
Solution:
  $ screen -r trtllm-server  # Check for errors
  $ tail -f ${LOG_DIR}/server.log

Problem: Benchmark connection refused
Solution:
  $ curl http://localhost:8000/health  # Check if server is up
  $ check_gpu  # Verify processes are running

Problem: Out of memory
Solution:
  $ check_gpu  # Check current usage
  $ stop_server  # Clean up and restart

Problem: Valgrind is too slow
Solution:
  Consider running without valgrind:
  $ trtllm-serve ${MODEL_DIR}/gpt-oss-120b \
      --trust_remote_code --tp_size 4 --ep_size 1 \
      --backend pytorch --max_num_tokens 20000

EXAMPLES
--------

Basic workflow:
  [DEBUG] $ setup_deps
  [DEBUG] $ start_server
  # Wait for ready message
  [DEBUG] $ run_benchmark
  [DEBUG] $ check_logs

Monitor while testing:
  [DEBUG] $ watch -n 1 check_gpu

View live server output:
  [DEBUG] $ screen -r trtllm-server
  # Ctrl+A, D to detach

Analyze specific leaks:
  [DEBUG] $ grep 'definitely lost' ${LOG_DIR}/valgrind-*.log

HELP_EOF
}

# Export all functions for use in the shell
export -f setup_deps start_server run_benchmark check_gpu check_logs stop_server help

# Set custom prompt
export PS1="\[\e[1;32m\][DEBUG]\[\e[0m\] \w $ "

# Change to work directory
cd ${WORK_DIR}

RCFILE
)

