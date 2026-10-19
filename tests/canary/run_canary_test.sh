#!/bin/bash
# Canary test script to verify secret leakage protection
# This script verifies that:
# 1. Non-RF_ prefixed secrets do NOT appear in logs or reports
# 2. RF_ prefixed variables ARE available to Robot Framework
# 3. Variable values are REDACTED in log output
# 4. Variable names (without values) ARE visible in logs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="$REPO_ROOT/tests/canary/reports"
LOG_FILE="$REPO_ROOT/tests/canary/entrypoint.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# Cleanup
rm -rf "$REPORT_DIR" "$LOG_FILE"
mkdir -p "$REPORT_DIR"

# Define canary secrets - these are unique strings that should NOT appear anywhere
# if the protection is working correctly
CANARY_SECRET_VALUE="CANARY_SECRET_12345_SHOULD_NOT_LEAK"
CANARY_LEAKED_SECRET="LEAKED_API_KEY_67890_DANGER"

# Define allowlisted variable value - this SHOULD be usable by Robot Framework
# but the value should still be REDACTED in logs
ALLOWLISTED_VALUE="ALLOWED_VALUE_ABCDE"

log_info "Starting canary secret leakage test..."
log_info "Canary secret (non-RF_): $CANARY_SECRET_VALUE"
log_info "Leaked secret simulation: $CANARY_LEAKED_SECRET"
log_info "Allowlisted value (RF_): $ALLOWLISTED_VALUE"

# Export environment variables
# These should NOT be injected (no RF_ prefix)
export SECRET_API_KEY="$CANARY_SECRET_VALUE"
export DATABASE_PASSWORD="$CANARY_LEAKED_SECRET"
export SUPER_SECRET="another_secret_that_should_not_leak"

# These SHOULD be injected (RF_ prefix)
export RF_ALLOWLISTED_VAR="$ALLOWLISTED_VALUE"
export RF_TEST_CONFIG="test_config_value"

# Run entrypoint.sh and capture output
log_info "Running entrypoint.sh..."
cd "$REPO_ROOT"

EXIT_CODE=0
bash "$REPO_ROOT/entrypoint.sh" \
    "tests/canary" \
    "http://localhost:8080" \
    "$REPORT_DIR" \
    "" "" "" "1" "" "INFO" \
    2>&1 | tee "$LOG_FILE" || EXIT_CODE=$?

log_info "Entrypoint exit code: $EXIT_CODE"

# Test results tracking
TESTS_PASSED=0
TESTS_FAILED=0

run_check() {
    local name="$1"
    local result="$2"
    if [ "$result" -eq 0 ]; then
        log_pass "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "$name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

echo ""
log_info "=== CANARY TEST RESULTS ==="
echo ""

# Check 1: Non-RF_ prefixed secrets should NOT appear in logs
log_info "Checking that non-RF_ secrets don't appear in logs..."
if grep -q "$CANARY_SECRET_VALUE" "$LOG_FILE" 2>/dev/null; then
    run_check "Non-RF_ secret NOT in logs" 1
    echo "  Found leaked secret in log!"
else
    run_check "Non-RF_ secret NOT in logs" 0
fi

if grep -q "$CANARY_LEAKED_SECRET" "$LOG_FILE" 2>/dev/null; then
    run_check "Simulated leaked secret NOT in logs" 1
    echo "  Found leaked secret in log!"
else
    run_check "Simulated leaked secret NOT in logs" 0
fi

# Check 2: RF_ prefixed variable VALUES should be REDACTED in logs
log_info "Checking that RF_ variable values are REDACTED in logs..."
if grep -q "$ALLOWLISTED_VALUE" "$LOG_FILE" 2>/dev/null; then
    run_check "RF_ variable value REDACTED in logs" 1
    echo "  Found allowlisted value in log (should be redacted)!"
else
    run_check "RF_ variable value REDACTED in logs" 0
fi

# Check 3: Variable NAMES should appear in logs (showing what was injected)
log_info "Checking that variable names ARE visible in logs..."
if grep -q "ALLOWLISTED_VAR" "$LOG_FILE" 2>/dev/null; then
    run_check "Variable name visible in logs" 0
else
    run_check "Variable name visible in logs" 1
    echo "  Variable name not found in log!"
fi

# Check 4: [REDACTED] placeholder should appear in logs
log_info "Checking that [REDACTED] placeholder appears in logs..."
if grep -q "\[REDACTED\]" "$LOG_FILE" 2>/dev/null; then
    run_check "[REDACTED] placeholder in logs" 0
else
    run_check "[REDACTED] placeholder in logs" 1
    echo "  [REDACTED] not found in log!"
fi

# Check 5: Non-RF_ secrets should NOT appear in report files
log_info "Checking that secrets don't appear in report files..."
REPORT_LEAK=0
for report_file in "$REPORT_DIR"/*.html "$REPORT_DIR"/*.xml; do
    if [ -f "$report_file" ]; then
        if grep -q "$CANARY_SECRET_VALUE" "$report_file" 2>/dev/null; then
            log_fail "Secret found in $(basename "$report_file")!"
            REPORT_LEAK=1
        fi
        if grep -q "$CANARY_LEAKED_SECRET" "$report_file" 2>/dev/null; then
            log_fail "Leaked secret found in $(basename "$report_file")!"
            REPORT_LEAK=1
        fi
    fi
done
run_check "No secrets in report files" $REPORT_LEAK

# Check 6: Allowlisted variables should work in tests (test should pass)
log_info "Checking that allowlisted variables work (tests pass)..."
if [ $EXIT_CODE -eq 0 ]; then
    run_check "Robot Framework tests passed" 0
else
    run_check "Robot Framework tests passed" 1
    echo "  Tests failed with exit code $EXIT_CODE"
fi

# Check 7: Grep for the canary in all generated files
log_info "Deep scan: searching all output files for canary secrets..."
DEEP_SCAN_FAIL=0
for file in "$REPORT_DIR"/* "$LOG_FILE"; do
    if [ -f "$file" ]; then
        if grep -q "$CANARY_SECRET_VALUE\|$CANARY_LEAKED_SECRET" "$file" 2>/dev/null; then
            log_fail "Canary secret found in: $(basename "$file")"
            DEEP_SCAN_FAIL=1
        fi
    fi
done
run_check "Deep scan: no canary secrets in any output" $DEEP_SCAN_FAIL

echo ""
log_info "=== SUMMARY ==="
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    log_fail "CANARY TEST FAILED - Secret leakage detected!"
    exit 1
else
    log_pass "CANARY TEST PASSED - No secret leakage detected!"
    exit 0
fi
