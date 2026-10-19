#!/bin/bash
# Canary test script to verify secret leakage protection
#
# Verifies:
# 1. Non-RF_ prefixed secrets do NOT appear anywhere
# 2. RF_ prefixed values are SCRUBBED from artifacts (all escaped forms)
# 3. Console command line shows [REDACTED]
# 4. Failing suite exits non-zero and artifacts still scrubbed
# 5. Console FAIL summary may have plaintext (documented limitation)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPORT_DIR="$REPO_ROOT/tests/canary/reports"
LOG_FILE="$REPO_ROOT/tests/canary/entrypoint.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# Cleanup
rm -rf "$REPORT_DIR" "$LOG_FILE"
mkdir -p "$REPORT_DIR"

# =============================================================================
# CANARY VALUES - clear canary naming, not real credential formats
# =============================================================================

# Non-RF_ secrets (should NEVER appear anywhere)
CANARY_NOSCAN_1="canary-noscan-secret-alpha"
CANARY_NOSCAN_2="canary-noscan-secret-beta"
CANARY_NOSCAN_3="canary-noscan-secret-gamma"

# RF_ values with canary naming
CANARY_RF_VAL_1="canary-rf-value-one-12345"
CANARY_RF_VAL_2="canary-rf-data<test>&check|val"
CANARY_RF_VAL_3='canary-rf-"quoted"&val<x>/$|@end'

# Target URL with userinfo
CANARY_TARGET_URL="http://canary-user:canary-pass-xyz@localhost:8080/api/v1"
CANARY_USERINFO_PASS="canary-pass-xyz"

log_info "=============================================="
log_info "CANARY SECRET LEAKAGE TEST"
log_info "=============================================="
log_info ""
log_info "Testing 3 non-RF canary values, 3 RF canary values"
log_info "RF value 2: contains & < >"
log_info 'RF value 3: contains " & < > / $ | @'
log_info "Includes intentionally FAILING suite (non-zero exit expected)"
log_info ""

# =============================================================================
# SET UP ENVIRONMENT
# =============================================================================

export SECRET_CANARY_1="$CANARY_NOSCAN_1"
export SECRET_CANARY_2="$CANARY_NOSCAN_2"
export SECRET_CANARY_3="$CANARY_NOSCAN_3"

export RF_CANARY_VAR_1="$CANARY_RF_VAL_1"
export RF_CANARY_VAR_2="$CANARY_RF_VAL_2"
export RF_CANARY_QUOTED="$CANARY_RF_VAL_3"

# =============================================================================
# RUN ENTRYPOINT
# =============================================================================

log_info "Running entrypoint.sh (includes failing suite)..."
cd "$REPO_ROOT"

ENTRYPOINT_EXIT=0
bash "$REPO_ROOT/entrypoint.sh" \
    "tests/canary" \
    "$CANARY_TARGET_URL" \
    "$REPORT_DIR" \
    "" "" "" "1" "" "INFO" \
    2>&1 | tee "$LOG_FILE" || ENTRYPOINT_EXIT=$?

log_info "Entrypoint exit code: $ENTRYPOINT_EXIT"
log_info ""

# =============================================================================
# TEST TRACKING
# =============================================================================

TESTS_PASSED=0
TESTS_FAILED=0
ARTIFACT_ISSUES=0
CONSOLE_LEAKS=0

