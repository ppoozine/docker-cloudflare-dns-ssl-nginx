## Nginx 日誌管理

此專案包含了 Nginx 日誌管理機制，確保僅保留最近 30 天的日誌，避免日誌佔用過多磁碟空間。

### 內建日誌限制

在 `docker-compose.yml` 中，我們已為 Nginx 容器設置了日誌限制：

```yaml
logging:
  driver: "json-file"
  options:
    max-size: "10m"    # 限制容器日誌大小
    max-file: "3"      # 限制日誌文件數量
```

這設置確保 Docker 引擎會自動限制日誌檔案大小並進行輪替。

### 使用日誌清理腳本

專案提供了 `nginx-log-cleanup.sh` 腳本，用於更全面地管理 Nginx 日誌：

1. **設置腳本**

   修改 `nginx-log-cleanup.sh` 中的變數：
   ```bash
   DOCKER_COMPOSE_DIR="/path/to/your/nginx-service"  # 實際專案路徑
   LOG_RETENTION_DAYS=30                             # 保留天數
   ```

2. **添加執行權限**

   ```bash
   chmod +x nginx-log-cleanup.sh
   ```

3. **設置定期執行**

   ```bash
   crontab -e
   ```

   添加以下行（每週日凌晨1點執行）：
   ```
   0 1 * * 0 /path/to/nginx-log-cleanup.sh >> /path/to/cron.log 2>&1
   ```

### 日誌清理腳本功能

- 對大於 5MB 的訪問日誌進行輪替
- 對大於 2MB 的錯誤日誌進行輪替
- 自動刪除超過 30 天的日誌檔案
- 將容器內日誌備份到宿主機的 `nginx/logs` 目錄

### AWS CloudWatch 整合（選項）

如需將 Nginx 日誌上傳至 AWS CloudWatch，可使用 `nginx-to-cloudwatch.sh` 腳本：

1. **設置腳本**

   修改 `nginx-to-cloudwatch.sh` 中的變數：
   ```bash
   DOCKER_COMPOSE_DIR="/path/to/your/nginx-service"
   LOG_GROUP_NAME="/nginx/production"      # CloudWatch 日誌群組名稱
   LOG_STREAM_PREFIX="nginx-"              # CloudWatch 日誌串流前綴
   AWS_REGION="ap-northeast-1"             # AWS 區域
   ```

2. **設置 AWS 憑證**

   確保已安裝 AWS CLI 並設置了適當的權限：
   ```bash
   aws configure
   ```

3. **設置定期執行**

   ```bash
   crontab -e
   ```

   添加以下行（每小時執行）：
   ```
   0 * * * * /path/to/nginx-to-cloudwatch.sh >> /path/to/cloudwatch.log 2>&1
   ```

使用 CloudWatch 可讓你在 AWS 管理主控台中集中查看和分析日誌，並設置警報和儀表板。

### 注意事項

- 定期檢查 `nginx/logs` 目錄，確保日誌正常輪替
- 如使用 CloudWatch，請確保 EC2 實例具有適當的 IAM 權限
- 在測試環境中先測試日誌管理腳本，確保其按預期工作# Nginx on ARM EC2 with SSL

這個項目提供了在 ARM 架構的 EC2 上部署 Nginx 服務的完整解決方案，包含以下功能：

1. 使用 docker-compose (v4) 部署 Nginx
2. 與 Cloudflare DNS 整合
3. 使用 Let's Encrypt 自動獲取和更新 SSL 憑證
4. 支援內網域名的 SSL 憑證自動更新
5. Nginx 日誌管理及可選的 AWS CloudWatch 整合

## 前置需求

- ARM 架構的 EC2 執行個體 (例如 A1, T4g, C7g 等)
- Docker 與 docker-compose 已安裝
- Cloudflare 帳號並已設定域名
- Cloudflare API Token (Zone:DNS:Edit 權限)
- Cloudflare Zone ID

## 專案架構

```
.
├── docker-compose.yml           # 主要的Docker Compose配置(版本4)
├── setup-ssl.sh                 # 初始化配置脚本
├── default.conf                 # Nginx初始配置模板
├── auto-renew.sh                # 证书自动更新脚本(可选)
├── nginx/
│   ├── conf.d/
│   │   └── default.conf         # 实际使用的Nginx配置
│   └── html/
│       └── index.html           # 示例网页(由setup-ssl.sh生成)
└── certbot/
    ├── conf/                    # 证书存储位置
    │   ├── cloudflare.ini       # Cloudflare API配置
    │   ├── live/                # 活跃证书目录
    │   ├── renewal/             # 证书续期配置目录
    │   │   └── .updated         # 证书更新标记文件(由certbot生成)
    │   └── archive/             # 历史证书存档
    ├── www/                     # ACME验证目录
    └── logs/                    # 证书操作日志
```

