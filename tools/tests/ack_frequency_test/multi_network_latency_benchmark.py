#!/usr/bin/env python3

# ============================================================================
# Network Latency Test Orchestrator (Python)
# ============================================================================
# Purpose: Orchestrate comprehensive network latency tests across
#          different network environments and congestion control algorithms.
#
# Description:
#   This script automates the latency testing process by:
#   1. Setting up various network environments (e.g., 5G, 4G, home)
#   2. Running latency tests with different congestion control algorithms
#   3. Collecting and organizing results in timestamped log files
# ============================================================================

import os
import subprocess
import time
from datetime import datetime

# ============================================================================
# Configuration
# ============================================================================

# Define network environments to test
NETWORK_TYPES = ["home", "mobile"]

# Define congestion control algorithms to test
CC_ALGOS = ["Bbr", "Bbr3", "Cubic", "Copa"]

# Output directory for results
RESULT_DIR = "result-latency"

# Delay between different algorithm tests (in seconds)
INTER_TEST_DELAY = 5

# Paths to required scripts
SET_ENV_SCRIPT = "./set_network_env.sh"
BENCHMARK_RUNNER_SCRIPT = "./latency_benchmark.py"


def check_prerequisites():
    """Verify that required scripts exist and are executable."""
    scripts = [SET_ENV_SCRIPT, BENCHMARK_RUNNER_SCRIPT]
    for script in scripts:
        if not os.path.exists(script):
            print(f"ERROR: Required script '{script}' is missing.")
            return False
        if not os.access(script, os.X_OK):
            print(f"WARNING: Script '{script}' is not executable.")
            print(f"  Consider running: chmod +x {script}")
    return True

def main():
    """Main function to orchestrate the test execution."""
    if not check_prerequisites():
        exit(1)

    timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
    os.makedirs(RESULT_DIR, exist_ok=True)

    print("=" * 60)
    print("Network Latency Performance Test Suite")
    print("=" * 60)
    print("Test Configuration:")
    print(f"  - Network Environments: {', '.join(NETWORK_TYPES)}")
    print(f"  - Congestion Control Algorithms: {', '.join(CC_ALGOS)}")
    print(f"  - Results Directory: {RESULT_DIR}")
    print(f"  - Test Session ID: {timestamp}")
    print("=" * 60)
    print()

    total_tests = 0
    successful_tests = 0

    for network in NETWORK_TYPES:
        print("=" * 60)
        print(f"NETWORK ENVIRONMENT: {network}")
        print("=" * 60)
        
        try:
            subprocess.run(["bash", SET_ENV_SCRIPT, network], check=True)
        except subprocess.CalledProcessError:
            print(f"ERROR: Failed to set up {network} environment. Skipping...")
            continue

        print(f"Network environment '{network}' successfully configured.")
        print("Starting latency tests...")
        print()

        for i, cc_algo in enumerate(CC_ALGOS):
            total_tests += 1
            result_file = os.path.join(RESULT_DIR, f"result_{network}_{cc_algo}_{timestamp}.txt")

            print("-" * 60)
            print(f"Test #{total_tests}")
            print(f"  Network Environment: {network}")
            print(f"  Congestion Control: {cc_algo}")
            print(f"  Output File: {result_file}")
            print("-" * 60)

            try:
                subprocess.run(["python3", BENCHMARK_RUNNER_SCRIPT, result_file, cc_algo], check=True)
                successful_tests += 1
                print("\n✓ Test completed successfully")
            except subprocess.CalledProcessError:
                print("\n✗ Test failed or completed with errors")

            if i < len(CC_ALGOS) - 1:
                print(f"Pausing for {INTER_TEST_DELAY} seconds before next test...")
                time.sleep(INTER_TEST_DELAY)

        print(f"All tests for network environment '{network}' completed.")
        print("=" * 60)
        print()

    failed_tests = total_tests - successful_tests
    summary = f"""
============================================================
LATENCY TEST SUITE COMPLETED
============================================================
Summary:
  - Total Tests Executed: {total_tests}
  - Successful Tests: {successful_tests}
  - Failed Tests: {failed_tests}
  - Results Location: {RESULT_DIR}
============================================================
"""
    print(summary)

if __name__ == "__main__":
    main()
