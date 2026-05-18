#!/bin/bash
# Issue a Let's Encrypt wildcard cert for a domain and generate a vhost
# config skeleton. Idempotent: re-running on an existing domain skips cert
# issuance and refuses to overwrite the vhost file (use --force-vhost to
# regenerate from skeleton).
#
# Usage:
#   ./add-domain.sh <domain> [options]
#
# Examples:
#   ./add-domain.sh kao-bar.com
#   ./add-domain.sh app.example.com --upstream-port 8080
#   ./add-domain.sh api.example.com --upstream-host api-svc --upstream-port 8080
#   ./add-domain.sh foo.com --upstream-port 3000 --upstream-path /v1/
#   ./add-domain.sh test.example.com --staging
#
# Notes on --upstream-host:
#   The default `host.docker.internal` reaches the docker host. To target
#   another container, add it to docker-compose.yml on the same network as
#   the nginx service, then pass its service name (e.g. `api-svc`). To target
#   another machine, pass its IP or DNS name — make sure the host's outbound
#   routing reaches it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

usage() {
    cat <<EOF
Usage: $0 <domain> [options]

Options:
  --upstream-host HOST    Upstream hostname (default: host.docker.internal)
                          Use this for cross-container routing, an internal IP,
                          or any non-host destination.
  --upstream-port PORT    Upstream port (default: 3000)
  --upstream-path PATH    Path to append to the upstream URL (default: empty)
                          Must start with /. Usually ends with / too, e.g. /api/.
                          With a trailing /, nginx strips the location prefix.
  --staging               Use Let's Encrypt staging endpoint (no rate limit,
                          untrusted certs — use for testing).
  --force                 Re-issue cert even if one exists (counts against the
                          LE production rate limit: 5/week/domain).
  --force-vhost           Overwrite an existing vhosts/<domain>.conf.
  -h, --help              Show this message.

Examples:
  $0 example.com
  $0 example.com --upstream-port 8080
  $0 example.com --upstream-host api-svc --upstream-port 8080
  $0 example.com --upstream-port 3000 --upstream-path /v1/
EOF
}

DOMAIN=""
UPSTREAM_HOST="host.docker.internal"
UPSTREAM_PORT=3000
UPSTREAM_PATH=""
ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
FORCE=0
FORCE_VHOST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --upstream-host)
            UPSTREAM_HOST="$2"; shift 2 ;;
        --upstream-port)
            UPSTREAM_PORT="$2"; shift 2 ;;
        --upstream-path)
            UPSTREAM_PATH="$2"; shift 2 ;;
        --staging)
            ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
            echo "Using staging ACME server (certs won't be trusted by browsers)"
            shift ;;
        --force)
            FORCE=1; shift ;;
        --force-vhost)
            FORCE_VHOST=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        -*)
            echo "Unknown option: $1" >&2; usage; exit 1 ;;
        *)
            if [ -z "$DOMAIN" ]; then
                DOMAIN="$1"
            else
                echo "Unexpected extra argument: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

if [ -z "$DOMAIN" ]; then
    echo "Error: domain is required" >&2
    usage; exit 1
fi

if ! [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
    echo "Error: '$DOMAIN' does not look like a valid domain" >&2
    exit 1
fi

if ! [[ "$UPSTREAM_PORT" =~ ^[0-9]+$ ]] || [ "$UPSTREAM_PORT" -lt 1 ] || [ "$UPSTREAM_PORT" -gt 65535 ]; then
    echo "Error: --upstream-port '$UPSTREAM_PORT' is not a valid TCP port" >&2
    exit 1
fi

if [ -n "$UPSTREAM_PATH" ] && [[ "$UPSTREAM_PATH" != /* ]]; then
    echo "Error: --upstream-path must start with / (got: '$UPSTREAM_PATH')" >&2
    exit 1
fi

if [ -n "$UPSTREAM_PATH" ] && [[ "$UPSTREAM_PATH" != */ ]]; then
    echo "Warning: --upstream-path '$UPSTREAM_PATH' has no trailing slash." >&2
    echo "         nginx will concatenate the request path without a separator." >&2
    echo "         You probably want '${UPSTREAM_PATH}/'. Continuing anyway." >&2
fi

if [ ! -f .env ]; then
    echo "Error: .env not found. Run ./bootstrap.sh first." >&2
    exit 1
fi

if [ ! -f certbot/secrets/cloudflare.ini ]; then
    echo "Error: certbot/secrets/cloudflare.ini not found. Run ./bootstrap.sh first." >&2
    exit 1
fi

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

# -- Issue cert (skip if already present) ----------------------------------
CERT_DIR="certbot/conf/live/${DOMAIN}"
if [ -f "${CERT_DIR}/fullchain.pem" ] && [ "${FORCE}" -ne 1 ]; then
    echo "Cert already exists for ${DOMAIN} (use --force to reissue)."
else
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
fi

# -- Generate vhost from skeleton ------------------------------------------
VHOST_FILE="nginx/vhosts/${DOMAIN}.conf"
SKELETON="nginx/vhosts/_example.conf.example"

if [ ! -f "${SKELETON}" ]; then
    echo "Error: skeleton ${SKELETON} missing — repo is incomplete." >&2
    exit 1
fi

if [ -f "${VHOST_FILE}" ] && [ "${FORCE_VHOST}" -ne 1 ]; then
    echo "Vhost ${VHOST_FILE} already exists (use --force-vhost to regenerate)."
else
    # Use | as sed delimiter so / in paths doesn't conflict.
    sed -e "s|__DOMAIN__|${DOMAIN}|g" \
        -e "s|__UPSTREAM_HOST__|${UPSTREAM_HOST}|g" \
        -e "s|__UPSTREAM_PORT__|${UPSTREAM_PORT}|g" \
        -e "s|__UPSTREAM_PATH__|${UPSTREAM_PATH}|g" \
        "${SKELETON}" > "${VHOST_FILE}"
    echo "Created ${VHOST_FILE}"
    echo "  upstream: http://${UPSTREAM_HOST}:${UPSTREAM_PORT}${UPSTREAM_PATH}"
fi

echo
echo "Next steps:"
echo "  1. Review nginx/vhosts/${DOMAIN}.conf (uncomment cookbook examples as needed)"
echo "  2. If nginx is already running:  docker compose up -d --force-recreate nginx"
echo "     Otherwise:                     docker compose up -d"
