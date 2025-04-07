#!/bin/bash

# 自動續期內網域名SSL憑證腳本
# 使用Cloudflare DNS驗證方式，適用於無法從公網訪問的伺服器

# 設置變數 - 請根據你的環境修改這些值
DOMAIN="example.com"
EMAIL="your-email@example.com"
CF_API_TOKEN="your-cloudflare-api-token"
DOCKER_COMPOSE_DIR="/path/to/your/nginx-service"  # 你的docker-compose.yml所在目錄

# 日誌函數
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${DOCKER_COMPOSE_DIR}/certbot/logs/auto-renew.log"
}

# 切換到工作目錄
cd "${DOCKER_COMPOSE_DIR}"
if [ $? -ne 0 ]; then
    log "錯誤: 無法切換到工作目錄 ${DOCKER_COMPOSE_DIR}"
    exit 1
fi

log "開始憑證續期過程..."

# 檢查Cloudflare憑證檔案
if [ ! -f "certbot/conf/cloudflare.ini" ]; then
    log "建立Cloudflare憑證檔案..."
    mkdir -p certbot/conf
    cat > certbot/conf/cloudflare.ini << EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
    chmod 600 certbot/conf/cloudflare.ini
fi

# 使用Docker運行Certbot進行憑證續期
log "使用Cloudflare DNS驗證方式續期憑證..."
docker run --rm \
  -v "${DOCKER_COMPOSE_DIR}/certbot/conf:/etc/letsencrypt" \
  -v "${DOCKER_COMPOSE_DIR}/certbot/logs:/var/log/letsencrypt" \
  -e CF_API_TOKEN="${CF_API_TOKEN}" \
  certbot/dns-cloudflare:latest renew \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  --non-interactive \
  --post-hook "touch /etc/letsencrypt/renewal/.updated"

# 檢查續期結果
if [ $? -eq 0 ]; then
    log "憑證續期過程完成，可能已更新憑證"
else
    log "憑證續期過程遇到錯誤，詳情請查看日誌"
    exit 1
fi

# 通知容器重載Nginx配置
log "建立更新標記，通知watcher容器重載Nginx..."
touch certbot/conf/renewal/.updated

# 等待Nginx重載完成
log "等待Nginx重載完成..."
sleep 10

# 檢查Nginx狀態
if docker exec nginx nginx -t &>/dev/null; then
    log "Nginx配置測試通過，服務應該已經重載完成"
else
    log "警告: Nginx配置測試失敗，請手動檢查配置"
fi

log "憑證續期過程全部完成"
exit 0