#!/usr/bin/env python3

# ============================================================================
# TQUIC Performance Benchmark Runner (Python)
# ============================================================================
# This script replaces tquic_benchmark_runner.sh and the 
# ack_frequency_performance test case from tquic_tools_test.sh.
#
# It performs these main functions:
#   1. Runs a single performance test iteration, capturing detailed metrics.
#   2. Executes the test iteration 10 times.
#   3. Calculates the average of all metrics across the 10 runs.
#   4. Outputs the averaged results to a specified log file.
# ============================================================================

import os
import subprocess
import time
import sys
import json
from collections import defaultdict
from datetime import datetime

# ============================================================================
# Configuration
# ============================================================================

# Number of test iterations to run for averaging
TEST_ITERATIONS = 10

# Path to TQUIC binaries (assuming they are in ../../../target/release)
TQUIC_BIN_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../target/release"))

# Test file sizes
TEST_FILES = ["1M", "10M", "100M","1000M"] 

# Min ACK delay values to test
MIN_ACK_DELAYS = [0, 2000]

# Default log level
LOG_LEVEL = "debug"

# ============================================================================
# Helper Functions
# ============================================================================

def parse_size(size_str):
    """Converts size string like '10M' to bytes."""
    size_str = size_str.upper()
    if size_str.endswith('K'):
        return int(size_str[:-1]) * 1024
    elif size_str.endswith('M'):
        return int(size_str[:-1]) * 1024 * 1024
    elif size_str.endswith('G'):
        return int(size_str[:-1]) * 1024 * 1024 * 1024
    return int(size_str)

def generate_cert(cert_dir):
    """Generates self-signed certificate for testing."""
    os.makedirs(cert_dir, exist_ok=True)
    key_path = os.path.join(cert_dir, "cert.key")
    csr_path = os.path.join(cert_dir, "cert.csr")
    crt_path = os.path.join(cert_dir, "cert.crt")

    print("  Generating test certificate...")
    # Generate private key
    subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-out", key_path, 
                    "-pkeyopt", "rsa_keygen_bits:2048"], capture_output=True)
    # Generate CSR
    subprocess.run(["openssl", "req", "-new", "-key", key_path, "-out", csr_path,
                    "-subj", "/C=CN/ST=beijing/O=tquic/CN=example.org"], capture_output=True)
    # Generate self-signed certificate
    subprocess.run(["openssl", "x509", "-req", "-in", csr_path, "-signkey", key_path, 
                    "-out", crt_path], capture_output=True)

def generate_file(data_dir, size_str):
    """Generates a test file of a given size with random data."""
    os.makedirs(data_dir, exist_ok=True)
    file_path = os.path.join(data_dir, size_str)
    byte_size = parse_size(size_str)
    print(f"  Generating {size_str} test file...")
    with open(file_path, 'wb') as f:
        f.write(os.urandom(byte_size))
    return byte_size

def run_command(command, allowed_exit_codes=None, **kwargs):
    """Helper to run a command and handle errors, allowing specific non-zero exit codes."""
    if allowed_exit_codes is None:
        allowed_exit_codes = {0}
    else:
        allowed_exit_codes = set(allowed_exit_codes)

    # Cannot use check=True if we want to allow non-zero exit codes
    kwargs.pop('check', None)

    try:
        result = subprocess.run(command, **kwargs)
        if result.returncode not in allowed_exit_codes:
            # Decode stdout/stderr if they are bytes
            stdout = result.stdout.decode(errors='ignore') if isinstance(result.stdout, bytes) else result.stdout
            stderr = result.stderr.decode(errors='ignore') if isinstance(result.stderr, bytes) else result.stderr

            print(f"  ERROR: Command '{' '.join(command)}' failed with exit code {result.returncode}")
            if stdout:
                print(f"    STDOUT: {stdout}")
            if stderr:
                print(f"    STDERR: {stderr}")
            return None
        return result
    except FileNotFoundError:
        print(f"  ERROR: Command not found: {command[0]}")
        return None

# ============================================================================
# Core Test Logic
# ============================================================================

