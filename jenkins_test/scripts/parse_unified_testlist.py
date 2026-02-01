#!/usr/bin/env python3
"""
parse_unified_testlist.py - 解析测试列表文件（支持 YAML 和 TXT 格式）

支持两种格式：
1. YAML 格式（test-db 兼容）：结构化配置，适合管理复杂测试套件
2. TXT 格式（pytest 格式）：简单文本列表，适合快速 debug 和手动测试

用法:
    python3 parse_unified_testlist.py <testlist.yml|testlist.txt> [--mode single-agg|multi-agg|disagg] [--summary]

示例:
    # 解析 YAML 格式
    python3 parse_unified_testlist.py testlists/gb200_unified_suite.yml
    
    # 解析 TXT 格式
    python3 parse_unified_testlist.py testlists/debug_cases.txt
    
    # 只解析 single-agg 测试
    python3 parse_unified_testlist.py testlists/gb200_unified_suite.yml --mode single-agg
    
    # 显示统计信息
    python3 parse_unified_testlist.py testlists/gb200_unified_suite.yml --summary
"""

import argparse
import json
import os
import sys
import yaml


# 配置目录路径（相对于 TensorRT-LLM 根目录）
AGGR_CONFIG_DIR = "tests/scripts/perf-sanity"
DISAGG_CONFIG_DIR = "tests/integration/defs/perf/disagg/test_configs/disagg/perf"


def get_trtllm_root():
    """获取 TensorRT-LLM 根目录"""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # 从 jenkins_test/scripts/ 向上两级到根目录
    return os.path.dirname(os.path.dirname(script_dir))


def load_yaml_config(config_file, config_dir):
    """加载并解析 YAML 配置文件"""
    trtllm_root = get_trtllm_root()
    config_path = os.path.join(trtllm_root, config_dir, config_file)
    
    if not os.path.exists(config_path):
        return None
    
    try:
        with open(config_path, 'r') as f:
            return yaml.safe_load(f)
    except Exception:
        return None


