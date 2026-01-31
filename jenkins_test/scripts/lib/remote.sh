#!/bin/bash
#
# Remote Operations Library for Jenkins Pipeline
# Supports SSH-based remote execution and local execution
#

# ============================================
# Initialization: Auto-detect execution mode
# ============================================
init_remote() {
    # Detect mode based on cluster configuration
    if [ "$CLUSTER_TYPE" = "local" ]; then
        export REMOTE_MODE="local"
    else
        export REMOTE_MODE="ssh"
    fi
    
    # Set remote prefix for SCP operations
    if [ "$REMOTE_MODE" = "ssh" ]; then
        export REMOTE_PREFIX="${CLUSTER_USER}@${CLUSTER_HOST}:"
    else
        export REMOTE_PREFIX=""
    fi
    
    echo "✓ Remote mode: $REMOTE_MODE (cluster: $CLUSTER_NAME)"
}

# ============================================
# Core Function: Execute remote command
# ============================================
remote_exec() {
    local cmd="$*"
    
    if [ "$REMOTE_MODE" = "local" ]; then
        eval "$cmd"
    else
        # Use pipe to avoid quote escaping issues with bash -l
        echo "$cmd" | ssh "${CLUSTER_USER}@${CLUSTER_HOST}" bash -l
    fi
}

# ============================================
# Core Function: Copy files/directories
# ============================================
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

# ============================================
# Convenience: Create remote directory
# ============================================
remote_mkdir() {
    local dir="$1"
    remote_exec "mkdir -p '$dir'"
}

# ============================================
# Convenience: Check if remote file exists
# ============================================
remote_file_exists() {
    local file="$1"
    remote_exec "test -f '$file'"
}

# ============================================
# Convenience: Execute remote script
# ============================================
remote_script() {
    local script_path="$1"
    shift
    
    if [ "$REMOTE_MODE" = "local" ]; then
        bash "$script_path" "$@"
    else
        # Upload script first
        local script_name=$(basename "$script_path")
        local remote_script="/tmp/${script_name}.$$"
        scp "$script_path" "${CLUSTER_USER}@${CLUSTER_HOST}:${remote_script}"
        
        # Execute and cleanup
        ssh "${CLUSTER_USER}@${CLUSTER_HOST}" "bash -l $remote_script $* && rm -f $remote_script"
    fi
}

# ============================================
# Setup SSH keys if needed
# ============================================
setup_ssh_keys() {
    if [ "$REMOTE_MODE" = "ssh" ]; then
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        
        if [ -n "$SSH_PRIVATE_KEY" ]; then
            echo "$SSH_PRIVATE_KEY" > ~/.ssh/id_rsa
            chmod 600 ~/.ssh/id_rsa
        fi
        
        if [ -n "$CLUSTER_HOST" ]; then
            ssh-keyscan -H "$CLUSTER_HOST" >> ~/.ssh/known_hosts 2>/dev/null || true
        fi
        
        echo "✓ SSH keys configured"
    fi
}

# ============================================
# Auto-initialize when sourced
# ============================================
if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    init_remote
    setup_ssh_keys
fi
