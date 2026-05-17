# CLAUDE.md

給 Claude Code 的專案備忘錄。

## 專案用途

在 Docker 上部署 Nginx + Let's Encrypt SSL 的腳手架。使用 Cloudflare DNS-01 驗證以支援**通配符證書**與**內網域名**（伺服器不必從公網可達）。

定位：學習用 / 自架站。**不是** turnkey 解決方案 — 若只想可靠長期跑而不在乎內部運作，考慮 Caddy。

## 架構（四容器）

| 容器 | 鏡像 | 角色 |
|------|------|------|
| `nginx` | `nginx:1.27-alpine` | 對外服務；啟動時用 envsubst 渲染 `default.conf.template` |
| `certbot` | `certbot/dns-cloudflare:v2.11.0` | 每 12h `certbot renew` |
| `docker-proxy` | `tecnativa/docker-socket-proxy:0.3.0` | 限縮 watcher 對 docker daemon 的存取權 |
| `certbot-watcher` | `docker:24-cli` | 偵測 `/signal/reload`，透過 docker-proxy reload nginx |

### 通訊流程

```
certbot renew 成功
  → renewal-hooks/post/reload-nginx.sh
  → touch /signal/reload         (在 ./certbot/signal/ 的共享 volume)
  → certbot-watcher 每 30s 偵測
  → docker exec nginx nginx -s reload (透過 docker-proxy)
  → 成功才 rm /signal/reload；失敗下次重試
```

### 為什麼用 envsubst

`nginx:alpine` 的官方 entrypoint 會把 `/etc/nginx/templates/*.template` 透過 envsubst 渲染到 `/etc/nginx/conf.d/`。本專案把根目錄的 `default.conf.template` 掛到 templates 目錄，`${DOMAIN}` 從 `.env` 經 `env_file:` 注入。

好處：**消除模板飄移問題**。改 template 後 `docker compose restart nginx` 立即生效，不會有「忘了同步 nginx/conf.d/...」的狀況。`$host`、`$uri` 等 nginx 變數不會被替換，因為 envsubst 只認 `${...}`。

### 為什麼有 docker-proxy

watcher 需要呼叫 `docker exec nginx nginx -s reload`。直接掛 `/var/run/docker.sock` = watcher 被攻破 = host root。`tecnativa/docker-socket-proxy` 是白名單代理，只開放 `CONTAINERS / POST / EXEC` API 端點。對 watcher 來說透明（透過 `DOCKER_HOST=tcp://docker-proxy:2375`）。

## 關鍵設計決策（不要倒回去）

- **必須用 `certbot/dns-cloudflare`**，不是 `certbot/certbot`。後者沒有 cloudflare 插件，通配符證書會直接失敗
- **必須用 DNS-01**，不能用 webroot/HTTP-01。通配符 ACME 規範強制 DNS-01
- **`cloudflare.ini` 不能放 `certbot/conf/`**。`certbot/conf/` 整個會被 nginx `:ro` 掛載；若 token 在裡面，nginx 被攻破就洩漏。放 `certbot/secrets/` 並單獨掛給 certbot
- **renew loop 必須帶 `--dns-cloudflare-propagation-seconds 30`**。預設 10s 對 Cloudflare 全球傳播不夠
- **reload 失敗時不要刪 signal 檔**。`docker exec nginx -s reload` 失敗（daemon hiccup / nginx 異常）就要留著等下次重試
- **不要重複設定 reload 機制**。`renewal-hooks/post/` 目錄一個就夠了，不要再加 `--post-hook` 旗標（兩個觸發點維護者會搞糊塗）
- **不要在 nginx 容器加 reload loop**。watcher 已負責，多加只是雜訊
- **不要再加 `ssl_stapling on`**。Let's Encrypt 從 2024 年中起發的 leaf cert 已不再內嵌 OCSP responder URL，加了會出現 `"ssl_stapling" ignored` 警告。一併不需要 `ssl_trusted_certificate` 與 `resolver`（兩者都是為 OCSP stapling 服務的）
- **nginx healthcheck 要打內部 `/health`**。打 `/` 會被 proxy 到上游 :3000，導致「上游掛 = healthcheck 失敗 = 容器被當成不健康」這種誤判。內部 `location = /health { return 200; }` 才反映 nginx 本身的存活
- **上游服務用 `host.docker.internal` 指到 host**。Linux 上要在 compose 加 `extra_hosts: - "host.docker.internal:host-gateway"`，否則 nginx 容器內這個名稱不解析。**注意**：host 上的服務必須 bind 到 `0.0.0.0` 或 docker bridge IP（如 `172.17.0.1`），bind 在 `127.0.0.1` 從容器看不到
- **不要重新引入下列腳本**：
  - `auto-renew.sh`：certbot service 已正確設定 DNS 驗證
  - `nginx-log-cleanup.sh`：Docker `json-file` driver 已輪替
  - `nginx-to-cloudwatch.sh`：用 logging driver 或 sidecar 取代

