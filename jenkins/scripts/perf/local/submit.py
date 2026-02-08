#!/usr/bin/env python3
import argparse
import os
import re
from datetime import datetime

import yaml


def get_llm_src_default():
    """Get default llm_src path by going up 4 directories from this script."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(script_dir, "..", "..", "..", ".."))


def parse_test_string(test_string, llm_src, is_disagg):
    """Parse test string to get config yaml path, config base name, and test name.

    Examples:
        perf/test_perf_sanity.py::test_e2e[aggr-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_tep8_mtp3]
        perf/test_perf_sanity.py::test_e2e[disagg_upload-gb200-deepseek-r1-fp4_1k1k_ctx1_dep4_gen1_dep4_eplb0_mtp1
            _ccb-UCX] TIMEOUT (120)

    We ignore "TIMEOUT (xxx)" suffix if present.
    Note: aggr_upload is treated as aggr, disagg_upload is treated as disagg.
    """
    # Remove TIMEOUT suffix if present
    test_string = re.sub(r"\s+TIMEOUT\s*\(\d+\)\s*$", "", test_string.strip())

    if "[" not in test_string or "]" not in test_string:
        raise ValueError(
            f"Invalid test string format. Expected test name with brackets: {test_string}"
        )
    bracket_content = test_string.split("[")[-1].split("]")[0]
    parts = bracket_content.split("-")
    if len(parts) < 2:
        raise ValueError(
            f"Invalid test name format. Expected format: prefix-config_name, got: {bracket_content}"
        )

    # Check prefix: aggr/aggr_upload for aggregated, disagg/disagg_upload for disaggregated
    prefix = parts[0]
    is_aggr_prefix = prefix in ("aggr", "aggr_upload")
    is_disagg_prefix = prefix in ("disagg", "disagg_upload")

    if is_disagg:
        # For disagg: disagg-gb200-deepseek-r1-fp4_1k1k_ctx1_dep4_gen1_dep4_eplb0_mtp1_ccb-UCX
        if not is_disagg_prefix:
            raise ValueError(
                f"Invalid test name format. Expected format: disagg-config_name or "
                f"disagg_upload-config_name, got: {bracket_content}"
            )
        config_base_name = "-".join(parts[1:])
        config_yaml_path = os.path.join(
            llm_src,
            "tests",
            "integration",
            "defs",
            "perf",
            "disagg",
            "test_configs",
            "disagg",
            "perf-sanity",
            f"{config_base_name}.yaml",
        )
        test_name = None
    else:
        # For aggr: aggr-config_yml-server_config_name
        if not is_aggr_prefix:
            raise ValueError(
                f"Invalid test name format. Expected format: aggr-config_name or "
                f"aggr_upload-config_name, got: {bracket_content}"
            )
        config_base_name = parts[1]
        config_yaml_path = os.path.join(
            llm_src,
            "tests",
            "scripts",
            "perf-sanity",
            f"{config_base_name}.yaml",
        )
        # test_name is server config name (e.g., "r1_fp8_dep8_mtp1_1k1k")
        test_name = "-".join(parts[2:]) if len(parts) > 2 else None

    if not os.path.exists(config_yaml_path):
        raise FileNotFoundError(f"Config file not found: {config_yaml_path}")
    return config_yaml_path, config_base_name, test_name


def get_hardware_config(config, is_disagg, test_name=None, benchmark_mode=None):
    """Get hardware config based on mode."""
    hardware = config.get("hardware", {})
    gpus_per_node = hardware.get("gpus_per_node")

    if gpus_per_node is None:
        raise ValueError("Missing gpus_per_node in hardware configuration")

    if not is_disagg:
        # Aggregated mode
        server_configs = config.get("server_configs", [])
        server_config = None
        for sc in server_configs:
            if sc.get("name") == test_name:
                server_config = sc
                break

        if server_config is None:
            raise ValueError(f"Server config not found for test_name: {test_name}")

        tp = server_config.get("tensor_parallel_size", 1)
        pp = server_config.get("pipeline_parallel_size", 1)
        cp = server_config.get("context_parallel_size", 1)
        gpus_per_server = tp * pp * cp

        nodes_per_server = (gpus_per_server + gpus_per_node - 1) // gpus_per_node
        total_nodes = nodes_per_server
        total_gpus = total_nodes * gpus_per_node
        gpus_per_node_per_server = min(gpus_per_server, gpus_per_node)

        return {
            "gpus_per_node": gpus_per_node,
            "gpus_per_server": gpus_per_server,
            "nodes_per_server": nodes_per_server,
            "gpus_per_node_per_server": gpus_per_node_per_server,
            "total_nodes": total_nodes,
            "total_gpus": total_gpus,
        }
    else:
        # Disaggregated mode
        worker_config = config.get("worker_config", {})

        num_ctx_servers = (
            0
            if "gen_only_no_context" in (benchmark_mode or "")
            else hardware.get("num_ctx_servers")
        )
        num_gen_servers = hardware.get("num_gen_servers")

        ctx_config = worker_config.get("ctx", {})
        gen_config = worker_config.get("gen", {})
        ctx_tp = ctx_config.get("tensor_parallel_size", 1)
        ctx_pp = ctx_config.get("pipeline_parallel_size", 1)
        ctx_cp = ctx_config.get("context_parallel_size", 1)
        gpus_per_ctx_server = ctx_tp * ctx_pp * ctx_cp
        gen_tp = gen_config.get("tensor_parallel_size", 1)
        gen_pp = gen_config.get("pipeline_parallel_size", 1)
        gen_cp = gen_config.get("context_parallel_size", 1)
        gpus_per_gen_server = gen_tp * gen_pp * gen_cp

        if None in [
            num_ctx_servers,
            num_gen_servers,
            gpus_per_ctx_server,
            gpus_per_gen_server,
        ]:
            raise ValueError("Missing required hardware configuration")

        nodes_per_ctx_server = (gpus_per_ctx_server + gpus_per_node - 1) // gpus_per_node
        nodes_per_gen_server = (gpus_per_gen_server + gpus_per_node - 1) // gpus_per_node

        gpus_per_node_per_ctx_server = min(gpus_per_ctx_server, gpus_per_node)
        gpus_per_node_per_gen_server = min(gpus_per_gen_server, gpus_per_node)

        total_nodes = (
            num_ctx_servers * nodes_per_ctx_server + num_gen_servers * nodes_per_gen_server
        )
        total_gpus = total_nodes * gpus_per_node

        return {
            "num_ctx_servers": num_ctx_servers,
            "num_gen_servers": num_gen_servers,
            "gpus_per_node": gpus_per_node,
            "gpus_per_ctx_server": gpus_per_ctx_server,
            "gpus_per_gen_server": gpus_per_gen_server,
            "nodes_per_ctx_server": nodes_per_ctx_server,
            "nodes_per_gen_server": nodes_per_gen_server,
            "gpus_per_node_per_ctx_server": gpus_per_node_per_ctx_server,
            "gpus_per_node_per_gen_server": gpus_per_node_per_gen_server,
            "total_nodes": total_nodes,
            "total_gpus": total_gpus,
        }


def get_env_config(config, is_disagg):
    """Get env config based on mode."""
    if not is_disagg:
        return {}
    env = config.get("environment", {})
    return {
        "worker_env_var": env.get("worker_env_var", ""),
        "server_env_var": env.get("server_env_var", ""),
        "benchmark_env_var": env.get("benchmark_env_var", ""),
    }


def get_benchmark_config(config, is_disagg):
    """Get benchmark config based on mode."""
    if not is_disagg:
        return {}
    benchmark = config.get("benchmark", {})
    mode = benchmark.get("mode", "e2e")
    concurrency_str = benchmark.get("concurrency_list", "1")
    concurrency = int(concurrency_str) if isinstance(concurrency_str, str) else concurrency_str

    return {
        "mode": mode,
        "concurrency": concurrency,
    }


def generate_sbatch_params(args, hardware_config, work_dir, mode):
    """Generate #SBATCH parameters."""
    total_nodes = hardware_config["total_nodes"]
    gpus_per_node = hardware_config["gpus_per_node"]
    total_gpus = hardware_config["total_gpus"]
    lines = [
        "#!/bin/bash",
        f"#SBATCH --nodes={total_nodes}",
        f"#SBATCH --segment={total_nodes}",
        f"#SBATCH --ntasks={total_gpus}",
        f"#SBATCH --ntasks-per-node={gpus_per_node}",
        f"#SBATCH --gpus-per-node={gpus_per_node}",
        f"#SBATCH --gres=gpu:{gpus_per_node}",
        f"#SBATCH --partition={args.partition}",
        f"#SBATCH --time={args.time}",
        f"#SBATCH --account={args.account}",
        f"#SBATCH -J {args.job_name}",
        f"#SBATCH -o {work_dir}/slurm-%j.out",
    ]
    return lines


