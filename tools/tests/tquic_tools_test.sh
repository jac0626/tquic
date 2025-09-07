#!/bin/bash

# Copyright (c) 2024 The TQUIC Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# ============================================================================
# TQUIC Comprehensive Test Suite
# ============================================================================
# This script provides automated testing for various TQUIC features including:
# - Multipath with different algorithms (minrtt, roundrobin, redundant)
# - HTTP range requests
# - ACK frequency optimization
# - Performance benchmarking
# ============================================================================

set -e  # Exit on error

# ============================================================================
# Configuration Variables
# ============================================================================

# Directory containing tquic_client and tquic_server binaries
BIN_DIR="./target/debug"

# Test working directory with timestamp
TEST_DIR="./test-$(date +%Y%m%d%H%M%S)"

# Comma-separated list of test cases to run
TEST_CASES="multipath_minrtt,multipath_roundrobin,multipath_redundant,range_request,ack_frequency,ack_frequency_performance"

# Process ID for cleanup handling
TEST_PID="$$"

# Default test file size
TEST_FILE="10M"

# Number of paths for multipath testing
PATH_NUM=4

# Logging level
LOG_LEVEL="debug"

# Additional client/server options
CLI_OPTIONS=""
SRV_OPTIONS=""

# Congestion control algorithm
CC_ALGO="Bbr"

# Exit code tracking
EXIT_CODE=0

# Server process ID for cleanup
server_pid=""

# ============================================================================
# Cleanup Function
# ============================================================================
# Ensures all processes are terminated on script exit
cleanup() {
    set +e  # Don't exit on error during cleanup
    
    # Kill server process if it exists
    if [ -n "$server_pid" ]; then
        kill $server_pid 2>/dev/null
    fi
    
    # Kill any child processes
    pkill -P $TEST_PID
    
    echo "Exit with code: $EXIT_CODE"
    exit $EXIT_CODE
}

# ============================================================================
# Help Function
# ============================================================================
show_help() {
    echo "TQUIC Test Suite"
    echo ""
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -b <dir>    Set the directory containing tquic_client/tquic_server binaries"
    echo "  -w <dir>    Set the working directory for testing"
    echo "  -l          List all supported test cases"
    echo "  -t <cases>  Run specific test cases (comma-separated)"
    echo "  -f <size>   File size for test cases (e.g., 10M, 100M)"
    echo "  -p <num>    Number of paths for multipath testing (default: 4)"
    echo "  -g <level>  Log level (debug, info, warn, error)"
    echo "  -c <opts>   Extra tquic_client options (use ~~ for --)"
    echo "  -s <opts>   Extra tquic_server options (use ~~ for --)"
    echo "  -a <algo>   Congestion control algorithm (Cubic, Bbr, etc.)"
    echo "  -h          Display this help message and exit"
    echo ""
    echo "Examples:"
    echo "  $0 -t multipath_minrtt -f 100M"
    echo "  $0 -t range_request -g info"
    echo "  $0 -c \"~~cid-len 10\" -s \"~~initial-rtt 100\""
}

# ============================================================================
# Command Line Argument Parsing
# ============================================================================
while getopts ":b:w:t:f:p:g:c:s:a:lh" opt; do
    case $opt in
        b)
            BIN_DIR="$OPTARG"
            ;;
        w)
            TEST_DIR="$OPTARG"
            ;;
        t)
            TEST_CASES="$OPTARG"
            ;;
        f)
            TEST_FILE="$OPTARG"
            ;;
        p)
            PATH_NUM="$OPTARG"
            ;;
        g)
            LOG_LEVEL="$OPTARG"
            ;;
        c)
            # Replace ~~ with -- for actual command line options
            CLI_OPTIONS="${OPTARG//\~/-}"
            ;;
        s)
            # Replace ~~ with -- for actual command line options
            SRV_OPTIONS="${OPTARG//\~/-}"
            ;;
        a)
            CC_ALGO="$OPTARG"
            ;;
        l)
            echo "Available test cases:"
            echo "$TEST_CASES" | tr ',' '\n' | sed 's/^/  - /'
            exit 0
            ;;
        h)
            show_help
            exit 0
            ;;
        \?)
            echo "Error: Invalid option -$OPTARG" >&2
            show_help
            exit 1
            ;;
        :)
            echo "Error: Option -$OPTARG requires an argument" >&2
            show_help
            exit 1
            ;;
    esac
