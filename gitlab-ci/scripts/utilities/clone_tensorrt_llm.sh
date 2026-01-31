#!/bin/bash
#
# Script to clone TensorRT-LLM repository with sparse or full checkout
#
# Usage: clone_tensorrt_llm.sh <WORKDIR> <GIT_URL> <BRANCH> <MODE>
#   MODE: "sparse" or "full"
#

set -e

WORKDIR=$1
GIT_URL=$2
BRANCH=$3
MODE=$4

# Configure Git timeout settings (avoid network hangs)
export GIT_SSH_COMMAND="ssh -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

# Retry function: retry <max_attempts> <timeout_seconds> <command...>
retry_git() {
  local max_attempts=$1
  local timeout_sec=$2
  shift 2
  local cmd="$@"
  
  for i in $(seq 1 $max_attempts); do
    echo "Attempt $i/$max_attempts: $cmd"
    if timeout $timeout_sec bash -c "$cmd" 2>&1; then
      echo "✓ Success on attempt $i"
      return 0
    fi
    exit_code=$?
    if [ $i -eq $max_attempts ]; then
      echo "✗ Failed after $max_attempts attempts (exit code: $exit_code)"
      return 1
    fi
    echo "⚠ Retry in $((i * 5)) seconds..."
    sleep $((i * 5))
  done
}

cd $WORKDIR

if [ "$MODE" = "sparse" ]; then
  echo "=== Sparse checkout ==="
  
  # Initialize or resume repository
  if [ ! -d "tensorrt_llm/.git" ]; then
    rm -rf tensorrt_llm
    mkdir -p tensorrt_llm
    cd tensorrt_llm
    git init
    git remote add origin $GIT_URL
  else
    cd tensorrt_llm
    git reset --hard 2>/dev/null || true
    git clean -fd 2>/dev/null || true
  fi
  
  # Configure sparse checkout
  git config core.sparseCheckout true
  git config http.lowSpeedLimit 1000
  git config http.lowSpeedTime 300
  
  cat > .git/info/sparse-checkout <<EOF
tests/integration/defs/
tests/integration/test_lists/
tests/integration/lm_eval_configs/
tests/test_common/
examples/disaggregated/slurm/benchmark/
jenkins/current_image_tags.properties
tensorrt_llm/version.py
requirements.txt
requirements-dev.txt
constraints.txt
EOF
  
  # Fetch with retry (10 minutes timeout, 3 attempts)
  retry_git 3 600 "git fetch --depth=1 --progress origin $BRANCH" || exit 1
  
  git checkout $BRANCH
  
else
  echo "=== Full clone ==="
  
  # Initialize or resume repository
  if [ ! -d "tensorrt_llm/.git" ]; then
    rm -rf tensorrt_llm
    mkdir -p tensorrt_llm
    cd tensorrt_llm
    git init
    git remote add origin $GIT_URL
  else
    cd tensorrt_llm
    git reset --hard 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    git submodule foreach --recursive 'git reset --hard 2>/dev/null || true' || true
  fi
  
  # Configure timeout settings
  git config http.lowSpeedLimit 1000
  git config http.lowSpeedTime 300
  
  # Fetch main repository with retry (30 minutes timeout, 3 attempts)
  retry_git 3 1800 "git fetch --progress origin $BRANCH" || exit 1
  
  git checkout $BRANCH
  
  # Update submodules with retry (30 minutes timeout, 3 attempts)
  retry_git 3 1800 "git submodule update --init --recursive --progress" || exit 1
fi

echo "✓ Clone completed successfully"

