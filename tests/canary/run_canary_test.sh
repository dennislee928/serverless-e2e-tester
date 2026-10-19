#!/bin/bash
# Canary test script to verify secret leakage protection
#
# Verifies:
# 1. Non-RF_ prefixed secrets do NOT appear anywhere
# 2. RF_ prefixed values are SCRUBBED from artifacts (all escaped forms)
# 3. Prefix truncations are SCRUBBED (password prefixes, not just full values)
# 4. Console command line shows [REDACTED]
# 5. Failing suite exits non-zero and artifacts still scrubbed
# 6. Console FAIL summary may have plaintext (documented limitation)
# 7. Both processes=1 (robot) and processes=2 (pabot) paths work
# 8. Recursive scan of entire report_dir including pabot_results/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

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
# Value 3 contains ALL special chars including both ' and "
CANARY_RF_VAL_3="canary-rf-\"dq'sq\"&val<x>/\$|@-end"

# Target URL with userinfo
CANARY_TARGET_URL="http://canary-user:canary-pass-xyz@localhost:8080/api/v1"
CANARY_USERINFO_PASS="canary-pass-xyz"

# Password prefixes for prefix scrubbing tests
CANARY_PASS_PREFIX_11="canary-pass"
CANARY_PASS_PREFIX_13="canary-pass-x"
CANARY_PASS_PREFIX_ENCODED="canary%2Dpass"

# =============================================================================
# RUN CANARY TEST FOR A SPECIFIC PROCESSES VALUE
# =============================================================================

