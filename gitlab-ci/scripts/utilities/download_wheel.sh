#!/bin/bash
#
# Download TensorRT-LLM wheel with retry and progress monitoring
#
# Usage: 7_download_wheel.sh <CLUSTER_WORKDIR> <WHEEL_URL>
#
# Features:
#   - Dynamic timeout: 10min → 20min → 30min
#   - Progress check: must reach 100%
#   - Auto retry: 3 attempts with cleanup
#

set -e  # Exit on error
set -x  # Print commands for debugging

# Parse arguments
CLUSTER_WORKDIR="$1"
WHEEL_URL="$2"

if [ -z "$CLUSTER_WORKDIR" ] || [ -z "$WHEEL_URL" ]; then
  echo "ERROR: Missing required arguments"
  echo "Usage: $0 <CLUSTER_WORKDIR> <WHEEL_URL>"
  exit 1
fi

echo "=== Downloading wheel ==="
echo "URL: $WHEEL_URL"

# Create target directory
mkdir -p "${CLUSTER_WORKDIR}/tensorrt_llm/build"

# Extract wheel filename
WHEEL_FILENAME=$(basename "$WHEEL_URL")
WHEEL_PATH="${CLUSTER_WORKDIR}/tensorrt_llm/build/${WHEEL_FILENAME}"

# Download configuration
MAX_ATTEMPTS=3
CONN_TIMEOUT=30  # 30 seconds connection timeout
RETRY_DELAY=10   # 10 seconds between retries

# Dynamic timeout per attempt (in seconds)
TIMEOUT_ATTEMPT_1=600   # 10 minutes for attempt 1
TIMEOUT_ATTEMPT_2=1200  # 20 minutes for attempt 2
TIMEOUT_ATTEMPT_3=1800  # 30 minutes for attempt 3

# Retry loop with integrity validation and progress monitoring
download_success=false
for attempt in $(seq 1 $MAX_ATTEMPTS); do
  # Dynamic timeout based on attempt number
  case $attempt in
    1) TIMEOUT_SEC=$TIMEOUT_ATTEMPT_1 ;;
    2) TIMEOUT_SEC=$TIMEOUT_ATTEMPT_2 ;;
    3) TIMEOUT_SEC=$TIMEOUT_ATTEMPT_3 ;;
    *) TIMEOUT_SEC=$TIMEOUT_ATTEMPT_3 ;;
  esac
  
  echo ""
  echo "Download attempt $attempt/$MAX_ATTEMPTS (timeout: ${TIMEOUT_SEC}s = $((TIMEOUT_SEC/60))min)..."
  
  # Remove any existing incomplete/corrupted file before retry
  if [ -f "${WHEEL_PATH}" ]; then
    echo "Removing previous download attempt..."
    rm -f "${WHEEL_PATH}"
  fi
  
  # Download with progress monitoring
  WGET_LOG="/tmp/wget_log_$$.txt"
  
  timeout ${TIMEOUT_SEC} wget \
    --timeout=${CONN_TIMEOUT} \
    --tries=1 \
    --progress=dot:mega \
    -O "${WHEEL_PATH}" \
    "${WHEEL_URL}" 2>&1 | tee "$WGET_LOG"
  
  wget_exit=$?
  
  # Analyze wget output for completion percentage
  if [ -f "$WGET_LOG" ]; then
    last_progress=$(grep -oP '\d+%' "$WGET_LOG" | tail -1 | tr -d '%')
    rm -f "$WGET_LOG"
  else
    last_progress=0
  fi
  
  echo ""
  echo "Result: exit=$wget_exit, progress=${last_progress}%"
  
  # Check if download completed successfully (exit 0 AND reached 100%)
  if [ $wget_exit -eq 0 ] && [ "${last_progress:-0}" -ge 99 ]; then
    # Validate file exists and size
    if [ ! -f "${WHEEL_PATH}" ]; then
      echo "✗ File not found after download"
    else
      file_size=$(stat -c%s "${WHEEL_PATH}" 2>/dev/null || stat -f%z "${WHEEL_PATH}" 2>/dev/null)
      file_size_human=$(ls -lh "${WHEEL_PATH}" | awk '{print $5}')
      
      if [ "$file_size" -lt 1048576 ]; then
        echo "✗ File too small: $file_size_human (< 1MB)"
      else
        echo "✓ Download complete: $file_size_human"
        download_success=true
        break
      fi
    fi
  else
    # Download failed or incomplete
    echo "✗ Download incomplete (exit: $wget_exit, progress: ${last_progress}%)"
  fi
  
  # Clean up and retry
  rm -f "${WHEEL_PATH}"
  
  if [ $attempt -eq $MAX_ATTEMPTS ]; then
    echo ""
    echo "✗ Download failed after $MAX_ATTEMPTS attempts"
    ls -lh "${CLUSTER_WORKDIR}/tensorrt_llm/build/" 2>/dev/null | tail -5 || true
    exit 1
  fi
  
  echo "Retrying in ${RETRY_DELAY} seconds..."
  sleep ${RETRY_DELAY}
done

# Final verification
echo ""
if [ "$download_success" = "true" ] && [ -f "${WHEEL_PATH}" ]; then
  file_size=$(ls -lh "${WHEEL_PATH}" | awk '{print $5}')
  echo "✓ Wheel downloaded successfully: $WHEEL_FILENAME ($file_size)"
  echo "  Path: $WHEEL_PATH"
else
  echo "✗ ERROR: Download failed"
  exit 1
fi

