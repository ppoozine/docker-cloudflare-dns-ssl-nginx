# docker-cloudflare-dns-ssl-nginx

在 Docker（ARM / x86 皆可）上部署 Nginx + Let's Encrypt SSL，使用 Cloudflare DNS-01 取得**通配符證書**，自動續期、自動重載。

適合：個人站、內網服務、無法暴露於公網的伺服器。

## 前置需求

- Docker 與 Docker Compose v2 (`docker compose`)
- 已託管於 Cloudflare 的網域
- Cloudflare API Token（權限：`Zone:DNS:Edit`，限定到對應 Zone）

## 快速開始

```bash
cp .env.example .env
# 編輯 .env 填入 DOMAIN / EMAIL / CF_API_TOKEN

# 強烈建議：先用 staging 端點測試（不會撞 Let's Encrypt rate limit）
./setup-ssl.sh --staging

# 確認 staging 流程 OK 後，刪掉 staging 證書再申請正式的
rm -rf certbot/conf/live certbot/conf/archive certbot/conf/renewal
./setup-ssl.sh

docker compose up -d
```

### `setup-ssl.sh` 參數

| 參數 | 用途 |
|------|------|
| `--staging` | 用 Let's Encrypt staging 端點。沒有 rate limit，但證書瀏覽器不信。**Debug 時必用** |
| `--force` | 即使證書已存在仍重新申請。**會消耗正式 rate limit（5/週/域名）** |
| `--help` | 印出說明 |

預設行為：偵測到 `certbot/conf/live/${DOMAIN}/fullchain.pem` 已存在就跳過申請，不會浪費 rate limit。

## 架構

```
┌─────────┐         ┌──────────┐         ┌──────────────────┐
│ certbot │ touch   │ /signal/ │  poll   │ certbot-watcher  │
│ (renew  ├────────►│ reload   │◄────────┤ (docker exec     │
│  12h)   │         │          │         │  nginx reload)   │
└─────────┘         └──────────┘         └────────┬─────────┘
                                                   │
                                                   ▼
                                          ┌──────────────────┐
                                          │  docker-proxy    │
                                          │  (限制只能 exec) │
                                          └────────┬─────────┘
                                                   │
                                                   ▼
                                          /var/run/docker.sock
```

| 容器 | 鏡像 | 角色 |
|------|------|------|
| `nginx` | `nginx:1.27-alpine` | 對外服務 HTTP/HTTPS，啟動時用 `envsubst` 渲染 `default.conf.template` |
| `certbot` | `certbot/dns-cloudflare:v2.11.0` | 每 12h 嘗試 `certbot renew`（DNS-01，無 propagation 短於 30s 的風險） |
| `docker-proxy` | `tecnativa/docker-socket-proxy:0.3.0` | 限制 watcher 能呼叫的 docker API（只開放 exec、containers、post） |
| `certbot-watcher` | `docker:24-cli` | 偵測 `/signal/reload` 標記檔，透過 docker-proxy 呼叫 `nginx -s reload` |

### 為什麼有 `docker-proxy`？

直接把 `/var/run/docker.sock` 掛進 watcher = watcher 被攻破就 = host root。`docker-socket-proxy` 是個白名單代理，只允許 watcher 呼叫 `POST /containers/.../exec`，無法 create / delete / pull 其他東西。

### 為什麼用 envsubst 而不是 sed？

nginx 官方 alpine 鏡像啟動時會自動處理 `/etc/nginx/templates/*.template` → `/etc/nginx/conf.d/*.conf`，把 `${DOMAIN}` 之類的環境變數替換掉。好處：

- 改 `default.conf.template` 後重啟 nginx 立刻生效，不會有「忘了同步 nginx/conf.d/...」的飄移問題
- 不需要在初始化腳本裡寫平台相依的 `sed -i`
- `nginx` 變數 `$host`、`$uri` 不會被替換（envsubst 只認 `${...}` 帶大括號的）

## 為什麼用 DNS 驗證

- **支援通配符**：HTTP-01 / webroot **不支援** `*.example.com`
- **不需要公網可達**：內網伺服器也能拿到正式證書
- **一張證書涵蓋所有子域名**：新子域名不用重申請

## 新增子域名

通配符證書已涵蓋所有子域名，只需在 `default.conf.template` 加 `server` 區塊：

```nginx
server {
    listen 443 ssl;
    server_name api.${DOMAIN};
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    # ...
}
```

然後 `docker compose restart nginx`。

## 證書到期監控（強烈建議）

容器內續期可能靜默失敗（API token 失效、CF 改 API、容器被 OOM 等）。**一定要**設外部監控：

### 方法 A：用內建腳本 + cron

```bash
chmod +x check-cert-expiry.sh

# 每日早上 9 點檢查
crontab -e
0 9 * * * cd /path/to/project && ./check-cert-expiry.sh
```

剩餘 < 14 天會 exit 1（搭配 cron 的 MAILTO 即可收到通知）。

### 方法 B：搭配 healthchecks.io（免費，推薦）

```bash
# 在 cron 中設定環境變數
0 9 * * * cd /path/to/project && \
    HEALTHCHECK_URL='https://hc-ping.com/xxx-xxx-xxx' \
    HEALTHCHECK_FAIL_URL='https://hc-ping.com/xxx-xxx-xxx/fail' \
    ./check-cert-expiry.sh
```

healthchecks.io 在沒收到心跳時會主動通知你（email / Slack / Discord）。

## 日誌

Docker 的 `json-file` driver 已設定自動輪替（10MB × 3 檔）。

若要集中式日誌，建議使用 Docker 內建 driver 而非自寫腳本：
- AWS CloudWatch → `awslogs` driver
- Loki → `loki` driver
- Fluentd → `fluentd` driver

## 故障排除

### Nginx 起不來，報找不到證書

`setup-ssl.sh` 沒成功跑過：
```bash
ls certbot/conf/live/${DOMAIN}/
# 應該要有 fullchain.pem、privkey.pem、chain.pem
```

### 證書沒有續期

```bash
docker logs certbot
cat certbot/logs/letsencrypt.log
```
常見：API Token 權限不足或過期（需要 `Zone:DNS:Edit`）。

### Nginx 沒有自動 reload

```bash
docker logs certbot-watcher
```
如果看到 connection refused，是 `docker-proxy` 沒起來：`docker compose restart docker-proxy`。

### 手動強制續期（測試用）

```bash
docker compose exec certbot certbot renew --force-renewal \
    --dns-cloudflare \
    --dns-cloudflare-credentials /run/secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30
```

### 撞到 Let's Encrypt rate limit

正式端點每個域名一週 5 張同 SAN 證書。如果在 debug，**改用 `--staging`**。被鎖時可在 [crt.sh](https://crt.sh) 查看已發行記錄。

## 安全注意事項

- `.env` 由 `setup-ssl.sh` 自動 `chmod 600`
- `cloudflare.ini` 放在 `certbot/secrets/`（**不在** `certbot/conf/`），不會被 nginx 容器讀到
- Docker socket 透過 `docker-socket-proxy` 限縮權限
- 安全群組 / 防火牆只開放 80（ACME 重導）與 443
- API Token **必須**綁定特定 Zone，不要用 Global API Key
