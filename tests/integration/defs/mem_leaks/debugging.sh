
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

srun -N1 -n4 \
    --partition=batch \
    --account=coreai_comparch_trtllm \
    --gres=gpu:4 \
    --time=04:00:00 \
    --container-image=${CONTAINER_IMAGE} \
    --container-name=debug-collect \
    --container-mounts=${WORK_DIR}:${WORK_DIR},${OUTPUT_PATH}:${OUTPUT_PATH},${REPO_DIR}:${REPO_DIR},${MODEL_DIR}:${MODEL_DIR} \
    --pty bash

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



# 在容器内安装（需要 root 权限）
apt-get update && apt-get install -y valgrind

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