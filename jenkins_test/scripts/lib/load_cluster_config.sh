#!/bin/bash
#
# Load cluster configuration by name
#
# Usage: source load_cluster_config.sh <cluster_name>
#

CLUSTER_CONFIG_NAME="$1"

if [ -z "$CLUSTER_CONFIG_NAME" ]; then
    echo "Error: Cluster name required"
    echo "Usage: source load_cluster_config.sh <cluster_name>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config/clusters.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Cluster config file not found: $CONFIG_FILE"
    exit 1
fi

# Parse INI-style config file
in_section=false
while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    
    # Check for section header
    if [[ "$key" =~ ^\[(.+)\]$ ]]; then
        section="${BASH_REMATCH[1]}"
        if [ "$section" = "$CLUSTER_CONFIG_NAME" ]; then
            in_section=true
        else
            in_section=false
        fi
        continue
    fi
    
    # Export variables in the current section
    if $in_section; then
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Expand environment variables in value
        value=$(eval echo "$value")
        
        export "$key=$value"
    fi
done < "$CONFIG_FILE"

if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: Cluster '$CLUSTER_CONFIG_NAME' not found in $CONFIG_FILE"
    exit 1
fi

echo "✓ Loaded cluster config: $CLUSTER_NAME"
echo "  Host: $CLUSTER_HOST"
echo "  User: $CLUSTER_USER"
echo "  Type: $CLUSTER_TYPE"
echo "  Partition: $CLUSTER_PARTITION"
