#!/bin/bash
# default main branch
BRANCH="main"
ARCH=$(arch)  # default architecture

# parse cmd
while [[ $# -gt 0 ]]; do
    case $1 in
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --arch)
            ARCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown parameter: $1"
            exit 1
            ;;
    esac
done

if [ "$BRANCH" = "main" ]; then
    BASE_URL="https://urm.nvidia.com/artifactory/sw-tensorrt-generic/llm-artifacts/LLM/main/L0_PostMerge/"
elif [ "$BRANCH" = "release" ]; then
    # get newest release version
    RELEASE_BASE="https://urm.nvidia.com/artifactory/sw-tensorrt-generic/llm-artifacts/LLM/"
    latest_release=$(curl -s ${RELEASE_BASE} | \
                    grep -o 'href="release-[0-9.]\+/"' | \
                    sed 's/href="//;s/\/"$//' | \
                    sort -V | \
                    tail -n 1)
    
    if [[ -z "${latest_release}" ]]; then
        echo "Error: No release version found."
        exit 1
    fi
    
    BASE_URL="${RELEASE_BASE}${latest_release}/L0_PostMerge/"
    echo "Using latest release: ${latest_release}"
else
    echo "Error: Invalid branch. Must be 'main' or 'release'"
    exit 1
fi

echo "Using BASE_URL: ${BASE_URL}"

# Get the HTML of the directory list
response=$(curl -s ${BASE_URL})

# Check if the HTML is successfully obtained
if [[ -z "${response}" ]]; then
    echo "Error: No response from server."
    exit 1
fi
# Get the subfolder links in the directory
folders=$(echo "${response}" | grep -o 'href="[0-9]\+/"' | sed 's/href="//;s/\/"$//' | sort -n -r)

# Initialize variables
latest_file=""
latest_folder=""
echo $folders

# Find the latest TensorRT-LLM.tar.gz file
for folder in ${folders}; do
    folder_url="${BASE_URL}${folder}/"
    echo "Checking folder: ${folder_url}"
    
    # Get the HTML of the subfolder
    folder_response=$(curl -s ${folder_url})

    # Check if the HTML is successfully obtained
    if [[ -z "${folder_response}" ]]; then
        echo "Error: No response from folder ${folder_url}."
        continue
    fi

    # Determine architecture subdirectory
    if [ "$ARCH" = "aarch64" ]; then
        arch_subdir="aarch64-linux-gnu"
        wheel_pattern='href="tensorrt_llm-[^"]*-cp312-cp312-linux_aarch64\.whl"'
    else
        arch_subdir="x86_64-linux-gnu"
        wheel_pattern='href="tensorrt_llm-[^"]*-cp312-cp312-linux_x86_64\.whl"'
    fi
    
    # Check if architecture subdirectory exists
    arch_url="${folder_url}${arch_subdir}/"
    arch_response=$(curl -s ${arch_url})
    
    if [[ -z "${arch_response}" ]]; then
        echo "No response from ${arch_url}"
        continue
    fi
    
    # Find wheel file for Python 3.12
    file=$(echo "${arch_response}" | grep -o "${wheel_pattern}" | sed 's/href="//;s/"$//' | sort -V | tail -n 1)
    
    if [[ -n "${file}" ]]; then
        latest_file="${file}"
        latest_folder="${arch_url}"
        break
    fi
done

# Check if the file is found
if [[ -z "${latest_file}" ]]; then
    if [ "$ARCH" = "aarch64" ]; then
        echo "Error: No tensorrt_llm wheel file (cp312, aarch64) found in any folders."
    else
        echo "Error: No tensorrt_llm wheel file (cp312, x86_64) found in any folders."
    fi
    exit 1
fi

# Build the download URL
echo "${latest_folder}${latest_file}" > download_url.txt