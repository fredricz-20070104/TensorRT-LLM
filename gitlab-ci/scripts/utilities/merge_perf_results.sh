#!/bin/bash

# merge_perf_results.sh
# This script is used to merge performance test results from multiple nodes
# Usage: ./merge_perf_results.sh <output_directory>

set -e  # Exit on error

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Log functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

show_usage() {
    echo "Usage: $0 <output_directory>"
    echo "Example: $0 /home/trt_llm_qa/trtllm_ci/Debug-TRT-LLM-Perf-Cluster/output_perf_debug"
    exit 1
}

if [ $# -eq 0 ]; then
    log_error "Missing output directory parameter"
    show_usage
fi

OUTPUT_DIR="$1"

log_info "Parameters: $OUTPUT_DIR"
log_info "Output directory type: $(echo $OUTPUT_DIR | cut -c1-1)"
log_info "Final output directory: $OUTPUT_DIR"

if [ ! -d "$OUTPUT_DIR" ]; then
    log_error "Output directory does not exist: $OUTPUT_DIR"
    exit 1
fi

log_info "Starting to merge performance test results..."
log_info "Output directory: $OUTPUT_DIR"

# Check if there are multiple output directories (parallel run)
log_info "Checking parallel output directories..."
OUTPUT_DIRS=$(find "$OUTPUT_DIR" -maxdepth 1 -type d \( -name 'tmp*_output_*' -o -name '20*' \))

if [ -z "$OUTPUT_DIRS" ]; then
    log_warning "Only detected single case, no need to merge"
    exit 0
fi

# Calculate directory count
DIR_COUNT=$(echo "$OUTPUT_DIRS" | wc -l)
log_info "Found $DIR_COUNT parallel output directories, starting to merge results..."

# Create merged file directory
log_info "Creating merged file directory..."
if mkdir -p "$OUTPUT_DIR/merged" 2>/dev/null; then
    log_success "Directory created successfully, no sudo needed"
else
    log_warning "Permission denied, trying to use sudo..."
    if sudo mkdir -p "$OUTPUT_DIR/merged"; then
        log_success "Successfully created directory using sudo"
    else
        log_error "Failed to create directory using sudo"
        log_error "Please check sudo permissions or manually create the directory"
        exit 1
    fi
fi

# Find all CSV files
log_info "Finding performance test files..."

PERF_CSV_FILES=$(find "$OUTPUT_DIR" -name 'perf_script_test_results.csv' -type f)
PROPERTIES_CSV_FILES=$(find "$OUTPUT_DIR" -name 'session_properties.csv' -type f)
XML_FILES=$(find "$OUTPUT_DIR" -name 'results.xml' -type f)
GPU_FILES=$(find "$OUTPUT_DIR" -name 'gpu.txt' -type f)
CPU_FILES=$(find "$OUTPUT_DIR" -name 'cpu.txt' -type f)
DRIVER_FILES=$(find "$OUTPUT_DIR" -name 'driver.txt' -type f)

# Calculate file count
PERF_COUNT=$(echo "$PERF_CSV_FILES" | grep -c . || echo "0")
PROPERTIES_COUNT=$(echo "$PROPERTIES_CSV_FILES" | grep -c . || echo "0")
XML_COUNT=$(echo "$XML_FILES" | grep -c . || echo "0")

log_info "Found $PERF_COUNT performance CSV files"
log_info "Found $PROPERTIES_COUNT properties CSV files"
log_info "Found $XML_COUNT XML files"

# Merge performance CSV files
if [ "$PERF_COUNT" -gt 0 ]; then
    log_info "Merging performance CSV files..."
    FIRST_FILE=$(echo "$PERF_CSV_FILES" | head -n1)
    
    if [ -f "$FIRST_FILE" ]; then
        # Copy the header of the first file
        head -n 1 "$FIRST_FILE" > "$OUTPUT_DIR/merged/merged_perf_results.csv"
        
        # Merge all files (skip the header)
        for file in $PERF_CSV_FILES; do
            if [ -f "$file" ]; then
                log_info "Processing performance CSV: $file"
                tail -n +2 "$file" >> "$OUTPUT_DIR/merged/merged_perf_results.csv"
            fi
        done
        
        LINE_COUNT=$(wc -l < "$OUTPUT_DIR/merged/merged_perf_results.csv")
        log_success "Merged performance CSV created, total $LINE_COUNT lines"
    fi
fi

# Merge properties CSV files
if [ "$PROPERTIES_COUNT" -gt 0 ]; then
    log_info "Merging properties CSV files..."
    FIRST_FILE=$(echo "$PROPERTIES_CSV_FILES" | head -n1)
    
    if [ -f "$FIRST_FILE" ]; then
        # Copy the header of the first file
        head -n 1 "$FIRST_FILE" > "$OUTPUT_DIR/merged/merged_properties.csv"
        
        # Merge all files (skip the header)
        for file in $PROPERTIES_CSV_FILES; do
            if [ -f "$file" ]; then
                log_info "Processing properties CSV: $file"
                tail -n +2 "$file" >> "$OUTPUT_DIR/merged/merged_properties.csv"
            fi
        done
        
        LINE_COUNT=$(wc -l < "$OUTPUT_DIR/merged/merged_properties.csv")
        log_success "Merged properties CSV created, total $LINE_COUNT lines"
    fi
fi

# Merge XML files (using python to ensure the format is correct)
if [ "$XML_COUNT" -gt 0 ]; then
    log_info "Merging XML files..."
    
    # Merge all XML files into a single testsuite using Python
    python3 << EOF > "$OUTPUT_DIR/merged/merged_results.xml"
import xml.etree.ElementTree as ET
import sys
from pathlib import Path

xml_files = """$XML_FILES""".strip().split('\n')

# Create root structure
root = ET.Element('testsuites')
root.set('name', 'merged pytest tests')

# Create single merged testsuite
merged_testsuite = ET.SubElement(root, 'testsuite')
merged_testsuite.set('name', 'merged')

# Counters for aggregated attributes
total_tests = 0
total_failures = 0
total_errors = 0
total_skipped = 0
total_time = 0.0

# Iterate through all XML files and collect testcases
for xml_file in xml_files:
    xml_file = xml_file.strip()
    if not xml_file:
        continue

    try:
        tree = ET.parse(xml_file)
        file_root = tree.getroot()

        # Find all testsuites and extract their testcases
        for testsuite in file_root.findall('.//testsuite'):
            # Aggregate testsuite attributes
            total_tests += int(testsuite.get('tests', 0))
            total_failures += int(testsuite.get('failures', 0))
            total_errors += int(testsuite.get('errors', 0))
            total_skipped += int(testsuite.get('skipped', 0))
            total_time += float(testsuite.get('time', 0.0))

            # Extract all testcases from this testsuite
            for testcase in testsuite.findall('testcase'):
                merged_testsuite.append(testcase)
    
    except Exception as e:
        print(f'Error processing {xml_file}: {e}', file=sys.stderr)

# Set aggregated attributes on merged testsuite
merged_testsuite.set('tests', str(total_tests))
merged_testsuite.set('failures', str(total_failures))
merged_testsuite.set('errors', str(total_errors))
merged_testsuite.set('skipped', str(total_skipped))
merged_testsuite.set('time', f'{total_time:.3f}')

# Write the merged XML
tree = ET.ElementTree(root)
ET.indent(tree, space='  ')
tree.write(sys.stdout.buffer, encoding='utf-8', xml_declaration=True)
EOF
    
    log_success "Merged XML file created with single testsuite"
fi

# Copy system information files (use the first found)
if [ -n "$GPU_FILES" ]; then
    FIRST_GPU=$(echo "$GPU_FILES" | head -n1)
    if [ "$FIRST_GPU" != "$OUTPUT_DIR/merged/gpu.txt" ]; then
        cp "$FIRST_GPU" "$OUTPUT_DIR/merged/gpu.txt"
        log_info "Copying GPU information file: $FIRST_GPU"
    else
        log_info "GPU information file already exists in merged directory"
    fi
fi

if [ -n "$CPU_FILES" ]; then
    FIRST_CPU=$(echo "$CPU_FILES" | head -n1)
    if [ "$FIRST_CPU" != "$OUTPUT_DIR/merged/cpu.txt" ]; then
        cp "$FIRST_CPU" "$OUTPUT_DIR/merged/cpu.txt"
        log_info "Copying CPU information file: $FIRST_CPU"
    else
        log_info "CPU information file already exists in merged directory"
    fi
fi

if [ -n "$DRIVER_FILES" ]; then
    FIRST_DRIVER=$(echo "$DRIVER_FILES" | head -n1)
    if [ "$FIRST_DRIVER" != "$OUTPUT_DIR/merged/driver.txt" ]; then
        cp "$FIRST_DRIVER" "$OUTPUT_DIR/merged/driver.txt"
        log_info "Copying driver information file: $FIRST_DRIVER"
    else
        log_info "Driver information file already exists in merged directory"
    fi
fi

# Show summary
log_info "=== Merged file summary ==="
if [ -f "$OUTPUT_DIR/merged/merged_perf_results.csv" ]; then
    LINE_COUNT=$(wc -l < "$OUTPUT_DIR/merged/merged_perf_results.csv")
    log_info "Merged performance CSV: $LINE_COUNT lines"
fi

if [ -f "$OUTPUT_DIR/merged/merged_properties.csv" ]; then
    LINE_COUNT=$(wc -l < "$OUTPUT_DIR/merged/merged_properties.csv")
    log_info "Merged properties CSV: $LINE_COUNT lines"
fi

if [ -f "$OUTPUT_DIR/merged/merged_results.xml" ]; then
    log_info "Merged results XML: created"
fi

log_info "=== Summary end ==="

log_success "Performance test results merged successfully"


log_info "Merged directory content:"
ls -la "$OUTPUT_DIR/merged/" 2>/dev/null || log_warning "Cannot list merged directory content" 