done

# ============================================================================
# Setup and Validation
# ============================================================================

# Register cleanup handler
trap 'cleanup' EXIT

# Verify binaries exist
if [[ ! -f "$BIN_DIR/tquic_client" || ! -f "$BIN_DIR/tquic_server" ]]; then
    echo "Error: tquic_client and/or tquic_server not found in $BIN_DIR"
    echo "Please build the project or specify the correct directory with -b option"
    show_help
    exit 1
fi

# Calculate CID limit based on path number
CID_LIMIT=$(( $PATH_NUM * 2 ))

# ============================================================================
# Utility Functions
# ============================================================================

# Generate self-signed certificate for testing
generate_cert() {
    local cert_dir="$1/cert"
    mkdir -p "$cert_dir"
    
    echo "Generating test certificate..."
    
    # Generate private key
    openssl genpkey -algorithm RSA \
        -out "$cert_dir/cert.key" \
        -pkeyopt rsa_keygen_bits:2048 \
        -quiet
    
    # Generate certificate signing request
    openssl req -new \
        -key "$cert_dir/cert.key" \
        -out "$cert_dir/cert.csr" \
        -subj "/C=CN/ST=beijing/O=tquic/CN=example.org"
    
    # Generate self-signed certificate
    openssl x509 -req \
        -in "$cert_dir/cert.csr" \
        -signkey "$cert_dir/cert.key" \
        -out "$cert_dir/cert.crt"
}

# Generate test files with random data
generate_files() {
    local data_dir="$1/data"
    mkdir -p "$data_dir"
    
    echo "Generating test file: $TEST_FILE"
    dd if=/dev/urandom of="$data_dir/$TEST_FILE" bs=$TEST_FILE count=1
}

# ============================================================================
# Test Case: Multipath
# ============================================================================
# Tests multipath functionality with different scheduling algorithms
test_multipath() {
    local test_dir=$1
    local algor=$2
    
    echo "[-] Running multipath test with algorithm: $algor"
    echo "    Test directory: $test_dir"
    
    # Prepare test environment
    local cert_dir="$test_dir/cert"
    local data_dir="$test_dir/data"
    local dump_dir="$test_dir/dump"
    local qlog_dir="$test_dir/qlog"
    
    generate_cert "$test_dir"
    generate_files "$test_dir"
    
    # Start TQUIC server with multipath enabled
    echo "    Starting server with multipath algorithm: $algor"
    RUST_BACKTRACE=1 $BIN_DIR/tquic_server \
        -l 127.0.8.8:8443 \
        --enable-multipath \
        --multipath-algor $algor \
        --cert "$cert_dir/cert.crt" \
        --key "$cert_dir/cert.key" \
        --root "$data_dir" \
        --active-cid-limit $CID_LIMIT \
        --log-file "$test_dir/server.log" \
        --log-level $LOG_LEVEL \
        $SRV_OPTIONS &
    server_pid=$!
    
    sleep 1  # Allow server to start
    
    # Start TQUIC client with multiple local addresses
    mkdir -p "$dump_dir"
    local_addresses=$(seq -s, -f "127.0.0.%g" 1 $PATH_NUM)
    
    echo "    Starting client with local addresses: $local_addresses"
    RUST_BACKTRACE=1 $BIN_DIR/tquic_client \
        -c 127.0.8.8:8443 \
        --enable-multipath \
        --multipath-algor $algor \
        --local-addresses $local_addresses \
        --active-cid-limit $CID_LIMIT \
        --qlog-dir "$qlog_dir" \
        --log-file "$test_dir/client.log" \
        --log-level $LOG_LEVEL \
        --dump-dir "$dump_dir" \
        $CLI_OPTIONS \
        https://example.org/$TEST_FILE
    
    # Verify downloaded file matches original
    echo "    Verifying file integrity..."
    if ! cmp -s "$dump_dir/$TEST_FILE" "$data_dir/$TEST_FILE"; then
        echo "    [FAIL] Downloaded file does not match original"
        echo "           Expected: $data_dir/$TEST_FILE"
        echo "           Got: $dump_dir/$TEST_FILE"
        EXIT_CODE=100
        exit $EXIT_CODE
    fi
    
    # Verify all paths received packets
    echo "    Verifying multipath usage..."
    pnum=$(grep "recv packet OneRTT" "$test_dir/client.log" | \
           grep -o "local=.*" | \
           sort | uniq -c | \
           tee /dev/stderr | \
           wc -l)
    
    if [ "$pnum" != "$PATH_NUM" ]; then
        echo "    [FAIL] Not all paths received packets ($pnum/$PATH_NUM)"
        EXIT_CODE=101
        exit $EXIT_CODE
    fi
    
    # Cleanup
    kill $server_pid
    server_pid=""
    
    echo "    [OK] Multipath test with $algor completed successfully"
    echo ""
}

