#!/usr/bin/env python3
import os
import sys
import csv
import re
import argparse
import pymysql
import json
import yaml
from collections import OrderedDict
import pandas as pd
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from common.jenkinsops import JenkinsOps

'''
TRT_perf DB Tables:

TRT_perf.runs
+--------------+---------------+------+-----+---------+----------------+
| Field        | Type          | Null | Key | Default | Extra          |
+--------------+---------------+------+-----+---------+----------------+
| id           | int unsigned  | NO   | PRI | NULL    | auto_increment |
| start_time   | datetime      | YES  |     | NULL    |                |
| end_time     | datetime      | YES  |     | NULL    |                |
| driver       | varchar(150)  | NO   |     | NULL    |                |
| cuda         | varchar(150)  | NO   |     | NULL    |                |
| cudnn        | varchar(150)  | NO   |     | NULL    |                |
| tensorrt     | varchar(150)  | NO   |     | NULL    |                |
| gpu          | varchar(150)  | NO   |     | NULL    |                |
| graphic_freq | varchar(150)  | NO   |     | NULL    |                |
| memory_freq  | varchar(150)  | NO   |     | NULL    |                |
| cpu          | varchar(150)  | YES  |     | NULL    |                |
| cl           | varchar(150)  | YES  |     | NULL    |                |
| os           | varchar(150)  | NO   |     | NULL    |                |
| notes        | varchar(2000) | YES  |     | NULL    |                |
| cublas       | varchar(150)  | YES  |     | NULL    |                |
| link         | varchar(2000) | YES  |     | NULL    |                |
| vbios        | varchar(150)  | YES  |     | NULL    |                |
| trtllm       | varchar(150)  | YES  |     | NULL    |                |
+--------------+---------------+------+-----+---------+----------------+

TRT_perf.cases
+-----------+---------------+------+-----+---------+----------------+
| Field     | Type          | Null | Key | Default | Extra          |
+-----------+---------------+------+-----+---------+----------------+
| id        | int unsigned  | NO   | PRI | NULL    | auto_increment |
| cmd       | varchar(2000) | NO   |     | NULL    |                |
| batchsize | int unsigned  | NO   |     | NULL    |                |
| format    | varchar(150)  | NO   |     | NULL    |                |
| network   | varchar(150)  | NO   |     | NULL    |                |
| precision | varchar(50)   | NO   |     | NULL    |                |
+-----------+---------------+------+-----+---------+----------------+

TRT_perf.perf_result
+---------------+---------------+------+-----+---------+----------------+
| Field         | Type          | Null | Key | Default | Extra          |
+---------------+---------------+------+-----+---------+----------------+
| id            | int unsigned  | NO   | PRI | NULL    | auto_increment |
| UUID          | varchar(1500) | YES  |     | NULL    |                |
| case_id       | int unsigned  | NO   | MUL | NULL    |                |
| run_id        | int unsigned  | NO   | MUL | NULL    |                |
| gpu_time      | float(16,6)   | NO   |     | NULL    |                |
| total_time    | float(16,6)   | YES  |     | NULL    |                |
| fp16_vs_fp32  | float(16,6)   | YES  |     | NULL    |                |
| int8_vs_fp16  | float(16,6)   | YES  |     | NULL    |                |
| int8_vs_fp32  | float(16,6)   | YES  |     | NULL    |                |
| build_time    | float(16,6)   | YES  |     | NULL    |                |
| perf_data     | json          | YES  |     | NULL    |                |
| perf_baseline | json          | YES  |     | NULL    |                |
| throughput    | float(16,6)   | YES  |     | NULL    |                |
| log           | longtext      | YES  |     | NULL    |                |
+---------------+---------------+------+-----+---------+----------------+

'''
# Set a very large field size limit to handle large OrderedDict strings in CSV files
# This is needed especially for perf_script_test_results.csv which may be up to 450MB
try:
    # First, try setting a very large field size limit (1GB)
    csv.field_size_limit(1024 * 1024 * 1024)  # 1GB
    print("Using 1GB CSV field size limit")
except OverflowError:
    # If that fails, try with progressive decreases
    print("CSV field size limit of 1GB not supported, trying lower values...")
    max_sizes = [500 * 1024 * 1024, 250 * 1024 * 1024, 100 * 1024 * 1024]  # 500MB, 250MB, 100MB

    for size in max_sizes:
        try:
            csv.field_size_limit(size)
            print(f"Using {size/(1024*1024):.0f}MB CSV field size limit")
            break
        except OverflowError:
            continue
    else:
        # If all specified sizes failed, try sys.maxsize with progressive decreases
        try:
            maxInt = sys.maxsize

            while True:
                try:
                    csv.field_size_limit(maxInt)
                    print(f"Using {maxInt/(1024*1024):.1f}MB CSV field size limit")
                    break
                except OverflowError:
                    maxInt = int(maxInt/10)

        except Exception as e:
            # As a last resort, try with a known safe value
            print(f"Warning: Could not properly set CSV field size limit: {e}")
            csv.field_size_limit(1024 * 1024 * 100)  # 100MB as last resort
            print("Using 100MB CSV field size limit as fallback")

