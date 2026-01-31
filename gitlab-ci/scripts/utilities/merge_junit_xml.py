#!/usr/bin/env python3
"""
Merge multiple JUnit XML files, with later results overriding earlier ones.
This is useful for test reruns where we want the final status to reflect rerun results.

Usage: merge_junit_xml.py <output_file> <input_file1> <input_file2> ...
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import OrderedDict


def merge_junit_xmls(output_file, *input_files):
    """
    Merge multiple JUnit XML files.
    Later files override earlier files for the same test case.
    """
    # Store test cases by their unique identifier (classname::name)
    test_cases = OrderedDict()
    
    # Counters for final testsuite
    total_tests = 0
    total_failures = 0
    total_errors = 0
    total_skipped = 0
    total_time = 0.0
    
    # Process each XML file in order
    for input_file in input_files:
        if not Path(input_file).exists():
            print(f"Warning: {input_file} not found, skipping")
            continue
            
        try:
            tree = ET.parse(input_file)
            root = tree.getroot()
            
            # Handle both <testsuite> and <testsuites> root elements
            testsuites = root.findall('.//testsuite') if root.tag == 'testsuites' else [root]
            
            for testsuite in testsuites:
                for testcase in testsuite.findall('testcase'):
                    classname = testcase.get('classname', '')
                    name = testcase.get('name', '')
                    test_id = f"{classname}::{name}"
                    
                    # Store or override test case
                    # Later results will override earlier ones
                    test_cases[test_id] = testcase
                    
        except ET.ParseError as e:
            print(f"Error parsing {input_file}: {e}")
            continue
    
    # Calculate final statistics
    for testcase in test_cases.values():
        total_tests += 1
        
        # Check for failures, errors, or skipped
        if testcase.find('failure') is not None:
            total_failures += 1
        if testcase.find('error') is not None:
            total_errors += 1
        if testcase.find('skipped') is not None:
            total_skipped += 1
            
        # Sum up time
        time_str = testcase.get('time', '0')
        try:
            total_time += float(time_str)
        except ValueError:
            pass
    
    # Create merged XML
    testsuite = ET.Element('testsuite', {
        'name': 'Merged Test Results',
        'tests': str(total_tests),
        'failures': str(total_failures),
        'errors': str(total_errors),
        'skipped': str(total_skipped),
        'time': f"{total_time:.3f}"
    })
    
    # Add all test cases
    for testcase in test_cases.values():
        testsuite.append(testcase)
    
    # Write merged XML
    tree = ET.ElementTree(testsuite)
    ET.indent(tree, space='  ')  # Pretty print (Python 3.9+)
    tree.write(output_file, encoding='utf-8', xml_declaration=True)
    
    # Print summary
    print(f"✓ Merged {len(input_files)} XML files into {output_file}")
    print(f"  Total tests: {total_tests}")
    print(f"  Passed: {total_tests - total_failures - total_errors - total_skipped}")
    print(f"  Failed: {total_failures}")
    print(f"  Errors: {total_errors}")
    print(f"  Skipped: {total_skipped}")
    
    return total_failures + total_errors


if __name__ == '__main__':
    if len(sys.argv) < 3:
        print("Usage: merge_junit_xml.py <output_file> <input_file1> [input_file2] ...")
        sys.exit(1)
    
    output_file = sys.argv[1]
    input_files = sys.argv[2:]
    
    exit_code = merge_junit_xmls(output_file, *input_files)
    sys.exit(0)  # Don't fail even if there are test failures

