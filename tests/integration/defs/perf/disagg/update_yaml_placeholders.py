#!/usr/bin/env python3
"""Update YAML files with standardized placeholder fields."""

import os
import yaml
from pathlib import Path
from typing import Dict, Any


def update_nested_dict(target: Dict[Any, Any], updates: Dict[Any, Any], keys_to_update: set) -> None:
    """Update specific keys in nested dictionary.
    
    Args:
        target: Target dictionary to update
        updates: Dictionary containing update values
        keys_to_update: Set of keys that should be updated (only these will be modified)
    """
    for key, value in updates.items():
        if key in keys_to_update:
            if isinstance(value, dict) and key in target and isinstance(target[key], dict):
                # Recursively update nested dict, but only for specified keys
                update_nested_dict(target[key], value, keys_to_update)
            else:
                # Update the value
                target[key] = value


def update_yaml_file(yaml_path: Path, template_updates: Dict[str, Any]) -> bool:
    """Update a single YAML file with template values.
    
    Args:
        yaml_path: Path to YAML file
        template_updates: Dictionary of updates to apply
        
    Returns:
        bool: True if file was modified, False otherwise
    """
    try:
        with open(yaml_path, 'r', encoding='utf-8') as f:
            data = yaml.safe_load(f)
        
        if not data:
            print(f"  [WARNING] Empty file: {yaml_path.name}")
            return False
        
        # Define which specific keys we want to update
        keys_to_update = {
            'script_file', 'partition', 'account',  # slurm fields
            'container_mount', 'container_image', 'model_path', 
            'dataset_file', 'work_dir'  # environment fields
        }
        
        modified = False
        
        # Update slurm section
        if 'slurm' in template_updates and 'slurm' in data:
            for key in ['script_file', 'partition', 'account']:
                if key in template_updates['slurm']:
                    old_val = data['slurm'].get(key)
                    new_val = template_updates['slurm'][key]
                    if old_val != new_val:
                        data['slurm'][key] = new_val
                        modified = True
        
        # Update environment section
        if 'environment' in template_updates and 'environment' in data:
            for key in ['container_mount', 'container_image', 'model_path', 'dataset_file', 'work_dir']:
                if key in template_updates['environment']:
                    old_val = data['environment'].get(key)
                    new_val = template_updates['environment'][key]
                    if old_val != new_val:
                        data['environment'][key] = new_val
                        modified = True
        
        # Write back if modified
        if modified:
            with open(yaml_path, 'w', encoding='utf-8') as f:
                yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
            return True
        
        return False
        
    except Exception as e:
        print(f"  [ERROR] Error processing {yaml_path.name}: {e}")
        return False


def main():
    """Main function to update all YAML files."""
    # Define the template updates (fields with <> placeholders)
    template_updates = {
        'slurm': {
            'script_file': 'disaggr_torch.slurm',
            'partition': '<partition>',
            'account': '<account>',
        },
        'environment': {
            'container_mount': '<container_mount>',
            'container_image': '<container_image>',
            'model_path': '<model_path>',
            'dataset_file': '<dataset_file>',
            'work_dir': '<full_path_to_work_dir>',
        }
    }
    
    # Get script directory and test_configs path
    script_dir = Path(__file__).parent
    test_configs_dir = script_dir / "test_configs"
    
    if not test_configs_dir.exists():
        print(f"❌ Directory not found: {test_configs_dir}")
        return
    
    print("=" * 80)
    print("[UPDATE] Updating YAML files with standardized placeholder fields")
    print("=" * 80)
    print()
    print("[FIELDS] Fields to update:")
    print("  - slurm.script_file: 'disaggr_torch.slurm'")
    print("  - slurm.partition: '<partition>'")
    print("  - slurm.account: '<account>'")
    print("  - environment.container_mount: '<container_mount>'")
    print("  - environment.container_image: '<container_image>'")
    print("  - environment.model_path: '<model_path>'")
    print("  - environment.dataset_file: '<dataset_file>'")
    print("  - environment.work_dir: '<full_path_to_work_dir>'")
    print()
    print("=" * 80)
    print()
    
    # Find all YAML files
    yaml_files = sorted(test_configs_dir.rglob("*.yaml"))
    
    if not yaml_files:
        print("[ERROR] No YAML files found")
        return
    
    print(f"[FOUND] Found {len(yaml_files)} YAML files")
    print()
    
    # Process each file
    updated_count = 0
    unchanged_count = 0
    
    for yaml_file in yaml_files:
        rel_path = yaml_file.relative_to(test_configs_dir)
        
        # Update the file
        was_modified = update_yaml_file(yaml_file, template_updates)
        
        if was_modified:
            print(f"  [UPDATED] {rel_path}")
            updated_count += 1
        else:
            print(f"  [SKIP] {rel_path}")
            unchanged_count += 1
    
    print()
    print("=" * 80)
    print("[SUMMARY]")
    print(f"  Total files: {len(yaml_files)}")
    print(f"  Updated: {updated_count}")
    print(f"  Unchanged: {unchanged_count}")
    print("=" * 80)
    print()
    print("[SUCCESS] Update complete!")


if __name__ == "__main__":
    main()

