#!/bin/bash
#SBATCH --job-name=debug-memory-leak-auto
#SBATCH --partition=batch
#SBATCH --account=coreai_comparch_trtllm
#SBATCH --nodes=1
#SBATCH --ntasks=4
#SBATCH --ntasks-per-node=4
#SBATCH --gres=gpu:4
#SBATCH --time=04:00:00
#SBATCH --output=%x-%j.out
#SBATCH --error=%x-%j.err

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
USER_NAME="${USER:-$(whoami)}"
SCRIPT_DIR="/lustre/fsw/portfolios/coreai/users/${USER_NAME}/tensorrt_llm/examples/disaggregated/slurm/benchmark"
WORK_DIR="/lustre/fsw/portfolios/coreai/users/${USER_NAME}/tensorrt_llm/tests/integration/defs/mem_leaks"
MODEL_DIR="/lustre/fs1/portfolios/coreai/projects/coreai_comparch_trtllm/common"
OUTPUT_PATH="/lustre/fsw/portfolios/coreai/users/${USER_NAME}/output"
CONTAINER_IMAGE="/lustre/fsw/portfolios/coreai/users/deemod/TRTLLM-7952/deemod+trtllm-2956978da3bf-aarch64-20251023.sqsh"

LOG_DIR="${OUTPUT_PATH}/debug_memory_leak_${SLURM_JOB_ID}"
mkdir -p ${LOG_DIR}

echo "============================================================================"
echo "TensorRT-LLM Memory Leak Debugging - Automated Test"
echo "============================================================================"
echo "Job ID: ${SLURM_JOB_ID}"
echo "Log Directory: ${LOG_DIR}"
echo "Start Time: $(date)"
echo "============================================================================"

# ============================================================================
# Step 1: Install Dependencies
# ============================================================================
echo ""
echo "Step 1: Installing dependencies (valgrind, sglang)..."
echo "------------------------------------------------------------------------"
srun -N1 -n1 --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-memory-${SLURM_JOB_ID} \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${SCRIPT_DIR}:${SCRIPT_DIR},${MODEL_DIR}:${MODEL_DIR},${OUTPUT_PATH}:${OUTPUT_PATH} \
    --mpi=pmix --overlap \
    bash -c "
        echo '📦 Installing valgrind...'
        apt-get update -qq && apt-get install -y -qq valgrind 2>&1 | tee ${LOG_DIR}/install_valgrind.log
        
        echo '📦 Installing sglang...'
        pip install --no-cache-dir sglang 2>&1 | tee ${LOG_DIR}/install_sglang.log
        
        echo '✅ Dependencies installed'
        echo ''
        echo 'Versions:'
        valgrind --version
        python3 -c 'import sglang; print(f\"sglang installed successfully\")'
    " 2>&1 | tee ${LOG_DIR}/step1_install.log

if [ $? -ne 0 ]; then
    echo "❌ Dependency installation failed"
    echo "Check logs: ${LOG_DIR}/step1_install.log"
    exit 1
fi

echo "✅ Step 1 completed"

# ============================================================================
# Step 2: Start trtllm-serve with valgrind (Background)
# ============================================================================
echo ""
echo "Step 2: Starting trtllm-serve with valgrind monitoring..."
echo "------------------------------------------------------------------------"
srun -N1 -n4 --ntasks-per-node=4 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-memory-${SLURM_JOB_ID} \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${SCRIPT_DIR}:${SCRIPT_DIR},${MODEL_DIR}:${MODEL_DIR},${OUTPUT_PATH}:${OUTPUT_PATH} \
    --mpi=pmix --overlap \
    bash -c "
        cd ${WORK_DIR}
        
        echo '🚀 Starting trtllm-serve under valgrind...'
        echo 'This will take several minutes to initialize...'
        
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
            2>&1 | tee ${LOG_DIR}/trtllm_serve.log
    " &

SERVER_PID=$!
echo "Server process started with PID: ${SERVER_PID}"

