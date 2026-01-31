#!/bin/bash
# ============================================
# Artifactory file manager script (GitLab CI only)
# ============================================

set -e

# ============================================
# Configuration variables - GitLab CI environment
# ============================================
ARTIFACTORY_URL="${ARTIFACTORY_URL:-https://artifactory.nvidia.com/artifactory}"
REPO_NAME="${REPO_NAME:-sw-tensorrt-llm-qa-generic-local}"
PROJECT_NAME="${PROJECT_NAME:-trtllm}"

# GitLab CI environment variable mapping
if [ -n "$CI_PIPELINE_ID" ]; then
    # GitLab CI environment (production environment)
    JOB_NAME="${CI_PROJECT_NAME}"
    BUILD_ID="${CI_PIPELINE_ID}"
    GIT_COMMIT="${CI_COMMIT_SHA:-unknown}"
    GIT_BRANCH="${CI_COMMIT_REF_NAME:-unknown}"
    BUILD_URL="${CI_PIPELINE_URL:-}"
else
    # Local test environment
    JOB_NAME="${JOB_NAME:-local}"
    BUILD_ID="${BUILD_ID:-$(date +%s)}"
    GIT_COMMIT="${GIT_COMMIT:-unknown}"
    GIT_BRANCH="${GIT_BRANCH:-unknown}"
    BUILD_URL="${BUILD_URL:-}"
fi

ARTIFACTORY_USER="${ARTIFACTORY_USER}"
ARTIFACTORY_TOKEN="${ARTIFACTORY_TOKEN}"

# Automatically generate target directory: project/job_name/build_id
TARGET_DIR="${PROJECT_NAME}/${JOB_NAME}/${BUILD_ID}"

# ============================================
# Debug information (can be enabled by DEBUG=1)
# ============================================
if [ "${DEBUG:-0}" = "1" ]; then
    echo "[DEBUG] GitLab CI environment information:"
    echo "[DEBUG]   PROJECT_NAME = $PROJECT_NAME"
    echo "[DEBUG]   JOB_NAME = $JOB_NAME"
    echo "[DEBUG]   BUILD_ID = $BUILD_ID"
    echo "[DEBUG]   TARGET_DIR = $TARGET_DIR"
    echo "[DEBUG]   GIT_COMMIT = $GIT_COMMIT"
    echo "[DEBUG]   GIT_BRANCH = $GIT_BRANCH"
    echo "[DEBUG]   BUILD_URL = $BUILD_URL"
fi

# ============================================
# Color output
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ============================================
# Check required credentials
# ============================================
check_credentials() {
    if [ -z "$ARTIFACTORY_USER" ] || [ -z "$ARTIFACTORY_TOKEN" ]; then
        log_error "ARTIFACTORY_USER and ARTIFACTORY_TOKEN environment variables are required"
        exit 1
    fi
}

# ============================================
# Upload file to Artifactory (with property support)
# Input: $1 - File path
#       $2 - Target directory (optional)
#       $3 - Property string (optional), format: "key1=value1;key2=value2"
# Output: Return 0 success, 1 failure
# ============================================
upload_to_artifactory() {
    local file_path="$1"
    local custom_target_dir="${2:-$TARGET_DIR}"
    local properties="$3"
    
    check_credentials
    
    if [ ! -f "$file_path" ]; then
        log_error "File not found: $file_path"
        return 1
    fi
    
    local file_name=$(basename "$file_path")
    local upload_url="${ARTIFACTORY_URL}/${REPO_NAME}/${custom_target_dir}/${file_name}"
    
    # If there are properties, add them to the URL
    if [ -n "$properties" ]; then
        upload_url="${upload_url};${properties}"
    fi
    
    log_info "Uploading file: $file_path"
    log_info "Target URL: $upload_url"
    
    # Get file size
    local file_size=$(du -h "$file_path" | cut -f1)
    log_info "File size: $file_size"
    
    # Upload file
    local http_code=$(curl -s -w "%{http_code}" -o /tmp/curl_output.txt \
        -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
        -X PUT \
        -T "$file_path" \
        "$upload_url")
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_success "Upload successful: $file_name"
        log_info "Access URL: ${ARTIFACTORY_URL}/${REPO_NAME}/${custom_target_dir}/${file_name}"
        return 0
    else
        log_error "Upload failed (HTTP $http_code)"
        cat /tmp/curl_output.txt
        return 1
    fi
}

