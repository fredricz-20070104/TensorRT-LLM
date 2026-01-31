# Disaggregated Test Pipeline - User Guide

## Overview

The `disagg_test.yml` pipeline provides a comprehensive, parameterized testing framework for TensorRT-LLM disaggregated multi-node performance testing. It supports flexible GPU selection, independent execution paths, and automated resource management.

**Latest Updates:**
- ✅ Independent DAG chains for GB200 and GB300 (fully parallel execution)
- ✅ Auto-fetch Docker images and Wheel URLs
- ✅ Uses modular scripts from `scripts/` folder
- ✅ Complete enroot Docker conversion workflow
- ✅ COMMIT_TIME support for performance tracking
- ✅ Extensive YAML anchor inheritance (645 lines, 0% code duplication)

## Key Features

### 1. Independent Execution Chains
- Each GPU (GB200/GB300) has its own set of jobs
- Jobs are linked via `needs` to form independent DAG chains
- GB200 can proceed to test/analyze while GB300 is still in sync stage
- No cross-GPU dependencies or waiting

### 2. GPU Selection Control
Control which GPUs to test using two variables:
- `RUN_GB200`: Set to `"true"` to run GB200 tests only
- `RUN_GB300`: Set to `"true"` to run GB300 tests only
- Leave both unset (or `"false"`) to run all GPUs (default)

### 3. Automated Resource Management
- **Auto-fetch Docker images** from GitHub releases
- **Auto-fetch Wheel URLs** from Artifactory
- **Automatic enroot conversion** for Docker images
- **Architecture detection** (aarch64 for GB200/GB300)

### 4. Fixed Runner Assignment per GPU
- GB200 jobs → `selene_login` runner (defined in `.disagg_gb200_base`)
- GB300 jobs → `lyris` runner (defined in `.disagg_gb300_base`)
- Each GPU has its own base configuration template

### 5. Modular Script Architecture with YAML Anchors
- **10 common script templates** (`.disagg_*_common_script`) shared across GPUs
- **2 base templates** (`.disagg_gb200_base`, `.disagg_gb300_base`) for GPU-specific config
- **Zero code duplication** - all scripts use anchor inheritance
Uses standalone scripts from `scripts/` folder:
- `1_get_docker_image.sh` - Fetch Docker image from GitHub
- `2_install_trtllm.sh` - Fetch Wheel URL from Artifactory
- `3_clone_tensorrt_llm.sh` - Clone TensorRT-LLM repository
- `4_setup_poetry.sh` - Setup poetry environment
- `5_run_disagg_test.sh` - Run disagg tests with retry support
- `6_merge_junit_xml.py` - Merge JUnit XML results
- `7_download_wheel.sh` - Download wheel files with retry

## Usage

### Method 1: Manual Trigger via GitLab Web UI

1. Navigate to **CI/CD → Pipelines**
2. Click **Run Pipeline**
3. Select branch
4. Add variables:

**⚠️ CRITICAL - Variable Rules:**
- ✅ **SAFE TO SET**: `TEST_TYPE`, `RUN_GB200`, `RUN_GB300`, `TRT_LLM_BRANCH`, `INSTALL_MODE`, etc.
- ❌ **NEVER SET**: `GPU`, `RUNNER_TAG`, `HOST`, `CLUSTER_PARTITION` - These are managed by base templates (`.disagg_gb200_base` / `.disagg_gb300_base`)

#### Run All GPUs (Default)
```
TEST_TYPE = disagg
```

#### Run GB200 Only
```
TEST_TYPE = disagg
RUN_GB200 = true
RUN_GB300 = false
```

#### Run GB300 Only
```
TEST_TYPE = disagg
RUN_GB200 = false
RUN_GB300 = true
```

#### Run Both GPUs Explicitly
```
TEST_TYPE = disagg
RUN_GB200 = true
RUN_GB300 = true
```

#### With Custom Configuration
```
TEST_TYPE = disagg
TRT_LLM_BRANCH = feature/my-branch
TEST_MODEL = llama3
FAILED_RERUN = 2
```

### Method 2: API Trigger

#### Run All GPUs
```bash
curl -X POST \
  --form token=YOUR_TRIGGER_TOKEN \
  --form ref=main \
  --form "variables[TEST_TYPE]=disagg" \
  https://gitlab-master.nvidia.com/api/v4/projects/YOUR_PROJECT_ID/trigger/pipeline
```