pass() {
    log_pass "$1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    log_fail "$1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# =============================================================================
# ARTIFACT CHECKS (must be 0 matches)
# =============================================================================

echo ""
log_info "=== ARTIFACT CHECKS (must be 0 matches) ==="
echo ""

check_artifact() {
    local desc="$1"
    local pattern="$2"
    local count
    count=$( (grep -rF -- "$pattern" "$REPORT_DIR" 2>/dev/null || true) | wc -l | tr -d ' ')
    if [ "$count" = "0" ]; then
        pass "$desc: 0 matches"
    else
        fail "$desc: $count matches - LEAK"
        ARTIFACT_ISSUES=$((ARTIFACT_ISSUES + 1))
    fi
}

log_info "Non-RF_ canary secrets in artifacts:"
check_artifact "  Canary noscan 1" "$CANARY_NOSCAN_1"
check_artifact "  Canary noscan 2" "$CANARY_NOSCAN_2"
check_artifact "  Canary noscan 3" "$CANARY_NOSCAN_3"

log_info "RF_ canary values (raw) in artifacts:"
check_artifact "  RF canary 1 raw" "$CANARY_RF_VAL_1"
check_artifact "  RF canary 2 raw" "$CANARY_RF_VAL_2"
check_artifact "  RF canary 3 raw" "$CANARY_RF_VAL_3"

log_info "RF_ canary 2 escaped forms in artifacts:"
check_artifact "  RF canary 2 HTML" "canary-rf-data&lt;test&gt;&amp;check|val"

log_info "RF_ canary 3 (quoted) escaped forms in artifacts:"
check_artifact "  RF canary 3 HTML" 'canary-rf-&quot;quoted&quot;&amp;val&lt;x&gt;/$|@end'
check_artifact "  RF canary 3 JS" 'canary-rf-\"quoted\"&val<x>\/$|@end'

log_info "Target URL and userinfo in artifacts:"
check_artifact "  Target URL" "$CANARY_TARGET_URL"
check_artifact "  Userinfo password" "$CANARY_USERINFO_PASS"

# =============================================================================
# CONSOLE CHECKS (separate - may have FAIL summary leaks)
# =============================================================================

echo ""
log_info "=== CONSOLE CHECKS (FAIL summary may leak - documented) ==="
echo ""

check_console() {
    local desc="$1"
    local pattern="$2"
    local count
    count=$( (grep -F -- "$pattern" "$LOG_FILE" 2>/dev/null || true) | wc -l | tr -d ' ')
    echo "  $desc: $count matches"
    if [ "$count" != "0" ]; then
        CONSOLE_LEAKS=$((CONSOLE_LEAKS + count))
    fi
}

log_info "RF_ values in console (may appear in FAIL summary):"
check_console "RF canary 1" "$CANARY_RF_VAL_1"
check_console "RF canary 2" "$CANARY_RF_VAL_2"
check_console "RF canary 3" "$CANARY_RF_VAL_3"
check_console "Userinfo pass" "$CANARY_USERINFO_PASS"

if [ "$CONSOLE_LEAKS" -gt 0 ]; then
    log_warn "Console has $CONSOLE_LEAKS leak(s) in FAIL summary (expected per README)"
fi

# =============================================================================
# FUNCTIONAL CHECKS
# =============================================================================

echo ""
log_info "=== FUNCTIONAL CHECKS ==="
echo ""

if [ "$ENTRYPOINT_EXIT" -ne 0 ]; then
    pass "Entrypoint exited non-zero ($ENTRYPOINT_EXIT)"
else
    fail "Entrypoint should exit non-zero for failing suite"
fi

if grep -rqF "[SCRUBBED]" "$REPORT_DIR" 2>/dev/null; then
    pass "[SCRUBBED] placeholder in artifacts"
else
    fail "[SCRUBBED] placeholder missing in artifacts"
fi

if [ -f "$REPORT_DIR/output.xml" ] && [ -f "$REPORT_DIR/log.html" ] && [ -f "$REPORT_DIR/report.html" ]; then
    pass "Robot artifacts generated"
else
    fail "Robot artifacts missing"
fi

if grep -qF "[REDACTED]" "$LOG_FILE" 2>/dev/null; then
    pass "[REDACTED] in console command line"
else
    fail "[REDACTED] missing in console"
fi

if grep -F "Target URL:" "$LOG_FILE" 2>/dev/null | grep -qF "***"; then
    pass "Userinfo masked (***) in log"
else
    fail "Userinfo not masked in log"
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
log_info "=== SUMMARY ==="
echo "Tests passed: $TESTS_PASSED"
echo "Tests failed: $TESTS_FAILED"
echo "Artifact issues: $ARTIFACT_ISSUES"
echo "Console leaks (FAIL summary, expected): $CONSOLE_LEAKS"
echo "Entrypoint exit code: $ENTRYPOINT_EXIT"
echo ""

if [ "$ARTIFACT_ISSUES" -gt 0 ]; then
    log_fail "CANARY FAILED - Artifact leakage detected!"
    exit 1
elif [ "$TESTS_FAILED" -gt 0 ]; then
    log_fail "CANARY FAILED - Test failures!"
    exit 1
else
    log_pass "CANARY PASSED - Artifacts clean"
    exit 0
fi