# ============================================
# Download file from Artifactory
# Input: $1 - Source path (relative to repository root), $2 - Destination file path
# Output: Return 0 success, 1 failure
# ============================================
download_from_artifactory() {
    local source_path="$1"
    local destination_file="$2"
    
    check_credentials
    
    # Create destination directory
    local dest_dir=$(dirname "$destination_file")
    mkdir -p "$dest_dir"
    
    local download_url="${ARTIFACTORY_URL}/${REPO_NAME}/${source_path}"
    
    log_info "Downloading file: $source_path"
    log_info "Saving to: $destination_file"
    
    # Download file
    local http_code=$(curl -s -w "%{http_code}" -o "$destination_file" \
        -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
        -L \
        "$download_url")
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_success "Download successful"
        return 0
    else
        log_error "Download failed (HTTP $http_code)"
        return 1
    fi
}

# ============================================
# List Artifactory directory content
# Input: $1 - Directory path (optional, default using TARGET_DIR)
# Output: Print file list, return 0 success
# ============================================
list_artifactory_directory() {
    local directory_path="${1:-$TARGET_DIR}"
    
    check_credentials
    
    local api_url="${ARTIFACTORY_URL}/api/storage/${REPO_NAME}/${directory_path}"
    
    log_info "Listing directory: $directory_path"
    
    # Get directory content
    local response=$(curl -s \
        -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
        "$api_url")
    
    # Check if there is an error
    if echo "$response" | grep -q '"errors"'; then
        log_error "Directory does not exist or no permission to access: $directory_path"
        return 1
    fi
    
    # Parse JSON and extract file names (use jq if available, otherwise use grep)
    if command -v jq &> /dev/null; then
        echo "$response" | jq -r '.children[]?.uri' | sed 's/^\///'
    else
        echo "$response" | grep -o '"uri":"[^"]*"' | grep -v '"uri":"/"' | cut -d'"' -f4 | sed 's/^\///'
    fi
    
    return 0
}

# ============================================
# Get file information
# Input: $1 - File path
#       $2 - Whether to format output (optional, default is raw JSON)
# Output: Print file information
# ============================================
get_artifact_info() {
    local artifact_path="$1"
    local format="${2:-raw}"
    
    check_credentials
    
    local api_url="${ARTIFACTORY_URL}/api/storage/${REPO_NAME}/${artifact_path}"
    
    local response=$(curl -s \
        -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
        "$api_url")
    
    if [ "$format" = "pretty" ] && command -v jq &> /dev/null; then
        echo "$response" | jq '.'
    elif [ "$format" = "summary" ]; then
        log_info "File information: $artifact_path"
        if command -v jq &> /dev/null; then
            echo "  Path: $(echo "$response" | jq -r '.path // "N/A"')"
            echo "  Size: $(echo "$response" | jq -r '.size // "N/A"') bytes"
            echo "  Created time: $(echo "$response" | jq -r '.created // "N/A"')"
            echo "  Modified time: $(echo "$response" | jq -r '.lastModified // "N/A"')"
            echo "  MIME type: $(echo "$response" | jq -r '.mimeType // "N/A"')"
            echo "  MD5: $(echo "$response" | jq -r '.checksums.md5 // "N/A"')"
            echo "  SHA1: $(echo "$response" | jq -r '.checksums.sha1 // "N/A"')"
        else
            echo "$response"
        fi
    else
        echo "$response"
    fi
}

# ============================================
# Delete file
# Input: $1 - File path
# Output: Return 0 success, 1 failure
# ============================================
delete_from_artifactory() {
    local artifact_path="$1"
    
    check_credentials
    
    local delete_url="${ARTIFACTORY_URL}/${REPO_NAME}/${artifact_path}"
    
    log_info "Deleting file: $artifact_path"
    
    local http_code=$(curl -s -w "%{http_code}" -o /tmp/curl_output.txt \
        -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
        -X DELETE \
        "$delete_url")
    
    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
        log_success "Deletion successful"
        return 0
    else
        log_error "Deletion failed (HTTP $http_code)"
        return 1
    fi
}