#### Run GB200 Only
```bash
curl -X POST \
  --form token=YOUR_TRIGGER_TOKEN \
  --form ref=main \
  --form "variables[TEST_TYPE]=disagg" \
  --form "variables[RUN_GB200]=true" \
  --form "variables[RUN_GB300]=false" \
  https://gitlab-master.nvidia.com/api/v4/projects/YOUR_PROJECT_ID/trigger/pipeline
```

#### Run GB300 Only
```bash
curl -X POST \
  --form token=YOUR_TRIGGER_TOKEN \
  --form ref=main \
  --form "variables[TEST_TYPE]=disagg" \
  --form "variables[RUN_GB200]=false" \
  --form "variables[RUN_GB300]=true" \
  https://gitlab-master.nvidia.com/api/v4/projects/YOUR_PROJECT_ID/trigger/pipeline
```

### Method 3: Predefined Workflows in `.gitlab-ci.yml`

Create specific workflow rules in the parent `.gitlab-ci.yml`:

```yaml
workflow:
  rules:
    # Nightly GB200 tests
    - if: $CI_PIPELINE_SOURCE == "schedule" && $SCHEDULE_TYPE == "nightly_gb200"
      variables:
        TEST_TYPE: "disagg"
        RUN_GB200: "true"
        RUN_GB300: "false"
    
    # Nightly GB300 tests
    - if: $CI_PIPELINE_SOURCE == "schedule" && $SCHEDULE_TYPE == "nightly_gb300"
      variables:
        TEST_TYPE: "disagg"
        RUN_GB200: "false"
        RUN_GB300: "true"
    
    # Weekly full regression (both GPUs)
    - if: $CI_PIPELINE_SOURCE == "schedule" && $SCHEDULE_TYPE == "weekly_full"
      variables:
        TEST_TYPE: "disagg"
        RUN_GB200: "true"
        RUN_GB300: "true"
```

## Configuration Variables

### Primary Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `GPU` | `GB200` | GPU type (auto-set by matrix) |
| `RUNNER_TAG` | Auto | Runner tag (auto-determined, or set manually) |
| `CLUSTER_USERNAME` | `fredricz` | Cluster username |
| `DOCKER_IMAGE` | `""` | Docker image (leave empty to auto-fetch) |
| `WHEEL_URL` | `""` | Wheel URL (leave empty to auto-fetch) |
| `INSTALL_MODE` | `wheel` | Installation mode: `none`, `wheel`, or `source` |
| `TEST_MODEL` | `kimi-k2 and 1k1k` | Test model filter |
| `LLM_VERSION` | `1.2.0rc5` | LLM version |
| `TRT_LLM_BRANCH` | `main` | Branch to fetch resources from |
| `TRT_LLM_REPO` | `fredricz-20070104/TensorRT-LLM` | Repository path |
| `FAILED_RERUN` | `0` | Number of retries for failed tests |
| `WRITE_PERF_DB` | `true` | Write performance data to database |
| `FORK_GITHUB` | `true` | Use GitHub fork for cloning |
| `DISAGG_MULTI_NODE_TEST_LIST` | `testlist/wideep.txt` | Test list file |

### GPU Selection Flags

| Variable | Default | Description |
|----------|---------|-------------|
| `RUN_GB200` | `false` | Set to `"true"` to run GB200 tests |
| `RUN_GB300` | `false` | Set to `"true"` to run GB300 tests |

**Note:** If both are `false` (or unset), all GPUs will run (default behavior).

### Internal Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TENSORRT_VERSION` | `10.8.0.32` | TensorRT version |
| `CUDA_VERSION` | `12.8` | CUDA version |
| `REPORT_DIR` | `output` | Output directory name |
| `TIMEOUT` | `3600` | Job timeout in seconds |
| `TEST_TIME` | `4:00:00` | Slurm test time limit |

## Pipeline Structure

The pipeline consists of 10 stages, with **independent job chains** for GB200 and GB300:

```
GB200 Chain:
  disagg:validate:gb200 (.pre)
    ↓
  disagg:init:gb200 (init)
    ↓
  disagg:scm:gb200 (scm)
    ↓
  disagg:sync:gb200 (sync)
    ↓
  disagg:build:gb200 (build)
    ↓
  disagg:setup:gb200 (setup)
    ↓
  disagg:test:gb200 (test)
    ↓
  disagg:artifacts:gb200 (artifacts)
    ↓
  disagg:analyze:gb200 (analyze)
    ↓
  disagg:report:gb200 (report)

GB300 Chain: (runs independently in parallel)
  disagg:validate:gb300 → init:gb300 → scm:gb300 → sync:gb300 → ... → report:gb300
```

