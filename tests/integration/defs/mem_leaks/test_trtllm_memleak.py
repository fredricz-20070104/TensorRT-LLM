"""Memory leak test for TensorRT-LLM using valgrind and benchmark stress test."""

import os
import re
import subprocess
import tempfile
import time
from pathlib import Path
from subprocess import Popen, PIPE, TimeoutExpired


def get_free_memory_mb():
    """Get available memory in MB using free -m."""
    result = subprocess.run(['free', '-m'], capture_output=True, text=True)
    # Parse output: second line is memory info, second column is available
    lines = result.stdout.strip().split('\n')
    mem_line = lines[1]  # Mem: line
    parts = mem_line.split()
    available_mb = int(parts[6])  # 'available' column
    return available_mb


def wait_for_server_ready(log_file_path, timeout=300, keyword="TensorRT-LLM started"):
    """Wait for server to be ready by monitoring log file."""
    start_time = time.time()
    print(f"Waiting for server to start (looking for '{keyword}')...")
    
    while time.time() - start_time < timeout:
        if os.path.exists(log_file_path):
            with open(log_file_path, 'r') as f:
                content = f.read()
                if keyword in content:
                    print(f"✅ Server started successfully (found '{keyword}')")
                    return True
        time.sleep(2)
    
    print(f"❌ Server start timeout after {timeout} seconds")
    return False


def check_valgrind_errors(valgrind_log_path):
    """Check valgrind log for errors and extract error traces."""
    if not os.path.exists(valgrind_log_path):
        return False, "Valgrind log file not found"
    
    with open(valgrind_log_path, 'r') as f:
        content = f.read()
    
    # Look for valgrind errors
    error_patterns = [
        r'ERROR SUMMARY: (\d+) errors',
        r'definitely lost:',
        r'indirectly lost:',
        r'Invalid read',
        r'Invalid write',
        r'Use of uninitialised value'
    ]
    
    errors_found = []
    for pattern in error_patterns:
        matches = re.findall(pattern, content, re.MULTILINE)
        if matches:
            errors_found.append((pattern, matches))
    
    # Extract error summary
    error_summary_match = re.search(r'ERROR SUMMARY: (\d+) errors', content)
    has_errors = False
    
    if error_summary_match:
        error_count = int(error_summary_match.group(1))
        has_errors = error_count > 0
    
    # Extract leak summary
    leak_summary = []
    leak_section = re.search(
        r'LEAK SUMMARY:.*?(?=\n\n|\Z)', 
        content, 
        re.DOTALL | re.MULTILINE
    )
    if leak_section:
        leak_summary = leak_section.group(0).split('\n')
    
    return has_errors or bool(leak_summary), {
        'errors': errors_found,
        'leak_summary': leak_summary,
        'full_log_excerpt': content[-2000:] if len(content) > 2000 else content
    }


