#!/bin/bash
#
# Remote Operations Library for GitLab CI
# Automatically adapts to GB200 (SSH) and GB300 (local) execution modes
#

# ============================================================
# Initialization: Auto-detect execution mode
# ============================================================
init_remote() {
    # Detect mode based on GPU type or runner tag
    if [ -n "$GPU" ] && [[ "$GPU" =~ ^(GB300|GB200_LYRIS)$ ]]; then
        export REMOTE_MODE="local"
    elif [ -n "$RUNNER_TAG" ] && [ "$RUNNER_TAG" = "lyris" ]; then
        export REMOTE_MODE="local"
    else
        export REMOTE_MODE="ssh"
    fi
    
    # Set remote prefix for SCP operations
    if [ "$REMOTE_MODE" = "ssh" ]; then
        export REMOTE_PREFIX="${CLUSTER_USERNAME}@${HOST}:"
    else
        export REMOTE_PREFIX=""
    fi
    
    echo "✓ Remote mode: $REMOTE_MODE"
}

# ============================================================
# Core Function: Execute remote command
# ============================================================
remote_exec() {
    local cmd="$*"
    
    if [ "$REMOTE_MODE" = "local" ]; then
        eval "$cmd"
    else
        # Use pipe to avoid quote escaping issues with bash -l
        echo "$cmd" | ssh "${CLUSTER_USERNAME}@${HOST}" bash -l
    fi
}

# ============================================================
# Core Function: Copy files/directories
# ============================================================
remote_copy() {
    local src="$1"
    local dest="$2"
    
    if [ "$REMOTE_MODE" = "local" ]; then
        # Remove possible user@host: prefix
        src="${src#*:}"
        dest="${dest#*:}"
        cp -r "$src" "$dest"
    else
        scp -r "$src" "$dest"
    fi
}

# ============================================================
# Convenience: Create remote directory
# ============================================================
remote_mkdir() {
    local dir="$1"
    remote_exec "mkdir -p '$dir'"
}

# ============================================================
# Convenience: Check if remote file exists
# ============================================================
remote_file_exists() {
    local file="$1"
    remote_exec "test -f '$file'"
}

# ============================================================
# Convenience: Execute remote script
# ============================================================
remote_script() {
    local script_path="$1"
    shift
    
    if [ "$REMOTE_MODE" = "local" ]; then
        bash "$script_path" "$@"
    else
        # Force bash login shell and properly escape arguments
        ssh "${CLUSTER_USERNAME}@${HOST}" "bash -l $(printf '%q ' "$script_path" "$@")"
    fi
}

# ============================================================
# Legacy Compatibility: Setup $SSH_CMD and $SCP_CMD
# ============================================================
setup_legacy_commands() {
    if [ "$REMOTE_MODE" = "local" ]; then
        # Define wrapper functions
        ssh_wrapper() { eval "$*"; }
        scp_wrapper() { remote_copy "$@"; }
        
        # Export functions (bash only)
        if [ -n "$BASH_VERSION" ]; then
            export -f ssh_wrapper 2>/dev/null || true
            export -f scp_wrapper 2>/dev/null || true
        fi
        
        export SSH_CMD="ssh_wrapper"
        export SCP_CMD="scp_wrapper"
    else
        export SSH_CMD="ssh ${CLUSTER_USERNAME}@${HOST}"
        export SCP_CMD="scp -r"
    fi
}

# ============================================================
# Auto-initialize when sourced
# ============================================================
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    init_remote
    setup_legacy_commands
fi
