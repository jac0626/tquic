#!/bin/bash

# ============================================================================
# TQUIC Performance Benchmark Runner
# ============================================================================
# Purpose: Execute multiple iterations of ACK frequency performance tests
#          to gather reliable benchmark data with different congestion
#          control algorithms.
#
# Usage: ./tquic_benchmark_runner.sh [log_file] [cc_algorithm]
#
# Parameters:
#   - log_file: Output file for test results (optional)
#   - cc_algorithm: Congestion control algorithm (optional, default: cubic)
#
# Example:
#   ./tquic_benchmark_runner.sh results.log bbr
#   ./tquic_benchmark_runner.sh  # Uses defaults
# ============================================================================

# ============================================================================
# Configuration
# ============================================================================

# Number of test iterations to run
TEST_ITERATIONS=10

# Path to TQUIC binaries
TQUIC_BIN_PATH="../../../target/release"

# Main test script
TEST_SCRIPT="../tquic_tools_test.sh"

# Test case to run
TEST_CASE="ack_frequency_performance"

# ============================================================================
# Parameter Processing
# ============================================================================

# Accept command line parameters with defaults
LOG_FILE=${1:-performance_runs_cubic_$(date +%Y%m%d_%H%M%S).txt}
CC_ALGO=${2:-cubic}

# ============================================================================
# Initialize
# ============================================================================

# Clear the log file if it exists (start fresh)
> "$LOG_FILE"

# ============================================================================
# Display Test Configuration
# ============================================================================

echo "=============================================="
echo "TQUIC ACK Frequency Performance Benchmark"
echo "=============================================="
echo "Configuration:"
echo "  - Iterations: $TEST_ITERATIONS"
echo "  - Congestion Control: $CC_ALGO"
echo "  - Log File: $LOG_FILE"
echo "  - Binary Path: $TQUIC_BIN_PATH"
echo "  - Test Case: $TEST_CASE"
echo "=============================================="
echo ""

echo "Starting $TEST_ITERATIONS iterations of ACK Frequency performance tests..."
echo "Algorithm: $CC_ALGO"
echo "All results will be saved to: $LOG_FILE"
echo ""

# ============================================================================
# Main Test Loop
# ============================================================================

# Run the test multiple times to get statistically meaningful results
for i in $(seq 1 $TEST_ITERATIONS)
do
    # Print iteration header
    echo "================================================" | tee -a "$LOG_FILE"
    echo "Test Iteration: $i of $TEST_ITERATIONS" | tee -a "$LOG_FILE"
    echo "Algorithm: $CC_ALGO" | tee -a "$LOG_FILE"
    echo "Start Time: $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
    echo "================================================" | tee -a "$LOG_FILE"
    
    # Execute the performance test
    # Redirect both stdout and stderr to the log file
    bash "$TEST_SCRIPT" \
        -b "$TQUIC_BIN_PATH" \
        -t "$TEST_CASE" \
        -a "$CC_ALGO" \
        >> "$LOG_FILE" 2>&1
    
    # Check test execution status
    TEST_EXIT_CODE=$?
    if [ $TEST_EXIT_CODE -ne 0 ]; then
        echo "WARNING: Test iteration $i failed with exit code $TEST_EXIT_CODE" | tee -a "$LOG_FILE"
    fi
    
    # Print iteration footer
    echo "------------------------------------------------" | tee -a "$LOG_FILE"
    echo "Iteration $i completed at $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$LOG_FILE"
    echo "------------------------------------------------" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    
    # Brief pause between iterations to avoid system overload
    # This helps ensure consistent test conditions
    if [ $i -lt $TEST_ITERATIONS ]; then
        echo "Pausing before next iteration..." | tee -a "$LOG_FILE"
        sleep 2
    fi
done

# ============================================================================
# Cleanup and Summary
# ============================================================================

echo "=============================================="
echo "Benchmark Complete!"
echo "=============================================="
echo "Summary:"
echo "  - Total iterations: $TEST_ITERATIONS"
echo "  - Results saved to: $LOG_FILE"
echo "  - End time: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================="

# Clean up temporary test directories created during testing
echo "Cleaning up temporary test directories..."
rm -rf test-*

# Optional: Generate a basic summary of results
echo ""
echo "Quick Statistics from Log File:"
echo "--------------------------------"
echo "Number of throughput measurements:"
grep -c "Throughput:" "$LOG_FILE" || echo "0"
echo ""
echo "Average throughput values (if available):"
grep "Throughput:" "$LOG_FILE" | awk '{print $2}' | grep -v "N/A" | \
    awk '{sum+=$1; count++} END {if(count>0) printf "Average: %.2f Mbps\n", sum/count; else print "No valid measurements"}'

echo ""
echo "All tests completed successfully!"