run_canary_for_processes() {
    local PROCESSES="$1"
    local REPORT_DIR="$REPO_ROOT/tests/canary/reports_p${PROCESSES}"
    local LOG_FILE="$REPO_ROOT/tests/canary/entrypoint_p${PROCESSES}.log"
    
    log_info "=============================================="
    log_info "CANARY TEST: processes=$PROCESSES"
    log_info "=============================================="
    
    # Cleanup
    rm -rf "$REPORT_DIR" "$LOG_FILE"
    mkdir -p "$REPORT_DIR"
    
    # Set up environment
    export SECRET_CANARY_1="$CANARY_NOSCAN_1"
    export SECRET_CANARY_2="$CANARY_NOSCAN_2"
    export SECRET_CANARY_3="$CANARY_NOSCAN_3"
    export RF_CANARY_VAR_1="$CANARY_RF_VAL_1"
    export RF_CANARY_VAR_2="$CANARY_RF_VAL_2"
    export RF_CANARY_QUOTED="$CANARY_RF_VAL_3"
    
    # Run entrypoint
    log_info "Running entrypoint.sh with processes=$PROCESSES..."
    cd "$REPO_ROOT"
    
    ENTRYPOINT_EXIT=0
    bash "$REPO_ROOT/entrypoint.sh" \
        "tests/canary" \
        "$CANARY_TARGET_URL" \
        "$REPORT_DIR" \
        "" "" "" "$PROCESSES" "" "INFO" \
        2>&1 | tee "$LOG_FILE" || ENTRYPOINT_EXIT=$?
    
    log_info "Entrypoint exit code: $ENTRYPOINT_EXIT"
    
    # ==========================================================================
    # PRE/POST COUNT FUNCTION (recursive scan)
    # ==========================================================================
    
    count_recursive() {
        local pattern="$1"
        local count
        count=$( (grep -rF -- "$pattern" "$REPORT_DIR" 2>/dev/null || true) | wc -l | tr -d ' ')
        echo "$count"
    }
    
    # ==========================================================================
    # ARTIFACT CHECKS WITH PRE/POST (must all be POST=0)
    # ==========================================================================
    
    echo ""
    log_info "=== ARTIFACT CHECKS (recursive scan, POST must be 0) ==="
    echo ""
    
    ARTIFACT_ISSUES=0
    TESTS_PASSED=0
    TESTS_FAILED=0
    
    check_artifact_post() {
        local desc="$1"
        local pattern="$2"
        local post_count
        post_count=$(count_recursive "$pattern")
        if [ "$post_count" = "0" ]; then
            log_pass "$desc: POST=0"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        else
            log_fail "$desc: POST=$post_count - LEAK"
            TESTS_FAILED=$((TESTS_FAILED + 1))
            ARTIFACT_ISSUES=$((ARTIFACT_ISSUES + 1))
        fi
    }
    
    log_info "Non-RF_ canary secrets:"
    check_artifact_post "  Canary noscan 1" "$CANARY_NOSCAN_1"
    check_artifact_post "  Canary noscan 2" "$CANARY_NOSCAN_2"
    check_artifact_post "  Canary noscan 3" "$CANARY_NOSCAN_3"
    
    log_info "RF_ canary values (raw):"
    check_artifact_post "  RF canary 1 raw" "$CANARY_RF_VAL_1"
    check_artifact_post "  RF canary 2 raw" "$CANARY_RF_VAL_2"
    check_artifact_post "  RF canary 3 raw" "$CANARY_RF_VAL_3"
    
    log_info "RF_ canary escaped forms:"
    check_artifact_post "  RF canary 2 HTML" "canary-rf-data&lt;test&gt;&amp;check|val"
    check_artifact_post "  RF canary 3 HTML quote=True" 'canary-rf-&quot;dq'"'"'sq&quot;&amp;val&lt;x&gt;/$|@-end'
    check_artifact_post "  RF canary 3 Robot actual" 'canary-rf-\"dq'"'"'sq\"&amp;val&lt;x&gt;/$|@-end'
    
    log_info "Target URL and userinfo:"
    check_artifact_post "  Full TARGET_URL" "$CANARY_TARGET_URL"
    check_artifact_post "  Userinfo password full" "$CANARY_USERINFO_PASS"
    
    log_info "Password PREFIX scrubbing (Blocker 1 fix):"
    check_artifact_post "  Password prefix 11 chars" "$CANARY_PASS_PREFIX_11"
    check_artifact_post "  Password prefix 13 chars" "$CANARY_PASS_PREFIX_13"
    
    log_info "Truncated userinfo fragment:"
    check_artifact_post "  user:pass@host fragment" "canary-user:canary-pass-xyz@localhost:8080"
    
    # ==========================================================================
    # RECURSIVE SCAN SCOPE VERIFICATION
    # ==========================================================================
    
    echo ""
    log_info "=== RECURSIVE SCAN SCOPE ==="
    echo "Files in report_dir:"
    find "$REPORT_DIR" -type f 2>/dev/null | wc -l | tr -d ' '
    echo "Directories scanned:"
    find "$REPORT_DIR" -type d 2>/dev/null | head -10
    
    # ==========================================================================
    # CONSOLE CHECKS
    # ==========================================================================
    
    echo ""
    log_info "=== CONSOLE CHECKS (FAIL summary may leak - documented) ==="
    
    CONSOLE_LEAKS=0
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
    
    check_console "RF canary 1" "$CANARY_RF_VAL_1"
    check_console "RF canary 2" "$CANARY_RF_VAL_2"
    check_console "RF canary 3" "$CANARY_RF_VAL_3"
    check_console "Userinfo pass" "$CANARY_USERINFO_PASS"
    
    if [ "$CONSOLE_LEAKS" -gt 0 ]; then
        log_warn "Console has $CONSOLE_LEAKS leak(s) in FAIL summary (expected per README)"
    fi
    
    # ==========================================================================
    # FUNCTIONAL CHECKS
    # ==========================================================================
    
    echo ""
    log_info "=== FUNCTIONAL CHECKS ==="
    
    if [ "$ENTRYPOINT_EXIT" -ne 0 ]; then
        log_pass "Entrypoint exited non-zero ($ENTRYPOINT_EXIT)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "Entrypoint should exit non-zero for failing suite"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    if grep -rqF "[SCRUBBED]" "$REPORT_DIR" 2>/dev/null; then
        log_pass "[SCRUBBED] placeholder in artifacts"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "[SCRUBBED] placeholder missing in artifacts"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    if [ -f "$REPORT_DIR/output.xml" ] && [ -f "$REPORT_DIR/log.html" ] && [ -f "$REPORT_DIR/report.html" ]; then
        log_pass "Robot merged artifacts generated"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "Robot merged artifacts missing"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    if grep -qF "[REDACTED]" "$LOG_FILE" 2>/dev/null; then
        log_pass "[REDACTED] in console command line"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "[REDACTED] missing in console"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    if grep -F "Target URL:" "$LOG_FILE" 2>/dev/null | grep -qF "***"; then
        log_pass "Userinfo masked (***) in log"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        log_fail "Userinfo not masked in log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    
    # pabot-specific checks
    if [ "$PROCESSES" != "1" ]; then
        if [ -d "$REPORT_DIR/pabot_results" ]; then
            log_pass "pabot_results directory exists"
            TESTS_PASSED=$((TESTS_PASSED + 1))
            
            # Verify pabot side files are also scrubbed
            if grep -rqF "[SCRUBBED]" "$REPORT_DIR/pabot_results" 2>/dev/null; then
                log_pass "pabot_results also scrubbed"
                TESTS_PASSED=$((TESTS_PASSED + 1))
            else
                log_warn "pabot_results may not have scrubbed content (check if sensitive values were present)"
            fi
        else
            log_fail "pabot_results directory missing for processes=$PROCESSES"
            TESTS_FAILED=$((TESTS_FAILED + 1))
        fi
    fi
    
    # ==========================================================================
    # SUMMARY FOR THIS PROCESSES VALUE
    # ==========================================================================
    
    echo ""
    log_info "=== SUMMARY (processes=$PROCESSES) ==="
    echo "Tests passed: $TESTS_PASSED"
    echo "Tests failed: $TESTS_FAILED"
    echo "Artifact issues: $ARTIFACT_ISSUES"
    echo "Console leaks (FAIL summary, expected): $CONSOLE_LEAKS"
    echo "Entrypoint exit code: $ENTRYPOINT_EXIT"
    
    # Return failure status
    if [ "$ARTIFACT_ISSUES" -gt 0 ] || [ "$TESTS_FAILED" -gt 0 ]; then
        return 1
    fi
    return 0
}

