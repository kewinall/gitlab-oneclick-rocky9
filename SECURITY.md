# Security Policy

## 支援版本

目前只維護最新 Release。舊版本若有安裝問題，請先在測試環境升級至最新腳本。

## 回報安全問題

請不要在公開 Issue 貼出：

- `glrt-` Runner Token
- GitLab root 密碼
- Database Password
- Private Key 或憑證
- 內部 IP、網域與系統 Log 中的機敏資訊

請透過 GitHub Private Vulnerability Reporting，或 Repository 擁有者指定的私人聯絡管道回報。

## 部署安全基線

- 正式環境配置 HTTPS。
- Runner 優先限制在 Project 或 Group 範圍。
- 僅允許可信任人員修改 `.gitlab-ci.yml`。
- 定期執行異機備份與還原演練。
- Offline Bundle 搬入前必須驗證 SHA-256。
- 版本升級前閱讀 Release Notes 並確認 GitLab Upgrade Path。