# ============================================
# Clean up old builds
# Input: $1 - Number of builds to keep (default 90)
#       $2 - Job name (optional)
#       $3 - Project name (optional)
# Output: Return 0 success
# ============================================
cleanup_old_builds() {
    local keep_builds="${1:-90}"
    local job_name="${2:-$JOB_NAME}"
    local project_name="${3:-$PROJECT_NAME}"
    
    check_credentials
    
    local job_path="${project_name}/${job_name}"
    local api_url="${ARTIFACTORY_URL}/api/storage/${REPO_NAME}/${job_path}"
    
    log_info "Cleaning up old builds: $job_path"
    log_info "Keeping the last $keep_builds builds"
    
    # Get all build directories
    local response=$(curl -s \
        -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" \
        "$api_url")
    
    # Extract build number (only keep numeric directories) and sort
    local builds=$(echo "$response" | grep -o '"uri":"[^"]*"' | cut -d'"' -f4 | sed 's/^\///' | grep '^[0-9]*$' | sort -rn)
    
    local total_builds=$(echo "$builds" | wc -l)
    log_info "Found $total_builds builds"
    
    if [ "$total_builds" -le "$keep_builds" ]; then
        log_info "No cleanup needed, current build count is less than the keep count"
        return 0
    fi
    
    # Skip the last N builds, delete the rest
    local deleted_count=0
    local build_num=0
    
    echo "$builds" | while read -r build; do
        build_num=$((build_num + 1))
        if [ "$build_num" -gt "$keep_builds" ]; then
            log_info "Deleting build #$build"
            if delete_from_artifactory "${job_path}/${build}"; then
                deleted_count=$((deleted_count + 1))
            fi
        fi
    done
    
    log_success "Cleanup completed, deleted $deleted_count old builds"
    return 0
}

# ============================================
# Upload multiple files
# Input: $@ - File list
# Output: Return 0 success
# ============================================
upload_multiple_files() {
    local failed=0
    
    for file in "$@"; do
        if ! upload_to_artifactory "$file"; then
            failed=$((failed + 1))
        fi
    done
    
    if [ "$failed" -gt 0 ]; then
        log_warn "$failed files uploaded failed"
        return 1
    fi
    
    return 0
}

# ============================================
# Upload directory (compressed)
# Input: $1 - Source directory, $2 - Archive name, $3 - Compression type (optional, default is tar.gz)
# Output: Return 0 success, 1 failure
# ============================================
upload_directory() {
    local source_dir="$1"
    local archive_name="$2"
    local compression="${3:-tar.gz}"
    
    if [ ! -d "$source_dir" ]; then
        log_error "Directory does not exist: $source_dir"
        return 1
    fi
    
    local archive_file="${archive_name}.${compression}"
    
    log_info "Compressing directory: $source_dir"
    
    # Create archive based on compression type
    case "$compression" in
        tar.gz)
            tar -czf "$archive_file" -C "$source_dir" .
            ;;
        tar.bz2)
            tar -cjf "$archive_file" -C "$source_dir" .
            ;;
        zip)
            (cd "$source_dir" && zip -r "../$archive_file" .)
            ;;
        *)
            log_error "Unsupported compression type: $compression"
            return 1
            ;;
    esac
    
    # Upload compressed archive
    if upload_to_artifactory "$archive_file"; then
        # Clean up local compressed archive
        rm -f "$archive_file"
        return 0
    else
        rm -f "$archive_file"
        return 1
    fi
}

