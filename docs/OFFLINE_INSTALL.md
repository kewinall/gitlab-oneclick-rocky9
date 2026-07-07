# GitLab 完全離線安裝作業說明

## 1. 流程

```text
有網路 Rocky Linux 9 x86_64
        │
        │ prepare-offline-bundle.sh
        ▼
Offline Bundle
  ├─ Docker/Rocky RPM 與相依套件
  ├─ Docker RPM 簽章金鑰
  ├─ GitLab/PostgreSQL/Runner Image
  ├─ 預設與額外 CI Image
  ├─ Installer
  └─ SHA-256 Manifest
        │
        │ USB、NAS、受控交換區
        ▼
離線 Rocky Linux 9 x86_64
        │
        │ verify-offline-bundle.sh
        │ install.sh --mode offline
        ▼
GitLab + PostgreSQL + Runner
```

## 2. 準備主機需求

- Rocky/RHEL-compatible Linux 9 x86_64。
- 可連線 Rocky BaseOS、AppStream、Docker RPM Repository 與 Container Registry。
- 建議使用與離線目標相同的 Rocky Linux Minor Release。
- Bundle 空間至少預留 10 GB，實際依額外 Image 而定。

準備程式會安裝 `dnf-plugins-core`、`curl`、`skopeo`、`gnupg2`。下載 Image 不需要啟動 Docker Daemon。

## 3. 建立 Bundle

```bash
sudo bash prepare-offline-bundle.sh \
  --output /data/gitlab-offline-bundle-v1.4.0
```

加入常用 CI Image：

```bash
sudo bash prepare-offline-bundle.sh \
  --output /data/gitlab-offline-bundle-v1.4.0 \
  --extra-image python:3.13-slim \
  --extra-image eclipse-temurin:21-jdk \
  --extra-image maven:3.9-eclipse-temurin-21
```

重建既有 Bundle：

```bash
sudo bash prepare-offline-bundle.sh \
  --output /data/gitlab-offline-bundle-v1.4.0 \
  --force
```

## 4. 搬移與驗證

來源端：

```bash
cd /data/gitlab-offline-bundle-v1.4.0
sha256sum -c SHA256SUMS
```

離線目標端：

```bash
cd /media/usb/gitlab-offline-bundle-v1.4.0
sudo bash verify-offline-bundle.sh --target-check
```

校驗未完全成功前，不要執行安裝。

## 5. 離線安裝

建議使用共同入口並明確指定模式：

```bash
sudo bash installer/install.sh \
  --mode offline \
  --offline-bundle "$PWD" \
  --host gitlab.example.com
```

或使用 Bundle 內包裝器：

```bash
sudo bash install-offline.sh \
  --host gitlab.example.com
```

包裝器等同於：

```bash
bash installer/install.sh \
  --mode offline \
  --offline-bundle <目前Bundle目錄> \
  <其他參數>
```

離線模式保證使用：

```text
dnf --disablerepo='*'
docker load
docker compose up --pull never
```

## 6. 模式錯誤防護

下列指令會直接停止：

```bash
# 缺少 Bundle
sudo bash install.sh --mode offline --host gitlab.example.com

# 線上模式卻指定 Bundle
sudo bash install.sh --mode online --offline-bundle /path/to/bundle --host gitlab.example.com
```

## 7. DNS

離線不代表可以省略 DNS。以下元件都必須解析 GitLab DNS：

- 使用者瀏覽器
- Git Client
- GitLab Runner
- Pipeline Job Container

建議使用內部 DNS。只修改主機 `/etc/hosts` 不一定能讓 Job Container 正確解析。

## 8. Runner Image 管理

查看已載入 Image：

```bash
docker image ls
```

若 Pipeline 使用 Bundle 未包含的 Image，Job 會因無法 Pull 而失敗。可採：

- 重建 Bundle 並加入 `--extra-image`。
- 連網區 `docker save`，離線區 `docker load`。
- 建立內部 Container Registry。

## 9. 安全更新

Offline Bundle 是不可變版本快照。每次升級建議重新產生：

1. 新版 Installer。
2. 新版 Docker RPM 與依賴。
3. 核准版本的 GitLab、Runner、PostgreSQL Image。
4. 新 SHA-256 Manifest。
5. 經變更管理後搬入離線區。

跨 GitLab Major 或 Minor Version 時，須先確認升級路徑並完成備份與還原測試。