def test_trtllm_memleak(llm_root, llm_venv):
    """
    Test for memory leaks in TensorRT-LLM using valgrind and stress benchmark.
    
    Test procedure:
    1. Start trtllm-serve under valgrind (background)
    2. Wait for server ready and record initial memory
    3. Run sglang benchmark (stress test)
    4. Record final memory after benchmark
    5. Check memory difference (fail if > 2GB)
    6. Check valgrind output for errors
    """
    # Model configuration
    model_name = "meta-llama/Llama-3.1-8B"
    llama_model_dir = Path(os.environ.get('LLM_MODELS_ROOT', '')) / "llama-3.1-model/Meta-Llama-3.1-8B"
    
    if not llama_model_dir.exists():
        print(f"⚠️  Model directory not found: {llama_model_dir}")
        print("Skipping test...")
        return
    
    # Prepare log files
    valgrind_log = "./valgrind-memleak-test.log"
    server_log = "./trtllm-server-test.log"
    
    # Clean up old logs
    for log_file in [valgrind_log, server_log]:
        if os.path.exists(log_file):
            os.remove(log_file)
    
    print("="*80)
    print("Memory Leak Test Starting")
    print("="*80)
    print(f"Model: {model_name}")
    print(f"Model path: {llama_model_dir}")
    print(f"Valgrind log: {valgrind_log}")
    print(f"Server log: {server_log}")
    print("")
    
    # Start server under valgrind (background)
    valgrind_cmd = [
        'valgrind',
        '--leak-check=full',
        '--show-leak-kinds=all',
        '--num-transtab-sectors=48',
        '--track-origins=yes',
        '--trace-children=yes',
        f'--log-file={valgrind_log}',
        'trtllm-serve',
        str(llama_model_dir),
        '--trust_remote_code',
        '--backend', 'pytorch',
        '--max_num_tokens', '20000'
    ]
    
    print("🚀 Starting server under valgrind...")
    print(f"Command: {' '.join(valgrind_cmd)}")
    
    with open(server_log, 'w') as log_file:
        server_process = Popen(
            valgrind_cmd,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=llm_venv._new_env
        )
    
    try:
        # Wait for server to be ready
        if not wait_for_server_ready(server_log, timeout=600):
            print("❌ Server failed to start")
            server_process.terminate()
            server_process.wait(timeout=30)
            raise RuntimeError("Server startup timeout")
        
        # Record initial memory
        time.sleep(5)  # Let server stabilize
        initial_memory_mb = get_free_memory_mb()
        print(f"📊 Initial available memory: {initial_memory_mb} MB")
        
        # Run benchmark
        print("")
        print("🔥 Starting benchmark stress test...")
        benchmark_cmd = [
            'python3', '-m', 'sglang.bench_serving',
            '--dataset-name', 'random-ids',
            '--backend', 'vllm',
            '--model', model_name,
            '--random-range-ratio', '1',
            '--num-prompt', '600',
            '--random-input', '1024',
            '--random-output', '1024',
            '--max-concurrency', '100'
        ]
        
        print(f"Command: {' '.join(benchmark_cmd)}")
        
        benchmark_result = subprocess.run(
            benchmark_cmd,
            capture_output=True,
            text=True,
            timeout=1800,  # 30 minutes
            env=llm_venv._new_env
        )
        
        if benchmark_result.returncode != 0:
            print(f"⚠️  Benchmark failed with code {benchmark_result.returncode}")
            print("STDERR:", benchmark_result.stderr[-500:])
        else:
            print("✅ Benchmark completed successfully")
        
        # Record final memory
        time.sleep(5)  # Let system stabilize
        final_memory_mb = get_free_memory_mb()
        print(f"📊 Final available memory: {final_memory_mb} MB")
        
        # Calculate memory difference
        memory_diff_mb = initial_memory_mb - final_memory_mb
        memory_diff_gb = memory_diff_mb / 1024.0
        
        print("")
        print("="*80)
        print("Memory Analysis")
        print("="*80)
        print(f"Initial memory:  {initial_memory_mb} MB")
        print(f"Final memory:    {final_memory_mb} MB")
        print(f"Memory consumed: {memory_diff_mb} MB ({memory_diff_gb:.2f} GB)")
        print("")
        
        # Check memory leak threshold
        memory_leak_threshold_gb = 2.0
        has_memory_leak = memory_diff_gb > memory_leak_threshold_gb
        
        if has_memory_leak:
            print(f"❌ MEMORY LEAK DETECTED!")
            print(f"   Memory consumed ({memory_diff_gb:.2f} GB) exceeds threshold ({memory_leak_threshold_gb} GB)")
        else:
            print(f"✅ Memory usage within acceptable range")
        
        # Terminate server
        print("")
        print("🛑 Stopping server...")
        server_process.terminate()
        try:
            server_process.wait(timeout=30)
        except TimeoutExpired:
            server_process.kill()
            server_process.wait()
        
        # Wait for valgrind to write final report
        time.sleep(5)
        
        # Check valgrind errors
        print("")
        print("="*80)
        print("Valgrind Analysis")
        print("="*80)
        
        has_valgrind_errors, error_details = check_valgrind_errors(valgrind_log)
        
        if has_valgrind_errors:
            print("❌ Valgrind detected errors/leaks:")
            print("")
            
            if error_details['leak_summary']:
                print("Leak Summary:")
                for line in error_details['leak_summary']:
                    print(f"  {line}")
                print("")
            
            if error_details['errors']:
                print("Errors Found:")
                for pattern, matches in error_details['errors']:
                    print(f"  Pattern: {pattern}")
                    print(f"  Matches: {matches}")
                print("")
            
            print("Valgrind Log Excerpt (last 2000 chars):")
            print("-"*80)
            print(error_details['full_log_excerpt'])
            print("-"*80)
        else:
            print("✅ No valgrind errors detected")
        
        # Final verdict
        print("")
        print("="*80)
        print("Test Result")
        print("="*80)
        
        test_passed = not has_memory_leak and not has_valgrind_errors
        
        if test_passed:
            print("✅ PASSED: No memory leaks detected")
        else:
            failure_reasons = []
            if has_memory_leak:
                failure_reasons.append(f"Memory leak: {memory_diff_gb:.2f} GB > {memory_leak_threshold_gb} GB")
            if has_valgrind_errors:
                failure_reasons.append("Valgrind errors detected")
            
            print("❌ FAILED:")
            for reason in failure_reasons:
                print(f"   - {reason}")
            
            raise AssertionError(f"Memory leak test failed: {'; '.join(failure_reasons)}")
    
    finally:
        # Cleanup: ensure server is killed
        if server_process.poll() is None:
            print("Cleaning up server process...")
            server_process.kill()
            server_process.wait()
        
        print("")
        print(f"Logs saved:")
        print(f"  - Valgrind: {valgrind_log}")
        print(f"  - Server:   {server_log}")
        print("="*80)


if __name__ == "__main__":
    # For standalone testing
    import sys
    
    class MockVenv:
        _new_env = os.environ.copy()
    
    test_trtllm_memleak(None, MockVenv())