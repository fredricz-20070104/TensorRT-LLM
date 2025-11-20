#!/usr/bin/env python3
"""Rename YAML config files based on their content."""

import os
import yaml
from pathlib import Path


def extract_new_filename(yaml_path: Path) -> str:
    """Extract configuration and generate new filename.
    
    Format: {model_name}_{benchmark_type}_ctx{ctx_num}_gen{gen_num}_{dep_flag}{tp_size}_bs{batch_size}_eplb{eplb}_mtp{mtp}_ccb-{backend}.yaml
    """
    with open(yaml_path, 'r') as f:
        config = yaml.safe_load(f)
    
    # Extract metadata
    metadata = config.get('metadata', {})
    model_name = metadata.get('model_name', 'unknown')
    
    # Extract sequence info
    sequence = config.get('sequence', {})
    isl = sequence.get('input_length', 0)
    osl = sequence.get('output_length', 0)
    benchmark_type = f"{isl//1024}k{osl//1024}k"
    
    # Extract hardware info
    hardware = config.get('hardware', {})
    ctx_num = hardware.get('num_ctx_servers', 0)
    gen_num = hardware.get('num_gen_servers', 0)
    
    # Extract worker config
    worker_config = config.get('worker_config', {})
    gen_config = worker_config.get('gen', {})
    
    tp_size = gen_config.get('tensor_parallel_size', 0)
    batch_size = gen_config.get('max_batch_size', 0)
    enable_dp = gen_config.get('enable_attention_dp', False)
    dep_flag = 'dep' if enable_dp else 'tep'
    
    # Extract cache transceiver backend
    cache_config = gen_config.get('cache_transceiver_config', {})
    backend = cache_config.get('backend', 'UNKNOWN')
    
    # Extract EPLB slots
    moe_config = gen_config.get('moe_config', {})
    load_balancer = moe_config.get('load_balancer', {})
    eplb_slots = load_balancer.get('num_slots', 0)
    
    # Extract MTP
    spec_config = gen_config.get('speculative_config', {})
    mtp_size = spec_config.get('num_nextn_predict_layers', 0)
    
    # Generate new filename
    new_name = (
        f"{model_name}_{benchmark_type}_"
        f"ctx{ctx_num}_gen{gen_num}_"
        f"{dep_flag}{tp_size}_bs{batch_size}_"
        f"eplb{eplb_slots}_mtp{mtp_size}_"
        f"ccb-{backend}.yaml"
    )
    
    return new_name


def rename_configs(test_configs_dir: str, dry_run: bool = True):
    """Rename all YAML config files in test_configs directory.
    
    Args:
        test_configs_dir: Path to test_configs directory
        dry_run: If True, only print what would be renamed without actually renaming
    """
    test_configs_path = Path(test_configs_dir)
    
    # Find all YAML files
    yaml_files = []
    for pattern in ['**/*.yaml', '**/*.yml']:
        yaml_files.extend(test_configs_path.glob(pattern))
    
    # Exclude README files
    yaml_files = [f for f in yaml_files if 'README' not in f.name]
    
    print(f"Found {len(yaml_files)} YAML files to process\n")
    
    rename_operations = []
    
    for yaml_file in sorted(yaml_files):
        try:
            new_name = extract_new_filename(yaml_file)
            new_path = yaml_file.parent / new_name
            
            if yaml_file.name != new_name:
                rename_operations.append((yaml_file, new_path, new_name))
                print(f"[RENAME] {yaml_file.relative_to(test_configs_path)}")
                print(f"      -> {new_name}")
                print()
            else:
                print(f"[OK] {yaml_file.relative_to(test_configs_path)} (already correct)")
                print()
                
        except Exception as e:
            print(f"[ERROR] processing {yaml_file.relative_to(test_configs_path)}: {e}")
            print()
    
    # Summary
    print(f"\n{'='*80}")
    print(f"Summary: {len(rename_operations)} files need to be renamed")
    print(f"{'='*80}\n")
    
    if not dry_run and rename_operations:
        # Auto-confirm in non-interactive mode
        import sys
        auto_yes = '--yes' in sys.argv or not sys.stdin.isatty()
        
        if auto_yes:
            response = 'yes'
            print("Auto-confirming rename operation...")
        else:
            response = input("Proceed with renaming? (yes/no): ")
        
        if response.lower() == 'yes':
            for old_path, new_path, new_name in rename_operations:
                try:
                    old_path.rename(new_path)
                    print(f"[SUCCESS] Renamed: {old_path.name} -> {new_name}")
                except Exception as e:
                    print(f"[FAILED] Failed to rename {old_path.name}: {e}")
            print(f"\nRenaming complete!")
        else:
            print("Renaming cancelled.")
    elif dry_run:
        print("This is a DRY RUN. No files were actually renamed.")
        print("Run with dry_run=False to perform actual renaming.")


if __name__ == '__main__':
    # Get the test_configs directory
    script_dir = Path(__file__).parent
    test_configs_dir = script_dir / 'test_configs'
    
    # Run in dry-run mode first to preview changes
    import sys
    dry_run = '--execute' not in sys.argv
    rename_configs(test_configs_dir, dry_run=dry_run)