# ============================================
# Full test - Test all functions
# Input: None
# Output: Return 0 on success
# ============================================
run_full_test() {
    log_info "===== Starting Full Function Test ====="
    
    local test_dir="test_artifacts_$$"
    local test_target_dir="${TARGET_DIR}/test-run"
    
    # 1. Create test files
    log_info "\n[1/7] Creating test files..."
    mkdir -p "$test_dir"/{logs,results,data}
    
    echo "Test log - Build ${BUILD_ID}" > "$test_dir/logs/test.log"
    echo "Test results - $(date)" > "$test_dir/results/results.txt"
    echo "Test data - Random: $RANDOM" > "$test_dir/data/data.txt"
    
    # Create a compressed archive
    tar -czf "$test_dir/test_archive.tar.gz" -C "$test_dir/data" .
    
    log_success "Test files created successfully"
    ls -lh "$test_dir"
    
    # 2. Upload single file (with properties)
    log_info "\n[2/7] Uploading file (with properties)..."
    local properties="build_id=${BUILD_ID};job_name=${JOB_NAME};timestamp=$(date +%s)"
    if upload_to_artifactory "$test_dir/test_archive.tar.gz" "$test_target_dir" "$properties"; then
        log_success "✓ File uploaded successfully (with properties)"
    else
        log_error "✗ File upload failed"
        return 1
    fi
    
    # 3. Upload multiple files
    log_info "\n[3/7] Batch uploading files..."
    if upload_multiple_files "$test_dir/logs/test.log" "$test_dir/results/results.txt" "$test_dir/data/data.txt"; then
        log_success "✓ Batch upload successful"
    else
        log_warn "⚠ Some files failed to upload"
    fi
    
    # 4. List files
    log_info "\n[4/7] Listing uploaded files..."
    local files=$(list_artifactory_directory "$test_target_dir")
    if [ -n "$files" ]; then
        log_success "✓ Found the following files:"
        echo "$files" | while read -r file; do
            echo "  - $file"
        done
    else
        log_warn "⚠ No files found"
    fi
    
    # 5. Get file information
    log_info "\n[5/7] Getting file information..."
    get_artifact_info "$test_target_dir/test_archive.tar.gz" "summary"
    
    # 6. Download file
    log_info "\n[6/7] Downloading file..."
    mkdir -p "$test_dir/downloaded"
    if download_from_artifactory "$test_target_dir/test_archive.tar.gz" "$test_dir/downloaded/test_archive.tar.gz"; then
        log_success "✓ File downloaded successfully"
        ls -lh "$test_dir/downloaded/"
    else
        log_warn "⚠ File download failed"
    fi
    
    # 7. Clean up test files
    log_info "\n[7/7] Cleaning up local test files..."
    rm -rf "$test_dir"
    log_success "✓ Local test files cleaned up"
    
    log_success "\n===== Full Function Test Completed ====="
    log_info "Test files kept in Artifactory: $test_target_dir"
    log_info "You can clean up with: $0 delete $test_target_dir"
    
    return 0
}

# ============================================
# Main function - Command line interface
# ============================================
main() {
    local command="${1:-help}"
    
    case "$command" in
        upload)
            shift
            if [ $# -lt 1 ]; then
                log_error "Usage: $0 upload <file_path> [target_dir]"
                exit 1
            fi
            upload_to_artifactory "$@"
            ;;
        download)
            shift
            if [ $# -lt 2 ]; then
                log_error "Usage: $0 download <source_path> <destination_file>"
                exit 1
            fi
            download_from_artifactory "$@"
            ;;
        list)
            shift
            list_artifactory_directory "$@"
            ;;
        info)
            shift
            if [ $# -lt 1 ]; then
                log_error "Usage: $0 info <artifact_path>"
                exit 1
            fi
            get_artifact_info "$@"
            ;;
        delete)
            shift
            if [ $# -lt 1 ]; then
                log_error "Usage: $0 delete <artifact_path>"
                exit 1
            fi
            delete_from_artifactory "$@"
            ;;
        cleanup)
            shift
            cleanup_old_builds "$@"
            ;;
        upload-multiple)
            shift
            if [ $# -lt 1 ]; then
                log_error "Usage: $0 upload-multiple <file1> [file2] ..."
                exit 1
            fi
            upload_multiple_files "$@"
            ;;
        upload-dir)
            shift
            if [ $# -lt 2 ]; then
                log_error "Usage: $0 upload-dir <source_dir> <archive_name> [compression_type]"
                exit 1
            fi
            upload_directory "$@"
            ;;
        test)
            shift
            run_full_test "$@"
            ;;
        help|*)
            cat << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Artifactory Artifact Manager Script v2.1 (GitLab CI Only)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Usage: $0 <command> [options]

