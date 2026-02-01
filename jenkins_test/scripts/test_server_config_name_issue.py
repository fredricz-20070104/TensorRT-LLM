#!/usr/bin/env python3
"""
测试不指定 server_config_name 时的行为
"""

import sys
import os

# 添加路径
sys.path.insert(0, os.path.join(os.path.dirname(__file__)))

from parse_unified_testlist import infer_test_mode_from_config


def test_without_server_config_name():
    """测试不指定 server_config_name 的情况"""
    
    print("=" * 80)
    print("测试：不指定 server_config_name 时的行为")
    print("=" * 80)
    
    # 测试用例
    test_cases = [
        # (test_id, expected_mode, has_server_config_name, description)
        
        # 1. Multi-Agg 配置文件，不指定 server_config_name
        (
            "aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell",
            "multi-agg",
            False,
            "Multi-Agg: 不指定 server_config_name"
        ),
        
        # 2. Multi-Agg 配置文件，指定 server_config_name
        (
            "aggr_upload-deepseek_r1_fp4_v2_2_nodes_grace_blackwell-r1_fp4_v2_dep8_mtp1_1k1k",
            "multi-agg",
            True,
            "Multi-Agg: 指定 server_config_name"
        ),
        
        # 3. Single-Agg 配置文件，不指定 server_config_name
        (
            "aggr_upload-deepseek_r1_fp4_v2_grace_blackwell",
            "single-agg",
            False,
            "Single-Agg: 不指定 server_config_name"
        ),
        
        # 4. Single-Agg 配置文件，指定 server_config_name
        (
            "aggr_upload-deepseek_r1_fp4_v2_grace_blackwell-r1_fp4_v2_tp4_mtp3_1k1k",
            "single-agg",
            True,
            "Single-Agg: 指定 server_config_name"
        ),
    ]
    
    failed_cases = []
    
    for test_id, expected_mode, has_server_config, description in test_cases:
        print(f"\n{'─' * 80}")
        print(f"测试: {description}")
        print(f"Test ID: {test_id}")
        print(f"指定 server_config_name: {'✅ 是' if has_server_config else '❌ 否'}")
        print(f"期望结果: {expected_mode}")
        
        inferred_mode = infer_test_mode_from_config(test_id)
        print(f"实际结果: {inferred_mode}")
        
        if inferred_mode == expected_mode:
            print("✅ PASS")
        else:
            print(f"❌ FAIL: 期望 {expected_mode}，实际 {inferred_mode}")
            failed_cases.append((test_id, expected_mode, inferred_mode))
    
    # 总结
    print("\n" + "=" * 80)
    print("测试总结")
    print("=" * 80)
    
    if failed_cases:
        print(f"\n❌ 发现 {len(failed_cases)} 个失败的测试:\n")
        for test_id, expected, actual in failed_cases:
            print(f"  • {test_id}")
            print(f"    期望: {expected}, 实际: {actual}")
        
        print("\n⚠️  问题分析:")
        print("  当不指定 server_config_name 时，infer_test_mode_from_config() 会：")
        print("  1. 遍历配置文件中的所有 server_configs")
        print("  2. 检查第一个 server_config 的 GPU 需求")
        print("  3. 如果第一个是 single-agg，就返回 single-agg")
        print("  4. ⚠️ 即使后面有 multi-agg 的配置，也不会检查！")
        
        print("\n💡 解决方案:")
        print("  选项 1: 要求用户必须指定 server_config_name")
        print("  选项 2: 遍历所有 server_configs，只要有一个是 multi-agg 就返回 multi-agg")
        print("  选项 3: 使用配置文件名判断（_2_nodes → multi-agg）")
        
        return 1
    else:
        print("\n✅ 所有测试通过！")
        return 0


def analyze_config_file():
    """分析配置文件中的所有 server_configs"""
    
    print("\n" + "=" * 80)
    print("配置文件分析")
    print("=" * 80)
    
    import yaml
    
    config_files = [
        ("deepseek_r1_fp4_v2_2_nodes_grace_blackwell.yaml", "Multi-Agg"),
        ("deepseek_r1_fp4_v2_grace_blackwell.yaml", "Single-Agg"),
    ]
    
    trtllm_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    config_dir = os.path.join(trtllm_root, "tests/scripts/perf-sanity")
    
    for config_file, expected_type in config_files:
        config_path = os.path.join(config_dir, config_file)
        
        if not os.path.exists(config_path):
            continue
        
        print(f"\n配置文件: {config_file}")
        print(f"期望类型: {expected_type}")
        
        with open(config_path, 'r') as f:
            config = yaml.safe_load(f)
        
        hardware = config.get('hardware', {})
        gpus_per_node = hardware.get('gpus_per_node', 0)
        print(f"gpus_per_node: {gpus_per_node}")
        
        server_configs = config.get('server_configs', [])
        print(f"server_configs 数量: {len(server_configs)}")
        
        for i, server_config in enumerate(server_configs):
            name = server_config.get('name', f'config_{i}')
            tp = server_config.get('tensor_parallel_size', 1)
            ep = server_config.get('moe_expert_parallel_size', 1)
            pp = server_config.get('pipeline_parallel_size', 1)
            cp = server_config.get('context_parallel_size', 1)
            
            total_gpus = tp * max(ep, 1) * pp * cp
            
            if total_gpus > gpus_per_node:
                config_type = "multi-agg"
            else:
                config_type = "single-agg"
            
            print(f"  [{i}] {name}")
            print(f"      TP={tp}, EP={ep}, PP={pp}, CP={cp}")
            print(f"      total_gpus={total_gpus}, 类型={config_type}")
        
        print(f"\n⚠️  问题：如果不指定 server_config_name，只会检查第一个配置！")


if __name__ == '__main__':
    result = test_without_server_config_name()
    analyze_config_file()
    sys.exit(result)