def infer_test_mode_from_config(test_id):
    """
    从测试 ID 推断测试模式（通过读取配置文件）
    
    Args:
        test_id: 测试用例 ID，格式为 "test_type-config_yml[-server_config_name]"
                例如: "profiling-deepseek_r1_fp4_v2_blackwell"
                     "benchmark-llama3_70b_tp4-default_config"
    
    Returns:
        str: 'single-agg', 'multi-agg', 或 'disagg'
    """
    # 1. 首先检查是否为 disagg 测试（通过命名规则）
    if '_disagg' in test_id or test_id.endswith('-disagg') or 'disagg' in test_id.split('-')[0]:
        return 'disagg'
    
    # 2. 解析测试 ID
    parts = test_id.split('-')
    if len(parts) < 2:
        return 'single-agg'
    
    test_type = parts[0]  # profiling, benchmark, etc.
    config_yml = parts[1]  # 配置文件名（不含扩展名）
    server_config_name = '-'.join(parts[2:]) if len(parts) > 2 else None
    
    # 3. 尝试从 aggr 配置目录加载
    config_file = f"{config_yml}.yaml"
    config = load_yaml_config(config_file, AGGR_CONFIG_DIR)
    
    if config:
        # 检查是否有 hardware.gpus_per_node 和实际使用的 GPUs
        hardware = config.get('hardware', {})
        gpus_per_node = hardware.get('gpus_per_node', 0)
        
        # 检查 server_configs
        server_configs = config.get('server_configs', [])
        for server_config in server_configs:
            # 如果指定了 server_config_name，只检查匹配的配置
            if server_config_name and server_config.get('name') != server_config_name:
                continue
            
            # 检查是否为多节点配置
            # 方法 1: 检查 gpus 字段
            gpus = server_config.get('gpus', 0)
            actual_gpus_per_node = server_config.get('gpus_per_node', gpus_per_node)
            
            if actual_gpus_per_node > 0 and gpus > actual_gpus_per_node:
                # GPUs 数量超过单节点，说明是 multi-agg
                return 'multi-agg'
            
            # 方法 2: 计算总 GPU 数（TP * EP * PP * CP）
            tp = server_config.get('tensor_parallel_size', 1)
            ep = server_config.get('moe_expert_parallel_size', 1)
            pp = server_config.get('pipeline_parallel_size', 1)
            cp = server_config.get('context_parallel_size', 1)
            
            total_gpus = tp * max(ep, 1) * pp * cp
            
            # 如果计算出的总 GPU 数超过单节点，说明是 multi-agg
            if actual_gpus_per_node > 0 and total_gpus > actual_gpus_per_node:
                return 'multi-agg'
            
            # 检查 disagg_run_type 字段
            if server_config.get('disagg_run_type') in ['ctx', 'gen']:
                return 'disagg'
        
        # 如果有多个 server_configs 且没有指定名称，默认为 single-agg
        return 'single-agg'
    
    # 4. 尝试从 disagg 配置目录加载
    # disagg 配置文件命名格式: {model}-{config}_ctx{n}_gen{m}...
    disagg_config_patterns = [
        f"{config_yml}.yaml",
        f"{'-'.join(parts[1:])}.yaml"  # 尝试完整路径
    ]
    
    for pattern in disagg_config_patterns:
        config = load_yaml_config(pattern, DISAGG_CONFIG_DIR)
        if config:
            # 找到 disagg 配置文件
            hardware = config.get('hardware', {})
            if 'num_ctx_servers' in hardware or 'num_gen_servers' in hardware:
                return 'disagg'
    
    # 5. 如果无法确定，根据命名模式推测
    # 检查配置名中是否包含多节点标识
    config_lower = config_yml.lower()
    if any(pattern in config_lower for pattern in ['_2_nodes', '_3_nodes', '_4_nodes', 
                                                     '_2nodes', '_3nodes', '_4nodes',
                                                     'multi_node', 'multinode']):
        return 'multi-agg'
    
    # 检查是否包含 disagg 标识
    if any(pattern in config_lower for pattern in ['ctx', 'gen', 'disagg']):
        # 进一步检查：如果同时包含 ctx 和 gen，很可能是 disagg
        if 'ctx' in config_lower and 'gen' in config_lower:
            return 'disagg'
    
    # 默认为 single-agg
    return 'single-agg'


def identify_test_mode(test):
    """
    识别测试模式
    
    规则:
    1. 如果有 test_type: disagg，则为 disagg
    2. 如果 condition.terms 中有 nodes，则为 multi-agg
    3. 否则为 single-agg
    """
    # 检查 test_type
    if test.get('test_type') == 'disagg':
        return 'disagg'
    
    # 检查 condition.terms 中的 nodes
    condition = test.get('condition', {})
    terms = condition.get('terms', {})
    
    if 'nodes' in terms:
        nodes_value = terms['nodes']
        # 可能是字符串 "2" 或整数 2
        try:
            nodes_count = int(nodes_value)
            if nodes_count > 1:
                return 'multi-agg'
        except (ValueError, TypeError):
            pass
    
    # 默认为 single-agg
    return 'single-agg'


