#!/usr/bin/env python3
"""
load_cluster_config.py - 加载集群配置并输出 JSON

用法:
    python3 load_cluster_config.py <cluster_name> [--config-file clusters.conf]

输出:
    JSON 格式的集群配置，供 Jenkins Groovy 或 Shell 脚本使用
"""

import argparse
import json
import os
import sys
from pathlib import Path


def parse_config_file(config_file: str) -> dict:
    """
    解析配置文件，支持 INI 风格的分组配置
    
    格式:
        [cluster_name]
        KEY=VALUE
        KEY="VALUE WITH SPACES"
    """
    if not os.path.exists(config_file):
        raise FileNotFoundError(f"配置文件不存在: {config_file}")
    
    configs = {}
    current_cluster = None
    
    with open(config_file, 'r', encoding='utf-8') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            
            # 跳过空行和注释
            if not line or line.startswith('#'):
                continue
            
            # 解析集群名称 [cluster_name]
            if line.startswith('[') and line.endswith(']'):
                current_cluster = line[1:-1].strip()
                if current_cluster:
                    configs[current_cluster] = {}
                continue
            
            # 解析配置项 KEY=VALUE
            if '=' in line and current_cluster:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip()
                
                # 移除引号
                if (value.startswith('"') and value.endswith('"')) or \
                   (value.startswith("'") and value.endswith("'")):
                    value = value[1:-1]
                
                configs[current_cluster][key] = value
    
    return configs


def get_cluster_config(cluster_name: str, config_file: str) -> dict:
    """获取指定集群的配置"""
    configs = parse_config_file(config_file)
    
    if cluster_name not in configs:
        available = ', '.join(configs.keys())
        raise ValueError(
            f"集群 '{cluster_name}' 未在配置文件中找到。\n"
            f"可用集群: {available}"
        )
    
    return configs[cluster_name]


def main():
    parser = argparse.ArgumentParser(
        description='加载集群配置并输出 JSON',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
    # 加载 gb200 集群配置
    python3 load_cluster_config.py gb200
    
    # 指定配置文件
    python3 load_cluster_config.py gb200 --config-file /path/to/clusters.conf
    
    # 在 Jenkins Groovy 中使用
    def config = sh(script: "python3 scripts/load_cluster_config.py gb200", returnStdout: true).trim()
    def configMap = readJSON text: config
    env.CLUSTER_HOST = configMap.CLUSTER_HOST
        """
    )
    
    parser.add_argument(
        'cluster',
        help='集群名称（例如: gb200, gb300, gb200_lyris）'
    )
    
    parser.add_argument(
        '--config-file',
        default=None,
        help='配置文件路径（默认: scripts/../config/clusters.conf）'
    )
    
    parser.add_argument(
        '--format',
        choices=['json', 'shell', 'env'],
        default='json',
        help='输出格式: json (默认), shell (export 语句), env (KEY=VALUE)'
    )
    
    parser.add_argument(
        '--pretty',
        action='store_true',
        help='美化 JSON 输出'
    )
    
    args = parser.parse_args()
    
    # 确定配置文件路径
    if args.config_file:
        config_file = args.config_file
    else:
        # 默认相对于脚本目录的 ../config/clusters.conf
        script_dir = Path(__file__).parent.resolve()
        config_file = script_dir.parent / 'config' / 'clusters.conf'
    
    try:
        # 获取集群配置
        cluster_config = get_cluster_config(args.cluster, str(config_file))
        
        # 输出配置
        if args.format == 'json':
            if args.pretty:
                print(json.dumps(cluster_config, indent=2, ensure_ascii=False))
            else:
                print(json.dumps(cluster_config, ensure_ascii=False))
        
        elif args.format == 'shell':
            # 输出 shell export 语句
            for key, value in cluster_config.items():
                # 转义引号
                value_escaped = value.replace('"', '\\"')
                print(f'export {key}="{value_escaped}"')
        
        elif args.format == 'env':
            # 输出 KEY=VALUE 格式
            for key, value in cluster_config.items():
                print(f'{key}={value}')
        
        return 0
    
    except FileNotFoundError as e:
        print(f"错误: {e}", file=sys.stderr)
        return 1
    
    except ValueError as e:
        print(f"错误: {e}", file=sys.stderr)
        return 1
    
    except Exception as e:
        print(f"未知错误: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
