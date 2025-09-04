#!/bin/bash
set -x

# ============================================================================
# Network Environment Test Orchestrator
# ============================================================================
# Purpose: Orchestrate comprehensive network performance tests across 
#          different network environments and congestion control algorithms.
#
# Description:
#   This script automates the testing process by:
#   1. Setting up various network environments (5G, 4G, home, datacenter, satellite)
#   2. Running performance tests with different congestion control algorithms
#   3. Collecting and organizing results in timestamped log files
#
# Dependencies:
#   - set_network_env.sh: Script to configure network environment
#   - tquic_benchmark_runner.sh: Script to execute the actual performance tests
#
# Usage:
#   ./network_test_orchestrator.sh
#
# Output:
#   Results are saved to: after_optimize_bbr/result_<network>_<algorithm>_<timestamp>.log
# ============================================================================

# ============================================================================
# Prerequisites Check
# ============================================================================

# Verify that required scripts exist and are executable
if [ ! -x ./set_network_env.sh ] || [ ! -x ./tquic_benchmark_runner.sh ]; then
    echo "ERROR: Required scripts are missing or not executable."
    echo ""
    echo "Please ensure the following scripts exist and have execute permissions:"
    echo "  - set_network_env.sh (Network environment configuration)"
    echo "  - tquic_benchmark_runner.sh (Test execution script)"
    echo ""
    echo "To fix permissions, run:"
    echo "  chmod +x set_network_env.sh tquic_benchmark_runner.sh"
    exit 1
fi

# ============================================================================
# Configuration
# ============================================================================

# Define network environments to test
# Each represents a different network characteristic profile
NETWORK_TYPES="home mobile"

# Define congestion control algorithms to test
# Add more algorithms as needed (e.g., "Bbr Cubic Reno")
CC_ALGOS="Bbr3 Bbr Cubic Copa"

# Output directory for results
RESULT_DIR="result-no-jitter"

# Delay between different algorithm tests (in seconds)
INTER_TEST_DELAY=5

# ============================================================================
# Initialize
# ============================================================================

# Generate timestamp for unique file naming
TIMESTAMP=$(date +%Y%m%d%H%M%S)

# Create results directory if it doesn't exist
mkdir -p "$RESULT_DIR"

# ============================================================================
# Display Test Configuration
# ============================================================================

echo "============================================================"
echo "Network Environment Performance Test Suite"
echo "============================================================"
echo "Test Configuration:"
echo "  - Network Environments: $NETWORK_TYPES"
echo "  - Congestion Control Algorithms: $CC_ALGOS"
echo "  - Results Directory: $RESULT_DIR"
echo "  - Test Session ID: $TIMESTAMP"
echo "============================================================"
echo ""

# ============================================================================
# Main Test Execution Loop
# ============================================================================

# Track total number of tests for summary
TOTAL_TESTS=0
SUCCESSFUL_TESTS=0

# Iterate through each network environment
for network in $NETWORK_TYPES; do
    echo "============================================================"
    echo "NETWORK ENVIRONMENT: $network"
    echo "============================================================"
    echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    
    # Configure the network environment
    echo "Setting up $network network environment..."
    bash ./set_network_env.sh "$network"
    
    # Check if network setup was successful
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to set up $network environment. Skipping..."
        continue
    fi
    
    echo ""
    echo "Network environment '$network' successfully configured."
    echo "Starting performance tests..."
    echo ""
    
    # Iterate through each congestion control algorithm
    for cc_algo in $CC_ALGOS; do
        # Increment test counter
        ((TOTAL_TESTS++))
        
        # Define the output file path for this test
        RESULT_FILE="${RESULT_DIR}/result_${network}_${cc_algo}_${TIMESTAMP}.txt"
        
        echo "------------------------------------------------------------"
        echo "Test #$TOTAL_TESTS"
        echo "  Network Environment: $network"
        echo "  Congestion Control: $cc_algo"
        echo "  Output File: $RESULT_FILE"
        echo "  Start Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "------------------------------------------------------------"
        
        # Execute the performance test
        bash ./tquic_benchmark_runner.sh "$RESULT_FILE" "$cc_algo"
        
        # Check test execution status
        if [ $? -eq 0 ]; then
            ((SUCCESSFUL_TESTS++))
            echo ""
            echo "✓ Test completed successfully"
        else
            echo ""
            echo "✗ Test failed or completed with errors"
        fi
        
        echo "  End Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        
        # Brief pause between algorithm tests to stabilize system
        if [ "$cc_algo" != "${CC_ALGOS##* }" ]; then
            echo "Pausing for $INTER_TEST_DELAY seconds before next test..."
            sleep $INTER_TEST_DELAY
        fi
    done
    
    echo ""
    echo "All tests for network environment '$network' completed."
    echo "============================================================"
    echo ""
done

# ============================================================================
# Test Summary
# ============================================================================

echo ""
echo "============================================================"
echo "TEST SUITE COMPLETED"
echo "============================================================"
echo "Summary:"
echo "  - Total Tests Executed: $TOTAL_TESTS"
echo "  - Successful Tests: $SUCCESSFUL_TESTS"
echo "  - Failed Tests: $((TOTAL_TESTS - SUCCESSFUL_TESTS))"
echo "  - Results Location: $RESULT_DIR"
echo "  - Session Timestamp: $TIMESTAMP"
echo ""
echo "To view results, check the files in:"
echo "  $RESULT_DIR/result_*_${TIMESTAMP}.log"
echo "============================================================"
echo ""

# Optional: Generate a summary file
SUMMARY_FILE="${RESULT_DIR}/summary_${TIMESTAMP}.txt"
{
    echo "Test Session Summary"
    echo "===================="
    echo "Date: $(date)"
    echo "Session ID: $TIMESTAMP"
    echo ""
    echo "Configuration:"
    echo "  Networks Tested: $NETWORK_TYPES"
    echo "  Algorithms Tested: $CC_ALGOS"
    echo ""
    echo "Results:"
    echo "  Total Tests: $TOTAL_TESTS"
    echo "  Successful: $SUCCESSFUL_TESTS"
    echo "  Failed: $((TOTAL_TESTS - SUCCESSFUL_TESTS))"
    echo ""
    echo "Individual Test Results:"
    echo "------------------------"
    ls -la "${RESULT_DIR}"/result_*_${TIMESTAMP}.log 2>/dev/null || echo "No result files found"
} > "$SUMMARY_FILE"

echo "Summary saved to: $SUMMARY_FILE"
echo ""
echo "All test cycles finished successfully!"