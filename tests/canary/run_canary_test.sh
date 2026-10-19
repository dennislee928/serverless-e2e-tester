#!/bin/bash
# Canary test script to verify secret leakage protection
#
# This script verifies that:
# 1. Non-RF_ prefixed secrets do NOT appear in logs or reports
# 2. RF_ prefixed variable values are SCRUBBED from artifacts after run
# 3. Variable values are REDACTED in console log output
# 4. Variable names (without values) ARE visible in logs
# 5. Tests that Log variables and fail assertions are exercised
#
# Uses grep -rF (recursive, fixed string) for all searches.

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

# Cleanup previous test artifacts
rm -rf "$REPORT_DIR" "$LOG_FILE"
mkdir -p "$REPORT_DIR"

# =============================================================================
# CANARY VALUES - Unique strings that must not leak
# =============================================================================

# Non-RF_ prefixed secrets - these should NEVER appear anywhere
CANARY_SECRET_1="CANARY_SECRET_12345_SHOULD_NOT_LEAK"
CANARY_SECRET_2="LEAKED_API_KEY_67890_DANGER"
CANARY_SECRET_3="SUPER_SECRET_XYZZY_PRIVATE"

# RF_ prefixed values - these should be SCRUBBED from artifacts after run
# They will initially appear in artifacts (Robot logs them), but entrypoint
# must scrub them before the script completes
RF_CANARY_VALUE_1="ALLOWED_VALUE_ABCDE"
RF_CANARY_VALUE_2="test_config_value_FGHIJ"

# Target URL with userinfo - the password should be masked in logs
TARGET_URL_WITH_USERINFO="http://testuser:secretpassword123@localhost:8080/api"
USERINFO_PASSWORD="secretpassword123"

log_info "=============================================="
log_info "CANARY SECRET LEAKAGE TEST"
log_info "=============================================="
log_info ""
log_info "Non-RF_ canary secrets (must NOT appear anywhere):"
log_info "  - $CANARY_SECRET_1"
log_info "  - $CANARY_SECRET_2"
log_info "  - $CANARY_SECRET_3"
log_info ""
log_info "RF_ canary values (must be SCRUBBED from artifacts):"
log_info "  - $RF_CANARY_VALUE_1"
log_info "  - $RF_CANARY_VALUE_2"
log_info ""
log_info "Userinfo password (must be masked in logs):"
log_info "  - $USERINFO_PASSWORD"
log_info ""

# =============================================================================
# SET UP ENVIRONMENT VARIABLES
# =============================================================================

# These should NOT be injected (no RF_ prefix)
export SECRET_API_KEY="$CANARY_SECRET_1"
export DATABASE_PASSWORD="$CANARY_SECRET_2"
export SUPER_SECRET="$CANARY_SECRET_3"

# These SHOULD be injected (RF_ prefix) - values will be in Robot variables
# and must be scrubbed from artifacts after the run
export RF_ALLOWLISTED_VAR="$RF_CANARY_VALUE_1"
export RF_TEST_CONFIG="$RF_CANARY_VALUE_2"

# Also set the expected value for the robot test assertion
export RF_CANARY_EXPECTED="$RF_CANARY_VALUE_1"

# =============================================================================
# RUN ENTRYPOINT
# =============================================================================

log_info "Running entrypoint.sh with target URL containing userinfo..."
cd "$REPO_ROOT"

ENTRYPOINT_EXIT=0
bash "$REPO_ROOT/entrypoint.sh" \
    "tests/canary" \
    "$TARGET_URL_WITH_USERINFO" \
    "$REPORT_DIR" \
    "" "" "" "1" "" "INFO" \
    2>&1 | tee "$LOG_FILE" || ENTRYPOINT_EXIT=$?

log_info "Entrypoint exit code: $ENTRYPOINT_EXIT"
log_info ""

# =============================================================================
# TEST RESULTS TRACKING
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
LEAK_DETAILS=""

run_check() {
    local name="$1"
    local result="$2"
    local details="${3:-}"
    if [ "$result" -eq 0 ]; then
        log_pass "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "$name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        if [ -n "$details" ]; then
            LEAK_DETAILS="${LEAK_DETAILS}\n  - $name: $details"
        fi
    fi
}

check_no_leak() {
    local description="$1"
    local search_value="$2"
    local search_path="$3"
    
    if grep -rF "$search_value" "$search_path" >/dev/null 2>&1; then
        local found_in
        found_in=$(grep -rlF "$search_value" "$search_path" 2>/dev/null | head -3 | tr '\n' ', ')
        run_check "$description" 1 "Found in: $found_in"
        return 1
    else
        run_check "$description" 0
        return 0
    fi
}

# =============================================================================
# CANARY CHECKS
# =============================================================================

echo ""
log_info "=== CANARY TEST RESULTS ==="
echo ""

# -----------------------------------------------------------------------------
# CHECK 1: Non-RF_ secrets must NOT appear in console logs
# -----------------------------------------------------------------------------
log_info "Checking console logs for non-RF_ secret leakage..."