DEFAULT_DB_HOST = os.getenv('DB_HOST', 'dlswqa-nas.nvidia.com')
DEFAULT_DB_PORT = os.getenv('DB_PORT', 13306)
DEFAULT_DB_USER = os.getenv('DB_USER', 'swqa')
DEFAULT_DB_PASSWORD = os.getenv('DB_PASSWORD', 'labuser')
DEFAULT_DB_SCHEMA = os.getenv('DB_SCHEMA', 'TRT_perf')

class TRTPerfParser:
    def __init__(self, args):
        self.args = args
        self.run_info = {
            "driver": self.args.driver.strip(),
            "cpu": self.args.cpu_name.strip(),
            "os": self.args.os.strip(),
            "gpu": self.args.gpu.replace("NVIDIA", "").strip(),
            "cuda": self.args.cuda.strip(),
            "sm_clock": self.args.sm_clock.strip(),
            "mem_clock": self.args.mem_clock.strip(),
            "tensorrt": self.args.tensorrt.strip(),
            "notes": self.args.notes.strip(),
            "cl": self.args.commit.strip(),
            "trtllm": self.args.trtllm.strip().split('\n')[0].strip(),
            "start_time": self.args.start_time.strip(),
            "end_time": self.args.end_time.strip(),
            "commit_time": self.args.commit_time.strip() if self.args.commit_time.strip() else self._get_commit_time(),
            "link": self.args.link.strip(),
            "hostname": self.args.hostname.strip(),
            "ip": self.args.ip.strip()
        }
        self.cases_results = {}
        self.verbose = args.verbose
        self.junit_log_map = {}
        if hasattr(args, 'junit_xml') and args.junit_xml:
            self.junit_log_map = self.parse_junit_xml(args.junit_xml)

    def _get_commit_time(self):
        """Fetch commit_time from GitHub API or Jenkins job console log."""
        # Method 1: Use --commit parameter to get from GitHub API (fast & reliable)
        commit_hash = self.args.commit.strip()
        if commit_hash:
            try:
                fetched_time = JenkinsOps._get_commit_time_from_github('NVIDIA', 'TensorRT-LLM', commit_hash)
                if fetched_time:
                    print(f"Fetched commit_time from GitHub: {fetched_time}")
                    return fetched_time
            except Exception as e:
                print(f"Failed to fetch commit_time from GitHub: {type(e).__name__}: {e}")
        
        # Method 2: Fallback to Jenkins job console log
        job_link = self.args.link.strip()
        if job_link:
            try:
                fetched_time, _ = JenkinsOps.get_trtllm_commit_time_from_job(job_link)
                if fetched_time:
                    print(f"Fetched commit_time from job: {fetched_time}")
                    return fetched_time
            except Exception as e:
                print(f"Failed to fetch commit_time from job: {type(e).__name__}: {e}")
        
        return ""

    def read_csv(self, csv_file):
        data = []
        with open(csv_file) as csvfile:
            reader = csv.DictReader(csvfile)
            for row in reader:
                data.append(row)
        return data

    def get_throughput(self, perf_data):
        """Extract throughput value from perf_data using consistent field names"""
        throughput = ""
        if "tokens_per__sec" in perf_data:
            throughput = perf_data["tokens_per__sec"]
        elif "throughput__qps" in perf_data:
            throughput = perf_data["throughput__qps"]
        elif "throughput" in perf_data:
            throughput = perf_data["throughput"]
        elif "Throughput" in perf_data:
            throughput = perf_data["Throughput"]

        if throughput == "" or throughput == "err":
            throughput = 0.0
        return throughput

    def get_session_properties(self):
        """Parse session properties from multi-column CSV format and update run_info"""
        if self.args.source_properties and os.path.exists(self.args.source_properties):
            print("INFO: Get Run Info from session properties csv")
            props_data = self.read_csv(self.args.source_properties)
            if not props_data:
                return

            # Get the first row of properties data
            props = props_data[0]

            # Map properties to run_info fields
            field_mapping = {
                "nvidia_driver_version": "driver",
                "cuda_version": "cuda",
                "trt_version": "tensorrt",
                "start_timestamp": "start_time",
                "end_timestamp": "end_time",
                "hostname": "hostname",
                "ip": "ip"
            }

            for prop_key, run_info_key in field_mapping.items():
                if prop_key in props and props[prop_key] and not self.run_info[run_info_key]:
                    self.run_info[run_info_key] = props[prop_key]

            # Extract GPU info from gpu_properties if available
            if "gpu_properties" in props and props["gpu_properties"]:
                try:
                    # Handle the OrderedDict string format
                    gpu_props_str = props["gpu_properties"]
                    if gpu_props_str.startswith("OrderedDict"):
                        # Extract device_product_name from gpu_properties
                        match = re.search(r"'device_product_name':\s*'([^']+)'", gpu_props_str)
                        if match and not self.run_info["gpu"]:
                            self.run_info["gpu"] = match.group(1).replace("NVIDIA", "").strip()
                except Exception as e:
                    if self.verbose:
                        print(f"Error parsing GPU properties: {e}")

            # Extract OS info from os_properties if available
            if "os_properties" in props and props["os_properties"]:
                try:
                    # Parse OS properties from OrderedDict string format
                    os_props_str = props["os_properties"]
                    if os_props_str.startswith("OrderedDict"):
                        # Extract name and version from os_properties
                        name_match = re.search(r"'name':\s*'([^']+)'", os_props_str)
                        version_match = re.search(r"'version':\s*'([^']+)'", os_props_str)
                        if name_match and version_match and not self.run_info["os"]:
                            self.run_info["os"] = f"{name_match.group(1)} {version_match.group(1)}"
                except Exception as e:
                    if self.verbose:
                        print(f"Error parsing OS properties: {e}")

            # Extract CPU info from cpu_properties if available
            if "cpu_properties" in props and props["cpu_properties"]:
                try:
                    # Parse CPU properties from OrderedDict string format
                    cpu_props_str = props["cpu_properties"]
                    if cpu_props_str.startswith("OrderedDict"):
                        # Extract product_name from cpu_properties
                        match = re.search(r"'product_name':\s*'([^']+)'", cpu_props_str)
                        if match and not self.run_info["cpu"]:
                            self.run_info["cpu"] = match.group(1)
                        else:
                            # Try shorthand_cpu_name
                            match = re.search(r"'shorthand_cpu_name':\s*'([^']+)'", cpu_props_str)
                            if match and not self.run_info["cpu"]:
                                self.run_info["cpu"] = match.group(1)
                except Exception as e:
                    if self.verbose:
                        print(f"Error parsing CPU properties: {e}")
                        
            # Extract GPU clock information
            if "sm_clk" in props and not self.run_info["sm_clock"]:
                self.run_info["sm_clock"] = props["sm_clk"]
            if "mem_clk" in props and not self.run_info["mem_clock"]:
                self.run_info["mem_clock"] = props["mem_clk"]
            
            # Also check for Graph Clock(MHz) and Memory Clock(MHz) fields
            if "Graph Clock(MHz)" in props and not self.run_info["sm_clock"]:
                self.run_info["sm_clock"] = props["Graph Clock(MHz)"]
            if "Memory Clock(MHz)" in props and not self.run_info["mem_clock"]:
                self.run_info["mem_clock"] = props["Memory Clock(MHz)"]

            if self.verbose:
                print(f"Run info after parsing properties: {self.run_info}")

    def parse_junit_xml(self, xml_path):
        """parse junit xml file and return {case_name: log} dictionary"""
        if not xml_path or not os.path.exists(xml_path):
            return {}
        tree = ET.parse(xml_path)
        root = tree.getroot()
        case_log_map = {}
        print(f"Parsing junit xml file: {xml_path}")
        for testcase in root.iter('testcase'):
            name = testcase.attrib.get('name', '')
            # Remove test_perf prefix and extract the parameter part in brackets
            name = name.replace("test_perf", "")
            # Extract the parameter part from brackets if it exists
            bracket_match = re.search(r'\[(.*?)\]', name)
            if bracket_match:
                name = bracket_match.group(1)
            system_out = testcase.find('system-out')
            if system_out is not None and system_out.text:
                case_log_map[name] = system_out.text
        return case_log_map
    
    def _relaxed_match(self, test_param, junit_key):
        """
        Perform relaxed matching by ignoring maxbs:512 and maxnt:2048 parameters(default values) if they don't exist in junit_key
        
        Args:
            test_param: The test parameter extracted from test name
            junit_key: The key from junit log map
            
        Returns:
            bool: True if parameters match after relaxing maxbs/maxnt constraints
        """
        normalized_param = test_param
        junit_key_normalized = junit_key
        if 'maxbs:' not in junit_key:
            normalized_param = re.sub(r'-?maxbs:512', '', normalized_param)
        if 'maxnt:' not in junit_key:
            normalized_param = re.sub(r'-?maxnt:2048', '', normalized_param)
        if 'tp:' in junit_key and 'tp:' not in normalized_param:
            param_gpus_match = re.search(r'gpus:(\d+)', normalized_param)
            junit_tp_match = re.search(r'tp:(\d+)', junit_key)
            if param_gpus_match and junit_tp_match:
                if param_gpus_match.group(1) == junit_tp_match.group(1):
                    junit_key_normalized = re.sub(r'-?tp:\d+', '', junit_key)
        if self.verbose:
            print(f"Original test parameter: {test_param}")
            print(f"Normalized test parameter (removed maxbs/maxnt): {normalized_param}")
            print(f"Normalized junit key parameter: {junit_key_normalized}")
        return normalized_param == junit_key_normalized

    
    def get_gpu_clocks(self):
        """Parse GPU clock information from gpu_monitoring.csv and update run_info"""
        if not hasattr(self.args, 'source_gpu_monitoring') or not os.path.exists(self.args.source_gpu_monitoring):
            self.run_info["sm_clock"] = ""
            self.run_info["mem_clock"] = ""
            return

        print("INFO: Get GPU clock information from gpu monitoring csv")
        try:
            df = pd.read_csv(self.args.source_gpu_monitoring)
            
            # calculate gpu clock frequency
            if 'gpu_clock__MHz' in df.columns:
                clock_counts = df['gpu_clock__MHz'].value_counts()
                print(f"GPU clock frequency distribution:\n{clock_counts}")
                self.run_info["sm_clock"] = str(int(clock_counts.index[0]))  # most common value
            else:
                self.run_info["sm_clock"] = ""
            
            # calculate memory clock frequency
            if 'memory_clock__MHz' in df.columns:
                mem_counts = df['memory_clock__MHz'].value_counts()
                print(f"Memory clock frequency distribution:\n{mem_counts}")
                self.run_info["mem_clock"] = str(int(mem_counts.index[0]))  # most common value
            else:
                self.run_info["mem_clock"] = ""
            
        except Exception as e:
            print(f"Error processing GPU monitoring data: {e}")
            self.run_info["sm_clock"] = ""
            self.run_info["mem_clock"] = ""

    def extract_batch_from_network(self, network_name):
        """Extract batch size from network name if available"""
        # Look for common batch size patterns in network name

        # Check for bs: or maxbs: pattern with multiple batch sizes separated by +
        multi_bs_pattern = re.search(r'(bs:|maxbs:)(\d+\+\d+)', network_name, re.IGNORECASE)
        if multi_bs_pattern:
            # Found multiple batch sizes (e.g., bs:32+64), return 0
            return "0"

        # Check for single bs: or maxbs: pattern
        bs_pattern = re.search(r'(bs:|maxbs:)(\d+)', network_name, re.IGNORECASE)
        if bs_pattern:
            return bs_pattern.group(2)

        # Other common patterns for batch size
        batch_patterns = [
            r'[-_/]bs_(\d+\+\d+)',                # Examples with multiple batch sizes: /bs_32+64
            r'[-_/]batch_size_(\d+\+\d+)',        # Examples with multiple batch sizes: /batch_size_8+16
            r'[-_/]bs(\d+\+\d+)',                 # Examples with multiple batch sizes: /bs32+64
            r'[-_/]b(\d+\+\d+)',                  # Examples with multiple batch sizes: /b16+32
            r'batch(\d+\+\d+)',                   # Examples with multiple batch sizes: batch4+8
        ]

        # Check for multi-batch patterns first
        for pattern in batch_patterns:
            match = re.search(pattern, network_name)
            if match:
                # Found a multi-batch pattern, return 0
                return "0"

        # If no multi-batch pattern found, check for single batch patterns
        single_batch_patterns = [
            r'[-_/]bs_(\d+)',                     # Examples: /bs_32, -bs_64, _bs_128
            r'[-_/]batch_size_(\d+)',             # Examples: /batch_size_8, -batch_size_16, _batch_size_32
            r'[-_/]bs(\d+)',                      # Examples: /bs32, -bs64, _bs128
            r'[-_/]b(\d+)',                       # Examples: /b16, -b32, _b64
            r'batch(\d+)',                        # Examples: batch4, batch8, batch16
        ]

        for pattern in single_batch_patterns:
            match = re.search(pattern, network_name)
            if match:
                return match.group(1)

        # Default batch size if not found
        return "0"

    def is_pre_ampere_arch(self, gpu_name):
        """Determine if the GPU is pre-Ampere architecture"""
        PRE_AMPERE_GPUS = [
            "P100",
            "P40",
            "P4",
            "Titan X",
            "V100",
            "Titan RTX",
            "RTX 6000",
            "RTX 8000",
            "RTX 2080",
            "T4",
            "TU104",
            "GTX1080",
        ]
        for gpu in PRE_AMPERE_GPUS:
            if gpu.lower() in gpu_name.lower():
                return True
        return False

    def get_framework_from_network(self, network_name):
        """Extract framework from network name

        Args:
            network_name: Name of the network to extract framework from

        Returns:
            Framework name: "ONNX" if "-onnx-" in network_name, "HF" otherwise
        """
        if "-onnx-" in network_name.lower():
            return "ONNX"
        return "ONNX"

    def get_precision_from_command(self, command):
        """Extract precision from command"""
        if "float16" in command or "--fp16" in command or "-fp16" in command:
            return "FP16"
        elif "int8" in command or "--int8" in command or "-int8" in command:
            return "INT8"
        elif "bfloat16" in command or "--bf16" in command or "-bf16" in command:
            return "BF16"
        elif "float32" in command or "--noTF32" in command or "-fp32" in command:
            return "FP32"
        elif "fp8" in command or "--fp8" in command or "-fp8" in command:
            return "FP8"
        elif "fp4" in command or "nvfp4" in command or "--fp4" in command or "-fp4" in command:
            return "FP4"
        else:
            # Default to TF32 for Ampere+ GPUs, FP32 otherwise
            if self.is_pre_ampere_arch(self.run_info["gpu"]):
                return "FP32"
            else:
                return "TF32"

    def format_command(self, cmd):
        """Format the command string to be more consistent by removing irrelevant options"""
        # Replace various forms of trtexec
        cmd = cmd.replace("trtexec_internal", "trtexec").replace("trtexec_safe", "trtexec")

        # Strip paths
        cmd = re.sub(
            r"=/.*?auto_sync\/data/",
            "=",
            re.sub(r"=/.*?\/master/", "=data/", cmd.strip().replace("\\","/").strip('"')),
        )
        cmd = re.sub(r'=.*\/data/', "=data/", cmd.strip().replace("\\","/").strip('"'))
        
        #strip the path of .py command
        cmd = re.sub(r"/\S*?demo\/BERT\/","",cmd)

        #strip the path of .engine file
        cmd = re.sub(r"/\S*?\/workspace\/generated_engine_data\/","",cmd)

        #strip the path of modle data
        cmd = re.sub(r"/\S*?\/joc\/bert_tf\/","",cmd)

        #strip the path of cache file
        cmd = re.sub(r"/\S*?\/performance.cache","performance.cache",cmd)

        #strip the path of benchmark.py
        cmd = re.sub(r"/\S*?\/benchmark.py","benchmark.py",cmd)

        #strip the path of benchmark.py
        cmd = re.sub(r"/\S*?\/build.py","build.py",cmd)

        #strip the path of gptSessionBenchmark
        cmd = re.sub(r"/\S*?\/gptSessionBenchmark","gptSessionBenchmark",cmd)

        #strip the path of gptManagerBenchmark
        cmd = re.sub(r"/\S*?\/gptManagerBenchmark","gptManagerBenchmark",cmd)

        #strip the path of bertBenchmark
        cmd = re.sub(r"/\S*?\/bertBenchmark","bertBenchmark",cmd)

        #strip the path of test input file
        cmd = re.sub(r"/\S*?\/common\/", "", cmd)

        #strip the datetime path of the e2e command
        cmd = re.sub(r"\d{4}-\d{2}-\d{2}.*?/", "*/",cmd)

        #strip the tmp folder of the e2e command
        cmd = re.sub(r"\/tmp.*? ", "/tmp* ",cmd)

        cmd = cmd.replace(" --log_level=info","")

        #in e2e command there are result foldes in the engine and data file
        cmd=re.sub(r" \/[^ ]+profile.engine", " profile.engine", cmd)
        cmd=re.sub(r" \/[^ ]+\/onnx_data\/", "/onnx_data/", cmd)
        cmd=cmd.replace('"', ' ')

        if "proxy_engine" in cmd:
            cmd = re.sub(r"=/.*proxy_engine\/", "=", cmd)
        # Strip command options that doesn't impact performance data
        filter_options = [
            " --nvtxMode=verbose",
            " --dumpEngineInfo",
            " --separateProfileRun",
            " --dumpProfile",
            " --dataTransfers",
            " --noDataTransfers",
            " --noBuilderCache",
            " --safe",
            " --dumpLayerInfo",
            " --dump_layer_info",
            " --dump_profile",
            " --profilingVerbosity=detailed",
            " --explicitBatch",
            " --useCudaGraph",
            " --useSpinWait",
            " --refit",
            " --monitorMemory",
            " --monitor_memory",
        ]
        filter_pattern = [
            r" --avgTiming=\d+",
            r" --minTiming=\d+",
            r" --timingCacheFile=.*cache",
            r" --preview=.*",
            r" --profiling_verbosity=.*",
            r" --output_dir=.*workspace\S*",
            r" --output_dir=.*tmp\S*",
            r" --engine_dir=.*workspace\S*",
            r" --engine_dir=.*tmp\S*",
            r" --checkpoint_dir=.*tmp\S*",
            r" --encoder_engine_dir=.*workspace\S*",
            r" --decoder_engine_dir=.*workspace\S*",
            r" --dataset=.*workspace\S*",
            r" --dataset=.*tmp\S*",
            r" --workspace=\d+",
            r" --workspace=[^\s]+",
            r"/[^/]+/llm_models",
            r" --num_runs=\d+",
            r" --warm_up=\d+",
            r" --opt_num_tokens=\d+",
            r" --opt_batch_size=\d+",
            r" --duration=\d+",
            r" --input_timing_cache=[^ ]+",
            r" --output_timing_cache=[^ ]+",
        ]
        for option in filter_options:
            cmd = cmd.replace(option, "")
        for pattern in filter_pattern:
            cmd = re.sub(pattern, "", cmd)
        return cmd.strip()

    def process_perf_data(self):
        """Process performance data from the metric CSV"""
        if not self.args.source_metric_csv or not os.path.exists(self.args.source_metric_csv):
            print("Error: Source metric CSV file not found or not specified")
            return

        # Update run info from session properties first
        self.get_session_properties()
        # get gpu clocks
        self.get_gpu_clocks()
        # Read the metric CSV
        source_data = self.read_csv(self.args.source_metric_csv)

        # Define metric name mapping consistent with perf_data_parser.py
        metrics_map = {
            "PEAK_CPU_MEMORY": "trt_peak_cpu_mem__MB",
            "PEAK_GPU_MEMORY": "trt_peak_gpu_mem__GB",
            "INFERENCE_PEAK_GPU_MEMORY": "trt_peak_gpu_mem__GB",
            "BUILD_PEAK_CPU_MEMORY": "trt_build_peak_cpu_memory__MB",
            "BUILD_PEAK_GPU_MEMORY": "trt_build_peak_gpu_mem__MB",
            "BUILD_TIME": "engine_build_time__sec",
            "LATENCY": "run_time__msec",
            "SEQ_LATENCY": "seq_latency__msec",
            "INFERENCE_TIME": "run_time__msec",
            "FIRST_TOKEN_TIME": "first_token_time__msec",
            "SERVER_TTFT": "first_token_time__msec",
            "SERVER_MEDIAN_TTFT": "server_median_ttft",
            "SERVER_MEAN_TTFT": "mean_ttft__msec",
            "SERVER_P99_TTFT": "p99_ttft__msec",
            "OUTPUT_TOKEN_TIME": "output_token_time__msec",
            "SERVER_TPOT": "output_token_time__msec",
            "SERVER_MEDIAN_TPOT": "server_median_tpot",
            "SERVER_MEAN_TPOT": "mean_tpot__msec",
            "SERVER_P99_TPOT": "p99_tpot__msec",
            "SERVER_ITL": "itl__msec",
            "SERVER_MEDIAN_ITL": "server_median_itl",
            "SERVER_MEAN_ITL": "mean_itl__msec",
            "SERVER_P99_ITL": "p99_itl__msec",
            "SERVER_E2EL": "server_e2el__msec",
            "SERVER_MEDIAN_E2EL": "server_median_e2el",
            "SERVER_MEAN_E2EL": "server_mean_e2el",
            "SERVER_P99_E2EL": "server_p99_e2el",
            "TOKENS_PER_SEC": "tokens_per__sec",
            "TOKEN_THROUGHPUT": "tokens_per__sec",
            "SEQ_THROUGHPUT": "seq_per__sec",
            "ENGINE_SIZE": "engine_file_size__MB",
            "CONTEXT_GPU_MEMORY": "execution_context_allocated_gpu_mem__MB",
            "KV_CACHE_SIZE": "kv_cache_size__GB",
        }
        
        # Extract GPU clock information if available in results
        for result in source_data:
            # Get GPU clock info if available and not already set
            if not self.run_info["sm_clock"] and "sm_clk" in result:
                self.run_info["sm_clock"] = result["sm_clk"]
            if not self.run_info["mem_clock"] and "mem_clk" in result:
                self.run_info["mem_clock"] = result["mem_clk"]
            # Only need to check one result with valid clock info
            if self.run_info["sm_clock"] and self.run_info["mem_clock"]:
                break

        # Process each row in the source data
        for result in source_data:
            # Skip failed tests
            if result.get("state", "") == "failed":
                continue

            # Skip specific test types we don't want to process
            if "test_perf.py::test_perf_onnx_" in result.get("turtle_case_name", ""):
                continue
            if "test_builder_perf.py::" in result.get("turtle_case_name", "") and "allCache" not in result.get("turtle_case_name", ""):
                continue

            # Get network name
            network_name = result.get("network_name", "")
            if not network_name:
                continue
            
            # For test_perf_metric tests, extract the network name from the test name
            if "test_perf_metric" in result.get("test_name", ""):
                test_name = result.get("test_name", "")
                match = re.search(r'\[(.*?)\]', test_name)
                if match:
                    # If we're evaluating a specific input length for inference_time
                    # or other per-input metrics, use the test name's value which will
                    # include only the specific input length being tested
                    if "inference_time" in test_name.lower() or "context_gpu_memory" in test_name.lower() or "token_throughput" in test_name.lower() or "seq_throughput" in test_name.lower() or "seq_latency" in test_name.lower() or "kv_cache_size" in test_name.lower():
                        network_name = match.group(1)

            # Get metric type and value
            metric_type = result.get("metric_type", "")
            metric_value = result.get("perf_metric", "")
            if not metric_type or not metric_value:
                continue

            # Map the metric type to the consistent field name
            mapped_metric_type = metrics_map.get(metric_type, metric_type.lower())

            # Determine precision from command
            command = result.get("command", "")
            precision = self.get_precision_from_command(command)

            # Get framework from network name
            framework = self.get_framework_from_network(network_name)

            # Extract batch size from network name
            batch_size = self.extract_batch_from_network(network_name)

            # Format the command to be more consistent
            formatted_command = self.format_command(command)

            # Create case key: (framework, network, batch_size, precision, command)
            case = (
                framework.upper(),
                network_name.replace("-REFIT", "").lower(),
                batch_size,
                precision.upper(),
                formatted_command
            )

            # Initialize the result data if this is a new case
            log_val = result.get("raw_result", "")
            if not log_val and self.junit_log_map:
                test_name = result.get("test_name", "")
                log_val = ""
                # Extract the parameter part from test name if it exists
                test_param = ""
                bracket_match = re.search(r'\[(.*?)\]', test_name)
                if bracket_match:
                    test_param = bracket_match.group(1)
                # Try to find matching log in junit_log_map
                for k, v in self.junit_log_map.items():
                    if k and test_name:
                        # First try exact match with test parameter
                        if test_param and k == test_param:
                            log_val = v
                            if self.verbose:
                                print(f"Exact match found for {test_name}")
                            break
                        # Then try substring match
                        elif k in test_name:
                            log_val = v
                            if self.verbose:
                                print(f"Substring match found for {test_name}")
                            break
                        # Try relaxed matching: if junit key doesn't contain maxbs/maxnt, ignore these in test parameter
                        elif test_param and self._relaxed_match(test_param, k):
                            log_val = v
                            if self.verbose:
                                print(f"Relaxed match found for {test_name}")
                            break
            
            if case not in self.cases_results:
                self.cases_results[case] = {
                    "gpu_time": None,
                    "total_time": None,
                    "build_time": None,
                    "throughput": None,
                    "perf_data": {},
                    "log": log_val
                }

            # Update the appropriate metric based on metric_type
            # SERVER_E2EL and SERVER_MEDIAN_E2EL are mapped to gpu_time for disagg/server mode tests
            if metric_type in ["INFERENCE_TIME", "LATENCY", "SERVER_E2EL", "SERVER_MEDIAN_E2EL"]:
                self.cases_results[case]["gpu_time"] = float(metric_value)
            elif metric_type == "BUILD_TIME":
                self.cases_results[case]["build_time"] = float(metric_value)
            elif metric_type in ["TOKEN_THROUGHPUT", "TOKENS_PER_SEC"]:
                self.cases_results[case]["throughput"] = float(metric_value)

            # Add the metric to the perf_data dictionary with the mapped field name
            self.cases_results[case]["perf_data"][mapped_metric_type] = metric_value

            # Get total time if available
            if "total_time__sec" in result:
                self.cases_results[case]["total_time"] = float(result["total_time__sec"])

        if self.verbose:
            print(f"Processed {len(self.cases_results)} test cases")

    def format_results_for_db(self):
        """Format results data for database insertion"""
        formatted_results = []

        for case, metrics in self.cases_results.items():
            framework, network, batch_size, precision, command = case

            # Create the case tuple with all values needed for DB insertion
            formatted_case = [
                framework,           # Format
                network,             # Network
                batch_size,          # Batch Size
                precision,           # Precision
                command,             # Command
                0.0 if metrics["gpu_time"] is None else metrics["gpu_time"],  # GPU Time(ms) - default to 0.0 if None
                0.0 if metrics["total_time"] is None else metrics["total_time"],  # Total Runtime(s) - default to 0.0 if None
                0.0 if metrics["build_time"] is None else metrics["build_time"],  # Build Time(s) - default to 0.0 if None
                0.0 if metrics["throughput"] is None else metrics["throughput"],  # Throughput - default to 0.0 if None
                json.dumps(metrics["perf_data"]),  # PerfData as JSON
                None,                # INT8 vs FP32 (not needed)
                None,                # INT8 vs FP16 (not needed)
                None,                # FP16 vs FP32 (not needed)
                metrics["log"]       # Log
            ]

            formatted_results.append(formatted_case)

        return formatted_results

