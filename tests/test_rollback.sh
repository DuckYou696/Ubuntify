#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

export STATE_FILE="/tmp/test-rollback-state-$$.env"
export STATE_DIR="/tmp/test-rollback-dir-$$"

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/retry.sh"
source "$LIB_DIR/rollback.sh"

TESTS_PASSED=0
TESTS_FAILED=0

run_test() {
    local test_name="$1"
    local test_func="$2"
    
    if $test_func; then
        echo "PASS: $test_name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo "FAIL: $test_name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

cleanup_test_state() {
    rm -f "$STATE_FILE" 2>/dev/null || true
    rm -rf "$STATE_DIR" 2>/dev/null || true
}

test_journal_init_creates_state_file() {
    cleanup_test_state
    
    journal_init "test_method"
    
    if [ -f "$STATE_FILE" ]; then
        cleanup_test_state
        return 0
    else
        cleanup_test_state
        echo "  State file not created"
        return 1
    fi
}

test_journal_set_and_read() {
    cleanup_test_state
    
    journal_init
    journal_set "TEST_KEY" "test_value"
    
    unset JOURNAL_TEST_KEY 2>/dev/null || true
    journal_read
    
    if [ "${JOURNAL_TEST_KEY:-}" = "test_value" ]; then
        cleanup_test_state
        return 0
    else
        cleanup_test_state
        echo "  Expected JOURNAL_TEST_KEY='test_value', got '${JOURNAL_TEST_KEY:-}'"
        return 1
    fi
}

test_journal_set_phase_and_is_complete() {
    cleanup_test_state
    
    journal_init
    journal_set_phase "analyze"
    
    if journal_is_complete "analyze"; then
        cleanup_test_state
        return 0
    else
        cleanup_test_state
        echo "  Phase 'analyze' not marked complete"
        return 1
    fi
}

test_journal_is_complete_nonexistent() {
    cleanup_test_state
    
    journal_init
    
    if journal_is_complete "nonexistent"; then
        cleanup_test_state
        echo "  Expected nonexistent phase to not be complete"
        return 1
    else
        cleanup_test_state
        return 0
    fi
}

test_journal_get_phase() {
    cleanup_test_state
    
    journal_init
    journal_set_phase "extract_iso"
    
    local current_phase
    current_phase="$(journal_get_phase)"
    
    if [ "$current_phase" = "extract_iso" ]; then
        cleanup_test_state
        return 0
    else
        cleanup_test_state
        echo "  Expected phase='extract_iso', got '$current_phase'"
        return 1
    fi
}

test_journal_destroy_removes_state() {
    cleanup_test_state
    
    journal_init
    journal_set "KEY" "value"
    journal_destroy
    
    if [ ! -f "$STATE_FILE" ] && [ ! -d "$STATE_DIR" ]; then
        return 0
    else
        echo "  State file or directory still exists after destroy"
        return 1
    fi
}

test_journal_set_invalid_key() {
    cleanup_test_state
    
    journal_init
    
    if journal_set "INVALID KEY" "value" 2>/dev/null; then
        cleanup_test_state
        echo "  Expected invalid key to fail"
        return 1
    else
        cleanup_test_state
        return 0
    fi
}

test_journal_atomic_write() {
    cleanup_test_state
    
    journal_init
    journal_set "ATOMIC_KEY" "atomic_value"
    
    local temp_files
    temp_files="$(ls -1 /tmp/test-rollback-state-$$.env.tmp.* 2>/dev/null | wc -l)"
    
    if [ "$temp_files" -eq 0 ]; then
        cleanup_test_state
        return 0
    else
        cleanup_test_state
        echo "  Temp files still exist: $temp_files"
        return 1
    fi
}

echo "=== Testing lib/rollback.sh ==="
echo ""

run_test "journal_init creates state file" test_journal_init_creates_state_file
run_test "journal_set + journal_read verifies value" test_journal_set_and_read
run_test "journal_set_phase + journal_is_complete returns 0" test_journal_set_phase_and_is_complete
run_test "journal_is_complete nonexistent returns 1" test_journal_is_complete_nonexistent
run_test "journal_set_phase then journal_get_phase returns correct value" test_journal_get_phase
run_test "journal_destroy removes state file" test_journal_destroy_removes_state
run_test "journal_set with invalid key fails" test_journal_set_invalid_key
run_test "journal_set atomic write cleanup" test_journal_atomic_write

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