# =============================================================================
# MAIN: RUN BOTH PROCESSES PATHS
# =============================================================================

log_info "=============================================="
log_info "CANARY SECRET LEAKAGE TEST - DUAL PATH"
log_info "=============================================="
log_info ""
log_info "Testing 3 non-RF canary values, 3 RF canary values"
log_info "RF value 2: contains & < >"
log_info 'RF value 3: contains " & < > / $ | @'
log_info "Testing password PREFIX scrubbing (Blocker 1)"
log_info "Testing recursive scan including pabot_results (Blocker 2)"
log_info "Includes intentionally FAILING suite (non-zero exit expected)"
log_info ""

FINAL_EXIT=0

# Run processes=1 (robot sequential)
if ! run_canary_for_processes "1"; then
    log_fail "CANARY FAILED for processes=1"
    FINAL_EXIT=1
else
    log_pass "CANARY PASSED for processes=1"
fi

echo ""
echo "=============================================="
echo ""

# Run processes=2 (pabot parallel)
if ! run_canary_for_processes "2"; then
    log_fail "CANARY FAILED for processes=2"
    FINAL_EXIT=1
else
    log_pass "CANARY PASSED for processes=2"
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================

echo ""
log_info "=============================================="
log_info "FINAL SUMMARY"
log_info "=============================================="

if [ "$FINAL_EXIT" -eq 0 ]; then
    log_pass "ALL CANARY TESTS PASSED (both processes=1 and processes=2)"
    exit 0
else
    log_fail "CANARY TESTS FAILED"
    exit 1
fi