# ============================================================================
# Step 3: Wait for Server to be Ready
# ============================================================================
echo ""
echo "Step 3: Waiting for server to be ready..."
echo "------------------------------------------------------------------------"
MAX_WAIT=600  # 10 minutes
WAIT_COUNT=0

echo "This may take 5-10 minutes under valgrind..."

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    # Check if server is responding
    if srun -N1 -n1 --container-name=debug-memory-${SLURM_JOB_ID} \
        --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH} \
        --overlap \
        bash -c "curl -s http://localhost:8000/health > /dev/null 2>&1"; then
        echo "✅ Server is ready!"
        break
    fi
    
    # Check if server process is still running
    if ! kill -0 $SERVER_PID 2>/dev/null; then
        echo "❌ Server process died unexpectedly"
        echo "Check logs: ${LOG_DIR}/trtllm_serve.log"
        exit 1
    fi
    
    if [ $((WAIT_COUNT % 30)) -eq 0 ]; then
        echo "Still waiting... ($WAIT_COUNT/$MAX_WAIT seconds)"
    fi
    
    sleep 10
    WAIT_COUNT=$((WAIT_COUNT + 10))
done

if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
    echo "❌ Server failed to start within ${MAX_WAIT} seconds"
    echo "Check logs: ${LOG_DIR}/trtllm_serve.log"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

echo "✅ Step 3 completed"

# ============================================================================
# Step 4: Collect Initial GPU Memory Stats
# ============================================================================
echo ""
echo "Step 4: Collecting initial GPU memory stats..."
echo "------------------------------------------------------------------------"
srun -N1 -n1 --container-name=debug-memory-${SLURM_JOB_ID} \
    --container-mounts=${OUTPUT_PATH}:${OUTPUT_PATH} \
    --overlap \
    bash -c "nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv > ${LOG_DIR}/initial_gpu_memory.csv"

cat ${LOG_DIR}/initial_gpu_memory.csv
echo "✅ Step 4 completed"

# ============================================================================
# Step 5: Run sglang Benchmark
# ============================================================================
echo ""
echo "Step 5: Running sglang benchmark..."
echo "------------------------------------------------------------------------"
echo "Test configuration:"
echo "  - Total requests: 40980"
echo "  - Max concurrency: 8196"
echo "  - Input tokens: 1024"
echo "  - Output tokens: 1024"
echo ""

srun -N1 -n1 --container-name=debug-memory-${SLURM_JOB_ID} \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${MODEL_DIR}:${MODEL_DIR},${OUTPUT_PATH}:${OUTPUT_PATH} \
    --overlap \
    bash -c "
        cd ${WORK_DIR}
        
        echo '📊 Starting benchmark...'
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
    "

BENCHMARK_STATUS=$?

if [ $BENCHMARK_STATUS -eq 0 ]; then
    echo "✅ Step 5 completed"
else
    echo "⚠️  Benchmark completed with errors (exit code: $BENCHMARK_STATUS)"
    echo "Check logs: ${LOG_DIR}/benchmark.log"
fi

# ============================================================================
# Step 6: Collect Final GPU Memory Stats
# ============================================================================
echo ""
echo "Step 6: Collecting final GPU memory stats..."
echo "------------------------------------------------------------------------"
srun -N1 -n1 --container-name=debug-memory-${SLURM_JOB_ID} \
    --container-mounts=${OUTPUT_PATH}:${OUTPUT_PATH} \
    --overlap \
    bash -c "nvidia-smi --query-gpu=index,memory.used,memory.free --format=csv > ${LOG_DIR}/final_gpu_memory.csv"

cat ${LOG_DIR}/final_gpu_memory.csv
echo "✅ Step 6 completed"

# ============================================================================
# Step 7: Stop Server and Cleanup
# ============================================================================
echo ""
echo "Step 7: Stopping server and collecting results..."
echo "------------------------------------------------------------------------"

# Stop the server gracefully
echo "Sending SIGTERM to server..."
kill -SIGTERM $SERVER_PID 2>/dev/null || true
sleep 10