### Stage Details

**Stage 0: .pre - Validation**
- `disagg:validate:gb200` - Display GB200 configuration
- `disagg:validate:gb300` - Display GB300 configuration

**Stage 1: init - Initialize Configuration**
- `disagg:init:gb200` - Detect architecture, auto-fetch Docker image/wheel for GB200
- `disagg:init:gb300` - Same for GB300
- Artifacts: `config_${GPU}.env`, `docker_image_${GPU}.txt`, `download_url_${GPU}.txt`

**Stage 2: scm - Clone Repositories**
- `disagg:scm:gb200` - Clone forest repository for GB200
- `disagg:scm:gb300` - Clone forest repository for GB300
- Artifacts: `config_${GPU}.env`, `forest_${GPU}/`

**Stage 3: sync - Sync Data to Cluster**
- `disagg:sync:gb200` - Sync data, clone TensorRT-LLM, convert Docker to enroot for GB200
- `disagg:sync:gb300` - Same for GB300
- Artifacts: `config_${GPU}.env`

**Stage 4: build - Build Wheel**
- `disagg:build:gb200` - Build wheel from source if `INSTALL_MODE=source` (GB200)
- `disagg:build:gb300` - Same for GB300
- Artifacts: `config_${GPU}.env`

**Stage 5: setup - Setup Environment**
- `disagg:setup:gb200` - Install poetry on GB200 cluster
- `disagg:setup:gb300` - Install poetry on GB300 cluster
- Artifacts: `config_${GPU}.env`

**Stage 6: test - Run Disaggregated Tests**
- `disagg:test:gb200` - Run tests on GB200 via Slurm
- `disagg:test:gb300` - Run tests on GB300 via Slurm
- Artifacts: `config_${GPU}.env`

**Stage 7: artifacts - Collect Artifacts**
- `disagg:artifacts:gb200` - Download results, package CSVs/logs, cleanup GB200 workdir
- `disagg:artifacts:gb300` - Same for GB300
- Artifacts: `config_${GPU}.env`, `output/`, `*_${GPU}.tar.gz`, JUnit XML

**Stage 8: analyze - Analyze Results**
- `disagg:analyze:gb200` - Parse performance results, upload to database (GB200)
- `disagg:analyze:gb300` - Same for GB300

**Stage 9: report - Generate Reports**
- `disagg:report:gb200` - Final report for GB200
- `disagg:report:gb300` - Final report for GB300

### Key Pipeline Characteristics

✅ **True Parallel Execution**: GB200 and GB300 chains run completely independently
✅ **No Cross-GPU Waiting**: GB200 can finish while GB300 is still in sync stage
✅ **Individual Job Control**: Retry or debug single GPU jobs without affecting the other
✅ **GPU-Specific Artifacts**: All artifacts are suffixed with `_${GPU}` (e.g., `config_GB200.env`)


## Job Naming Convention

Each GPU has its own explicitly named jobs:

```
# GB200 Jobs
disagg:validate:gb200
disagg:init:gb200
disagg:scm:gb200
disagg:sync:gb200
disagg:build:gb200
disagg:setup:gb200
disagg:test:gb200
disagg:artifacts:gb200
disagg:analyze:gb200
disagg:report:gb200

# GB300 Jobs
disagg:validate:gb300
disagg:init:gb300
disagg:scm:gb300
disagg:sync:gb300
disagg:build:gb300
disagg:setup:gb300
disagg:test:gb300
disagg:artifacts:gb300
disagg:analyze:gb300
disagg:report:gb300
```

**Benefits:**
- ✅ Clear job names - easy to find and debug
- ✅ Individual retry - can retry single GPU jobs without affecting others
- ✅ Clean DAG visualization - two distinct chains visible in pipeline graph
- ✅ No matrix confusion - job names are exactly what you see

## GPU-Specific Configuration

### GB200 Configuration
- **Cluster**: OCI HSG
- **Host**: `oci-hsg-cs-001-login-01`
- **Runner**: `selene_login`
- **Account**: `coreai_comparch_trtllm`
- **Partition**: `batch`
- **Storage**: `/lustre/fs1/portfolios/coreai/projects/coreai_comparch_trtllm/common`
- **Enroot Partition**: `cpu_datamover`
- **Authentication**: SSH key (requires `SSH_PRIVATE_KEY` CI variable)

