#!/bin/bash
# run_perf_tests.sh - 统一的性能测试执行入口
# 
# 功能：
# 1. 解析统一的 testlist 文件
# 2. 自动识别测试类型（single-agg、multi-agg、disagg）
# 3. 调用对应的执行脚本（复用现有代码）
# 4. 收集和汇总结果
#
# 注意：此脚本在 cluster 上运行或通过 SSH 在中转机上运行

set -euo pipefail

# ============================================
# 脚本目录
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================
# 参数解析
# ============================================
TESTLIST=""
TRTLLM_DIR=""
FILTER_MODE=""
FILTER_TAGS=""
PYTEST_K=""
DRY_RUN=false
STOP_ON_ERROR=false

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

统一的性能测试执行入口 - 自动识别测试类型并调用对应脚本

Options:
    --testlist FILE         统一的 testlist 文件路径 (必需)
    --trtllm-dir DIR        TensorRT-LLM 目录路径 (必需)
    --mode MODE             只运行指定模式的测试 [single-agg|multi-agg|disagg|all]
    --tags TAGS             按标签过滤测试（逗号分隔）
    --stop-on-error         遇到错误时停止（默认继续）
    --dry-run               试运行模式
    -h, --help              显示帮助信息

示例:
    # 运行整个测试套件
    $0 --testlist testlists/gb200_unified_suite.yml \\
       --trtllm-dir /path/to/TensorRT-LLM

    # 只运行 single-agg 测试
    $0 --testlist testlists/gb200_unified_suite.yml \\
       --trtllm-dir /path/to/TensorRT-LLM \\
       --mode single-agg

    # 试运行
    $0 --testlist testlists/gb200_unified_suite.yml \\
       --trtllm-dir /path/to/TensorRT-LLM \\
       --dry-run

    # 使用 pytest -k 过滤（仅 single-agg 和 multi-agg）
    $0 --testlist testlists/gb200_unified_suite.yml \\
       --trtllm-dir /path/to/TensorRT-LLM \\
       -k "deepseek and not fp8"

    # 组合使用：只运行 single-agg 中包含 deepseek 的测试
    $0 --testlist testlists/gb200_unified_suite.yml \\
       --trtllm-dir /path/to/TensorRT-LLM \\
       --mode single-agg \\
       -k deepseek

注意：pytest -k 过滤仅支持 single-agg 和 multi-agg 模式，disagg 模式不支持。
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --testlist)
            TESTLIST="$2"
            shift 2
            ;;
        --trtllm-dir)
            TRTLLM_DIR="$2"
            shift 2
            ;;
        --mode)
            FILTER_MODE="$2"
            shift 2
            ;;
        --tags)
            FILTER_TAGS="$2"
            shift 2
            ;;
        -k)
            PYTEST_K="$2"
            shift 2
            ;;
        --stop-on-error)
            STOP_ON_ERROR=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "错误：未知参数 $1"
            usage
            ;;
    esac
done

# 验证必需参数
if [[ -z "$TESTLIST" ]]; then
    echo "错误：必须指定 --testlist"
    exit 1
fi

if [[ -z "$TRTLLM_DIR" ]]; then
    echo "错误：必须指定 --trtllm-dir"
    exit 1
fi

if [[ ! -f "$TESTLIST" ]]; then
    echo "错误：testlist 文件不存在: $TESTLIST"
    exit 1
fi

echo "========================================"
echo "统一性能测试执行"
echo "========================================"
echo "TestList: $TESTLIST"
echo "TensorRT-LLM: $TRTLLM_DIR"
echo "过滤模式: ${FILTER_MODE:-all}"
echo "试运行: $DRY_RUN"
echo "========================================"

# ============================================
# 步骤 1: 解析 testlist
# ============================================
echo ""
echo "[步骤 1] 解析 testlist 并识别测试类型..."

TESTLIST_JSON=$(python3 "$SCRIPT_DIR/parse_unified_testlist.py" "$TESTLIST" ${FILTER_MODE:+--mode $FILTER_MODE})

if [[ $? -ne 0 ]]; then
    echo "错误：解析 testlist 失败"
    exit 1