Commands:
  upload <file> [target_dir] [properties]
      Upload file to Artifactory
      properties format: "key1=value1;key2=value2"
      
  download <source> <destination>
      Download file from Artifactory
      
  list [directory]
      List directory content (default uses TARGET_DIR)
      
  info <artifact_path> [format]
      Get file information
      format: raw (default), pretty, summary
      
  delete <artifact_path>
      Delete specified file or directory
      
  cleanup [keep_builds] [job_name] [project_name]
      Clean up old builds (default keeps 90)
      
  upload-multiple <file1> [file2] ...
      Batch upload multiple files
      
  upload-dir <source_dir> <archive_name> [compression_type]
      Upload directory (compressed)
      compression_type: tar.gz (default), tar.bz2, zip
      
  test
      Run full function test
      
  help
      Show this help message

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Environment Variables:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Required (GitLab CI/CD Variables):
    ARTIFACTORY_USER     Username (service account)
    ARTIFACTORY_TOKEN    Access token (Masked)
  
  Optional Configuration:
    ARTIFACTORY_URL      Artifactory server URL
                         Default: https://artifactory.nvidia.com/artifactory
    REPO_NAME            Repository name
                         Default: sw-tensorrt-llm-qa-generic-local
    PROJECT_NAME         Project name (default: trtllm)
  
  GitLab CI Auto-detected (no manual setup required):
    CI_PROJECT_NAME      GitLab project name → JOB_NAME
    CI_PIPELINE_ID       GitLab Pipeline ID → BUILD_ID
    CI_COMMIT_SHA        Git commit SHA → GIT_COMMIT
    CI_COMMIT_REF_NAME   Git branch/tag → GIT_BRANCH
    CI_PIPELINE_URL      Pipeline access URL → BUILD_URL

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Usage Examples:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  # 1. Upload file (basic)
  $0 upload build_output.tar.gz

  # 2. Upload file (with properties)
  $0 upload build.tar.gz "trtllm/my-job/123" "build=123;status=success"

  # 3. Batch upload
  $0 upload-multiple logs/*.log results/*.xml

  # 4. Upload directory
  $0 upload-dir ./test_results test_results_20240115

  # 5. Download file
  $0 download trtllm/my-job/123/build.tar.gz ./local_build.tar.gz

  # 6. List files
  $0 list trtllm/my-job/123

  # 7. Get file details
  $0 info trtllm/my-job/123/build.tar.gz summary

  # 8. Clean up old builds (keep only last 5)
  $0 cleanup 5

  # 9. Run full test
  $0 test

  # 10. Delete file
  $0 delete trtllm/my-job/123/old_build.tar.gz

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
GitLab CI Pipeline Usage Examples:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  # Basic usage
  upload_artifacts:
    stage: upload
    script:
      - chmod +x scripts/8_artifactory_manager.sh
      - ./scripts/8_artifactory_manager.sh upload build.tar.gz
      - ./scripts/8_artifactory_manager.sh list

  # Upload with metadata
  upload_with_metadata:
    stage: upload
    script:
      - |
        PROPS="build_id=\${CI_PIPELINE_ID};commit=\${CI_COMMIT_SHA};branch=\${CI_COMMIT_REF_NAME}"
        ./scripts/8_artifactory_manager.sh upload build.tar.gz "" "\${PROPS}"

  # Batch upload and verify
  upload_and_verify:
    stage: upload
    script:
      - ./scripts/8_artifactory_manager.sh upload-multiple logs/*.log results/*.xml
      - ./scripts/8_artifactory_manager.sh list
      - ./scripts/8_artifactory_manager.sh info "trtllm/\${CI_PROJECT_NAME}/\${CI_PIPELINE_ID}/build.tar.gz" summary

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

For more detailed examples, see: .gitlab-ci-artifactory-test.yml

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
            ;;
    esac
}

# If script is executed directly, run main function
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi