
# How to collect the entire test list
# Please apply the corresponding env file under ./envs before collect the test list

cd /lustre/fsw/portfolios/coreai/users/fredricz/tensorrt_llm/tests/integration/defs/perf/disagg

source ./perf/disagg/envs/.env_oci

# Local test cases collect
export WORK_DIR="/mnt/c/code/TensorRT-LLM/tests/integration/defs/perf/disagg"
export OUTPUT_PATH=/mnt/c/code/TensorRT-LLM/tests/integration/defs/perf/disagg/output
poetry run pytest --disagg --collect-only -q &> testlist_h100.txt


# run compare_backends.py to generate backend comparison report
poetry run python compare_backends.py \
    --csv-path "$CSV_PATH" \
    --threshold 5.0 \
    --default-backend NIXL \
    --output backend_comparison.csv \
    --html backend_comparison.html

# run with test list file
poetry run pytest --disagg test_disagg.py -s -vv --disagg-test-list=./testlist/testlist_gb200_debug.txt

# Remove the .cache directory when it's too big
# This one will lead the poetry install command to fail
rm -rf ~/.cache

# Test simple collect with TensorRT-LLM installed from source
srun -N1 -n1 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=01:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-collect \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH},${REPO_DIR}:${REPO_DIR} \
    bash -c "cd ${REPO_DIR}
     pip3 install -r ${REPO_DIR}/requirements-dev.txt || echo '⚠️  requirements-dev.txt install failed, continuing...'
     echo '📦 Step 2: Installing TensorRT-LLM wheel...'
     pip3 install ${REPO_DIR}/build/*.whl --extra-index-url https://gitlab-master.nvidia.com/api/v4/projects/100660/packages/pypi/simple
     cd ${WORK_DIR}
     python3 simple_collect.py ${OUTPUT_PATH}"

# Test simple collect with TensorRT-LLM built in
srun -N1 -n1 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=01:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-collect \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH} \
    bash -c "cd ${WORK_DIR} && python3 simple_collect.py ${OUTPUT_PATH}"

# Get max GPU frequency and memory frequency
srun -N1 -n1 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=00:10:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-collect \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH} \
    bash -c "nvidia-smi --query-gpu=index,name,clocks.current.graphics,clocks.current.memory,clocks.max.graphics,clocks.max.memory --format=csv"


# Test memory leak
srun -N1 -n2 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=04:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-collect \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH},${REPO_DIR}:${REPO_DIR} \
    --pty bash

cd /lustre/fsw/portfolios/coreai/users/fredricz/tensorrt_llm/tests/integration/defs/perf/disagg

# Start trtllm-serve without valgrind
srun -N2 --ntasks-per-node=4 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=04:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-collect \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH},${REPO_DIR}:${REPO_DIR},${MODEL_DIR}:${MODEL_DIR} \
    bash -c "
        if [[ \$SLURM_PROCID == 0 ]]; then
            apt-get update && apt-get install -y valgrind;
            pip install sglang --no-deps;
            pip install pybase64;
        fi;
        trtllm-llmapi-launch trtllm-serve ${MODEL_DIR}/gpt-oss-120b --trust_remote_code --tp_size 8 --ep_size 8 --kv_cache_free_gpu_memory_fraction 0.9 --backend pytorch --extra_llm_api_options  ${WORK_DIR}/extra-llm-api-config.yaml --max_num_tokens 20000
    " &> ${OUTPUT_PATH}/trtllm-serve.log


# Compare and install valgrind from source
srun -N1 --ntasks-per-node=1 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=04:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-mounts=${WORK_DIR}:${WORK_DIR} \
    bash -c "
      cd ${WORK_DIR}
      wget https://sourceware.org/pub/valgrind/valgrind-3.22.0.tar.bz2
      tar -xjf valgrind-3.22.0.tar.bz2
      cd valgrind-3.22.0
      ./configure --prefix=${WORK_DIR}/valgrind-install
      make -j$(nproc)
      make install
    "

# Start trtllm-serve with valgrind
srun -N2 --ntasks-per-node=4 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=04:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-collect \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH},${REPO_DIR}:${REPO_DIR},${MODEL_DIR}:${MODEL_DIR} \
    bash <<'EOF' &> ${OUTPUT_PATH}/trtllm-serve-valgrind.log
INSTALL_DONE="/tmp/install_done_${SLURM_JOB_ID}"

if [[ $SLURM_PROCID == 0 ]]; then
    apt-get update && apt-get install -y valgrind libc6-dbg
    pip install sglang --no-deps
    pip install pybase64
    
    # Write flag file
    touch $INSTALL_DONE
    echo "Process 0: Installation done, marker created"
else
    # Other processes wait for the flag file
    echo "Process $SLURM_PROCID: Waiting for installation..."
    while [[ ! -f $INSTALL_DONE ]]; do
        sleep 2
    done
    echo "Process $SLURM_PROCID: Installation complete, continuing"
fi


    trtllm-llmapi-launch valgrind --leak-check=full \
    --show-leak-kinds=definite,possible \
    --num-transtab-sectors=48 \
    --track-origins=yes \
    --log-file=${OUTPUT_PATH}/valgrind-output-%p.log \
    trtllm-serve ${MODEL_DIR}/gpt-oss-120b --trust_remote_code --tp_size 8 --ep_size 8 --kv_cache_free_gpu_memory_fraction 0.9 --backend pytorch --extra_llm_api_options ${WORK_DIR}/extra-llm-api-config.yaml --max_num_tokens 20000

EOF

# Run benchmark get result
srun  --container-remap-root --container-name=debug-collect  --overlap \
    -N1 --ntasks-per-node=1 -w nvl72058-T11  --jobid=822318 \
    bash -c " 
        python3 -m sglang.bench_serving \
        --dataset-name random-ids \
        --backend vllm \
        --model openai/gpt-oss-120b \
        --random-range-ratio 1 \
        --num-prompt 40980 \
        --random-input 1024 \
        --random-output 1024 \
        --max-concurrency 8196
    " &> ${OUTPUT_PATH}/benchmark.log




# 在容器内安装（需要 root 权限）
apt-get update && apt-get install -y valgrind && apt-get install libc6-dbg
pip install sglang --no-deps 



trtllm-serve ${MODEL_DIR}/gpt-oss-120b --trust_remote_code --tp_size 4 --ep_size 4 --kv_cache_free_gpu_memory_fraction 0.9 --backend pytorch --extra_llm_api_options  extra-llm-api-config.yaml --max_num_tokens 20000

# 抑制 Python 内部的已知问题
valgrind --leak-check=full \
  --show-leak-kinds=definite,possible \
  --track-origins=yes \
  --suppressions=/usr/share/doc/python3.12/valgrind-python.supp \
  --log-file=valgrind-output-%p.log \
  python3 -u $(which trtllm-serve) ${MODEL_DIR}/gpt-oss-120b \
    --trust_remote_code \
    --tp_size 4 \
    --ep_size 4 \
    --kv_cache_free_gpu_memory_fraction 0.9 \
    --backend pytorch \
    --extra_llm_api_options extra-llm-api-config.yaml \
    --max_num_tokens 20000





valgrind --leak-check=full \
  --show-leak-kinds=definite,possible \
  --track-origins=yes \
  --log-file=valgrind-output-%p.log \
  python3 -u $(which trtllm-serve) ${MODEL_DIR}/gpt-oss-120b \
    --trust_remote_code \
    --tp_size 4 \
    --ep_size 4 \
    --kv_cache_free_gpu_memory_fraction 0.9 \
    --backend pytorch \
    --extra_llm_api_options extra-llm-api-config.yaml \
    --max_num_tokens 20000