## 慣例

- 所有秘密從 `.env` 讀取，絕不寫死
- `.env` 用 line-by-line regex 解析，**不用 `source`**（避免 shell injection）
- 鏡像釘版本，不用 `:latest`
- Bash 腳本一律 `set -euo pipefail` + 變數加引號
- 加新檔案前先想：Docker / nginx 內建是否已解決？（多半是）

## 設定流程

```bash
cp .env.example .env       # 填 DOMAIN / EMAIL / CF_API_TOKEN
./setup-ssl.sh --staging   # 先用 staging 測試
# 確認流程 OK 後：
rm -rf certbot/conf/live certbot/conf/archive certbot/conf/renewal
./setup-ssl.sh             # 正式申請
docker compose up -d
```

setup-ssl.sh 是 idempotent — 偵測到 `certbot/conf/live/${DOMAIN}/fullchain.pem` 就跳過。要強制重發加 `--force`（會消耗 LE rate limit）。

## 證書到期監控

容器內 `certbot renew` 可能靜默失敗 60+ 天。`check-cert-expiry.sh` 是 out-of-band 探針：cron 每天跑一次，剩 < 14 天就 exit 1。可選搭配 healthchecks.io。

**這是必備的，不是可選**。沒有外部監控的話，續期失敗到證書過期之間沒有任何通知。

## 檔案結構

```
.
├── .env.example                    # 環境變數範本
├── .env                            # 實際秘密（gitignored, chmod 600）
├── docker-compose.yml
├── default.conf.template           # nginx 設定模板，啟動時 envsubst 渲染
├── setup-ssl.sh                    # 一次性初始化（含 --staging / --force）
├── check-cert-expiry.sh            # 排程探針（cron 用）
├── README.md
├── CLAUDE.md
├── nginx/                          # gitignored
│   └── html/                       # 靜態檔案
└── certbot/                        # gitignored
    ├── conf/                       # 證書（nginx 唯讀掛載這個）
    ├── secrets/cloudflare.ini      # CF API token（chmod 600，只給 certbot）
    ├── signal/                     # certbot 與 watcher 之間的訊號檔
    ├── www/                        # ACME challenge（DNS-01 下實際用不到）
    └── logs/
```

## 修改時的檢查清單

- [ ] 沒有把秘密寫死在被 commit 的檔案
- [ ] 鏡像版本是釘住的，不是 `:latest`
- [ ] 沒有重新引入「不要重新引入」清單裡的腳本
- [ ] nginx 容器沒有再被加上 reload loop
- [ ] cloudflare.ini 沒有跑回 `certbot/conf/`
- [ ] renew loop 還有 `--dns-cloudflare-propagation-seconds 30`
- [ ] watcher 的 `rm` 還是 conditional on reload success
- [ ] reload 觸發只有一個來源（`renewal-hooks/post/`），沒有重複的 `--post-hook`
- [ ] 改了 `default.conf.template` 後重啟 nginx（不需要動 nginx/conf.d/）
- [ ] **不要嘗試 `docker exec nginx vi /etc/nginx/conf.d/...`**。那個檔是 envsubst 從 template 渲染的臨時檔，重啟就被覆蓋；template 本身也是 `:ro` 掛載。要改 → 改 host 上的 `default.conf.template` → `docker compose restart nginx`
