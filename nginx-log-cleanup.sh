#!/bin/bash

# Nginx日誌清理腳本 - 僅保留最近30天的Nginx日誌
# 可設置為定期執行，例如每週執行一次

# 設置變數
DOCKER_COMPOSE_DIR="/path/to/your/nginx-service"  # 請修改為你的實際路徑
LOG_RETENTION_DAYS=30                            # 日誌保留天數

echo "[$(date '+%Y-%m-%d %H:%M:%S')] 開始清理Nginx日誌，保留最近 ${LOG_RETENTION_DAYS} 天..."

# 確保日誌目錄存在
mkdir -p "${DOCKER_COMPOSE_DIR}/nginx/logs"

# 檢查Nginx容器是否運行
if docker ps | grep -q nginx; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清理Nginx容器日誌..."

    # 移動當前日誌到外部存儲，以便能夠刪除舊日誌
    docker exec nginx bash -c "
        # 建立備份目錄
        mkdir -p /var/log/nginx/archive

        # 對存取日誌進行輪替 (如果超過5MB)
        if [ -f /var/log/nginx/access.log ] && [ \$(stat -c%s /var/log/nginx/access.log) -gt 5242880 ]; then
            mv /var/log/nginx/access.log /var/log/nginx/archive/access-\$(date +%Y%m%d%H%M%S).log
            touch /var/log/nginx/access.log
            nginx -s reopen
        fi

        # 對錯誤日誌進行輪替 (如果超過2MB)
        if [ -f /var/log/nginx/error.log ] && [ \$(stat -c%s /var/log/nginx/error.log) -gt 2097152 ]; then
            mv /var/log/nginx/error.log /var/log/nginx/archive/error-\$(date +%Y%m%d%H%M%S).log
            touch /var/log/nginx/error.log
            nginx -s reopen
        fi

        # 刪除超過30天的存檔日誌
        find /var/log/nginx/archive -type f -name '*.log' -mtime +${LOG_RETENTION_DAYS} -delete
    "

    # 將Nginx日誌從容器中複製到主機
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 將Nginx日誌複製到主機存儲..."
    docker cp nginx:/var/log/nginx/archive/ "${DOCKER_COMPOSE_DIR}/nginx/logs/" 2>/dev/null || echo "沒有日誌需要復制或複製過程中出錯"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx容器未運行，無法清理容器內日誌"
fi

# 清理主機上的舊日誌
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清理主機上的舊Nginx日誌..."
find "${DOCKER_COMPOSE_DIR}/nginx/logs" -type f -name "*.log" -mtime +${LOG_RETENTION_DAYS} -delete

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Nginx日誌清理完成!"
exit 0