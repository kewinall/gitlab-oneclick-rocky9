# 疑難排解

## GitLab 第一次啟動很久

第一次啟動會執行 Reconfigure 與 Database Migration，可能需數分鐘。

```bash
cd /srv/gitlab-stack
docker compose logs -f --tail=200 gitlab
```

## `password authentication failed for user "gitlab"`

```bash
sudo /srv/gitlab-stack/scripts/ensure-gitlab-db.sh
cd /srv/gitlab-stack
docker compose up -d --force-recreate gitlab
```

## `/-/health` 回傳 404

GitLab 可能依 `external_url` Host Header 路由。請以內建驗證程式判定：

```bash
sudo /srv/gitlab-stack/scripts/verify-install.sh
```

只要 Container Healthy、UI 回應正常且核心服務為 Running，單獨的 `/-/health` 404 不代表安裝失敗。

## Runner 顯示 Offline

```bash
cd /srv/gitlab-stack
docker compose ps gitlab-runner
docker logs --tail=200 gitlab-runner
```

若出現重複 TOML Key：

```bash
sudo /srv/gitlab-stack/scripts/repair-runner.sh
```

## `procReady not received`

通常是 Container Restart 過程立刻執行 `docker exec`。等待數秒後再驗證：

```bash
sleep 5
docker exec gitlab-runner gitlab-runner verify
```

## 離線安裝仍嘗試連外

確認執行方式包含：

```bash
--mode offline --offline-bundle /path/to/bundle
```

查看部署設定：

```bash
grep '^INSTALL_MODE=' /srv/gitlab-stack/.env
```

應為：

```text
INSTALL_MODE=offline
```

## 離線 Pipeline 找不到 Image

```bash
docker image ls
```

將缺少的 Image 加入下一版 Bundle，或在連網環境 `docker save` 後搬入並執行 `docker load`。

## 記憶體不足

```bash
free -h
docker stats --no-stream
journalctl -k --since '-30 min' | grep -Ei 'oom|out of memory|killed process'
```

8 GB 主機應使用 `--low-memory`，並限制 Runner 同時工作數。
