# Local SLURM Launch Scripts

## Optional Arguments

- `--test-list`: Test string, e.g., `perf/test_perf_sanity.py::test_e2e[aggr-config-test_name]`. If both `--test-list` and `--config-file` are provided, `--test-list` takes precedence.
- `--config-file`: Path to config YAML file.
- `--test-name`: Test name (only used for aggregated mode when `--config-file` is provided).
- `--time`: SLURM time limit (default: `02:00:00`).
- `--mounts`: Container mounts.
- `--work-dir`: Work directory (used for both workdir and container-workdir).
- `--draft-launch-sh`: Path to draft-launch.sh script.
- `--launch-sh`: Path to output launch.sh script.
- `--run-sh`: Path to slurm_run.sh script.
- `--install-sh`: Path to slurm_install.sh script.
- `--llm-src`: Path to LLM source code.
- `--build-wheel`: Add this flag to build the wheel before running tests.

## Aggregated Mode

Using `--test-list`:

```bash
python3 submit.py --test-list "perf/test_perf_sanity.py::test_e2e[aggr-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_tep8_mtp3]" \
    --partition batch \
    --account coreai_comparch_trtllm \
    --job-name aggr_test \
    --image "urm.nvidia.com#sw-tensorrt-docker/tensorrt-llm:pytorch-25.12-py3-aarch64-ubuntu24.04-trt10.14.1.48-skip-tritondevel-202602011118-10901" \
    --mounts "/home/chenfeiz/:/home/chenfeiz/,/home/chenfeiz/.cache:/root/.cache,/lustre/fsw/portfolios/coreai/:/lustre/fsw/portfolios/coreai/,/lustre/fs1/portfolios/coreai/:/lustre/fs1/portfolios/coreai/" \
    --llm-models-root /lustre/fs1/portfolios/coreai/projects/coreai_tensorrt_ci/llm-models
```

Using `--config-file` and `--test-name`:

```bash
python3 submit.py --config-file /lustre/fsw/portfolios/coreai/users/chenfeiz/repo/trtllm-1/tests/scripts/perf-sanity/deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yaml \
    --test-name r1_fp4_v2_tep8_mtp3 \
    --partition batch \
    --account coreai_comparch_trtllm \
    --job-name aggr_test \
    --image "urm.nvidia.com#sw-tensorrt-docker/tensorrt-llm:pytorch-25.12-py3-aarch64-ubuntu24.04-trt10.14.1.48-skip-tritondevel-202602011118-10901" \
    --mounts "/home/chenfeiz/:/home/chenfeiz/,/home/chenfeiz/.cache:/root/.cache,/lustre/fsw/portfolios/coreai/:/lustre/fsw/portfolios/coreai/,/lustre/fs1/portfolios/coreai/:/lustre/fs1/portfolios/coreai/" \
    --llm-models-root /lustre/fs1/portfolios/coreai/projects/coreai_tensorrt_ci/llm-models
```

## Disaggregated Mode

Using `--test-list`:

```bash
python3 submit.py --test-list "perf/test_perf_sanity.py::test_e2e[disagg-gb200-deepseek-r1-fp4_1k1k_ctx1_dep4_gen1_dep4_eplb0_mtp1_ccb-UCX]" \
    --partition batch \
    --account coreai_comparch_trtllm \
    --job-name disagg_test \
    --image "urm.nvidia.com#sw-tensorrt-docker/tensorrt-llm:pytorch-25.12-py3-aarch64-ubuntu24.04-trt10.14.1.48-skip-tritondevel-202602011118-10901" \
    --mounts "/home/chenfeiz/:/home/chenfeiz/,/home/chenfeiz/.cache:/root/.cache,/lustre/fsw/portfolios/coreai/:/lustre/fsw/portfolios/coreai/,/lustre/fs1/portfolios/coreai/:/lustre/fs1/portfolios/coreai/" \
    --llm-models-root /lustre/fs1/portfolios/coreai/projects/coreai_tensorrt_ci/llm-models
```

Using `--config-file`:

```bash
python3 submit.py --config-file /lustre/fsw/portfolios/coreai/users/chenfeiz/repo/trtllm-1/tests/integration/defs/perf/disagg/test_configs/disagg/perf-sanity/gb200-deepseek-r1-fp4_1k1k_ctx1_dep4_gen1_dep4_eplb0_mtp1_ccb-UCX.yaml \
    --benchmark-mode gen_only \
    --partition batch \
    --account coreai_comparch_trtllm \
    --job-name disagg_test \
    --image "urm.nvidia.com#sw-tensorrt-docker/tensorrt-llm:pytorch-25.12-py3-aarch64-ubuntu24.04-trt10.14.1.48-skip-tritondevel-202602011118-10901" \
    --mounts "/home/chenfeiz/:/home/chenfeiz/,/home/chenfeiz/.cache:/root/.cache,/lustre/fsw/portfolios/coreai/:/lustre/fsw/portfolios/coreai/,/lustre/fs1/portfolios/coreai/:/lustre/fs1/portfolios/coreai/" \
    --llm-models-root /lustre/fs1/portfolios/coreai/projects/coreai_tensorrt_ci/llm-models
```