def generate_srun_args(args, mode, timestamp):
    """Generate srun arguments."""
    is_disagg = mode == "disaggregated"
    container_name = f"{'disagg' if is_disagg else 'aggr'}_test-{timestamp}"

    lines = [
        f"--container-name={container_name}",
        f"--container-image={args.image}",
    ]

    if args.work_dir:
        lines.append(f"--container-workdir={args.work_dir}")

    if args.mounts:
        lines.append(f"--container-mounts={args.mounts}")

    lines.append("--container-env=NVIDIA_IMEX_CHANNELS")

    if is_disagg:
        lines.append("--mpi=pmix")
    else:
        lines.append("--mpi=pmi2")

    return lines


def generate_pytest_command(llm_src, work_dir, config_file_base_name, test_name, mode):
    """Generate pytest command and test list."""
    is_disagg = mode == "disaggregated"

    if is_disagg:
        test_list_content = f"perf/test_perf_sanity.py::test_e2e[disagg-{config_file_base_name}]"
    else:
        test_list_content = (
            f"perf/test_perf_sanity.py::test_e2e[aggr-{config_file_base_name}-{test_name}]"
        )

    test_list_path = os.path.join(work_dir, "test_list.txt")

    pytest_command = (
        f"pytest -v -s "
        f"--test-prefix={llm_src}/tests/integration/defs "
        f"--test-list={test_list_path} "
        f"--output-dir={work_dir}/output "
        f"-o junit_logging=out-err"
    )

    return pytest_command, test_list_content, test_list_path


