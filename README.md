# Serverless E2E Tester (Robot Framework)

在 GitHub Actions 裡執行 Robot Framework API 測試，不需要先安裝 Python、Java 或測試相依套件。

[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 使用方式

此 Action 是 **composite action**，會自動設定 Python 環境、安裝相依套件、執行測試並上傳報告 artifact。

```yaml
name: API E2E Tests

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run Robot Framework Tests
        uses: dennislee928/serverless-e2e-tester@v0.1.0
        with:
          test_dir: tests
          target_url: https://your-api.workers.dev
          artifact_retention_days: 3  # 建議 1-3 天，報告可能含敏感資料
```

**注意：** Artifact 上傳功能已內建於此 Action，無需另外呼叫 `actions/upload-artifact`。若要停用自動上傳，設定 `upload_artifact: 'false'`。

## ⚠️ 升級注意事項 (Migration Note)

**從舊版升級的使用者請注意：** 此版本內建 artifact 上傳功能，預設使用 `robot-framework-reports` 作為 artifact 名稱。如果您的 workflow 已有自己加的 `upload-artifact` step 且使用相同名稱，會造成 name conflict。

**解決方式（二擇一）：**

**方式一：移除自己的 upload-artifact step（推薦）**
```yaml
- name: Run Robot Framework Tests
  uses: dennislee928/serverless-e2e-tester@v0.1.0
  with:
    test_dir: tests
    target_url: https://your-api.workers.dev
    # 內建上傳已啟用，無需額外 step
```

**方式二：停用內建上傳，保留自己的 step**
```yaml
- name: Run Robot Framework Tests
  uses: dennislee928/serverless-e2e-tester@v0.1.0
  with:
    test_dir: tests
    target_url: https://your-api.workers.dev
    upload_artifact: 'false'  # 停用內建上傳

- name: Upload Test Reports  # 保留您自己的 step
  uses: actions/upload-artifact@v4
  if: always()
  with:
    name: robot-framework-reports
    path: reports/
    retention-days: 3
```

## 平行執行 (pabot)

設定 `processes` 大於 1 時，此 Action 會自動安裝並使用 [pabot](https://pabot.org/)（robotframework-pabot）進行平行測試：

```yaml
- name: Run Tests in Parallel
  uses: dennislee928/serverless-e2e-tester@v0.1.0
  with:
    test_dir: tests
    target_url: https://your-api.workers.dev
    processes: 4  # 使用 pabot 以 4 個 processes 平行執行
```

- `processes: 1`（預設）：使用 `robot` 循序執行
- `processes: 2` 或更大：使用 `pabot --processes N` 平行執行

## 環境變數與 Robot Framework 變數

`target_url` 會自動提供 `${BASE_URL}` 與 `${TARGET_URL}` 變數給 Robot Framework 測試使用。

### 傳遞自訂變數（RF_ 前綴）

若要將環境變數傳遞給 Robot Framework，必須使用 `RF_` 前綴。這是一種安全的 allowlist 機制，可防止 secrets 意外洩漏到日誌或報告中。

```yaml
- name: Run Robot Framework Tests
  uses: dennislee928/serverless-e2e-tester@v0.1.0
  env:
    RF_API_KEY: ${{ secrets.API_KEY }}
    RF_AUTH_TOKEN: ${{ secrets.AUTH_TOKEN }}
    RF_ENVIRONMENT: production
  with:
    test_dir: tests
    target_url: https://your-api.workers.dev
```

`RF_` 前綴會在轉換時被移除，所以在 Robot Framework 測試中使用 `${API_KEY}`、`${AUTH_TOKEN}`、`${ENVIRONMENT}` 等變數名稱（不含 `RF_` 前綴）。

## Security

### Secret 處理警告

**重要：** 此 Action 實作了以下安全措施來防止 secret 洩漏：

1. **Allowlist 機制：** 只有帶 `RF_` 前綴的環境變數會被轉換為 Robot Framework 變數。未帶前綴的環境變數（包括 GitHub secrets）不會被自動注入。

2. **Console 日誌部分遮蔽：** 執行命令列中的變數值會以 `[REDACTED]` 顯示。**但請注意：當測試失敗時，Robot Framework 的 FAIL 摘要可能會在 console 明文顯示變數值。** 此行為無法完全避免，請勿將 RF_* 值放入會出現在 FAIL 訊息中的位置。

3. **Artifact 清洗：** 測試完成後，報告檔案（`output.xml`、`log.html`、`report.html`）中的 `RF_*` 變數值（包含 XML/HTML escaped 形式如 `&amp;`、`&lt;`、`&gt;`）會被替換為 `[SCRUBBED]`。

4. **URL 安全：** 如果 `target_url` 包含 userinfo（如 `https://user:password@host`），密碼部分會在日誌中遮蔽為 `***`。

5. **Userinfo 密碼獨立清洗：** 從 URL 型環境變數（`TARGET_URL`、`RF_*` 中的 URL 值）解析出 userinfo 的密碼部分，作為獨立的清洗目標。即使完整 URL 未出現在 artifact 中，只有 `username:password@` 片段出現也會被清洗。這可處理 RequestsLibrary 等套件記錄截斷 URL 片段的情況。

6. **Prefix 截斷清洗：** 敏感值的前綴（prefix）也會被清洗，從完整值到最短 6 個字元為止。這可處理日誌或錯誤訊息截斷敏感值只顯示前幾個字元的情況。每種 escaped 變體（raw、HTML、JS、Robot 實際形）都會產生對應的 prefix 形。替換順序由長到短，避免短 prefix 先吃掉長的。
   - **最短長度：6 字元** — 足以避免誤 scrub 常見字串，又能涵蓋有意義的截斷形
   - 例如：密碼 `secret-pass-xyz` 的 prefix `secret`、`secret-`、`secret-p`... 都會被清洗

7. **遞迴清洗：** 清洗器會遞迴處理整個報告目錄（含子目錄如 `pabot_results/`），涵蓋 `.xml`、`.html`、`.txt`、`.log`、`.out` 及無副檔名的文字檔。二進位檔會安全跳過。

### ⚠️ RF_* 是明文 Opt-in 機制

使用 `RF_` 前綴代表您**明確選擇**將該值傳遞給 Robot Framework 作為變數。請注意：

- **請勿將高度敏感的 secrets 透過 `RF_*` 傳遞**（如資料庫密碼、私鑰等）
- 雖然 artifact 會被清洗，但處理過程中值仍會短暫存在於記憶體和磁碟
- 若您必須使用敏感資料，請考慮使用 `variable_file` 並確保檔案不會被上傳

#### RF_PASSWORD 注意事項

即使您將變數命名為 `RF_PASSWORD`，它仍會被當作一般 RF_* 變數處理：

```yaml
env:
  RF_PASSWORD: ${{ secrets.DB_PASSWORD }}  # ⚠️ 仍會被傳入 Robot Framework
```

這個值會：
- 成為 Robot Framework 變數 `${PASSWORD}`
- 被清洗器從 artifact 中移除
- **但可能在測試失敗時出現於 console FAIL 摘要中**

**建議：** 避免使用 `RF_PASSWORD`、`RF_SECRET`、`RF_TOKEN` 等命名傳遞高度敏感資料。

### Artifact 處理建議

**GitHub 的日誌遮蔽不適用於 artifact 檔案內容。** 即使經過清洗，報告 artifact 仍應視為敏感資料。

此 Action 會自動上傳報告 artifact（使用 `actions/upload-artifact@v4`），可透過以下 inputs 控制：

- `artifact_name`：artifact 名稱（預設：`robot-framework-reports`）
- `artifact_retention_days`：保留天數（預設：3 天，建議 1-3 天）
- `upload_artifact`：是否上傳（預設：`true`，設為 `false` 可停用）

```yaml
- name: Run Tests with Custom Artifact Settings
  uses: dennislee928/serverless-e2e-tester@v0.1.0
  with:
    test_dir: tests
    target_url: https://your-api.workers.dev
    artifact_name: my-test-reports
    artifact_retention_days: 1  # 建議 1-3 天
```

### Artifact 上傳範圍 (Upload Allowlist)

為安全起見，此 Action 只上傳已清洗的 **merged reports**：

| 上傳的檔案 | 說明 |
| --- | --- |
| `output.xml` | Robot Framework 測試結果 XML |
| `log.html` | 詳細測試日誌 |
| `report.html` | 測試報告摘要 |

**不上傳的檔案（Side files）：**

| 排除的路徑 | 原因 |
| --- | --- |
| `pabot_results/` | 含 raw `--variable NAME:VALUE` 及 worker log，可能有未 escaped 的敏感值 |
| `robot_argfile.txt` | 直接含變數值明文 |
| Worker stdout/stderr | 可能含測試 FAIL 時的敏感值 |

這些 side files 仍會被遞迴清洗（作為第二道防線），但不會被上傳至 artifact。如需自行上傳完整目錄，請設定 `upload_artifact: 'false'` 並自行處理。

### 最佳實務

- 使用 `RF_` 前綴明確標示要傳遞給測試的變數
- **避免透過 `RF_*` 傳遞高度敏感的 secrets**
- 將 artifact `retention-days` 設為較短時間（1-3 天）
- 使用 `variable_file` 搭配 `.gitignore` 管理本地測試的敏感設定
- 避免在測試中使用 `Log` 關鍵字記錄敏感資料
- **避免將 RF_* 值放入會出現在 Fail 訊息或 assertion 錯誤中的位置**

## Inputs

| Input | 說明 | 必填 | 預設值 |
| --- | --- | --- | --- |
| `test_dir` | 含 `.robot` 測試檔的目錄 | 是 | - |
| `target_url` | API 基礎 URL | 是 | - |
| `report_dir` | 報告輸出目錄 | 否 | `reports` |
| `include_tags` | 要執行的標籤，逗號分隔 | 否 | - |
| `exclude_tags` | 要排除的標籤，逗號分隔 | 否 | - |
| `variable_file` | Robot Framework 變數檔，多個路徑用逗號分隔 | 否 | - |
| `processes` | 平行行程數：`1` 使用 `robot`（循序），`>1` 使用 `pabot`（平行） | 否 | `1` |
| `timeout` | 測試逾時，例如 `5 minutes` | 否 | - |
| `log_level` | `TRACE`、`DEBUG`、`INFO`、`WARN`、`ERROR`、`NONE` | 否 | `INFO` |
| `artifact_name` | 報告 artifact 名稱 | 否 | `robot-framework-reports` |
| `artifact_retention_days` | artifact 保留天數（建議 1-3 天） | 否 | `3` |
| `upload_artifact` | 是否自動上傳報告 artifact | 否 | `true` |

## Outputs

| Output | 說明 |
| --- | --- |
| `exit_code` | Robot Framework 結束碼，`0` 代表通過 |
| `report_path` | 報告目錄 |

## 授權

MIT
