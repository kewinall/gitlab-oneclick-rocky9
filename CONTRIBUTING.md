# Contributing

## 開發流程

1. 從 `main` 建立功能分支。
2. 保持每個 Commit 只處理一個主題。
3. 修改腳本後執行 `make test`。
4. 更新使用方式時同步調整 README 與 `docs/`。
5. 透過 Pull Request 合併，不直接推送受保護的 `main`。

## 程式規範

- Shell 使用 Bash，開頭採 `set -Eeuo pipefail`。
- 所有變數引用應加雙引號，除非有明確理由。
- 破壞性操作必須有確認或明確參數。
- Offline 模式不得新增外部 Pull 或啟用系統 Repository。
- 固定版本應集中於 `.env.example` 與安裝程式預設值。
- 不得將密碼、Token、憑證、備份或實際 `.env` 提交到 Git。

## 測試

```bash
make test
```

新增功能至少要包含一個 Regression Test。完整 GitLab Runtime 測試應在 Rocky Linux 9 測試主機執行。

## Pull Request 說明

請列出：

- 問題與根因。
- 修改內容。
- 線上與離線模式的影響。
- 測試方式與結果。
- 是否涉及資料刪除、升級或相容性變更。