fi

# 显示统计信息
python3 "$SCRIPT_DIR/parse_unified_testlist.py" "$TESTLIST" --summary

# ============================================
# 步骤 2: 按模式分组执行
# ============================================
echo ""
echo "[步骤 2] 按测试模式执行..."

# 提取各个模式的测试
SINGLE_AGG_TESTS=$(echo "$TESTLIST_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(json.dumps(data.get('tests_by_mode', {}).get('single-agg', [])))")
MULTI_AGG_TESTS=$(echo "$TESTLIST_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(json.dumps(data.get('tests_by_mode', {}).get('multi-agg', [])))")
DISAGG_TESTS=$(echo "$TESTLIST_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(json.dumps(data.get('tests_by_mode', {}).get('disagg', [])))")

# 统计信息
SINGLE_COUNT=$(echo "$SINGLE_AGG_TESTS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
MULTI_COUNT=$(echo "$MULTI_AGG_TESTS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")
DISAGG_COUNT=$(echo "$DISAGG_TESTS" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

TOTAL_TESTS=$((SINGLE_COUNT + MULTI_COUNT + DISAGG_COUNT))

# 结果统计
PASSED_TESTS=0
FAILED_TESTS=0
FAILED_LIST=()

# ============================================
# 函数：执行 Single-Agg 测试
# ============================================
run_single_agg_tests() {
    if [[ $SINGLE_COUNT -eq 0 ]]; then
        echo "⊘ 没有 Single-Agg 测试"
        return 0
    fi
    
    echo ""
    echo "========================================"
    echo "运行 Single-Agg 测试 ($SINGLE_COUNT 个)"
    echo "========================================"
    
    for i in $(seq 0 $((SINGLE_COUNT - 1))); do
        local test_info=$(echo "$SINGLE_AGG_TESTS" | python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin)[$i]))")
        local config_file=$(echo "$test_info" | python3 -c "import sys, json; print(json.load(sys.stdin)['config_file'])")
        local config_name=$(echo "$test_info" | python3 -c "import sys, json; print(json.load(sys.stdin).get('config_name', ''))")
        
        echo ""
        echo "----------------------------------------"
        echo "[Single-Agg $((i + 1))/$SINGLE_COUNT] $config_file${config_name:+ - $config_name}"
        echo "----------------------------------------"
        
        local script_args=()
        script_args+=("--trtllm-dir" "$TRTLLM_DIR")
        script_args+=("--config-file" "$config_file")
        
        # 添加 pytest -k 过滤
        if [[ -n "$PYTEST_K" ]]; then
            script_args+=("-k" "$PYTEST_K")
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            script_args+=("--dry-run")
        fi
        
        if "$SCRIPT_DIR/run_single_agg_test.sh" "${script_args[@]}"; then
            ((PASSED_TESTS++))
            echo "✓ 测试通过"
        else
            ((FAILED_TESTS++))
            FAILED_LIST+=("Single-Agg: $config_file${config_name:+ - $config_name}")
            echo "✗ 测试失败"
            
            if [[ "$STOP_ON_ERROR" == "true" ]]; then
                echo "遇到错误，停止执行"
                return 1
            fi
        fi
    done
    
    return 0
}

