# 統一安裝說明

`install.sh` 是線上與離線部署的共同入口，透過 `--mode` 明確選擇資料來源。

## 1. 模式判定

### 線上模式

```bash
sudo bash install.sh \
  --mode online \
  --host gitlab.example.com
```

線上模式會：

1. 使用系統 DNF Repository 安裝基礎套件。
2. 加入 Docker 官方 RPM Repository。
3. 安裝 Docker Engine 與 Compose Plugin。
4. Pull 固定版本 Container Image。
5. 建立 PostgreSQL、GitLab 與 Runner。

### 離線模式

```bash
sudo bash install.sh \
  --mode offline \
  --offline-bundle /media/usb/gitlab-offline-bundle-v1.4.0 \
  --host gitlab.example.com
```

離線模式會：

1. 先驗證 Bundle 的 SHA-256、版本、OS Major 與架構。
2. 使用 `dnf --disablerepo='*'` 安裝 Bundle RPM。
3. 使用 `docker load` 載入 Bundle Image。
4. 使用 `docker compose up --pull never` 啟動服務。
5. 不執行 `docker compose pull`。

## 2. 參數驗證規則

| 組合 | 結果 |
|---|---|
| `--mode online` | 正常線上安裝 |
| 無 `--mode` | 預設線上安裝 |
| `--mode offline --offline-bundle PATH` | 正常離線安裝 |
| `--mode offline` 但無 Bundle | 立即停止 |
| `--mode online --offline-bundle PATH` | 立即停止 |
| 僅 `--offline-bundle PATH` | 相容模式：推斷 offline 並顯示警告 |

## 3. 通用範例

自訂 Port：

```bash
sudo bash install.sh \
  --mode online \
  --host gitlab.example.com \
  --http-port 8080 \
  --ssh-port 2222
```

8 GB RAM：

```bash
sudo bash install.sh \
  --mode online \
  --host gitlab.example.com \
  --low-memory
```

安裝時直接註冊 Runner：

```bash
sudo bash install.sh \
  --mode online \
  --host gitlab.example.com \
  --runner-token 'glrt-xxxxxxxxxxxxxxxx'
```

## 4. 安裝前檢查

- Rocky Linux 9.x x86_64。
- DNS 名稱已建立，或已規劃稍後建立。
- TCP 80 與 2222 未被占用，或指定其他 Port。
- 建議至少 8 GB RAM、60 GB 可用空間；正式環境建議更高。
- 確認 Podman/Buildah/runc 是否可移除。
- 確認 `/srv/gitlab-stack` 不含既有正式資料。

## 5. 安裝後檢查

```bash
sudo /srv/gitlab-stack/scripts/verify-install.sh
sudo /srv/gitlab-stack/scripts/status.sh
```

```bash
cd /srv/gitlab-stack
docker compose ps
```

## 6. 重裝

安裝程式不覆寫既有 Stack。需要乾淨重裝時：

```bash
sudo bash uninstall.sh \
  --stack-dir /srv/gitlab-stack \
  --purge-data \
  --yes
```

此操作不可復原，正式資料應先完成異機備份。