## 服務架構

這個專案採用三個容器的設計：

1. **nginx** - 提供 Web 服務，處理 HTTP/HTTPS 請求
2. **certbot** - 負責獲取和更新 SSL 憑證
3. **certbot-watcher** - 監控憑證更新，並在需要時重載 Nginx

這種設計可確保容器各司其職，同時保證憑證更新後 Nginx 能正確重載配置。

## 設定步驟

### 1. 準備環境

```bash
git clone https://github.com/your-username/nginx-ssl-arm-ec2.git
cd nginx-ssl-arm-ec2
```

### 2. 設定域名和 Cloudflare 認證

編輯 `setup-ssl.sh` 檔案，替換以下變數：

```bash
DOMAIN="your-domain.com"         # 您的域名
EMAIL="your-email@example.com"   # 您的電子郵件地址
CF_API_TOKEN="your-api-token"    # 您的 Cloudflare API Token
```

### 3. 執行設定腳本

```bash
chmod +x setup-ssl.sh
./setup-ssl.sh
```

此腳本會：
- 創建必要的目錄結構
- 設定 Cloudflare DNS 認證
- 使用 DNS 驗證方式獲取 Let's Encrypt 憑證（包括通配符憑證）
- 準備 Nginx 配置

### 4. 啟動服務

```bash
docker-compose up -d
```

## 支援多個子域名

如果您有多個子域名（例如 www.example.com, admin.example.com 等），您只需要獲取一次通配符證書。在 `setup-ssl.sh` 中已經配置了 `-d *.$DOMAIN` 參數，這會為所有子域名申請一個通配符證書。

對於多個子域名，您需要在 Nginx 配置中添加多個 server 區塊。您可以編輯 `nginx/conf.d/default.conf` 添加更多的 server 區塊，每個子域名一個。

## 內網域名證書更新

對於內網域名（如 192.168.X.X），系統使用 Cloudflare DNS 驗證方式來獲取和更新證書，這種方式不需要公網可達，非常適合內網環境。

證書自動更新流程：
1. certbot 容器定期嘗試更新證書（每12小時）
2. 更新成功後創建標記文件 `.updated`
3. certbot-watcher 容器檢測到標記文件並重載 Nginx

## 故障排除

### Nginx 無法啟動

如果 Nginx 因為找不到 SSL 證書而無法啟動，確保先運行 `setup-ssl.sh` 腳本：

```bash
docker-compose down
./setup-ssl.sh
docker-compose up -d
```

### 證書獲取失敗

檢查 Cloudflare API Token 是否有正確的權限：

```bash
cat certbot/logs/letsencrypt.log
```

### certbot-watcher 無法重載 Nginx

確保 Docker socket 正確掛載且有訪問權限：

```bash
docker logs certbot-watcher
```

如果看到權限錯誤，可能需要調整 Docker 的組權限。

## 安全注意事項

1. 請妥善保護您的 Cloudflare API Token
2. `cloudflare.ini` 文件的權限應設為 600（只有文件所有者可讀寫）
3. 確保 EC2 安全組僅允許必要的端口訪問（80/443）

## 使用 auto-renew.sh 自動更新腳本

除了容器內建的自動更新機制外，我們還提供了 `auto-renew.sh` 腳本作為額外的保障機制，特別適合於內網環境和生產系統。

### 設置步驟

1. **編輯腳本參數**

   修改 `auto-renew.sh` 中的以下參數：
   ```bash
   DOMAIN="your-domain.com"                # 你的域名
   EMAIL="your-email@example.com"          # 你的電子郵件
   CF_API_TOKEN="your-cloudflare-api-token" # Cloudflare API令牌
   DOCKER_COMPOSE_DIR="/path/to/project"   # 專案路徑
   ```

2. **添加執行權限**

   ```bash
   chmod +x auto-renew.sh
   ```

3. **設置定期執行**

   使用 crontab 設置定期執行：
   ```bash
   crontab -e
   ```

   添加以下行（每月1號和15號凌晨3點執行）：
   ```
   0 3 1,15 * * /path/to/auto-renew.sh >> /path/to/cron.log 2>&1
   ```

### 為什麼需要這個腳本？

這個腳本提供了以下好處：

- **雙重保障**：為憑證更新提供額外的保障機制
- **定期強制更新**：不管容器內的自動更新是否成功
- **適合內網環境**：特別針對內網伺服器優化
- **詳細日誌**：提供更詳細的更新過程記錄
- **獨立於容器**：即使容器出現問題也能工作

## 其他資訊

- Let's Encrypt 證書有效期為 90 天
- 系統設定為每 12 小時自動檢查更新一次
- 通配符證書可覆蓋所有子域名（*.example.com）
- `auto-renew.sh` 腳本建議每月執行1-2次，作為額外的保障機制