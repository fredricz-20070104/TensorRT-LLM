#!/usr/bin/env python3
"""
计算 Disagg 测试需要的硬件节点数
从 YAML 配置文件读取逻辑服务器配置，计算实际需要的物理节点数
"""

import argparse
import math
import sys
import yaml


def calculate_nodes(world_size, num_servers, gpus_per_node):
    """计算需要的硬件节点数"""
    return math.ceil(world_size * num_servers / gpus_per_node)


def calculate_hardware_nodes(config_path):
    """从配置文件计算硬件节点数"""
    
    with open(config_path, 'r') as f:
        config = yaml.safe_load(f)
    
    hardware = config.get('hardware', {})
    worker_config = config.get('worker_config', {})
    benchmark = config.get('benchmark', {})
    
    # 读取硬件配置
    gpus_per_node = hardware.get('gpus_per_node')
    num_ctx_servers = hardware.get('num_ctx_servers', 0)
    num_gen_servers = hardware.get('num_gen_servers', 0)
    
    # gen_only 模式不需要 ctx servers
    benchmark_mode = benchmark.get('mode', 'e2e')
    if 'gen_only' in benchmark_mode:
        num_ctx_servers = 0
    
    # 计算 CTX world size
    ctx_config = worker_config.get('ctx', {})
    ctx_tp = ctx_config.get('tensor_parallel_size', 1)
    ctx_pp = ctx_config.get('pipeline_parallel_size', 1)
    ctx_cp = ctx_config.get('context_parallel_size', 1)
    ctx_world_size = ctx_tp * ctx_pp * ctx_cp
    
    # 计算 GEN world size
    gen_config = worker_config.get('gen', {})
    gen_tp = gen_config.get('tensor_parallel_size', 1)
    gen_pp = gen_config.get('pipeline_parallel_size', 1)
    gen_cp = gen_config.get('context_parallel_size', 1)
    gen_world_size = gen_tp * gen_pp * gen_cp
    
    # 计算硬件节点数
    ctx_nodes = 0
    if num_ctx_servers > 0:
        ctx_nodes = calculate_nodes(ctx_world_size, num_ctx_servers, gpus_per_node)
    
    gen_nodes = calculate_nodes(gen_world_size, num_gen_servers, gpus_per_node)
    
    total_nodes = ctx_nodes + gen_nodes
    total_gpus = total_nodes * gpus_per_node
    
    return {
        'num_ctx_servers': num_ctx_servers,
        'num_gen_servers': num_gen_servers,
        'ctx_world_size': ctx_world_size,
        'gen_world_size': gen_world_size,
        'ctx_nodes': ctx_nodes,
        'gen_nodes': gen_nodes,
        'total_nodes': total_nodes,
        'total_gpus': total_gpus,
        'gpus_per_node': gpus_per_node,
    }


def main():
    parser = argparse.ArgumentParser(
        description='计算 Disagg 测试需要的硬件节点数'
    )
    parser.add_argument(
        '--config',
        type=str,
        required=True,
        help='YAML 配置文件路径'
    )
    parser.add_argument(
        '--json',
        action='store_true',
        help='以 JSON 格式输出'
    )
    parser.add_argument(
        '--check-nodes',
        type=int,
        help='检查实际节点数是否匹配（用于验证）'
    )
    
    args = parser.parse_args()
    
    try:
        result = calculate_hardware_nodes(args.config)
        
        if args.json:
            import json
            print(json.dumps(result, indent=2))
        else:
            print(f"逻辑服务器配置:")
            print(f"  CTX servers: {result['num_ctx_servers']}")
            print(f"  GEN servers: {result['num_gen_servers']}")
            print(f"  CTX world size: {result['ctx_world_size']}")
            print(f"  GEN world size: {result['gen_world_size']}")
            print(f"")
            print(f"硬件节点计算:")
            print(f"  GPUs per node: {result['gpus_per_node']}")
            print(f"  CTX hardware nodes: {result['ctx_nodes']}")
            print(f"  GEN hardware nodes: {result['gen_nodes']}")
            print(f"  Total hardware nodes: {result['total_nodes']}")
            print(f"  Total GPUs: {result['total_gpus']}")
        
        # 验证节点数
        if args.check_nodes is not None:
            if result['total_nodes'] != args.check_nodes:
                print(f"", file=sys.stderr)
                print(f"❌ 节点数不匹配!", file=sys.stderr)
                print(f"  配置要求: {result['total_nodes']} 个节点", file=sys.stderr)
                print(f"  实际提供: {args.check_nodes} 个节点", file=sys.stderr)
                sys.exit(1)
            else:
                print(f"")
                print(f"✓ 节点数验证通过: {result['total_nodes']} 个节点")
        
        sys.exit(0)
        
    except Exception as e:
        print(f"错误: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
