# GitLab CE One-Click for Rocky Linux 9

在單一 Rocky Linux 9.x x86_64 主機，以 Docker Compose 部署：

- GitLab CE `19.1.1`
- GitLab Runner `19.1.1`（Docker Executor）
- PostgreSQL `17.10`
- Docker Engine 與 Docker Compose Plugin
- 每日 systemd 備份
- 線上安裝與完全離線安裝

> PostgreSQL 儲存 GitLab 中繼資料；Git repository、Artifact、LFS 等資料由 GitLab/Gitaly 儲存在持久化目錄，不是存放在 PostgreSQL。

## 功能

- 以 `--mode online|offline` 明確選擇安裝模式。
- 線上模式自動安裝 Docker 套件並 Pull 固定版本映像。
- 離線模式只使用事先建立的 Bundle，不連線外部 DNF Repository 或 Container Registry。
- 自動建立並驗證 PostgreSQL Role、Database、Extension 與密碼。
- GitLab Host Header、容器 Healthcheck 與核心服務多重驗證。
- Runner 註冊、設定正規化及修復工具。
- GitLab、PostgreSQL、Runner 資料分開持久化。
- 備份、升級、狀態檢查與乾淨移除腳本。

## 建議主機規格

| 項目 | 建議 |
|---|---:|
| CPU | 8 vCPU |
| RAM | 16 GB；8 GB 使用 `--low-memory` |
| 磁碟 | SSD 200 GB 以上 |
| Web | TCP 80，或自訂 Port |
| Git SSH | TCP 2222，或自訂 Port |

部署前請先建立內部 DNS，例如：

```text
gitlab.example.com  →  GitLab 主機 IP
```

使用者、Git Client、Runner 與 Pipeline Job Container 都必須能解析此名稱。

---

## 快速開始

### 線上安裝

```bash
git clone https://github.com/<YOUR_ACCOUNT>/gitlab-oneclick-rocky9.git
cd gitlab-oneclick-rocky9

sudo bash install.sh \
  --mode online \
  --host gitlab.example.com
```

8 GB RAM：

```bash
sudo bash install.sh \
  --mode online \
  --host gitlab.example.com \
  --low-memory
```

### 離線安裝

#### 1. 有網路的 Rocky Linux 9 主機建立 Bundle

```bash
sudo bash prepare-offline-bundle.sh \
  --output /data/gitlab-offline-bundle-v1.4.0
```

需要額外 CI Image 時：

```bash
sudo bash prepare-offline-bundle.sh \
  --output /data/gitlab-offline-bundle-v1.4.0 \
  --extra-image python:3.13-slim \
  --extra-image maven:3.9-eclipse-temurin-21
```

#### 2. 將 Bundle 搬入離線主機並驗證

```bash
cd /media/usb/gitlab-offline-bundle-v1.4.0
sudo bash verify-offline-bundle.sh --target-check
```

#### 3. 明確指定離線模式安裝

```bash
sudo bash installer/install.sh \
  --mode offline \
  --offline-bundle "$PWD" \
  --host gitlab.example.com
```

Bundle 也提供簡化包裝器：

```bash
sudo bash install-offline.sh \
  --host gitlab.example.com
```

`install-offline.sh` 內部仍會以 `--mode offline` 呼叫主安裝程式。

---

## 安裝模式參數

| 參數 | 說明 |
|---|---|
| `--mode online` | 線上安裝；預設值。不能搭配 `--offline-bundle`。 |
| `--mode offline` | 離線安裝；必須搭配 `--offline-bundle PATH`。 |
| `--online` | `--mode online` 的簡寫。 |
| `--offline` | `--mode offline` 的簡寫。 |
| `--offline-bundle PATH` | 完整 Offline Bundle 目錄。 |

為相容 v1.3.0，單獨指定 `--offline-bundle` 仍會推斷為離線模式，但會顯示棄用警告。新部署請明確指定 `--mode offline`。

## 完整安裝參數

