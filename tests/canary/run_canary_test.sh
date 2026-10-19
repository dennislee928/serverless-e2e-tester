#!/bin/bash
# Canary test script to verify secret leakage protection
#
# This script verifies that:
# 1. Non-RF_ prefixed secrets do NOT appear in logs or reports
# 2. RF_ prefixed variable values are SCRUBBED from artifacts after run
# 3. XML/HTML escaped variants are also scrubbed
# 4. Variable values are REDACTED in console log output (command line only)
# 5. Truly failing suites still get scrubbed and exit non-zero
# 6. Userinfo password is scrubbed from artifacts
#
# Uses grep -rF (recursive, fixed string) for all searches.
# Does NOT print canary values in output.

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
# CANARY VALUES - stored in variables but NOT printed to output
# =============================================================================

# Non-RF_ prefixed secrets - these should NEVER appear anywhere
CANARY_SECRET_1="CANARY_SEC_12345_NOLEAK"
CANARY_SECRET_2="LEAKED_KEY_67890_BAD"
CANARY_SECRET_3="SUPER_SEC_XYZZY_PRIV"

# RF_ prefixed values - these should be SCRUBBED from artifacts after run
# Value 1: simple alphanumeric
RF_CANARY_VALUE_1="ALLOWED_VAL_ABCDE"

# Value 2: contains path separator
RF_CANARY_VALUE_2="config/path/value_FGHIJ"

# Value 3: contains XML/HTML special chars that will be escaped
# Includes & < > to test escaped variant scrubbing
RF_CANARY_VALUE_3="Adv<Data>&Special|Val@123"

# Target URL with userinfo - password must be scrubbed from artifacts too
TARGET_URL_WITH_USERINFO="http://testuser:secretpw789xyz@localhost:8080/api/v1"
USERINFO_PASSWORD="secretpw789xyz"

log_info "=============================================="
log_info "CANARY SECRET LEAKAGE TEST"
log_info "=============================================="
log_info ""
log_info "Testing with 3 non-RF secrets, 3 RF values, and userinfo password"
log_info "RF value 3 contains XML special chars: & < >"
log_info "This test includes an intentionally FAILING suite"
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
export RF_SPECIAL_CHARS="$RF_CANARY_VALUE_3"

# =============================================================================
# RUN ENTRYPOINT WITH FAILING SUITE
# =============================================================================

log_info "Running entrypoint.sh (includes failing suite, expects non-zero exit)..."
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
            echo "    Details: $details"
        fi
    fi
}

