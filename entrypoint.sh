#!/bin/bash
set -euo pipefail

# 顏色輸出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日誌函數
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# SECURITY: Mask userinfo (user:password@) in URLs for logging
mask_url_userinfo() {
    local url="$1"
    # Replace user:password@ with user:***@ in URLs
    # Matches http(s)://user:password@host patterns
    echo "$url" | sed -E 's|(https?://)([^:]+):([^@]+)@|\1\2:***@|g'
}

# 解析輸入參數
TEST_DIR="${1:-}"
TARGET_URL="${2:-}"
REPORT_DIR="${3:-reports}"
INCLUDE_TAGS="${4:-}"
EXCLUDE_TAGS="${5:-}"
VARIABLE_FILE="${6:-}"
PROCESSES="${7:-1}"
TIMEOUT="${8:-}"
LOG_LEVEL="${9:-INFO}"

# 驗證必要參數
if [ -z "$TEST_DIR" ] || [ -z "$TARGET_URL" ]; then
    log_error "Missing required parameters: test_dir and target_url are required"
    exit 1
fi

# 驗證測試目錄存在
if [ ! -d "$TEST_DIR" ]; then
    log_error "Test directory does not exist: $TEST_DIR"
    exit 1
fi

# 安全性檢查：防止目錄遍歷
if [[ "$TEST_DIR" == *".."* ]] || [[ "$REPORT_DIR" == *".."* ]]; then
    log_error "Invalid path detected. Directory traversal is not allowed."
    exit 1
fi

log_info "Starting Robot Framework E2E Tests"
log_info "Test Directory: $TEST_DIR"
log_info "Target URL: $(mask_url_userinfo "$TARGET_URL")"
log_info "Report Directory: $REPORT_DIR"

# 建立報告目錄
mkdir -p "$REPORT_DIR"

# 注入環境變數為 Robot Framework 變數
# SECURITY: Only variables with the RF_ prefix are converted to Robot Framework variables.
# This prevents accidental exposure of secrets in logs or generated reports.
log_info "Injecting environment variables as Robot Framework variables..."

# 建立變數陣列（避免使用 eval，提高安全性）
ROBOT_VARIABLES=()
ROBOT_VAR_NAMES=()
# SECURITY: Track values for post-run artifact scrubbing
SCRUB_VALUES=()

# 注入 TARGET_URL 作為 BASE_URL 和 TARGET_URL 變數（常用於測試）
ROBOT_VARIABLES+=("BASE_URL:$TARGET_URL")
ROBOT_VARIABLES+=("TARGET_URL:$TARGET_URL")
ROBOT_VAR_NAMES+=("BASE_URL")
ROBOT_VAR_NAMES+=("TARGET_URL")
SCRUB_VALUES+=("$TARGET_URL")

# SECURITY FIX: Only process environment variables with explicit RF_ prefix.
# This is an allowlist approach that prevents secrets from being accidentally exposed.
# Users must explicitly opt-in by prefixing variables with RF_.
# The RF_ prefix is stripped when creating the Robot Framework variable name.
# Example: RF_API_KEY=secret -> Robot variable ${API_KEY}

while IFS='=' read -r key value; do
    # 跳過空行
    [[ -z "$key" ]] && continue
    
    # Only process variables with RF_ prefix (explicit allowlist)
    if [[ "$key" =~ ^RF_[A-Z][A-Z0-9_]*$ ]] && [[ -n "${!key:-}" ]]; then
        # Strip the RF_ prefix for the Robot Framework variable name
        robot_var_name="${key#RF_}"
        var_value="${!key}"
        ROBOT_VARIABLES+=("$robot_var_name:$var_value")
        ROBOT_VAR_NAMES+=("$robot_var_name")
        # Track value for post-run artifact scrubbing
        SCRUB_VALUES+=("$var_value")
    fi
done < <(env | sort || true)

