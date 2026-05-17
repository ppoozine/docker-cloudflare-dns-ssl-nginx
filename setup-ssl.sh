#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

# --- Parse args ---
ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --staging)
            ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
            echo "Using staging ACME server (certs won't be trusted by browsers)"
            ;;
        --force)
            FORCE=1
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [--staging] [--force]

  --staging   Use Let's Encrypt staging endpoint (no rate limit, untrusted certs)
              Use this for testing — switch back to production after success.
  --force     Re-issue cert even if one already exists.
              Counts against LE rate limit (5/week/domain).
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (try --help)" >&2
            exit 1
            ;;
    esac
done

# --- Require .env ---
if [ ! -f .env ]; then
    echo "Error: .env not found. Run: cp .env.example .env (and fill in values)" >&2
    exit 1
fi
chmod 600 .env

# --- Robust .env parser (no `source` — avoids arbitrary code execution) ---
load_env() {
    local file="$1"
    local line key value
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

: "${DOMAIN:?DOMAIN not set in .env}"
: "${EMAIL:?EMAIL not set in .env}"
: "${CF_API_TOKEN:?CF_API_TOKEN not set in .env}"

# --- Create directory structure ---
mkdir -p \
    nginx/html \
    certbot/conf \
    certbot/www \
    certbot/logs \
    certbot/secrets \
    certbot/signal \
    certbot/conf/renewal-hooks/post

# --- Cloudflare credentials (outside certbot/conf so nginx :ro mount can't see it) ---
cat > certbot/secrets/cloudflare.ini <<EOF
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOF
chmod 600 certbot/secrets/cloudflare.ini

# --- Renewal hook: signal watcher via shared volume (not certbot's own dirs) ---
cat > certbot/conf/renewal-hooks/post/reload-nginx.sh <<'EOF'
#!/bin/sh
touch /signal/reload
EOF
chmod +x certbot/conf/renewal-hooks/post/reload-nginx.sh

# --- Sample index.html ---
if [ ! -f nginx/html/index.html ]; then
    cat > nginx/html/index.html <<'EOF'
<!doctype html>
<html><body><h1>It works.</h1></body></html>
EOF
fi

# --- Skip cert issuance if one already exists ---
if [ -f "certbot/conf/live/${DOMAIN}/fullchain.pem" ] && [ "${FORCE}" -ne 1 ]; then
    echo "Cert already exists for ${DOMAIN}."
    echo "Use --force to reissue (counts against Let's Encrypt rate limit)."
    echo "Setup complete. Next: docker compose up -d"
    exit 0
fi

# --- Issue cert via Cloudflare DNS-01 (supports wildcard) ---
docker run --rm \
    -v "${SCRIPT_DIR}/certbot/conf:/etc/letsencrypt" \
    -v "${SCRIPT_DIR}/certbot/logs:/var/log/letsencrypt" \
    -v "${SCRIPT_DIR}/certbot/secrets/cloudflare.ini:/run/secrets/cloudflare.ini:ro" \
    certbot/dns-cloudflare:v2.11.0 certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /run/secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30 \
    -d "${DOMAIN}" \
    -d "*.${DOMAIN}" \
    --email "${EMAIL}" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --server "${ACME_SERVER}"

echo
echo "Setup complete. Next: docker compose up -d"