### GB300 Configuration
- **Cluster**: Lyris
- **Host**: `login-lyris02`
- **Runner**: `lyris`
- **Account**: `coreai_comparch_trtllm`
- **Partition**: `gb300`
- **Storage**: `/lustre/fsw/coreai_comparch_trtllm/common`
- **Enroot Partition**: `gb300`
- **Authentication**: Kerberos (no SSH key needed)

## Auto-Fetch Feature

### Docker Image Auto-Fetch

When `DOCKER_IMAGE` is empty or not set:

1. Runs `scripts/1_get_docker_image.sh`
2. Fetches latest Docker image from GitHub releases
3. Uses branch specified in `TRT_LLM_BRANCH`
4. Saves to `docker_image.txt`

Example:
```bash
./scripts/1_get_docker_image.sh \
  --repo fredricz-20070104/TensorRT-LLM \
  --branch main \
  --arch aarch64
```

### Wheel URL Auto-Fetch

When `WHEEL_URL` is empty and `INSTALL_MODE=wheel`:

1. Runs `scripts/2_install_trtllm.sh`
2. Determines Artifactory branch:
   - `release` if `TRT_LLM_BRANCH` contains "release"
   - `main` otherwise
3. Fetches latest wheel URL from Artifactory
4. Saves to `download_url.txt`

Example:
```bash
./scripts/2_install_trtllm.sh \
  --branch main \
  --arch aarch64
```

## Enroot Docker Conversion

When `DOCKER_IMAGE` is not a `.sqsh` file:

1. Extracts image tag from Docker image URL
2. Checks if `.sqsh` file already exists
3. If not, submits Slurm job to convert:
   ```bash
   enroot-import --partition <PARTITION> -o <OUTPUT>.sqsh <DOCKER_IMAGE>
   ```
4. Waits for job completion
5. Verifies `.sqsh` file creation
6. Updates `DOCKER_IMAGE` to point to `.sqsh` file

## COMMIT_TIME Feature

Automatically captures commit timestamp:

```bash
git show -s --date=format:'%Y-%m-%d %H:%M:%S' --format=%cd
```

Format: `YYYY-MM-DD HH:MM:SS`

Used in performance database for tracking:
```bash
--commit="$COMMIT_HASH"
--commit-time="$COMMIT_TIME"
```

## Failed Test Retry

Set `FAILED_RERUN` to enable automatic retry of failed tests:

```yaml
FAILED_RERUN: "0"  # Disabled (default)
FAILED_RERUN: "1"  # Retry once
FAILED_RERUN: "2"  # Retry twice
FAILED_RERUN: "3"  # Retry three times
```

The `5_run_disagg_test.sh` script handles retry logic automatically.

## Artifacts

Each pipeline run produces:

### Files
- `config.env` - Pipeline configuration
- `docker_image.txt` - Docker image URL/path
- `download_url.txt` - Wheel download URL
- `perf_results_csv.tar.gz` - Performance CSV results
- `slurm_test_logs.tar.gz` - Slurm job logs

### Directories
- `output/` - Test results and logs
- `forest/` - Performance parser scripts

### Reports
- JUnit XML test results (integrated in GitLab Tests tab)

Artifacts are kept for **30 days**.

## Troubleshooting

### Issue: Both GPU jobs run when I only want one

**Solution:** Explicitly set both flags:
```
RUN_GB200 = true
RUN_GB300 = false
```

### Issue: Job not running on correct runner

**Solution:** Check runner tag. You can manually override:
```
RUNNER_TAG = selene_login
```

Or check available runners:
```bash
# On GitLab
Settings → CI/CD → Runners
```

### Issue: Auto-fetch fails

**Symptoms:**
```
ERROR: Failed to fetch Docker image and none was provided
```

**Solution:**
1. Check GitHub API rate limits
2. Verify `TRT_LLM_REPO` and `TRT_LLM_BRANCH` are correct
3. Manually specify `DOCKER_IMAGE`:
   ```
   DOCKER_IMAGE = /path/to/custom.sqsh
   ```

### Issue: Enroot conversion hangs

**Solution:**
1. Check Slurm queue: `squeue -u $USER`
2. Check job state: `sacct -j <JOB_ID>`
3. Use pre-converted `.sqsh` file:
   ```
   DOCKER_IMAGE = /lustre/.../tensorrt-llm-xxx.sqsh
   ```

