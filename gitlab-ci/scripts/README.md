# Scripts Directory Structure

This directory contains all scripts used in the disagg CI/CD pipeline.

## Directory Layout

```
scripts/
├── lib/                          # Shared libraries
│   └── remote.sh                # Remote operations (SSH/SCP) wrapper
├── disagg/                      # Main pipeline scripts (numbered by execution order)
│   ├── 1_validate.sh           # Display configuration
│   ├── 2_init.sh               # Initialize (fetch Docker/wheel)
│   ├── 3_scm.sh                # Clone repositories  
│   ├── 4_sync.sh               # Sync to cluster
│   ├── 5_build.sh              # Build from source
│   ├── 6_setup.sh              # Setup poetry environment
│   ├── 7_test.sh               # Run tests
│   ├── 8_artifacts.sh          # Collect results
│   ├── 9_analyze.sh            # Analyze performance
│   └── 10_report.sh            # Generate report
└── utilities/                   # Reusable utility scripts
    ├── get_docker_image.sh     # Fetch Docker image from GitHub
    ├── install_trtllm.sh       # Fetch wheel URL from Artifactory
    ├── clone_tensorrt_llm.sh   # Clone TensorRT-LLM repository
    ├── setup_poetry.sh         # Setup poetry dependencies
    ├── run_disagg_test.sh      # Main test execution script
    ├── merge_junit_xml.py      # Merge JUnit XML files
    └── download_wheel.sh       # Download wheel file
```

## Usage

### Main Pipeline Scripts (disagg/)

Called from `.gitlab-ci/disagg_test.yml`:

```bash
bash scripts/disagg/1_validate.sh "${GPU}"
bash scripts/disagg/2_init.sh "${GPU}"
# ... etc
```

Each script:
- Takes `GPU` (GB200/GB300) as the first argument
- Sources configuration from `config_${GPU}.env` or `config_final_${GPU}.env`
- Uses `scripts/lib/remote.sh` for remote operations

### Utility Scripts (utilities/)

Called by main pipeline scripts or uploaded to remote cluster:

```bash
# Called locally
bash scripts/utilities/get_docker_image.sh --repo REPO --branch BRANCH --arch ARCH

# Called on remote cluster
remote_script "${CLUSTER_WORKDIR}/scripts/run_disagg_test.sh" ARGS...
```

### Remote Operations Library (lib/remote.sh)

Automatically adapts to GB200 (SSH) and GB300 (local) execution:

```bash
# In any script
source scripts/lib/remote.sh

# Use unified interface
remote_exec "command"                    # Execute command
remote_copy local_file remote_path       # Copy files
remote_mkdir "/path"                     # Create directory
remote_script "/path/to/script.sh" args  # Execute script

# Or use legacy variables (backward compatible)
$SSH_CMD "command"
$SCP_CMD local_file ${CLUSTER_USERNAME}@${HOST}:remote_path
```

## Migration Notes

### From Old Structure

**Old:**
```
scripts/
├── 1_get_docker_image.sh
├── 2_install_trtllm.sh
├── 3_clone_tensorrt_llm.sh
└── ...
```

**New:**
```
scripts/
├── lib/remote.sh
├── disagg/1_validate.sh, 2_init.sh, ...
└── utilities/get_docker_image.sh, install_trtllm.sh, ...
```

### Path Updates

- ✅ YAML references: Updated to `scripts/disagg/*.sh`
- ✅ Utility scripts: Moved to `scripts/utilities/`
- ✅ Remote operations: Centralized in `lib/remote.sh`

## Benefits

1. **Clear organization**: Pipeline scripts in `disagg/`, utilities in `utilities/`
2. **Easy navigation**: Scripts numbered by execution order (1-10)
3. **Unified remote ops**: Single `remote.sh` library for SSH/SCP
4. **Better modularity**: Each pipeline step in a separate file
5. **Easier testing**: Can run individual scripts locally

## Example: Running Locally

```bash
# Set up environment
export GPU=GB200
export DOCKER_IMAGE=""
export INSTALL_MODE="wheel"
# ... other variables ...

# Run individual steps
bash scripts/disagg/2_init.sh GB200
bash scripts/disagg/3_scm.sh GB200
# etc.
```