def run_single_test_iteration(cc_algo):
    """ 
    Runs a single full iteration of the ack_frequency_performance test case.
    This corresponds to the logic within `test_ack_frequency_performance`.
    """
    iteration_results = []
    test_dir = f"./test-{datetime.now().strftime('%Y%m%d%H%M%S')}-{os.getpid()}"
    os.makedirs(test_dir, exist_ok=True)

    cert_dir = os.path.join(test_dir, "cert")
    data_dir = os.path.join(test_dir, "data")
    dump_dir = os.path.join(test_dir, "dump")
    os.makedirs(dump_dir, exist_ok=True)

    generate_cert(cert_dir)
    for file_size_str in TEST_FILES:
        generate_file(data_dir, file_size_str)

    for file_size_str in TEST_FILES:
        for min_ack_delay in MIN_ACK_DELAYS:
            test_label = f"min_ack_delay={min_ack_delay}us" if min_ack_delay > 0 else "Baseline"
            print(f"\n  Running test: {file_size_str}, {cc_algo}, {test_label}")

            # Start server
            server_log = os.path.join(test_dir, f"server_{file_size_str}_{min_ack_delay}.log")
            server_cmd = [
                "ip", "netns", "exec", "server_ns", 
                os.path.join(TQUIC_BIN_PATH, "tquic_server"),
                "-l", "10.0.0.2:8443",
                "--cert", os.path.join(cert_dir, "cert.crt"),
                "--key", os.path.join(cert_dir, "cert.key"),
                "--root", data_dir,
                "--log-file", server_log,
                "--log-level", LOG_LEVEL,
                "--congestion-control-algor", cc_algo
            ]
            server_proc = subprocess.Popen(server_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            time.sleep(2) # Allow server to start

            # Prepare client command
            client_log = os.path.join(test_dir, f"client_{file_size_str}_{min_ack_delay}.log")
            cpu_log = os.path.join(test_dir, f"cpu_{file_size_str}_{min_ack_delay}.txt")
            
            client_cmd_base = [
                "ip", "netns", "exec", "client_ns",
                os.path.join(TQUIC_BIN_PATH, "tquic_client"),
                "-c", "10.0.0.2:8443",
                "--log-file", client_log,
                "--log-level", LOG_LEVEL,
                "--dump-dir", dump_dir,
                f"https://example.org/{file_size_str}"
            ]
            if min_ack_delay > 0:
                client_cmd_base.extend(["--min-ack-delay", str(min_ack_delay)])

            time_cmd = ["/usr/bin/time", "-f", '{"user": "%U", "sys": "%S", "cpu_percent": "%P"}', "-o", cpu_log]
            client_cmd = time_cmd + client_cmd_base

            # Run client and measure time
            start_time = time.monotonic()
            run_command(client_cmd)
            elapsed = time.monotonic() - start_time

            # Kill server
            server_proc.kill()
            server_proc.wait()

            # --- Result Parsing ---
            metrics = {"file_size": file_size_str, "min_ack_delay": min_ack_delay, "cc_algo": cc_algo}
            metrics["transfer_time"] = elapsed

            try:
                with open(cpu_log, 'r') as f:
                    cpu_stats = json.loads(f.read())
                    metrics["user_cpu"] = float(cpu_stats.get("user", 0))
                    metrics["sys_cpu"] = float(cpu_stats.get("sys", 0))
                    metrics["total_cpu"] = metrics["user_cpu"] + metrics["sys_cpu"]
                    metrics["cpu_percent"] = float(cpu_stats.get("cpu_percent", "0%").replace('%', ''))
            except (IOError, json.JSONDecodeError):
                metrics["user_cpu"] = metrics["sys_cpu"] = metrics["total_cpu"] = metrics["cpu_percent"] = 0

            file_size_bytes = parse_size(file_size_str)
            if elapsed > 0:
                metrics["throughput"] = (file_size_bytes * 8) / (elapsed * 1000 * 1000) # Mbps
            else:
                metrics["throughput"] = 0

            try:
                # Allow exit code 1 for grep (no matches found)
                ack_count_proc = run_command(["grep", "-c", "sent packet.*ACK", client_log], 
                                             allowed_exit_codes=[0, 1], 
                                             capture_output=True, text=True)
                metrics["ack_packets"] = int(ack_count_proc.stdout.strip()) if ack_count_proc and ack_count_proc.stdout else 0
            except (ValueError, AttributeError):
               print("  WARNING: Could not parse ACK packet count.")
               metrics["ack_packets"] = 0

            iteration_results.append(metrics)
            print(f"  Finished test. Throughput: {metrics['throughput']:.2f} Mbps")

    # Cleanup
    subprocess.run(["rm", "-rf", test_dir])
    return iteration_results

# ============================================================================
# Main Runner Logic
# ============================================================================

def main():
    """
    Main runner. This replaces tquic_benchmark_runner.sh.
    It calls the test function multiple times and averages the results.
    """
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} [log_file] [cc_algorithm]")
        sys.exit(1)

    log_file = sys.argv[1]
    cc_algo = sys.argv[2]

    print("=" * 50)
    print("TQUIC ACK Frequency Performance Benchmark (Python)")
    print("=" * 50)
    print(f"Configuration:")
    print(f"  - Iterations: {TEST_ITERATIONS}")
    print(f"  - Congestion Control: {cc_algo}")
    print(f"  - Log File: {log_file}")
    print("=" * 50)

    # Data structure to hold the sum of metrics for averaging
    # e.g., totals[(file_size, delay)]['throughput'] = total_throughput
    totals = defaultdict(lambda: defaultdict(float))
    counts = defaultdict(int)

    for i in range(TEST_ITERATIONS):
        print(f"\n--- Starting Test Iteration: {i + 1} of {TEST_ITERATIONS} ---")
        results = run_single_test_iteration(cc_algo)
        for r in results:
            key = (r['file_size'], r['min_ack_delay'])
            counts[key] += 1
            totals[key]['transfer_time'] += r['transfer_time']
            totals[key]['throughput'] += r['throughput']
            totals[key]['total_cpu'] += r['total_cpu']
            totals[key]['user_cpu'] += r['user_cpu']
            totals[key]['sys_cpu'] += r['sys_cpu']
            totals[key]['cpu_percent'] += r['cpu_percent']
            totals[key]['ack_packets'] += r['ack_packets']
        print(f"--- Finished Test Iteration: {i + 1} ---")

    # --- Averaging and Output ---
    print("\nCalculating averages and writing results...")
    
    header_format = "%-12s | %-27s | %-15s | %-15s | %-15s | %-15s | %-15s | %-12s | %-12s"
    header = header_format % ("File Size", "Test Case", "Avg Time (s)", "Avg Tput (Mbps)", "Avg CPU (s)",
                              "Avg User (s)", "Avg Sys (s)", "Avg CPU (%)", "Avg ACKs")
    separator = "-" * len(header)

    with open(log_file, 'w') as f:
        f.write(f"ACK Frequency Performance Test Results\n")
        f.write("="*40 + "\n")
        f.write(f"Congestion Control: {cc_algo}\n")
        f.write(f"Test Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        f.write(header + "\n")
        f.write(separator + "\n")

        sorted_keys = sorted(totals.keys(), key=lambda k: (parse_size(k[0]), k[1]))

        for key in sorted_keys:
            file_size, min_ack_delay = key
            count = counts[key]
            avg = {metric: total / count for metric, total in totals[key].items()}

            delay_label = "Baseline (no ACK frequency)" if min_ack_delay == 0 else f"min_ack_delay={min_ack_delay}us"

            row_data = (
                file_size,
                delay_label,
                avg['transfer_time'],
                avg['throughput'],
                avg['total_cpu'],
                avg['user_cpu'],
                avg['sys_cpu'],
                avg['cpu_percent'],
                avg['ack_packets']
            )
            row_format = "%-12s | %-27s | %15.3f | %15.2f | %15.3f | %15.3f | %15.3f | %12.2f | %12.0f"
            f.write(row_format % row_data + "\n")

    print(f"\nBenchmark Complete! Results saved to: {log_file}")

if __name__ == "__main__":
    main()