### Issue: Tests fail but pipeline succeeds

**Check:**
1. JUnit XML in GitLab Tests tab
2. Review `slurm_test_logs.tar.gz`
3. Set `FAILED_RERUN` for automatic retry

### Issue: Cannot SSH to cluster

**Symptoms:**
```
Permission denied (publickey)
```

**Solution:**
1. Verify `SSH_PRIVATE_KEY` CI/CD variable is set
2. Check runner has network access to cluster
3. For GitHub clone issues, verify SSH keys on cluster

## Migration Guide

### From Parallel Matrix to Split Job Names

**Old Way (parallel:matrix):**
```yaml
disagg:init:
  stage: init
  parallel:
    matrix:
      - GPU: "GB200"
        RUNNER_TAG: "selene_login"
      - GPU: "GB300"
        RUNNER_TAG: "lyris"
  tags:
    - $RUNNER_TAG
  script:
    - ...
```

**New Way (split job names + needs chain):**
```yaml
# Base templates with YAML anchors
.disagg_gb200_base: &disagg_gb200_base
  variables:
    GPU: "GB200"
    RUNNER_TAG: "selene_login"
  tags:
    - selene_login
  before_script:
    - export GPU="GB200"
    - export HOST="oci-hsg-cs-001-login-01"
    # ... more GB200 config

.disagg_gb300_base: &disagg_gb300_base
  variables:
    GPU: "GB300"
    RUNNER_TAG: "lyris"
  tags:
    - lyris
  before_script:
    - export GPU="GB300"
    - export HOST="login-lyris02"
    # ... more GB300 config

# Common script templates
.disagg_init_common_script: &disagg_init_common_script
  - echo "=== Initializing ${GPU} ==="
  - # ... common logic using $GPU variable

# Individual jobs
disagg:init:gb200:
  stage: init
  <<: *disagg_gb200_base
  script: *disagg_init_common_script
  artifacts: [...]

disagg:init:gb300:
  stage: init
  <<: *disagg_gb300_base
  script: *disagg_init_common_script
  artifacts: [...]

disagg:scm:gb200:
  stage: scm
  <<: *disagg_gb200_base
  needs:
    - job: disagg:init:gb200  # ← needs chain
  script: *disagg_scm_common_script
```

**Benefits:**
- ✅ True parallel execution - GB200 and GB300 don't wait for each other
- ✅ Better debuggability - clear job names, easy to find and retry
- ✅ Zero code duplication - YAML anchor inheritance
- ✅ GPU-specific artifacts - all files suffixed with `_${GPU}`
- ✅ Cleaner DAG visualization - two distinct chains

## Best Practices

1. **Use auto-fetch** for reproducibility:
   ```yaml
   DOCKER_IMAGE: ""  # Auto-fetch
   WHEEL_URL: ""     # Auto-fetch
   TRT_LLM_BRANCH: "main"
   ```

2. **Specify branch** for consistent results:
   ```yaml
   TRT_LLM_BRANCH: "release/1.0"
   ```

3. **Enable retries** for flaky tests:
   ```yaml
   FAILED_RERUN: "2"
   ```

4. **Run specific GPU** in development:
   ```yaml
   RUN_GB200: "true"
   RUN_GB300: "false"
   ```

5. **Use scheduled pipelines** for nightly tests:
   ```yaml
   # In .gitlab-ci.yml
   workflow:
     rules:
       - if: $CI_PIPELINE_SOURCE == "schedule"
         variables:
           TEST_TYPE: "disagg"
   ```

## Maintenance Guide

### Adding a New GPU (e.g., GB400)

**Step 1: Create base template (~30 lines)**
```yaml
.disagg_gb400_base: &disagg_gb400_base
  variables:
    <<: *disagg_variables
    GPU: "GB400"
    RUNNER_TAG: "gb400_runner"
  tags:
    - gb400_runner
  before_script:
    - export GPU="GB400"
    - export HOST="gb400-host"
    - export CLUSTER_PARTITION="gb400"
    - export CLUSTER_STORAGE="/lustre/.../gb400"
    # ... other GB400-specific config
  rules:
    - if: '$TEST_TYPE == "disagg" && $RUN_GB400 == "true"'
```

