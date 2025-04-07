#!/bin/bash

# 設置參數
DOMAIN="example.com"
EMAIL="email@example.com"
CF_API_TOKEN="cloudflare-api-token" # Zone DNS Token


# 建立目錄
mkdir -p nginx/conf.d
mkdir -p nginx/html
mkdir -p certbot/conf
mkdir -p certbot/www
mkdir -p certbot/logs
mkdir -p certbot/conf/renewal

# 複製默認設定文件到nginx設定目錄
if [ ! -f nginx/conf.d/$DOMAIN.conf ]; then
    cp default.conf nginx/conf.d/$DOMAIN.conf
fi

# 建立 Cloudflare 憑證文件
cat > certbot/conf/cloudflare.ini << EOF
dns_cloudflare_api_token = $CF_API_TOKEN
EOF
chmod 600 certbot/conf/cloudflare.ini

# 為内網域名生成SSL憑證
# 使用DNS驗證方式，這樣内網域名也可以獲取證書
docker run -it --rm \
  -v $(pwd)/certbot/conf:/etc/letsencrypt \
  -v $(pwd)/certbot/logs:/var/log/letsencrypt \
  -e CF_API_TOKEN=$CF_API_TOKEN \
  certbot/dns-cloudflare:latest certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d $DOMAIN \
  -d *.$DOMAIN \
  --email $EMAIL \
  --agree-tos \
  --no-eff-email \
  --server https://acme-v02.api.letsencrypt.org/directory

# 建立證書更新的 Hook Script
cat > certbot/conf/renewal-hooks/post/reload-nginx.sh << EOF
#!/bin/sh
touch /etc/letsencrypt/renewal/.updated
EOF
chmod +x certbot/conf/renewal-hooks/post/reload-nginx.sh

# 建立更新標記的目錄
mkdir -p certbot/conf/renewal/

# 替换 Nginx 設定文件中的域名
# 根據系統類型使用不同的 sed 命令
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/example.com/$DOMAIN/g" nginx/conf.d/$DOMAIN.conf
else
    # Linux
    sed -i "s/example.com/$DOMAIN/g" nginx/conf.d/$DOMAIN.conf
fi

# 建立範例HTML網頁
echo "<html><body><h1>Hello from Nginx on ARM!</h1></body></html>" > nginx/html/index.html

echo "Setup completed. Now you can run docker-compose up -d"