# ============================================
# 函数：执行 Multi-Agg 测试
# ============================================
run_multi_agg_tests() {
    if [[ $MULTI_COUNT -eq 0 ]]; then
        echo "⊘ 没有 Multi-Agg 测试"
        return 0
    fi
    
    echo ""
    echo "========================================"
    echo "运行 Multi-Agg 测试 ($MULTI_COUNT 个)"
    echo "========================================"
    
    for i in $(seq 0 $((MULTI_COUNT - 1))); do
        local test_info=$(echo "$MULTI_AGG_TESTS" | python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin)[$i]))")
        local config_file=$(echo "$test_info" | python3 -c "import sys, json; print(json.load(sys.stdin)['config_file'])")
        local config_name=$(echo "$test_info" | python3 -c "import sys, json; print(json.load(sys.stdin).get('config_name', ''))")
        
        echo ""
        echo "----------------------------------------"
        echo "[Multi-Agg $((i + 1))/$MULTI_COUNT] $config_file${config_name:+ - $config_name}"
        echo "----------------------------------------"
        
        local script_args=()
        script_args+=("--trtllm-dir" "$TRTLLM_DIR")
        script_args+=("--config-file" "$config_file")
        script_args+=("--workspace" "${WORKSPACE:-$(pwd)}/multi_agg_workspace")
        
        # 添加 pytest -k 过滤
        if [[ -n "$PYTEST_K" ]]; then
            script_args+=("-k" "$PYTEST_K")
        fi
        
        if [[ "$DRY_RUN" == "true" ]]; then
            script_args+=("--dry-run")
        fi
        
        if "$SCRIPT_DIR/run_multi_agg_test.sh" "${script_args[@]}"; then
            ((PASSED_TESTS++))
            echo "✓ 测试通过"
        else
            ((FAILED_TESTS++))
            FAILED_LIST+=("Multi-Agg: $config_file${config_name:+ - $config_name}")
            echo "✗ 测试失败"
            
            if [[ "$STOP_ON_ERROR" == "true" ]]; then
                echo "遇到错误，停止执行"
                return 1
            fi
        fi
    done
    
    return 0
}

# ============================================
# 函数：执行 Disagg 测试
# ============================================
run_disagg_tests() {
    if [[ $DISAGG_COUNT -eq 0 ]]; then
        echo "⊘ 没有 Disagg 测试"
        return 0
    fi
    
    echo ""
    echo "========================================"
    echo "运行 Disagg 测试 ($DISAGG_COUNT 个)"
    echo "========================================"
    
    for i in $(seq 0 $((DISAGG_COUNT - 1))); do
        local test_info=$(echo "$DISAGG_TESTS" | python3 -c "import sys, json; print(json.dumps(json.load(sys.stdin)[$i]))")
        local config_file=$(echo "$test_info" | python3 -c "import sys, json; print(json.load(sys.stdin)['config_file'])")
        
        echo ""
        echo "----------------------------------------"
        echo "[Disagg $((i + 1))/$DISAGG_COUNT] $config_file"
        echo "----------------------------------------"
        
        local script_args=()
        script_args+=("--trtllm-dir" "$TRTLLM_DIR")
        script_args+=("--config-file" "$config_file")
        script_args+=("--workspace" "${WORKSPACE:-$(pwd)}/disagg_workspace")
        
        # 注意：disagg 模式不支持 pytest -k 过滤
        
        if [[ "$DRY_RUN" == "true" ]]; then
            script_args+=("--dry-run")
        fi
        
        if "$SCRIPT_DIR/run_disagg_test.sh" "${script_args[@]}"; then
            ((PASSED_TESTS++))
            echo "✓ 测试通过"
        else
            ((FAILED_TESTS++))
            FAILED_LIST+=("Disagg: $config_file")
            echo "✗ 测试失败"
            
            if [[ "$STOP_ON_ERROR" == "true" ]]; then
                echo "遇到错误，停止执行"
                return 1
            fi
        fi
    done
    
    return 0
}

# ============================================
# 执行所有测试
# ============================================
run_single_agg_tests
run_multi_agg_tests
run_disagg_tests

# ============================================
# 步骤 3: 输出总结
# ============================================
echo ""
echo "========================================"
echo "测试执行完成"
echo "========================================"
echo "总测试数: $TOTAL_TESTS"
echo "  - Single-Agg: $SINGLE_COUNT"
echo "  - Multi-Agg:  $MULTI_COUNT"
echo "  - Disagg:     $DISAGG_COUNT"
echo ""
echo "结果统计:"
echo "  - 成功: $PASSED_TESTS"
echo "  - 失败: $FAILED_TESTS"

if [[ ${#FAILED_LIST[@]} -gt 0 ]]; then
    echo ""
    echo "失败的测试:"
    for test in "${FAILED_LIST[@]}"; do
        echo "  ✗ $test"
    done
    echo "========================================"
    exit 1
fi

echo "========================================"
echo "✓ 所有测试通过"
exit 0
