# GitHub 發布流程

## 1. 建立 Repository

建議名稱：

```text
gitlab-oneclick-rocky9
```

建立空 Repository 時不要另外初始化 README，避免與本專案內容衝突。

## 2. 首次推送

```bash
cd gitlab-oneclick-rocky9

git init
git branch -M main
git add .
git commit -m "Initial release"
git remote add origin https://github.com/<YOUR_ACCOUNT>/gitlab-oneclick-rocky9.git
git push -u origin main
```

## 3. 推送前檢查

```bash
make test
make release
```

確認沒有提交機敏資料：

```bash
git status --short
git grep -nE 'glrt-|Password:|BEGIN (RSA|OPENSSH|PRIVATE) KEY' -- . ':!docs/*' || true
```

不得提交：

- `/srv/gitlab-stack/.env`
- `secrets/`
- Runner Token
- 初始 root 密碼
- Database Password
- Backup Archive
- 實際 Offline Bundle

## 4. Branch 與 Pull Request

建議保護 `main`：

- Require a pull request before merging。
- Require status checks to pass。
- Require conversation resolution。
- 禁止直接 Force Push。

功能開發：

```bash
git checkout -b feature/install-mode
# 修改與測試
git push -u origin feature/install-mode
```

再由 GitHub 建立 Pull Request。

## 5. 建立 Release

更新：

```text
VERSION
CHANGELOG.md
README.md
```

產生封裝：

```bash
make release
```

輸出位置：

```text
dist/
├── gitlab-oneclick-rocky9-vX.Y.Z.zip
├── gitlab-oneclick-rocky9-vX.Y.Z.tar.gz
└── gitlab-oneclick-rocky9-vX.Y.Z.SHA256SUMS
```

建立 Tag：

```bash
VERSION=$(cat VERSION)
git tag -a "v${VERSION}" -m "Release v${VERSION}"
git push origin "v${VERSION}"
```

在 GitHub Releases 上傳 `dist/` 中三個檔案。

## 6. GitHub Actions

`.github/workflows/ci.yml` 會執行：

- Bash 語法檢查。
- Compose YAML 解析。
- Mock 線上安裝流程。
- Mock 離線 Bundle 與離線安裝流程。
- Runner TOML 正規化測試。
- 安裝模式參數測試。

GitLab 的完整 Container Runtime 測試仍應在 Rocky Linux 測試機執行。
