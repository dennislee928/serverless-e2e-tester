# Serverless E2E Tester (Robot Framework)

在 GitHub Actions 裡執行 Robot Framework API 測試，不需要先安裝 Python、Java 或測試相依套件。

[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## 使用方式

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

      - name: Upload Test Reports
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: robot-framework-reports
          path: reports/
          retention-days: 7
```

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

2. **日誌遮蔽：** 執行日誌只會顯示變數名稱，不會顯示變數值。所有值都會以 `[REDACTED]` 取代。

3. **報告注意事項：** Robot Framework 生成的報告（`log.html`、`report.html`、`output.xml`）可能包含測試過程中使用的變數值。**GitHub 的日誌遮蔽不適用於 artifact 檔案內容。** 請謹慎處理包含敏感資料的報告。

### 最佳實務

- 使用 `RF_` 前綴明確標示要傳遞給測試的變數
- 避免在測試中記錄敏感資料
- 考慮對包含敏感資訊的報告設定較短的 retention 時間
- 使用 `variable_file` 搭配 `.gitignore` 管理本地測試的敏感設定

## Inputs

| Input | 說明 | 必填 | 預設值 |
| --- | --- | --- | --- |
| `test_dir` | 含 `.robot` 測試檔的目錄 | 是 | - |
| `target_url` | API 基礎 URL | 是 | - |
| `report_dir` | 報告輸出目錄 | 否 | `reports` |
| `include_tags` | 要執行的標籤，逗號分隔 | 否 | - |
| `exclude_tags` | 要排除的標籤，逗號分隔 | 否 | - |
| `variable_file` | Robot Framework 變數檔，多個路徑用逗號分隔 | 否 | - |
| `processes` | 平行行程數，`1` 為循序執行 | 否 | `1` |
| `timeout` | 測試逾時，例如 `5 minutes` | 否 | - |
| `log_level` | `TRACE`、`DEBUG`、`INFO`、`WARN`、`ERROR`、`NONE` | 否 | `INFO` |
| `artifact_name` | 報告 artifact 名稱 | 否 | `robot-framework-reports` |
| `artifact_retention_days` | artifact 保留天數 | 否 | `7` |

## Outputs

| Output | 說明 |
| --- | --- |
| `exit_code` | Robot Framework 結束碼，`0` 代表通過 |
| `report_path` | 報告目錄 |

## 授權

MIT