VAR_COUNT=${#ROBOT_VAR_NAMES[@]}
log_info "Injected $VAR_COUNT variables as Robot Framework variables"
# SECURITY: Only log variable names, never values
if [ $VAR_COUNT -gt 0 ]; then
    log_info "Variables injected: ${ROBOT_VAR_NAMES[*]}"
fi

# 建構 robot 命令參數陣列（安全執行，避免命令注入）
EXIT_CODE=0
ROBOT_ARGS=()

# 設定基本參數
ROBOT_ARGS+=("--outputdir" "$REPORT_DIR")
ROBOT_ARGS+=("--loglevel" "$LOG_LEVEL")

# 添加標籤過濾
if [ -n "$INCLUDE_TAGS" ]; then
    IFS=' ' read -ra TAGS <<< "$(echo "$INCLUDE_TAGS" | tr ',' ' ')"
    for tag in "${TAGS[@]}"; do
        ROBOT_ARGS+=("--include" "$tag")
    done
    log_info "Including tags: $INCLUDE_TAGS"
fi

if [ -n "$EXCLUDE_TAGS" ]; then
    IFS=' ' read -ra TAGS <<< "$(echo "$EXCLUDE_TAGS" | tr ',' ' ')"
    for tag in "${TAGS[@]}"; do
        ROBOT_ARGS+=("--exclude" "$tag")
    done
    log_info "Excluding tags: $EXCLUDE_TAGS"
fi

# 添加變數檔案
if [ -n "$VARIABLE_FILE" ]; then
    IFS=',' read -ra VAR_FILES <<< "$VARIABLE_FILE"
    for var_file in "${VAR_FILES[@]}"; do
        var_file=$(echo "$var_file" | xargs)
        if [ -f "$var_file" ]; then
            ROBOT_ARGS+=("--variablefile" "$var_file")
            log_info "Using variable file: $var_file"
        else
            log_warning "Variable file not found: $var_file (skipping)"
        fi
    done
fi

# Determine execution mode: robot (sequential) or pabot (parallel)
USE_PABOT=false
if [ -n "$PROCESSES" ] && [ "$PROCESSES" != "1" ]; then
    # Validate processes is a positive integer > 1
    if [[ "$PROCESSES" =~ ^[0-9]+$ ]] && [ "$PROCESSES" -gt 1 ]; then
        USE_PABOT=true
        log_info "Running tests in parallel with $PROCESSES processes (using pabot)"
    else
        log_warning "Invalid processes value '$PROCESSES', falling back to sequential execution"
    fi
fi

# 添加超時
if [ -n "$TIMEOUT" ]; then
    ROBOT_ARGS+=("--testtimeout" "$TIMEOUT")
    log_info "Test timeout: $TIMEOUT"
fi

# 添加變數
for var in "${ROBOT_VARIABLES[@]}"; do
    ROBOT_ARGS+=("--variable" "$var")
done

# 添加測試目錄
ROBOT_ARGS+=("$TEST_DIR")

# SECURITY: Build a sanitized version of arguments for logging that redacts variable values
SAFE_LOG_ARGS=()
NEXT_IS_VAR_VALUE=false
for arg in "${ROBOT_ARGS[@]}"; do
    if [ "$NEXT_IS_VAR_VALUE" = true ]; then
        # Redact the value part of --variable NAME:VALUE
        var_name="${arg%%:*}"
        SAFE_LOG_ARGS+=("$var_name:[REDACTED]")
        NEXT_IS_VAR_VALUE=false
    elif [ "$arg" = "--variable" ]; then
        SAFE_LOG_ARGS+=("$arg")
        NEXT_IS_VAR_VALUE=true
    else
        SAFE_LOG_ARGS+=("$arg")
    fi
done

# Execute robot or pabot based on processes setting
if [ "$USE_PABOT" = true ]; then
    # Build pabot arguments: --processes goes before robot args
    PABOT_ARGS=("--processes" "$PROCESSES")
    log_info "Executing: pabot ${PABOT_ARGS[*]} ${SAFE_LOG_ARGS[*]}"
    pabot "${PABOT_ARGS[@]}" "${ROBOT_ARGS[@]}" || EXIT_CODE=$?
else
    log_info "Executing: robot ${SAFE_LOG_ARGS[*]}"
    robot "${ROBOT_ARGS[@]}" || EXIT_CODE=$?
fi

# SECURITY: Scrub sensitive values from generated artifacts using Python scrubber
# Robot Framework logs variable values in output.xml, log.html, and report.html.
# The scrubber replaces values (including XML/HTML escaped variants) with [SCRUBBED].
# Values are passed via env vars to avoid printing them to console.
log_info "Scrubbing sensitive values from report artifacts..."

# Pass values to scrubber via environment variables (null-separated, never printed)
# The scrubber reads RF_* env vars directly, plus _SCRUB_TARGET_URL
export _SCRUB_TARGET_URL="$TARGET_URL"

# Run Python scrubber - errors are caught internally, always exits 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$SCRIPT_DIR/scrub_artifacts.py" "$REPORT_DIR" || true

# Clean up env var
unset _SCRUB_TARGET_URL

# 輸出結果
if [ $EXIT_CODE -eq 0 ]; then
    log_success "All tests passed!"
else
    log_error "Tests failed with exit code: $EXIT_CODE"
fi

# 檢查報告檔案是否存在
if [ -f "$REPORT_DIR/report.html" ]; then
    log_success "Test report generated: $REPORT_DIR/report.html"
else
    log_warning "Test report not found at expected location: $REPORT_DIR/report.html"
fi

# 輸出報告路徑（供後續步驟使用）
# 使用新的 GITHUB_OUTPUT 方式（向後相容舊的 set-output）
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "exit_code=$EXIT_CODE" >> "$GITHUB_OUTPUT"
    echo "report_path=$REPORT_DIR" >> "$GITHUB_OUTPUT"
else
    # 向後相容舊的 set-output 方式
    echo "::set-output name=exit_code::$EXIT_CODE"
    echo "::set-output name=report_path::$REPORT_DIR"
fi

# 退出時使用相同的退出碼
exit $EXIT_CODE


