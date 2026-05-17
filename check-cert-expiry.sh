#!/bin/bash
# External cert-expiry probe. Run from cron (e.g. daily) to catch silent
# renewal failures. Exit 1 if cert expires within $WARN_DAYS days.
#
# Optional env vars:
#   WARN_DAYS                 (default 14) — alert threshold
#   HEALTHCHECK_URL           — ping on success (e.g. healthchecks.io)
#   HEALTHCHECK_FAIL_URL      — ping on failure
#
# Example cron:
#   0 9 * * * cd /path/to/project && ./check-cert-expiry.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

if [ ! -f .env ]; then
    echo ".env not found" >&2
    exit 1
fi

DOMAIN=$(grep '^DOMAIN=' .env | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")
[ -n "$DOMAIN" ] || { echo "DOMAIN empty in .env" >&2; exit 1; }

WARN_DAYS="${WARN_DAYS:-14}"

EXPIRY=$(echo \
    | openssl s_client -servername "$DOMAIN" -connect "${DOMAIN}:443" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d'=' -f2)

if [ -z "$EXPIRY" ]; then
    echo "Failed to fetch cert for ${DOMAIN}" >&2
    [ -n "${HEALTHCHECK_FAIL_URL:-}" ] && wget -q -O- "$HEALTHCHECK_FAIL_URL" || true
    exit 1
fi

# Portable date parsing (GNU date / BSD date)
if EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null); then
    :
elif EXPIRY_EPOCH=$(date -j -f "%b %e %T %Y %Z" "$EXPIRY" +%s 2>/dev/null); then
    :
else
    echo "Could not parse expiry: $EXPIRY" >&2
    exit 1
fi

NOW=$(date +%s)
DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW) / 86400 ))

echo "Cert for ${DOMAIN} expires in ${DAYS_LEFT} days (${EXPIRY})"

if [ "$DAYS_LEFT" -lt "$WARN_DAYS" ]; then
    echo "WARNING: cert expires in less than ${WARN_DAYS} days" >&2
    [ -n "${HEALTHCHECK_FAIL_URL:-}" ] && wget -q -O- "$HEALTHCHECK_FAIL_URL" || true
    exit 1
fi

[ -n "${HEALTHCHECK_URL:-}" ] && wget -q -O- "$HEALTHCHECK_URL" || true