```text
--host HOSTNAME             必填，GitLab DNS 名稱
--mode online|offline       安裝模式，預設 online
--online                    --mode online 簡寫
--offline                   --mode offline 簡寫
--offline-bundle PATH       離線 Bundle，offline 模式必填
--http-port PORT            Web Port，預設 80
--ssh-port PORT             Git SSH Port，預設 2222
--runner-token TOKEN        選填，直接註冊 glrt- Token
--stack-dir PATH            資料目錄，預設 /srv/gitlab-stack
--low-memory                Puma=1、Sidekiq concurrency=5
--remove-podman             移除衝突的 Podman/Buildah/runc
--skip-firewall             不修改 firewalld
-h, --help                  顯示說明
```

範例：

```bash
sudo bash install.sh \
  --mode online \
  --host gitlab.example.com \
  --http-port 8080 \
  --ssh-port 2222 \
  --low-memory
```

---

## 安裝完成後

檢查服務：

```bash
sudo /srv/gitlab-stack/scripts/verify-install.sh
sudo /srv/gitlab-stack/scripts/status.sh
```

查看初始管理員帳密：

```bash
sudo cat /srv/gitlab-stack/secrets/initial_admin.txt
```

首次登入後請立即修改 `root` 密碼，並刪除明文檔：

```bash
sudo rm -f /srv/gitlab-stack/secrets/initial_admin.txt
```

## 註冊 Runner

在 GitLab UI 建立 Project、Group 或 Instance Runner，取得 `glrt-` Token 後：

```bash
sudo /srv/gitlab-stack/scripts/register-runner.sh \
  'glrt-xxxxxxxxxxxxxxxx'
```

驗證：

```bash
docker exec gitlab-runner gitlab-runner verify
```

離線環境的 Pipeline `image:` 必須已包含於 Bundle、手動 `docker load`，或存在於內部 Registry。

## 資料目錄

```text
/srv/gitlab-stack/
├── .env
├── compose.yaml
├── gitlab/
│   ├── config/
│   ├── data/
│   └── logs/
├── postgres/data/
├── runner/config/
├── secrets/
├── backups/
└── scripts/
```

## 備份與維運

```bash
# 立即備份
sudo /srv/gitlab-stack/scripts/backup.sh

# 備份排程
systemctl status gitlab-backup.timer
systemctl list-timers gitlab-backup.timer

# 查看容器
cd /srv/gitlab-stack
docker compose ps

# 修復 Runner 設定
sudo /srv/gitlab-stack/scripts/repair-runner.sh
```

本機備份仍應同步到 NAS、另一台伺服器或離線媒體。

## 乾淨移除

下列指令會永久刪除 GitLab、Repository、PostgreSQL、Secrets 與本機備份：

```bash
sudo bash uninstall.sh \
  --stack-dir /srv/gitlab-stack \
  --purge-data \
  --yes
```

## 專案測試

```bash
bash tests/run-tests.sh
```

或使用 Make：

```bash
make test
make release
```

GitHub Actions 會在 Push 與 Pull Request 執行 Bash 語法、YAML 與行為測試。

## 文件

- [統一安裝說明](docs/INSTALLATION.md)
- [完全離線安裝](docs/OFFLINE_INSTALL.md)
- [Runner 設定](docs/RUNNER.md)
- [疑難排解](docs/TROUBLESHOOTING.md)
- [GitHub 發布流程](docs/GITHUB_PUBLISH.md)
- [貢獻說明](CONTRIBUTING.md)
- [安全政策](SECURITY.md)
- [版本變更](CHANGELOG.md)

## 安全注意事項

- 不要將 `.env`、Secrets、Runner Token、root 密碼或備份提交到 Git。
- Runner 掛載 Docker Socket，應限制可修改 CI 設定的人員及可使用 Runner 的專案範圍。
- 正式環境應配置 HTTPS、異機備份及定期安全更新。
- Offline Bundle 是版本快照；升級時應重新建立並重新校驗 Bundle。

## License

MIT License。公司內部若有其他授權要求，可在發布前替換 `LICENSE`。
