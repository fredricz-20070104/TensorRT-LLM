#!/usr/bin/env python3
"""
测试自动推断功能

用于验证 parse_unified_testlist.py 能否正确识别测试类型
"""

import sys
import os

# 添加脚本目录到 PATH
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from parse_unified_testlist import infer_test_mode_from_config


def test_cases():
    """测试用例"""
    test_cases = [
        # (test_id, expected_mode, description)
        
        # Single-Agg 测试
        ("profiling-deepseek_r1_fp4_v2_blackwell", "single-agg", "DeepSeek R1 FP4 V2 单节点"),
        ("benchmark-deepseek_r1_fp4_v2_blackwell-r1_fp4_v2_tp4_mtp3_1k1k", "single-agg", "指定 server config"),
        
        # Multi-Agg 测试（通过配置文件识别）
        ("benchmark-deepseek_r1_fp4_v2_2_nodes_grace_blackwell", "multi-agg", "DeepSeek R1 2 节点（配置文件）"),
        ("profiling-k2_thinking_fp4_2_nodes_grace_blackwell", "multi-agg", "K2 Thinking 2 节点（配置文件）"),
        
        # Multi-Agg 测试（通过命名识别）
        ("profiling-llama3_405b_2_nodes", "multi-agg", "命名包含 2_nodes"),
        
        # Disagg 测试
        ("benchmark-llama3_70b_disagg", "disagg", "包含 _disagg 后缀"),
        ("profiling-deepseek_r1_disagg", "disagg", "包含 disagg"),
        ("disagg-deepseek-r1-fp4_8k1k_ctx1_gen1", "disagg", "disagg 类型前缀"),
    ]
    
    print("=" * 80)
    print("测试自动推断功能")
    print("=" * 80)
    print()
    
    passed = 0
    failed = 0
    
    for test_id, expected_mode, description in test_cases:
        actual_mode = infer_test_mode_from_config(test_id)
        status = "✅ PASS" if actual_mode == expected_mode else "❌ FAIL"
        
        if actual_mode == expected_mode:
            passed += 1
        else:
            failed += 1
        
        print(f"{status} | {description}")
        print(f"      Test ID: {test_id}")
        print(f"      Expected: {expected_mode}, Actual: {actual_mode}")
        print()
    
    print("=" * 80)
    print(f"测试结果: {passed} 通过, {failed} 失败")
    print("=" * 80)
    
    return failed == 0


if __name__ == '__main__':
    success = test_cases()
    sys.exit(0 if success else 1)