# ============================================================================
# Test Case: Range Request
# ============================================================================
# Tests HTTP range request functionality
run_range_test_case() {
    local test_name=$1
    local range_header=$2
    local expected_status=$3
    local expected_size=$4
    local original_file=$5
    local dump_dir=$6
    local test_dir=$7
    
    echo "    -- Testing: $test_name (Range: $range_header)"
    
    local downloaded_file="$dump_dir/$TEST_FILE"
    rm -f "$downloaded_file"  # Clean previous download
    
    local client_log="$test_dir/client_${test_name}.log"
    
    # Execute range request
    local client_output=$($BIN_DIR/tquic_client \
        -c 127.0.8.8:8443 \
        --log-file "$client_log" \
        --log-level $LOG_LEVEL \
        --dump-dir "$dump_dir" \
        --range="$range_header" \
        --print-res \
        $CLI_OPTIONS \
        https://example.org/$TEST_FILE 2>&1)
    
    # Verify HTTP status code
    local status_code=$(echo "$client_output" | grep ':status:' | awk '{print $2}')
    if [ "$status_code" != "$expected_status" ]; then
        echo "       [FAIL] Incorrect status code"
        echo "              Expected: $expected_status, Got: $status_code"
        EXIT_CODE=110
        exit $EXIT_CODE
    fi
    
    # Verify file size
    local downloaded_size=0
    if [ -f "$downloaded_file" ]; then
        downloaded_size=$(stat -c%s "$downloaded_file")
    fi
    
    if [ "$downloaded_size" -ne "$expected_size" ]; then
        echo "       [FAIL] Incorrect file size"
        echo "              Expected: $expected_size bytes, Got: $downloaded_size bytes"
        EXIT_CODE=111
        exit $EXIT_CODE
    fi
    
    # Verify content for non-empty files
    if [ "$expected_size" -ne 0 ]; then
        local start_byte=$(echo $range_header | cut -d'-' -f1)
        local count_bytes=$expected_size
        
        # Handle suffix range requests
        if [[ "$range_header" == -* ]]; then
            local suffix_len=$(echo $range_header | cut -d'-' -f2)
            start_byte=$(($(stat -c%s "$original_file") - suffix_len))
        fi
        
        local expected_content_file="$test_dir/expected_content"
        dd if="$original_file" \
           of="$expected_content_file" \
           bs=1 \
           count=$count_bytes \
           skip=$start_byte \
           status=none
        
        if ! cmp -s "$downloaded_file" "$expected_content_file"; then
            echo "       [FAIL] Content mismatch"
            EXIT_CODE=112
            exit $EXIT_CODE
        fi
    fi
    
    echo "       [OK] $test_name"
}

test_range_request() {
    local test_dir=$1
    
    echo "[-] Running HTTP range request tests"
    echo "    Test directory: $test_dir"
    
    # Prepare environment
    local cert_dir="$test_dir/cert"
    local data_dir="$test_dir/data"
    local dump_dir="$test_dir/dump"
    mkdir -p "$dump_dir"
    
    generate_cert "$test_dir"
    generate_files "$test_dir"
    
    local original_file="$data_dir/$TEST_FILE"
    local file_size=$(stat -c%s "$original_file")
    
    # Start TQUIC server
    echo "    Starting server..."
    RUST_BACKTRACE=1 $BIN_DIR/tquic_server \
        -l 127.0.8.8:8443 \
        --cert "$cert_dir/cert.crt" \
        --key "$cert_dir/cert.key" \
        --root "$data_dir" \
        --log-file "$test_dir/server.log" \
        --log-level $LOG_LEVEL \
        $SRV_OPTIONS &
    server_pid=$!
    
    sleep 1  # Wait for server startup
    
    # Run comprehensive range request test cases
    echo "    Running test cases..."
    
    # Test various range request scenarios
    run_range_test_case "middle_segment" "100-199" 206 100 \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "from_start" "0-99" 206 100 \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "to_end_open" "$((file_size-100))-" 206 100 \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "suffix_range" "-100" 206 100 \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "single_byte" "50-50" 206 1 \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "entire_file" "0-$((file_size-1))" 206 $file_size \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "start_out_of_bounds" "$file_size-" 416 0 \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "start_gt_end" "200-100" 416 0 \
        "$original_file" "$dump_dir" "$test_dir"
    
    run_range_test_case "multipart_range" "0-99,200-299" 200 $file_size \
        "$original_file" "$dump_dir" "$test_dir"
    
    # Cleanup
    kill $server_pid
    server_pid=""
    
    echo "    [OK] Range request tests completed successfully"
    echo ""
}

# ============================================================================
# Test Case: ACK Frequency
# ============================================================================
# Tests ACK frequency extension functionality
test_ack_frequency() {
    local test_dir=$1
    
    echo "[-] Running ACK frequency test"
    echo "    Test directory: $test_dir"
    
    # Prepare environment
    local cert_dir="$test_dir/cert"
    local data_dir="$test_dir/data"
    local dump_dir="$test_dir/dump"
    mkdir -p "$dump_dir"
    
    generate_cert "$test_dir"
    generate_files "$test_dir"
    
    # Start TQUIC server with ACK frequency settings
    echo "    Starting server with min-ack-delay=2000us..."
    RUST_BACKTRACE=1 $BIN_DIR/tquic_server \
        -l 127.0.0.1:8443 \
        --cert "$cert_dir/cert.crt" \
        --key "$cert_dir/cert.key" \
        --root "$data_dir" \
        --min-ack-delay 2000 \
        --log-file "$test_dir/server.log" \
        --log-level $LOG_LEVEL \
        $SRV_OPTIONS &
    server_pid=$!
    
    sleep 10  # Allow server to fully initialize
    
    # Start TQUIC client with ACK frequency settings
    echo "    Starting client with min-ack-delay=1000us..."
    RUST_BACKTRACE=1 $BIN_DIR/tquic_client \
        -c 127.0.0.1:8443 \
        --min-ack-delay 1000 \
        --log-file "$test_dir/client.log" \
        --log-level $LOG_LEVEL \
        --dump-dir "$dump_dir" \
        $CLI_OPTIONS \
        https://example.org/$TEST_FILE
    
    # Verify file transfer
    echo "    Verifying file integrity..."
    if ! cmp -s "$dump_dir/$TEST_FILE" "$data_dir/$TEST_FILE"; then
        echo "    [FAIL] Downloaded file does not match original"
        EXIT_CODE=100
        exit $EXIT_CODE
    fi
    echo "    [OK] File transfer successful"
    
    # Verify ACK_FREQUENCY frames in logs
    echo "    Verifying ACK_FREQUENCY frames..."
    
    if ! grep "ACK_FREQUENCY" "$test_dir/client.log" > /dev/null; then
        echo "    [FAIL] Client log missing ACK_FREQUENCY frames"
        EXIT_CODE=101
    else
        echo "    [OK] Client log contains ACK_FREQUENCY frames"
    fi
    
    if ! grep "ACK_FREQUENCY" "$test_dir/server.log" > /dev/null; then
        echo "    [FAIL] Server log missing ACK_FREQUENCY frames"
        EXIT_CODE=102
    else
        echo "    [OK] Server log contains ACK_FREQUENCY frames"
    fi
    
    # Cleanup
    kill $server_pid
    server_pid=""
    
    echo "    [OK] ACK frequency test completed successfully"
    echo ""
}
# ============================================================================
# Helper function for reliable time measurement
# ============================================================================
get_monotonic_time() {
    # Returns current monotonic time in seconds with microsecond precision
    # This time is unaffected by NTP adjustments or system time changes
    awk '{printf "%.6f", $1}' /proc/uptime
}

# ============================================================================
# Helper function for time difference calculation
# ============================================================================
calculate_time_diff() {
    local start_time=$1
    local end_time=$2
    
    # Calculate difference and ensure it's positive
    local diff=$(echo "scale=6; $end_time - $start_time" | bc)
    
    # Validate the result
    if (( $(echo "$diff < 0" | bc -l) )); then
        echo "0"
        return 1
    fi
    
    echo "$diff"
    return 0
}
# ============================================================================
# Test Case: ACK Frequency Performance
# ============================================================================
# Benchmarks performance impact of ACK frequency optimization
test_ack_frequency_performance() {
    local test_dir=$1
    local cc_algo=${2:-Bbr}
    
    echo "[-] Running ACK frequency performance test"
    echo "    Congestion control: $cc_algo"
    echo "    Test directory: $test_dir"
    
    # Prepare environment
    local cert_dir="$test_dir/cert"
    local data_dir="$test_dir/data"
    local dump_dir="$test_dir/dump"
    mkdir -p "$dump_dir"
    mkdir -p "$data_dir"
    
    generate_cert "$test_dir"
    
    # Generate various test file sizes
    local test_files="1M"
    echo "    Generating test files..."
    for file_size in $test_files; do
        echo "      Creating $file_size file..."
        dd if=/dev/urandom of="$data_dir/$file_size" bs=$file_size count=1 2>/dev/null
    done
    
    # Initialize results file
    local perf_results="$test_dir/performance_results.txt"
    {
        echo "ACK Frequency Performance Test Results"
        echo "======================================"
        echo "Congestion Control: $cc_algo"
        echo "Test Date: $(date)"
        echo ""
    } > "$perf_results"
    
    # Test with different min_ack_delay values
    local min_ack_delays="0 2000"
    
    for file_size in $test_files; do
        echo "Testing file size: $file_size" | tee -a "$perf_results"
        echo "----------------------------------------" >> "$perf_results"
        
        for min_ack_delay in $min_ack_delays; do
            # Set test label
            local test_label="min_ack_delay=${min_ack_delay}us"
            if [ "$min_ack_delay" == "0" ]; then
                test_label="Baseline (no ACK frequency)"
            fi
            
            echo "  [$test_label] Running test..." | tee -a "$perf_results"
            
            # Start server
            RUST_BACKTRACE=1 ip netns exec server_ns $BIN_DIR/tquic_server \
                -l 10.0.0.2:8443 \
                --cert "$cert_dir/cert.crt" \
                --key "$cert_dir/cert.key" \
                --root "$data_dir" \
                --log-file "$test_dir/server_${file_size}_${min_ack_delay}.log" \
                --log-level $LOG_LEVEL \
                --congestion-control-algor $cc_algo \
                $SRV_OPTIONS &
            server_pid=$!
            sleep 2
            
            # Prepare client command
            local client_cmd="ip netns exec client_ns $BIN_DIR/tquic_client \
                -c 10.0.0.2:8443 \
                $([ "$min_ack_delay" != "0" ] && echo "--min-ack-delay $min_ack_delay") \
                --log-file $test_dir/client_${file_size}_${min_ack_delay}.log \
                --log-level $LOG_LEVEL \
                --dump-dir $dump_dir \
                $CLI_OPTIONS \
                https://example.org/$file_size"
            
            local cpu_log="$test_dir/cpu_${file_size}_${min_ack_delay}.txt"
            local output_log="$test_dir/output_${file_size}_${min_ack_delay}.txt"
            
           # Using helper functions for cleaner code
            local start_time=$(get_monotonic_time)
            
            # Run the test
            /usr/bin/time -f "user=%U sys=%S cpu=%P" -o "$cpu_log" \
                $client_cmd > "$output_log" 2>&1
            local client_exit_code=$?
            
            local end_time=$(get_monotonic_time)
            
            # Calculate elapsed time with validation
            local elapsed=$(calculate_time_diff "$start_time" "$end_time")
            if [ $? -ne 0 ]; then
                echo "    ERROR: Time calculation failed" | tee -a "$perf_results"
                continue
            fi
            
            # Parse CPU statistics
            if [ -f "$cpu_log" ]; then
                local user_time=$(grep "user=" "$cpu_log" | sed 's/user=\([^ ]*\).*/\1/')
                local sys_time=$(grep "sys=" "$cpu_log" | sed 's/.*sys=\([^ ]*\).*/\1/')
                local cpu_percent=$(grep "cpu=" "$cpu_log" | sed 's/.*cpu=\([^ ]*\).*/\1/' | sed 's/%//')
                local total_cpu=$(echo "$user_time + $sys_time" | bc)
                
                # Calculate throughput
                local file_size_bytes=$(stat -c%s "$data_dir/$file_size" 2>/dev/null || echo 0)
                
                if [ "$file_size_bytes" -gt 0 ] && (( $(echo "$elapsed > 0" | bc -l) )); then
                    local throughput=$(echo "scale=2; ($file_size_bytes * 8) / ($elapsed * 1000 * 1000)" | bc)
                    
                    # Sanity check throughput
                    if (( $(echo "$throughput > 10000" | bc -l) )); then
                        echo "    Warning: Unusually high throughput: ${throughput} Mbps" | tee -a "$perf_results"
                    fi
                else
                    local throughput="N/A"
                    echo "    Warning: Cannot calculate throughput" | tee -a "$perf_results"
                fi
                
                # Count ACK packets sent
                local ack_count=$(grep -c "sent packet.*ACK" "$test_dir/client_${file_size}_${min_ack_delay}.log" 2>/dev/null || echo 0)
                
                # Report results
                {
                    echo "    Transfer time: ${elapsed}s"
                    echo "    Throughput: ${throughput} Mbps"
                    echo "    Total CPU time: ${total_cpu}s (user: ${user_time}s, sys: ${sys_time}s)"
                    echo "    CPU usage: ${cpu_percent}%"
                    echo "    ACK packets sent: $ack_count"
                    echo ""
                } | tee -a "$perf_results"
            else
                echo "    Error: CPU log file not found: $cpu_log" | tee -a "$perf_results"
            fi
            
            # Cleanup server process
            if [ -n "$server_pid" ] && kill -0 $server_pid 2>/dev/null; then
                kill $server_pid 2>/dev/null || true
                wait $server_pid 2>/dev/null || true
            fi
            server_pid=""
            sleep 2
        done
        
        echo "" >> "$perf_results"
    done
    
    echo "    Performance test completed. Results saved to: $perf_results"
    echo ""
}

# Execute each test case
for TEST_CASE in ${TEST_CASES//,/ }; do
    case $TEST_CASE in
        multipath_minrtt)
            test_multipath "$TEST_DIR/minrtt" minrtt
            ;;
        multipath_redundant)
            test_multipath "$TEST_DIR/redundant" redundant
            ;;
        multipath_roundrobin)
            test_multipath "$TEST_DIR/roundrobin" roundrobin
            ;;
        range_request)
            test_range_request "$TEST_DIR/range"
            ;;
        ack_frequency)
            test_ack_frequency "$TEST_DIR/ack_frequency"
            ;;
        ack_frequency_performance)
            test_ack_frequency_performance "$TEST_DIR/ack_freq_perf" "$CC_ALGO"
            ;;
        *)
            echo "[ERROR] Unknown test case: $TEST_CASE"
            echo "        Use -l option to list available test cases"
            ;;
    esac
done

echo "=========================================="
echo "All tests completed successfully!"
echo "=========================================="
exit 0