class TRTPerfDB:
    def __init__(self, host, port, user, password, database, verbose=False):
        self.host = host
        self.user = user
        self.password = password
        self.database = database
        self.verbose = verbose
        self.db = pymysql.connect(host=host, port=port, user=user, password=password, database=database)
        self.cursor = self.db.cursor()

    def close(self):
        self.cursor.close()
        self.db.close()

    def create_run_table(self, run_info):
        """Insert a new run into the runs table"""
        sql_run = """INSERT INTO runs (`driver`,`cpu`,`os`,`gpu`,`cuda`,`graphic_freq`,`memory_freq`,`tensorrt`,`notes`,`cl`,`trtllm`,`start_time`,`end_time`,`link`,`commit_time`) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)"""
        params = (
            run_info['driver'], run_info['cpu'], run_info['os'], run_info['gpu'], run_info['cuda'],
            run_info['sm_clock'], run_info['mem_clock'], run_info['tensorrt'],
            run_info['notes'], run_info['cl'], run_info['trtllm'], run_info['start_time'], run_info['end_time'], run_info['link'], run_info['commit_time']
        )
        run_id = -1
        if self.verbose:
            print(f"Inserting run with params: {params}")
        try:
            self.cursor.execute(sql_run, params)
            self.db.commit()
            run_id = self.cursor.lastrowid
            print("Inserted New Run ID: {}".format(run_id))
        except Exception as e:
            self.db.rollback()
            print(f"Failed to Insert New Run: {e}")
        return run_id

    def get_or_create_case_id(self, framework, network, batch_size, precision, command):
        """Get existing case ID or create a new one if it doesn't exist"""
        # Try to find existing case
        sql_query = """SELECT id from cases where `format`=%s AND `network`=%s AND `batchsize`=%s AND `precision`=%s AND `cmd`=%s;"""
        self.cursor.execute(sql_query, (framework, network, batch_size, precision, command))
        case_id = self.cursor.fetchall()

        if case_id:
            # Return the existing case ID
            return case_id[0][0]
        else:
            # Insert a new case
            insert_case_cmd = """INSERT INTO cases (`format`,`network`,`batchsize`,`precision`,`cmd`) VALUES (%s, %s, %s, %s, %s)"""
            self.cursor.execute(insert_case_cmd, (framework, network, batch_size, precision, command))
            self.db.commit()
            return self.cursor.lastrowid

    def insert_perf_results(self, run_id, results_data):
        """Insert performance results into perf_result table"""
        if run_id == -1:
            print("Run ID is invalid!")
            return

        sql_result_data = []

        for result in results_data:
            framework, network, batch_size, precision, command = result[:5]

            # Get or create case ID
            case_id = self.get_or_create_case_id(framework, network, batch_size, precision, command)

            # Format the data for insertion
            sql_result = [
                run_id,
                case_id,
                0.0 if result[5] is None else result[5],   # gpu_time (default to 0.0 if None)
                0.0 if result[6] is None else result[6],   # total_time (default to 0.0 if None)
                0.0 if result[7] is None else result[7],   # build_time (default to 0.0 if None)
                0.0 if result[8] is None else result[8],   # throughput (default to 0.0 if None)
                result[9],   # perf_data
                result[10],  # int8_vs_fp32 (None)
                result[11],  # int8_vs_fp16 (None)
                result[12],  # fp16_vs_fp32 (None)
                result[13]   # log
            ]

            sql_result_data.append(tuple(sql_result))

        # Execute the insert
        sql_result_command = "INSERT INTO perf_result (`run_id`,`case_id`,`gpu_time`,`total_time`,`build_time`,`throughput`,`perf_data`,`int8_vs_fp32`,`int8_vs_fp16`,`fp16_vs_fp32`,`log`) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)"

        if self.verbose:
            print(f"Inserting {len(sql_result_data)} performance results")

        try:
            self.cursor.executemany(sql_result_command, sql_result_data)
            self.db.commit()
            print(f"Inserted {len(sql_result_data)} performance results")
        except Exception as e:
            print(f"Failed to insert perf_results: {e}")
            self.db.rollback()

