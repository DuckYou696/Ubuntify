#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"

source "$LIB_DIR/logging.sh"
source "$LIB_DIR/verify.sh"

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

test_verify_disk_space_root_sufficient() {
    if verify_disk_space "/" 1; then
        return 0
    else
        echo "  Root should have > 1MB free"
        return 1
    fi
}

test_verify_disk_space_nonexistent_path() {
    local parent="/nonexistent_parent_$$"
    local full_path="$parent/subdir"
    
    if verify_disk_space "$full_path" 999999999 2>/dev/null; then
        rm -rf "$parent"
        echo "  Expected failure for path with insufficient space"
        return 1
    else
        rm -rf "$parent"
        return 0
    fi
}

test_verify_iso_extraction_no_files() {
    local temp_dir="/tmp/test_iso_empty_$$"
    mkdir -p "$temp_dir"
    
    if verify_iso_extraction "$temp_dir" 2>/dev/null; then
        rm -rf "$temp_dir"
        echo "  Expected failure for empty directory"
        return 1
    else
        rm -rf "$temp_dir"
        return 0
    fi
}

test_verify_esp_mount_nonexistent() {
    if verify_esp_mount "/nonexistent_esp_$$" 2>/dev/null; then
        echo "  Expected failure for nonexistent ESP"
        return 1
    else
        return 0
    fi
}

test_verify_yaml_syntax_nonexistent() {
    if verify_yaml_syntax "/nonexistent_$$.yaml" 2>/dev/null; then
        echo "  Expected failure for nonexistent YAML"
        return 1
    else
        return 0
    fi
}

test_verify_yaml_syntax_valid() {
    local temp_yaml="/tmp/test_valid_$$.yaml"
    
    cat > "$temp_yaml" << 'EOF'
key: value
list:
  - item1
  - item2
nested:
  key: "value with spaces"
EOF
    
    if verify_yaml_syntax "$temp_yaml"; then
        rm -f "$temp_yaml"
        return 0
    else
        rm -f "$temp_yaml"
        echo "  Valid YAML should parse successfully"
        return 1
    fi
}

test_verify_yaml_syntax_invalid() {
    local temp_yaml="/tmp/test_invalid_$$.yaml"
    
    echo ':invalid: [yaml' > "$temp_yaml"
    
    if verify_yaml_syntax "$temp_yaml" 2>/dev/null; then
        rm -f "$temp_yaml"
        echo "  Expected failure for invalid YAML"
        return 1
    else
        rm -f "$temp_yaml"
        return 0
    fi
}

echo "=== Testing lib/verify.sh ==="
echo ""

run_test "verify_disk_space / with 1MB requirement" test_verify_disk_space_root_sufficient
run_test "verify_disk_space nonexistent path fails" test_verify_disk_space_nonexistent_path
run_test "verify_iso_extraction empty directory fails" test_verify_iso_extraction_no_files
run_test "verify_esp_mount nonexistent directory fails" test_verify_esp_mount_nonexistent
run_test "verify_yaml_syntax nonexistent file fails" test_verify_yaml_syntax_nonexistent
run_test "verify_yaml_syntax valid YAML" test_verify_yaml_syntax_valid
run_test "verify_yaml_syntax invalid YAML fails" test_verify_yaml_syntax_invalid

echo ""
echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"

[ "$TESTS_FAILED" -eq 0 ] && exit 0 || exit 1
