#!/usr/bin/env python3

# ============================================================================
# TQUIC Latency Benchmark Runner (Python) - v3
# ============================================================================
# This script is designed to measure and compare request/response latency
# with ACK Frequency enabled vs. disabled.
#
# It performs these main functions:
#   1. Runs latency tests for baseline (ACK Freq off) and with min_ack_delay.
#   2. Executes the test iteration 10 times.
#   3. Calculates the average of all metrics across the 10 runs for both cases.
#   4. Outputs the averaged results to a specified log file for comparison.
# ============================================================================

import os
import subprocess
import time
import sys
import json
import re
from collections import defaultdict
from datetime import datetime

# ============================================================================
# Configuration
# ============================================================================

TEST_ITERATIONS = 10
TQUIC_BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../target/release"))
TEST_FILE_SIZE = "1K"
REQUEST_COUNT = 1000
LOG_LEVEL = "off"

# Min ACK delay values to test: 0 is baseline, 2000 enables ACK Frequency
MIN_ACK_DELAYS = [0, 2000]

# ============================================================================
# Helper Functions (No changes from previous version)
# ============================================================================

def parse_size(size_str):
    size_str = size_str.upper()
    if size_str.endswith('K'): return int(size_str[:-1]) * 1024
    elif size_str.endswith('M'): return int(size_str[:-1]) * 1024 * 1024
    return int(size_str)

def generate_cert(cert_dir):
    os.makedirs(cert_dir, exist_ok=True)
    key_path = os.path.join(cert_dir, "cert.key")
    crt_path = os.path.join(cert_dir, "cert.crt")
    if os.path.exists(crt_path):
        return
    print("  Generating test certificate...")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", 
                    "-keyout", key_path, "-out", crt_path, 
                    "-days", "365", "-nodes", 
                    "-subj", "/C=CN/ST=beijing/O=tquic/CN=example.org"], capture_output=True)

def generate_file(data_dir, size_str):
    os.makedirs(data_dir, exist_ok=True)
    file_path = os.path.join(data_dir, size_str)
    if os.path.exists(file_path):
        return
    byte_size = parse_size(size_str)
    print(f"  Generating {size_str} test file...")
    with open(file_path, 'wb') as f:
        f.write(os.urandom(byte_size))

def parse_latency_from_stdout(stdout_str):
    metrics = {}
    try:
        mean_match = re.search(r"mean: (\d+\.\d+)", stdout_str)
        median_match = re.search(r"median: (\d+\.\d+)", stdout_str)
        p90_match = re.search(r"p90: (\d+\.\d+)", stdout_str)
        p99_match = re.search(r"p99: (\d+\.\d+)", stdout_str)

        if mean_match: metrics["avg_us"] = float(mean_match.group(1))
        if median_match: metrics["p50_us"] = float(median_match.group(1))
        if p90_match: metrics["p90_us"] = float(p90_match.group(1))
        if p99_match: metrics["p99_us"] = float(p99_match.group(1))
        
        if len(metrics) == 4:
            return metrics
        else:
            print("  WARNING: Could not parse all latency metrics from stdout.")
            return None
    except Exception as e:
        print(f"  ERROR: Failed to parse latency from stdout: {e}")
        return None

def run_command(command, **kwargs):
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True, **kwargs)
    except subprocess.CalledProcessError as e:
        print(f"  ERROR: Command '{' '.join(command)}' failed with exit code {e.returncode}")
        print(f"    STDOUT: {e.stdout}")
        print(f"    STDERR: {e.stderr}")
        return None
    except FileNotFoundError:
        print(f"  ERROR: Command not found: {command[0]}")
        return None

# ============================================================================
# Core Test Logic
# ============================================================================