def parse_yaml_testlist(testlist_file, mode_filter=None):
    """
    解析 YAML 格式的 testlist 文件（test-db 兼容）
    
    Args:
        testlist_file: YAML 文件路径
        mode_filter: 可选的模式过滤器 (single-agg, multi-agg, disagg)
    
    Returns:
        dict: {
            "tests_by_mode": {
                "single-agg": [...],
                "multi-agg": [...],
                "disagg": [...]
            },
            "statistics": {
                "total": N,
                "single-agg": N,
                "multi-agg": N,
                "disagg": N
            }
        }
    """
    try:
        with open(testlist_file, 'r') as f:
            data = yaml.safe_load(f)
    except FileNotFoundError:
        print(f"错误: 文件不存在 - {testlist_file}", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"错误: YAML 解析失败 - {e}", file=sys.stderr)
        sys.exit(1)
    
    # test-db 格式: 顶层是 suite 名称
    # 例如: gb200_unified_perf_suite: { ... }
    # YAML 格式有两种结构：
    # 1. suite_name: {"tests": [...]}  # 字典格式
    # 2. suite_name: [{"condition": {...}, "tests": [...]}]  # 列表格式
    # 
    # ⚠️ 注意：可能有 "version" 字段，需要跳过
    if not data or not isinstance(data, dict):
        print(f"错误: YAML 文件格式不正确", file=sys.stderr)
        sys.exit(1)
    
    # 获取 suite 名称（跳过 "version" 字段）
    suite_name = None
    for key in data.keys():
        if key != 'version':
            suite_name = key
            break
    
    if not suite_name:
        print(f"错误: 未找到 suite 名称", file=sys.stderr)
        sys.exit(1)
    
    suite_data = data[suite_name]
    
    # 按模式分组
    tests_by_mode = {
        'single-agg': [],
        'multi-agg': [],
        'disagg': []
    }
    
    # 处理不同的 YAML 结构
    if isinstance(suite_data, list):
        # 列表格式：每个元素是一个测试组
        # [{"condition": {...}, "tests": [...]}, ...]
        for test_group in suite_data:
            if not isinstance(test_group, dict):
                continue
            
            # 获取测试组的条件
            condition = test_group.get('condition', {})
            terms = condition.get('terms', {})
            
            # 判断测试组的模式
            if test_group.get('test_type') == 'disagg':
                group_mode = 'disagg'
            elif 'nodes' in terms:
                try:
                    nodes_count = int(terms['nodes'])
                    group_mode = 'multi-agg' if nodes_count > 1 else 'single-agg'
                except (ValueError, TypeError):
                    group_mode = 'single-agg'
            else:
                # 如果没有明确指定，尝试从测试路径推断
                test_paths = test_group.get('tests', [])
                if test_paths and isinstance(test_paths, list) and len(test_paths) > 0:
                    first_test = test_paths[0]
                    if isinstance(first_test, str) and '[' in first_test and ']' in first_test:
                        # 从 test_path 提取 test_id
                        test_id = first_test.split('[')[1].split(']')[0]
                        group_mode = infer_test_mode_from_config(test_id)
                    else:
                        group_mode = 'single-agg'
                else:
                    group_mode = 'single-agg'
            
            # 应用过滤器
            if mode_filter and group_mode != mode_filter:
                continue
            
            # 添加测试
            for test_path in test_group.get('tests', []):
                tests_by_mode[group_mode].append({
                    'name': test_path,
                    'pytest_path': test_path,
                    'config_file': test_path,
                    'source_file': testlist_file,
                    'test_type': group_mode
                })
    
    elif isinstance(suite_data, dict):
        # 字典格式：直接包含 tests
        # {"tests": [...], "condition": {...}}
        tests = suite_data.get('tests', [])
        
        # 判断整个 suite 的模式
        condition = suite_data.get('condition', {})
        terms = condition.get('terms', {})
        
        if suite_data.get('test_type') == 'disagg':
            suite_mode = 'disagg'
        elif 'nodes' in terms:
            try:
                nodes_count = int(terms['nodes'])
                suite_mode = 'multi-agg' if nodes_count > 1 else 'single-agg'
            except (ValueError, TypeError):
                suite_mode = 'single-agg'
        else:
            suite_mode = 'single-agg'
        
        # 应用过滤器
        if mode_filter and suite_mode != mode_filter:
            tests = []
        
        # 添加测试
        for test_path in tests:
            tests_by_mode[suite_mode].append({
                'name': test_path,
                'pytest_path': test_path,
                'config_file': test_path,
                'source_file': testlist_file,
                'test_type': suite_mode
            })
    
    else:
        print(f"错误: 未找到 tests 列表", file=sys.stderr)
        sys.exit(1)
    
    # 统计信息
    statistics = {
        'total': sum(len(tests) for tests in tests_by_mode.values()),
        'single-agg': len(tests_by_mode['single-agg']),
        'multi-agg': len(tests_by_mode['multi-agg']),
        'disagg': len(tests_by_mode['disagg'])
    }
    
    return {
        'format': 'yaml',
        'tests_by_mode': tests_by_mode,
        'statistics': statistics
    }