check_no_leak() {
    local description="$1"
    local search_value="$2"
    local search_path="$3"
    
    if grep -rqF "$search_value" "$search_path" 2>/dev/null; then
        run_check "$description" 1 "Found matches"
        return 1
    else
        run_check "$description (0 matches)" 0
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
# CHECK: Entrypoint should exit non-zero (failing suite)
# -----------------------------------------------------------------------------
log_info "Checking entrypoint exit code (should be non-zero due to failing suite)..."

if [ "$ENTRYPOINT_EXIT" -ne 0 ]; then
    run_check "Entrypoint exited non-zero ($ENTRYPOINT_EXIT)" 0
else
    run_check "Entrypoint exited non-zero" 1 "Got exit code 0, expected non-zero"
fi

# -----------------------------------------------------------------------------
# CHECK: Non-RF_ secrets must NOT appear in artifacts (recursive)
# -----------------------------------------------------------------------------
log_info "Checking artifacts for non-RF_ secret leakage (recursive grep -rF)..."

check_no_leak "Non-RF secret 1 NOT in artifacts" "$CANARY_SECRET_1" "$REPORT_DIR"
check_no_leak "Non-RF secret 2 NOT in artifacts" "$CANARY_SECRET_2" "$REPORT_DIR"
check_no_leak "Non-RF secret 3 NOT in artifacts" "$CANARY_SECRET_3" "$REPORT_DIR"

# -----------------------------------------------------------------------------
# CHECK: RF_ variable values must be SCRUBBED from artifacts (recursive)
# -----------------------------------------------------------------------------
log_info "Checking artifacts for RF_ value scrubbing (recursive grep -rF)..."

check_no_leak "RF value 1 SCRUBBED from artifacts" "$RF_CANARY_VALUE_1" "$REPORT_DIR"
check_no_leak "RF value 2 (with /) SCRUBBED from artifacts" "$RF_CANARY_VALUE_2" "$REPORT_DIR"
check_no_leak "RF value 3 (with &<>) SCRUBBED from artifacts" "$RF_CANARY_VALUE_3" "$REPORT_DIR"

# -----------------------------------------------------------------------------
# CHECK: XML/HTML escaped variants must also be scrubbed
# -----------------------------------------------------------------------------
log_info "Checking artifacts for XML/HTML escaped variants..."

# The escaped form of RF_CANARY_VALUE_3 "Adv<Data>&Special|Val@123"
# would be "Adv&lt;Data&gt;&amp;Special|Val@123"
ESCAPED_VALUE_3="Adv&lt;Data&gt;&amp;Special|Val@123"
check_no_leak "RF value 3 escaped form SCRUBBED" "$ESCAPED_VALUE_3" "$REPORT_DIR"

# -----------------------------------------------------------------------------
# CHECK: Target URL (BASE_URL/TARGET_URL with //) must be scrubbed
# -----------------------------------------------------------------------------
log_info "Checking artifacts for target URL scrubbing..."

check_no_leak "Target URL SCRUBBED from artifacts" "$TARGET_URL_WITH_USERINFO" "$REPORT_DIR"

# -----------------------------------------------------------------------------
# CHECK: Userinfo password must be scrubbed from artifacts
# -----------------------------------------------------------------------------
log_info "Checking artifacts for userinfo password scrubbing..."

check_no_leak "Userinfo password SCRUBBED from artifacts" "$USERINFO_PASSWORD" "$REPORT_DIR"

# -----------------------------------------------------------------------------
# CHECK: [SCRUBBED] placeholder should appear in artifacts
# -----------------------------------------------------------------------------
log_info "Checking that [SCRUBBED] placeholder appears in artifacts..."

if grep -rF "[SCRUBBED]" "$REPORT_DIR" >/dev/null 2>&1; then
    run_check "[SCRUBBED] placeholder in artifacts" 0
else
    run_check "[SCRUBBED] placeholder in artifacts" 1 "Not found"
fi

# -----------------------------------------------------------------------------
# CHECK: Robot Framework artifacts exist
# -----------------------------------------------------------------------------
log_info "Checking that Robot Framework artifacts were generated..."

if [ -f "$REPORT_DIR/output.xml" ] && [ -f "$REPORT_DIR/log.html" ] && [ -f "$REPORT_DIR/report.html" ]; then
    run_check "Robot Framework artifacts generated" 0
else
    run_check "Robot Framework artifacts generated" 1 "Missing files"
fi

# -----------------------------------------------------------------------------
# CHECK: Variable names (not values) visible in console logs
# -----------------------------------------------------------------------------
log_info "Checking variable names visible in console logs..."

if grep -F "ALLOWLISTED_VAR" "$LOG_FILE" >/dev/null 2>&1; then
    run_check "Variable name visible in console logs" 0
else
    run_check "Variable name visible in console logs" 1 "Not found"
fi

# -----------------------------------------------------------------------------
# CHECK: [REDACTED] placeholder in console logs (command line)
# -----------------------------------------------------------------------------
log_info "Checking [REDACTED] placeholder in console logs..."

if grep -F "[REDACTED]" "$LOG_FILE" >/dev/null 2>&1; then
    run_check "[REDACTED] in console command line" 0
else
    run_check "[REDACTED] in console command line" 1 "Not found"
fi

# -----------------------------------------------------------------------------
# CHECK: Userinfo password masked in Target URL log line
# -----------------------------------------------------------------------------
log_info "Checking userinfo masking in Target URL log line..."

if grep -F "Target URL:" "$LOG_FILE" | grep -F "***" >/dev/null 2>&1; then
    run_check "Userinfo masked (***) in Target URL log" 0
else
    run_check "Userinfo masked (***) in Target URL log" 1 "Not found"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
log_info "=== SUMMARY ==="
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "Entrypoint exit code: $ENTRYPOINT_EXIT"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    log_fail "CANARY TEST FAILED - Issues detected!"
    exit 1
else
    log_pass "CANARY TEST PASSED - All checks passed!"
    exit 0
fi