# Force kill if still running
if kill -0 $SERVER_PID 2>/dev/null; then
    echo "Server still running, sending SIGKILL..."
    kill -SIGKILL $SERVER_PID 2>/dev/null || true
fi

echo "✅ Step 7 completed"

# ============================================================================
# Step 8: Generate Summary Report
# ============================================================================
echo ""
echo "Step 8: Generating summary report..."
echo "------------------------------------------------------------------------"

SUMMARY_FILE="${LOG_DIR}/summary.txt"

cat > ${SUMMARY_FILE} << EOF
============================================================================
TensorRT-LLM Memory Leak Test Summary
============================================================================
Job ID: ${SLURM_JOB_ID}
Start Time: $(head -1 ${LOG_DIR}/step1_install.log | grep -o '[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}' || echo "N/A")
End Time: $(date +%H:%M:%S)
Test Duration: $SECONDS seconds

Configuration:
  - Model: gpt-oss-120b
  - TP Size: 4
  - EP Size: 1
  - Backend: pytorch
  - Max Tokens: 20000

Benchmark:
  - Total Requests: 40980
  - Max Concurrency: 8196
  - Input Tokens: 1024
  - Output Tokens: 1024
  - Status: $([ $BENCHMARK_STATUS -eq 0 ] && echo 'SUCCESS' || echo 'FAILED')

Logs Location: ${LOG_DIR}
  - Valgrind reports: valgrind-*.log
  - Server log: trtllm_serve.log
  - Benchmark log: benchmark.log
  - GPU memory: initial_gpu_memory.csv, final_gpu_memory.csv

============================================================================
Memory Analysis
============================================================================

Valgrind Leak Summary:
EOF

# Extract leak summary from valgrind logs
if ls ${LOG_DIR}/valgrind-*.log 1> /dev/null 2>&1; then
    for log in ${LOG_DIR}/valgrind-*.log; do
        echo "" >> ${SUMMARY_FILE}
        echo "File: $(basename $log)" >> ${SUMMARY_FILE}
        grep -A 5 "LEAK SUMMARY" $log >> ${SUMMARY_FILE} 2>/dev/null || echo "  No leak summary found" >> ${SUMMARY_FILE}
    done
else
    echo "  No valgrind logs found" >> ${SUMMARY_FILE}
fi

cat >> ${SUMMARY_FILE} << EOF

GPU Memory Comparison:
Initial:
$(cat ${LOG_DIR}/initial_gpu_memory.csv)

Final:
$(cat ${LOG_DIR}/final_gpu_memory.csv)

============================================================================
Quick Commands to Analyze Results
============================================================================

# View this summary
cat ${SUMMARY_FILE}

# View detailed valgrind output
less ${LOG_DIR}/valgrind-*.log

# Search for definite memory leaks
grep "definitely lost" ${LOG_DIR}/valgrind-*.log

# View benchmark results
tail -50 ${LOG_DIR}/benchmark.log

# View server output
less ${LOG_DIR}/trtllm_serve.log

============================================================================
EOF

cat ${SUMMARY_FILE}

echo "✅ Step 8 completed"

# ============================================================================
# Final Summary
# ============================================================================
echo ""
echo "============================================================================"
echo "Test Completed Successfully"
echo "============================================================================"
echo "End Time: $(date)"
echo "Total Duration: $SECONDS seconds ($((SECONDS / 60)) minutes)"
echo "Benchmark Status: $([ $BENCHMARK_STATUS -eq 0 ] && echo 'SUCCESS ✅' || echo 'FAILED ❌')"
echo ""
echo "Results saved to: ${LOG_DIR}"
echo "Summary report: ${SUMMARY_FILE}"
echo ""
echo "Next steps:"
echo "  1. Review summary: cat ${SUMMARY_FILE}"
echo "  2. Check valgrind logs: ls -lh ${LOG_DIR}/valgrind-*.log"
echo "  3. Analyze leaks: grep 'definitely lost' ${LOG_DIR}/valgrind-*.log"
echo "============================================================================"

exit $BENCHMARK_STATUS