def parse_txt_testlist(testlist_file, mode_filter=None):
    """
    解析 TXT 格式的 testlist 文件
    
    支持两种格式:
    1. pytest 路径格式（推荐）:
       test_perf_sanity.py::test_e2e[profiling-deepseek_r1_fp4_v2_blackwell]
       test_perf_sanity.py::test_e2e[benchmark-llama3_70b_disagg]
    
    2. 性能测试 ID 格式（简化）:
       profiling-deepseek_r1_fp4_v2_blackwell
       benchmark-llama3_70b_disagg
    
    3. 通用 pytest 格式:
       perf/test_perf.py::test_perf[gpt_next_2b-float16-input_len:128]
    
    模式识别:
    - 性能测试自动识别类型（通过读取配置文件或命名规则）
    - 支持手动标记覆盖自动识别: # mode:multi-agg, # mode:disagg
    
    Args:
        testlist_file: TXT 文件路径
        mode_filter: 可选的模式过滤器 (single-agg, multi-agg, disagg)
    
    Returns:
        dict: 同 parse_yaml_testlist
    """
    try:
        with open(testlist_file, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"错误: 文件不存在 - {testlist_file}", file=sys.stderr)
        sys.exit(1)
    
    tests_by_mode = {
        'single-agg': [],
        'multi-agg': [],
        'disagg': []
    }
    
    for line_num, line in enumerate(lines, 1):
        # 去除首尾空白
        line = line.strip()
        
        # 跳过空行和注释行
        if not line or line.startswith('#'):
            continue
        
        # 解析 pytest 路径和可选的模式标记
        test_path = line
        manual_mode = None  # 手动指定的模式
        
        # 检查行尾注释（例如: # mode:multi-agg）
        if '#' in line:
            parts = line.split('#', 1)
            test_path = parts[0].strip()
            comment = parts[1].strip()
            
            # 解析 mode:xxx 标记
            if comment.startswith('mode:'):
                specified_mode = comment[5:].strip()
                if specified_mode in ['single-agg', 'multi-agg', 'disagg']:
                    manual_mode = specified_mode
        
        # 自动识别测试模式
        test_mode = 'single-agg'  # 默认
        
        # 特殊处理：test_perf_sanity.py 性能测试格式
        if 'test_perf_sanity.py::test_e2e[' in test_path:
            # 从 test_perf_sanity.py::test_e2e[xxx] 提取 xxx
            if '[' in test_path and ']' in test_path:
                test_id = test_path.split('[')[1].split(']')[0]
                
                # 使用智能推断函数
                test_mode = infer_test_mode_from_config(test_id)
        
        # 如果是简化的测试 ID 格式（没有 ::）
        elif '-' in test_path and '::' not in test_path and '/' not in test_path:
            # 直接是测试 ID: profiling-deepseek_r1_fp4_v2_blackwell
            test_mode = infer_test_mode_from_config(test_path)
        
        # 手动标记优先级最高，覆盖自动识别
        if manual_mode:
            test_mode = manual_mode
        
        # 如果有模式过滤器，只保留匹配的测试
        if mode_filter and test_mode != mode_filter:
            continue
        
        # 构造测试对象（模拟 YAML 格式）
        test = {
            'name': test_path,
            'pytest_path': test_path,
            'config_file': test_path,  # 对于 txt 格式，直接用 pytest 路径
            'source_file': testlist_file,
            'source_line': line_num,
            'test_type': test_mode
        }
        
        tests_by_mode[test_mode].append(test)
    
    # 统计信息
    statistics = {
        'total': sum(len(tests) for tests in tests_by_mode.values()),
        'single-agg': len(tests_by_mode['single-agg']),
        'multi-agg': len(tests_by_mode['multi-agg']),
        'disagg': len(tests_by_mode['disagg'])
    }
    
    return {
        'format': 'txt',
        'tests_by_mode': tests_by_mode,
        'statistics': statistics
    }


