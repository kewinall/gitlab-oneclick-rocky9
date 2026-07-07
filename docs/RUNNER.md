# GitLab Runner 使用說明

## 建議範圍

同機部署時優先使用 Project Runner 或 Group Runner，避免所有不受信任專案都可在 GitLab 主機執行 CI Job。

## 註冊

1. 在 GitLab UI 建立 Runner。
2. 取得 `glrt-` 開頭的 Authentication Token。
3. 執行：

```bash
sudo /srv/gitlab-stack/scripts/register-runner.sh \
  'glrt-xxxxxxxxxxxxxxxx'
```

## 驗證

```bash
docker exec gitlab-runner gitlab-runner list
docker exec gitlab-runner gitlab-runner verify
docker logs --tail=100 gitlab-runner
```

## 預設限制

```text
concurrent = 1
CPU = 2
Memory = 4 GB
Privileged = false
Default image = alpine:3.23
Pull policy = if-not-present
```

## Tags

Runner 設定 Tags 時，Job 必須包含相符 Tags：

```yaml
runner-test:
  image: alpine:3.23
  tags:
    - docker
    - linux
  script:
    - echo "runner works"
```

## 離線環境

離線 Runner 不可從 Internet Pull 新 Image。Job Image 必須：

- 建立 Bundle 時以 `--extra-image` 納入。
- 手動 `docker load`。
- 或由內部 Container Registry 提供。

## 修復設定

Runner Offline 且 Log 顯示重複 TOML Key 時：

```bash
sudo /srv/gitlab-stack/scripts/repair-runner.sh
```

修復程式會備份並正規化 `runner/config/config.toml`，不需重新取得 Token。