check_no_leak "Non-RF_ secret 1 NOT in console logs" "$CANARY_SECRET_1" "$LOG_FILE"
check_no_leak "Non-RF_ secret 2 NOT in console logs" "$CANARY_SECRET_2" "$LOG_FILE"
check_no_leak "Non-RF_ secret 3 NOT in console logs" "$CANARY_SECRET_3" "$LOG_FILE"

# -----------------------------------------------------------------------------
# CHECK 2: Non-RF_ secrets must NOT appear in report artifacts
# -----------------------------------------------------------------------------
log_info "Checking report artifacts for non-RF_ secret leakage (recursive)..."

check_no_leak "Non-RF_ secret 1 NOT in artifacts" "$CANARY_SECRET_1" "$REPORT_DIR"
check_no_leak "Non-RF_ secret 2 NOT in artifacts" "$CANARY_SECRET_2" "$REPORT_DIR"
check_no_leak "Non-RF_ secret 3 NOT in artifacts" "$CANARY_SECRET_3" "$REPORT_DIR"

# -----------------------------------------------------------------------------
# CHECK 3: RF_ variable values must be REDACTED in console logs
# -----------------------------------------------------------------------------
log_info "Checking console logs for RF_ value redaction..."

check_no_leak "RF_ value 1 REDACTED in console logs" "$RF_CANARY_VALUE_1" "$LOG_FILE"
check_no_leak "RF_ value 2 REDACTED in console logs" "$RF_CANARY_VALUE_2" "$LOG_FILE"

# -----------------------------------------------------------------------------
# CHECK 4: RF_ variable values must be SCRUBBED from artifacts
# -----------------------------------------------------------------------------
log_info "Checking report artifacts for RF_ value scrubbing (recursive)..."

check_no_leak "RF_ value 1 SCRUBBED from artifacts" "$RF_CANARY_VALUE_1" "$REPORT_DIR"
check_no_leak "RF_ value 2 SCRUBBED from artifacts" "$RF_CANARY_VALUE_2" "$REPORT_DIR"

# -----------------------------------------------------------------------------
# CHECK 5: Userinfo password must be masked in console logs
# -----------------------------------------------------------------------------
log_info "Checking that userinfo password is masked in console logs..."

check_no_leak "Userinfo password masked in console logs" "$USERINFO_PASSWORD" "$LOG_FILE"

# -----------------------------------------------------------------------------
# CHECK 6: Variable NAMES should appear in logs (for debugging)
# -----------------------------------------------------------------------------
log_info "Checking that variable names ARE visible in console logs..."

if grep -F "ALLOWLISTED_VAR" "$LOG_FILE" >/dev/null 2>&1; then
    run_check "Variable name ALLOWLISTED_VAR visible in logs" 0
else
    run_check "Variable name ALLOWLISTED_VAR visible in logs" 1 "Name not found"
fi

# -----------------------------------------------------------------------------
# CHECK 7: [REDACTED] placeholder should appear in logs
# -----------------------------------------------------------------------------
log_info "Checking that [REDACTED] placeholder appears in console logs..."

if grep -F "[REDACTED]" "$LOG_FILE" >/dev/null 2>&1; then
    run_check "[REDACTED] placeholder in console logs" 0
else
    run_check "[REDACTED] placeholder in console logs" 1 "Placeholder not found"
fi

# -----------------------------------------------------------------------------
# CHECK 8: [SCRUBBED] placeholder should appear in artifacts (if scrubbing worked)
# -----------------------------------------------------------------------------
log_info "Checking that [SCRUBBED] placeholder appears in artifacts..."

if grep -rF "[SCRUBBED]" "$REPORT_DIR" >/dev/null 2>&1; then
    run_check "[SCRUBBED] placeholder in artifacts" 0
else
    run_check "[SCRUBBED] placeholder in artifacts" 1 "Scrubbing may not have occurred"
fi

# -----------------------------------------------------------------------------
# CHECK 9: Robot Framework should have run (artifacts exist)
# -----------------------------------------------------------------------------
log_info "Checking that Robot Framework artifacts were generated..."

if [ -f "$REPORT_DIR/output.xml" ] && [ -f "$REPORT_DIR/log.html" ] && [ -f "$REPORT_DIR/report.html" ]; then
    run_check "Robot Framework artifacts generated" 0
else
    run_check "Robot Framework artifacts generated" 1 "Missing output.xml, log.html, or report.html"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
log_info "=== SUMMARY ==="
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"

if [ -n "$LEAK_DETAILS" ]; then
    echo ""
    log_info "Leak details:"
    echo -e "$LEAK_DETAILS"
fi

echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    log_fail "CANARY TEST FAILED - Secret leakage or scrubbing issues detected!"
    echo ""
    log_info "Debug: Listing report directory contents..."
    ls -la "$REPORT_DIR" 2>/dev/null || true
    exit 1
else
    log_pass "CANARY TEST PASSED - No secret leakage detected!"
    exit 0
fi