def parse_testlist(testlist_file, mode_filter=None):
    """
    自动识别格式并解析 testlist 文件
    
    根据文件扩展名自动选择解析器：
    - .yml, .yaml -> parse_yaml_testlist
    - .txt -> parse_txt_testlist
    
    Args:
        testlist_file: 测试列表文件路径
        mode_filter: 可选的模式过滤器
    
    Returns:
        dict: 解析结果
    """
    # 检查文件是否存在
    if not os.path.exists(testlist_file):
        print(f"错误: 文件不存在 - {testlist_file}", file=sys.stderr)
        sys.exit(1)
    
    # 根据扩展名选择解析器
    ext = os.path.splitext(testlist_file)[1].lower()
    
    if ext in ['.yml', '.yaml']:
        return parse_yaml_testlist(testlist_file, mode_filter)
    elif ext == '.txt':
        return parse_txt_testlist(testlist_file, mode_filter)
    else:
        print(f"错误: 不支持的文件格式 - {ext}", file=sys.stderr)
        print(f"支持的格式: .yml, .yaml, .txt", file=sys.stderr)
        sys.exit(1)


def print_summary(result):
    """打印统计摘要"""
    stats = result['statistics']
    file_format = result.get('format', 'unknown')
    
    print("")
    print("=" * 60)
    print(f"测试统计信息 (格式: {file_format.upper()})")
    print("=" * 60)
    print(f"总测试数:       {stats['total']}")
    print(f"  single-agg:   {stats['single-agg']}")
    print(f"  multi-agg:    {stats['multi-agg']}")
    print(f"  disagg:       {stats['disagg']}")
    print("=" * 60)
    print("")


def main():
    parser = argparse.ArgumentParser(
        description='解析测试列表文件（支持 YAML 和 TXT 格式）',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
格式说明:

1. YAML 格式 (test-db 兼容):
   gb200_unified_perf_suite:
     tests:
       - name: "DeepSeek-R1 FP4"
         config_file: "deepseek_r1_fp4_v2_blackwell"
         condition:
           terms:
             nodes: 1  # single-agg
       
       - name: "Multi-Node Test"
         config_file: "llama3_70b"
         test_type: disagg
         condition:
           terms:
             nodes: 3

2. TXT 格式 (pytest 格式，一行一个 case):
   perf/test_perf.py::test_perf[gpt_next_2b-float16-input_len:128]
   accuracy/test_llm.py::TestLlama::test_nvfp4
   
   可选：在行尾添加模式标记
   perf/test_perf.py::test_case1  # mode:multi-agg
   perf/test_perf.py::test_case2  # mode:disagg

示例:
  # 解析 YAML 格式
  python3 parse_unified_testlist.py testlists/gb200_unified_suite.yml
  
  # 解析 TXT 格式（debug 用）
  python3 parse_unified_testlist.py testlists/debug_cases.txt
  
  # 只解析 single-agg 测试
  python3 parse_unified_testlist.py testlists/gb200_unified_suite.yml --mode single-agg
  
  # 显示统计信息
  python3 parse_unified_testlist.py testlists/gb200_unified_suite.yml --summary
        '''
    )
    
    parser.add_argument(
        'testlist',
        help='测试列表文件路径 (支持 .yml, .yaml, .txt 格式)'
    )
    
    parser.add_argument(
        '--mode',
        choices=['single-agg', 'multi-agg', 'disagg'],
        help='只解析指定模式的测试'
    )
    
    parser.add_argument(
        '--summary',
        action='store_true',
        help='显示统计摘要而不是 JSON 输出'
    )
    
    args = parser.parse_args()
    
    # 解析 testlist
    result = parse_testlist(args.testlist, args.mode)
    
    # 输出
    if args.summary:
        print_summary(result)
    else:
        # JSON 输出（供 shell 脚本使用）
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