def run_single_test_iteration(cc_algo):
    iteration_results = []
    test_dir = f"./test-latency-{datetime.now().strftime('%Y%m%d%H%M%S')}-{os.getpid()}"
    os.makedirs(test_dir, exist_ok=True)

    cert_dir = os.path.join(test_dir, "cert")
    data_dir = os.path.join(test_dir, "data")
    generate_cert(cert_dir)
    generate_file(data_dir, TEST_FILE_SIZE)

    server_log = os.path.join(test_dir, "server.log")
    server_cmd = [
        "ip", "netns", "exec", "server_ns", 
        os.path.join(TQUIC_BIN_PATH, "tquic_server"),
        "-l", "10.0.0.2:8443",
        "--cert", os.path.join(cert_dir, "cert.crt"),
        "--key", os.path.join(cert_dir, "cert.key"),
        "--root", data_dir,
        "--log-level", LOG_LEVEL,
        "--congestion-control-algor", cc_algo
    ]
    server_proc = subprocess.Popen(server_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(2)

    for min_ack_delay in MIN_ACK_DELAYS:
        test_label = f"min_ack_delay={min_ack_delay}us" if min_ack_delay > 0 else "Baseline"
        print(f"\n  Running test: {REQUEST_COUNT} requests for {TEST_FILE_SIZE}, {cc_algo}, {test_label}")

        client_cmd_base = [
            "ip", "netns", "exec", "client_ns",
            os.path.join(TQUIC_BIN_PATH, "tquic_client"),
            "-c", "10.0.0.2:8443",
            "--log-level", LOG_LEVEL,
            "--total-requests-per-thread", str(REQUEST_COUNT),
            "--max-requests-per-conn", "0",
            "--max-concurrent-requests", "1",
            f"https://example.org/{TEST_FILE_SIZE}"
        ]
        if min_ack_delay > 0:
            client_cmd_base.extend(["--min-ack-delay", str(min_ack_delay)])
        
        client_result = run_command(client_cmd_base)

        if client_result and client_result.stdout:
            metrics = parse_latency_from_stdout(client_result.stdout)
            if metrics:
                metrics['min_ack_delay'] = min_ack_delay
                print(f"  Finished test. Avg Latency: {metrics['avg_us']:.2f} us")
                iteration_results.append(metrics)
            else:
                print("  Finished test but could not retrieve latency metrics.")
        else:
            print("  Finished test but client command failed or produced no output.")

    server_proc.kill()
    server_proc.wait()
    subprocess.run(["rm", "-rf", test_dir])
    return iteration_results

# ============================================================================
# Main Runner Logic
# ============================================================================

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} [log_file] [cc_algorithm]")
        sys.exit(1)

    log_file = sys.argv[1]
    cc_algo = sys.argv[2]

    print("=" * 60)
    print("TQUIC Latency Performance Benchmark (with ACK Freq comparison)")
    print(f"  - Iterations: {TEST_ITERATIONS}")
    print(f"  - Congestion Control: {cc_algo}")
    print("=" * 60)

    totals = defaultdict(lambda: defaultdict(float))
    counts = defaultdict(int)

    for i in range(TEST_ITERATIONS):
        print(f"\n--- Starting Latency Test Iteration: {i + 1} of {TEST_ITERATIONS} ---")
        results = run_single_test_iteration(cc_algo)
        for r in results:
            key = r['min_ack_delay']
            counts[key] += 1
            totals[key]['avg_us'] += r['avg_us']
            totals[key]['p50_us'] += r['p50_us']
            totals[key]['p90_us'] += r['p90_us']
            totals[key]['p99_us'] += r['p99_us']
        print(f"--- Finished Latency Test Iteration: {i + 1} ---")

    print("\nCalculating averages and writing results...")
    
    header_format = "%-30s | %-18s | %-15s | %-15s | %-15s"
    header = header_format % ("Test Case", "Avg Latency (us)", "p50 (us)", "p90 (us)", "p99 (us)")
    separator = "-" * len(header)

    with open(log_file, 'w') as f:
        f.write(f"Latency Test Results for {cc_algo} ({datetime.now().strftime('%Y-%m-%d %H:%M:%S')})\n")
        f.write(separator + "\n")
        f.write(header + "\n")
        f.write(separator + "\n")

        for key in sorted(totals.keys()):
            count = counts[key]
            if count == 0: continue
            avg = {metric: total / count for metric, total in totals[key].items()}
            
            label = f"Baseline (ACK Freq Off)" if key == 0 else f"min_ack_delay={key}us"
            
            row_data = (
                label,
                avg['avg_us'],
                avg['p50_us'],
                avg['p90_us'],
                avg['p99_us']
            )
            row_format = "%-30s | %18.2f | %15.2f | %15.2f | %15.2f"
            f.write(row_format % row_data + "\n")
        f.write(separator + "\n")

    print(f"\nBenchmark Complete! Results written to: {log_file}")

if __name__ == "__main__":
    main()