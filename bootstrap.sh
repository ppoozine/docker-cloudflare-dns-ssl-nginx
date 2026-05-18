#!/bin/bash
# One-time bootstrap: create the directory layout, write Cloudflare
# credentials, install the certbot renewal hook, and create a sample
# index.html. Idempotent — safe to re-run.
#
# After this completes, use `./add-domain.sh <domain>` for each domain
# you want to serve.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f .env ]; then
    echo "Error: .env not found. Run: cp .env.example .env (and fill in values)" >&2
    exit 1
fi
chmod 600 .env

# Line-by-line .env parser (avoids `source` running arbitrary shell code)
load_env() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            export "$key=$value"
        fi
    done < "$file"
}
load_env .env

: "${EMAIL:?EMAIL not set in .env}"
: "${CF_API_TOKEN:?CF_API_TOKEN not set in .env}"

mkdir -p \
    nginx/html \
    certbot/conf \
    certbot/www \
    certbot/logs \
    certbot/secrets \
    certbot/signal \
    certbot/conf/renewal-hooks/post

# Cloudflare credentials live OUTSIDE certbot/conf/ so that the nginx :ro
# mount of certbot/conf can't expose the token to the public-facing container.
cat > certbot/secrets/cloudflare.ini <<EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
chmod 600 certbot/secrets/cloudflare.ini

# Renewal hook signals certbot-watcher via shared volume (not certbot's own
# internal dirs, which could collide with future certbot file names).
cat > certbot/conf/renewal-hooks/post/reload-nginx.sh <<'EOF'
#!/bin/sh
touch /signal/reload
EOF
chmod +x certbot/conf/renewal-hooks/post/reload-nginx.sh

if [ ! -f nginx/html/index.html ]; then
    cat > nginx/html/index.html <<'EOF'
<!doctype html>
<html><body><h1>It works.</h1></body></html>
EOF
fi

echo "Bootstrap complete."
echo
echo "Next steps:"
echo "  1. ./add-domain.sh <your-domain.com>         # issue cert and create vhost"
echo "  2. customize nginx/vhosts/<your-domain.com>.conf (set upstream)"
echo "  3. docker compose up -d"