def remove_whitespace_lines(lines):
    """Remove empty lines and strip whitespace."""
    return [line for line in lines if line.strip()]


def main():
    parser = argparse.ArgumentParser(
        description="Generate SLURM launch script for local runs (aggregated or disaggregated)"
    )
    parser.add_argument(
        "--mode",
        required=True,
        choices=["aggregated", "disaggregated"],
        help="Mode: aggregated or disaggregated",
    )
    parser.add_argument(
        "--test-list",
        default="",
        help="Test string, e.g., 'perf/test_perf_sanity.py::test_e2e[aggr-config-test_name]'. "
        "If both --test-list and --config-file are provided, --test-list takes precedence.",
    )
    parser.add_argument("--config-file", default="", help="Path to config YAML file")
    parser.add_argument(
        "--test-name",
        default="",
        help="Test name (only used for aggregated mode when --config-file is provided)",
    )
    parser.add_argument("--partition", required=True, help="SLURM partition")
    parser.add_argument("--time", default="02:00:00", help="SLURM time limit")
    parser.add_argument("--account", required=True, help="SLURM account")
    parser.add_argument("--job-name", required=True, help="SLURM job name")
    parser.add_argument("--image", required=True, help="Container image")
    parser.add_argument("--mounts", default="", help="Container mounts")
    parser.add_argument(
        "--work-dir",
        default="",
        help="Work directory (used for both workdir and container-workdir)",
    )
    parser.add_argument("--draft-launch-sh", default="", help="Path to draft-launch.sh script")
    parser.add_argument("--launch-sh", default="", help="Path to output launch.sh script")
    parser.add_argument("--run-sh", default="", help="Path to slurm_run.sh script")
    parser.add_argument("--install-sh", default="", help="Path to slurm_install.sh script")
    parser.add_argument("--llm-src", default="", help="Path to LLM source code")
    parser.add_argument("--llm-models-root", required=True, help="Path to LLM models root")
    parser.add_argument(
        "--build-wheel", action="store_true", help="Build wheel before running tests"
    )

    args = parser.parse_args()

    # Determine llm_src
    llm_src = args.llm_src if args.llm_src else get_llm_src_default()
    llm_src = os.path.abspath(llm_src)
    is_disagg = args.mode == "disaggregated"

    # Determine config_yaml, config_file_base_name, and test_name
    # --test-list takes precedence over --config-file
    if args.test_list:
        config_yaml, config_file_base_name, test_name = parse_test_string(
            args.test_list, llm_src, is_disagg
        )
    elif args.config_file:
        config_yaml = args.config_file
        config_file_base_name = os.path.splitext(os.path.basename(config_yaml))[0]
        test_name = args.test_name if not is_disagg else None
    else:
        raise ValueError("Either --test-list or --config-file must be provided")

    # Validate test_name for aggregated mode
    if not is_disagg and not test_name:
        raise ValueError("--test-name is required for aggregated mode when --config-file is used")

    # Load config
    with open(config_yaml, "r") as f:
        config = yaml.safe_load(f)

    # Create timestamp
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    # Determine work_dir
    work_dir = args.work_dir
    if not work_dir:
        work_dir = os.path.join(llm_src, "jenkins", "scripts", "perf", "local", timestamp)
    os.makedirs(work_dir, exist_ok=True)

    # Determine paths
    launch_sh = args.launch_sh if args.launch_sh else os.path.join(work_dir, "slurm_launch.sh")
    run_sh = (
        args.run_sh
        if args.run_sh
        else os.path.join(llm_src, "jenkins", "scripts", "perf", "local", "slurm_run.sh")
    )
    install_sh = (
        args.install_sh
        if args.install_sh
        else os.path.join(llm_src, "jenkins", "scripts", "perf", "local", "slurm_install.sh")
    )
    draft_launch_sh = args.draft_launch_sh
    if not draft_launch_sh:
        draft_launch_sh = os.path.join(
            llm_src,
            "jenkins",
            "scripts",
            "perf",
            "disaggregated" if is_disagg else "aggregated",
            "slurm_launch_draft.sh",
        )

    # Get configs based on mode
    env_config = get_env_config(config, is_disagg)
    benchmark_config = get_benchmark_config(config, is_disagg)
    hardware_config = get_hardware_config(
        config,
        is_disagg,
        test_name=test_name,
        benchmark_mode=benchmark_config.get("mode", "e2e") if is_disagg else None,
    )

    # Generate sbatch params
    sbatch_lines = generate_sbatch_params(args, hardware_config, work_dir, args.mode)

    # Generate srun args
    srun_args_lines = generate_srun_args(args, args.mode, timestamp)

    # Generate pytest command
    pytest_command, test_list_content, test_list_path = generate_pytest_command(
        llm_src, work_dir, config_file_base_name, test_name, args.mode
    )

    # Write test list file
    with open(test_list_path, "w") as f:
        f.write(test_list_content + "\n")

    # Build script prefix lines
    script_prefix_lines = sbatch_lines.copy()
    script_prefix_lines.append("")  # Empty line after sbatch

    # Add export variables
    script_prefix_lines.extend(
        [
            f"export llmSrcNode='{llm_src}'",
            f"export jobWorkspace='{work_dir}'",
            f"export runScript='{run_sh}'",
            f"export installScript='{install_sh}'",
            f"export configYamlPath='{config_yaml}'",
            f"export BUILD_WHEEL={'true' if args.build_wheel else 'false'}",
        ]
    )

    pytest_common_vars = (
        f"LLM_ROOT='{llm_src}' "
        f"LLM_BACKEND_ROOT='{llm_src}/triton_backend' "
        f"LLM_MODELS_ROOT='{args.llm_models_root}' "
    )
    llmapi_launch = f"{llm_src}/tensorrt_llm/llmapi/trtllm-llmapi-launch"

    if is_disagg:
        # Build worker env vars
        worker_env_vars = env_config.get("worker_env_var", "")
        server_env_vars = env_config.get("server_env_var", "")
        benchmark_env_var = env_config.get("benchmark_env_var", "")
        # Handle gen only mode
        if "gen_only_no_context" in benchmark_config.get("mode", ""):
            worker_env_vars = f"TRTLLM_DISAGG_BENCHMARK_GEN_ONLY=1 {worker_env_vars}"
            server_env_vars = f"TRTLLM_DISAGG_BENCHMARK_GEN_ONLY=1 {server_env_vars}"
            script_prefix_lines.append("export TRTLLM_DISAGG_BENCHMARK_GEN_ONLY=1")
            srun_args_lines.append("--container-env=TRTLLM_DISAGG_BENCHMARK_GEN_ONLY")
        elif "gen_only" in benchmark_config.get("mode", ""):
            concurrency = benchmark_config.get("concurrency", 1)
            worker_env_vars = (
                f"TRTLLM_DISABLE_KV_CACHE_TRANSFER_OVERLAP=1 "
                f"TLLM_BENCHMARK_REQ_QUEUES_SIZE={concurrency} {worker_env_vars}"
            )

        pytest_cmd_worker = (
            f"unset UCX_TLS && {worker_env_vars} {pytest_common_vars} "
            f"{llmapi_launch} {pytest_command}"
        )
        script_prefix_lines.extend(
            [
                f'export pytestCommandWorker="{pytest_cmd_worker}"',
                f'export pytestCommandDisaggServer="{server_env_vars} {pytest_common_vars} {pytest_command}"',
                f'export pytestCommandBenchmark="{benchmark_env_var} {pytest_common_vars} {pytest_command}"',
                f"export numCtxServers={hardware_config.get('num_ctx_servers', '')}",
                f"export numGenServers={hardware_config.get('num_gen_servers', '')}",
                f"export gpusPerNode={hardware_config.get('gpus_per_node', '')}",
                f"export gpusPerCtxServer={hardware_config.get('gpus_per_ctx_server', '')}",
                f"export gpusPerGenServer={hardware_config.get('gpus_per_gen_server', '')}",
                f"export nodesPerCtxServer={hardware_config.get('nodes_per_ctx_server', '')}",
                f"export nodesPerGenServer={hardware_config.get('nodes_per_gen_server', '')}",
                f"export gpusPerfNodePerfCtxServer={hardware_config.get('gpus_per_node_per_ctx_server', '')}",
                f"export gpusPerfNodePerfGenServer={hardware_config.get('gpus_per_node_per_gen_server', '')}",
                f"export totalNodes={hardware_config.get('total_nodes', '')}",
                f"export totalGpus={hardware_config.get('total_gpus', '')}",
            ]
        )

        # Add srun args for disagg
        srun_args_lines.extend(
            [
                "--container-env=DISAGG_SERVING_TYPE",
                "--container-env=pytestCommand",
            ]
        )
    else:
        # Aggregated mode - only export pytestCommand
        script_prefix_lines.extend(
            [
                f'export pytestCommand="{pytest_common_vars} {llmapi_launch} {pytest_command}"',
                f"export gpusPerNode={hardware_config.get('gpus_per_node', '')}",
                f"export totalNodes={hardware_config.get('total_nodes', '')}",
                f"export totalGpus={hardware_config.get('total_gpus', '')}",
            ]
        )

    # Remove whitespace lines
    script_prefix_lines = remove_whitespace_lines(script_prefix_lines)

    # Format srun args
    srun_args_lines = ["srunArgs=("] + [f'  "{line}"' for line in srun_args_lines] + [")"]
    srun_args = "\n".join(srun_args_lines)

    # Read draft launch script
    with open(draft_launch_sh, "r") as f:
        draft_launch_content = f.read()
    draft_launch_lines = draft_launch_content.split("\n")
    draft_launch_lines = remove_whitespace_lines(draft_launch_lines)
    draft_launch_content = "\n".join(draft_launch_lines)

    # Combine and write launch script
    script_prefix = "\n".join(script_prefix_lines)
    final_script = f"{script_prefix}\n\n{srun_args}\n\n{draft_launch_content}"

    with open(launch_sh, "w") as f:
        f.write(final_script)

    # Make scripts executable
    os.chmod(launch_sh, 0o755)
    os.chmod(run_sh, 0o755)
    os.chmod(install_sh, 0o755)

    print(f"\nLaunch script generated at: {launch_sh}")
    print("\nTo submit the job, run:")
    print(f"  sbatch {launch_sh}")


if __name__ == "__main__":
    main()