def parse_args():
    parser = argparse.ArgumentParser(
        description="Parse TensorRT-LLM performance data and insert into TRT_perf database"
    )
    parser.add_argument(
        "--source-metric-csv", required=False, help="CSV file with metric data (perf_script_test_results.csv)"
    )
    parser.add_argument(
        "--source-properties", required=False, default="", help="Session properties CSV file"
    )
    parser.add_argument(
        "--source-gpu-monitoring", required=False, default="", help="GPU monitoring CSV file"
    )
    parser.add_argument("--tensorrt", default="", help="TensorRT version")
    parser.add_argument("--trtllm", default="", help="TensorRT-LLM version")
    parser.add_argument("--driver", default="", help="Driver version")
    parser.add_argument(
        "--start-time", default="", help='Start time of the run in format: "YYYY-MM-DD HH:MM:SS"'
    )
    parser.add_argument(
        "--end-time", default="", help='End time of the run in format: "YYYY-MM-DD HH:MM:SS"'
    )
    parser.add_argument("--os", default="", help="OS name and version")
    parser.add_argument("--gpu", default="", help="GPU name")
    parser.add_argument("--cuda", default="", help="CUDA version")
    parser.add_argument("--sm-clock", default="", help="GPU SM clock frequency (MHz)")
    parser.add_argument("--mem-clock", default="", help="GPU memory clock frequency (MHz)")
    parser.add_argument("--cpu-name", default="", help="CPU name")
    parser.add_argument("--ip", default="", help="IP address")
    parser.add_argument("--hostname", default="", help="Hostname")
    parser.add_argument("--notes", default="", help="Notes for the run")
    parser.add_argument("--link", default="", help="Link to test results/job")
    parser.add_argument("--commit", default="", help="Commit ID or hash")
    parser.add_argument("--commit-time", default="", help="Commit time")
    parser.add_argument(
        "--write-db", default="yes", help="Whether to write to DB (yes/no)"
    )
    parser.add_argument("--DB-host", default=DEFAULT_DB_HOST, help="Database host")
    parser.add_argument("--DB-port", type=int, default=DEFAULT_DB_PORT, help="Database port")
    parser.add_argument("--DB-user", default=DEFAULT_DB_USER, help="Database username")
    parser.add_argument("--DB-password", default=DEFAULT_DB_PASSWORD, help="Database password")
    parser.add_argument("--DB-schema", default=DEFAULT_DB_SCHEMA, help="Database schema/name")
    parser.add_argument("--verbose", action="store_true", help="Enable verbose output")
    parser.add_argument('--junit-xml', type=str, default='', help='junit xml file for extracting log if csv has no log')

    return parser.parse_args()

def main():
    args = parse_args()

    # Create parser and process data
    parser = TRTPerfParser(args)
    parser.process_perf_data()

    # Format results for DB insertion
    results_data = parser.format_results_for_db()
    # Insert into database if requested
    if args.write_db.lower() == "yes" and results_data:
        db = TRTPerfDB(
            host=args.DB_host,
            port=args.DB_port,
            user=args.DB_user,
            password=args.DB_password,
            database=args.DB_schema,
            verbose=args.verbose
        )
        print(json.dumps(parser.run_info, indent=2))
        # Insert the run and performance results
        run_id = db.create_run_table(parser.run_info)
        if run_id != -1:
            db.insert_perf_results(run_id, results_data)
            print(
                f"TRTPerf: http://dlswqa.nvidia.com/trtperf?req=get_html&run_ids={run_id}&baseline=--&target=--&drop_limit=5&time_limit=0.0&gap_limit=-999.9&only_show_drop=true"
            )

        db.close()
    elif not results_data:
        print("No valid performance data found to insert into the database")

if __name__ == "__main__":
    main()