**Step 2: Create 10 jobs (~80 lines total)**
```yaml
disagg:validate:gb400:
  stage: .pre
  <<: *disagg_gb400_base
  script: *disagg_validate_common_script

disagg:init:gb400:
  stage: init
  <<: *disagg_gb400_base
  script: *disagg_init_common_script
  artifacts:
    paths:
      - config_GB400.env
      - docker_image_GB400.txt
      - download_url_GB400.txt

disagg:scm:gb400:
  stage: scm
  <<: *disagg_gb400_base
  needs:
    - job: disagg:init:gb400
  script: *disagg_scm_common_script
  artifacts:
    paths:
      - config_GB400.env
      - forest_GB400/

# ... repeat for sync, build, setup, test, artifacts, analyze, report
```

**Step 3: Update common scripts if needed**

If GB400 requires special logic, add conditional in common script:
```yaml
.disagg_sync_common_script: &disagg_sync_common_script
  - source config_${GPU}.env
  - |
    if [ "${GPU}" = "GB200" ]; then
      ENROOT_PARTITION="cpu_datamover"
    elif [ "${GPU}" = "GB300" ]; then
      ENROOT_PARTITION="gb300"
    elif [ "${GPU}" = "GB400" ]; then
      ENROOT_PARTITION="gb400_special"  # ← add new GPU logic
    fi
```

**Total:** ~110 lines to add a new GPU, with zero code duplication!

### Modifying Pipeline Logic

**To change logic for all GPUs:**
1. Edit the relevant `.disagg_*_common_script` template
2. Change automatically applies to all GPUs

**To change logic for one GPU:**
1. Override the `script` section in that GPU's job, OR
2. Create a GPU-specific script template

Example:
```yaml
# Override for GB400 only
disagg:test:gb400:
  stage: test
  <<: *disagg_gb400_base
  needs:
    - job: disagg:setup:gb400
  script:
    - echo "GB400 custom test logic"
    - # ... GB400-specific commands
```

## Advanced Configuration

### Custom Test Models

```yaml
TEST_MODEL: "llama3-70b and gpt4"
```

Uses pytest `-k` filter to select tests.

### Source Build Mode

```yaml
INSTALL_MODE: "source"
```

Builds TensorRT-LLM from source using ccache.

### Custom Repository

```yaml
TRT_LLM_REPO: "my-org/my-fork"
FORK_GITHUB: "true"
```

### Disable Performance DB Upload

```yaml
WRITE_PERF_DB: "false"
```

### Custom Test List

```yaml
DISAGG_MULTI_NODE_TEST_LIST: "testlist/custom.txt"
```

## Performance Database

When `WRITE_PERF_DB=true`, results are uploaded to the performance database with:

- **Metrics**: Throughput, latency, token/s
- **Environment**: GPU type, CUDA version, TensorRT version
- **Code**: Commit hash, commit time
- **Link**: Pipeline URL

Access results via internal performance dashboard.

## Support & Resources

- **Pipeline File**: `.gitlab-ci/disagg_test.yml`
- **Scripts**: `scripts/` folder
- **Main README**: `README.md` (project root)
- **Refactor Summary**: `DISAGG_FINAL_REFACTOR.md`

## Examples

### Example 1: Quick Test on GB200

```yaml
TEST_TYPE: disagg
RUN_GB200: true
RUN_GB300: false
TEST_MODEL: llama3
FAILED_RERUN: 1
```

### Example 2: Full Regression (Both GPUs)

```yaml
TEST_TYPE: disagg
TRT_LLM_BRANCH: main
WRITE_PERF_DB: true
FAILED_RERUN: 2
```

### Example 3: Custom Configuration

```yaml
TEST_TYPE: disagg
RUN_GB300: true
RUN_GB200: false
DOCKER_IMAGE: /custom/path/image.sqsh
WHEEL_URL: https://custom-url/wheel.whl
TEST_MODEL: custom-model
INSTALL_MODE: wheel
```

### Example 4: Development Branch Testing

```yaml
TEST_TYPE: disagg
TRT_LLM_BRANCH: feature/new-feature
TRT_LLM_REPO: dev-team/TensorRT-LLM
WRITE_PERF_DB: false
FAILED_RERUN: 0
```

---

**Version:** 3.0 (Split Job Names + Needs Chain Architecture)  
**Last Updated:** 2025-12-31  
**Status:** Production Ready ✅  
**Line Count:** 645 lines (26.7% reduction from matrix approach)  
**Code Duplication:** 0% (YAML anchor inheritance)

