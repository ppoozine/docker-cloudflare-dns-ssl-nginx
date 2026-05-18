#!/bin/bash
# External cert-expiry probe. Run from cron (e.g. daily) to catch silent
# renewal failures. Exits 1 if ANY discovered cert expires within WARN_DAYS.
#
# Discovers domains automatically from certbot/conf/live/*/. If you pass
# specific domains as args, only those are checked.
#
# Env vars:
#   WARN_DAYS               (default 14) — alert threshold
#   HEALTHCHECK_URL         — ping on overall success (e.g. healthchecks.io)
#   HEALTHCHECK_FAIL_URL    — ping on any failure
#
# Examples:
#   ./check-cert-expiry.sh
#   ./check-cert-expiry.sh kao-bar.com
#   WARN_DAYS=21 ./check-cert-expiry.sh
#
# Cron example:
#   0 9 * * * cd /path/to/project && ./check-cert-expiry.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

WARN_DAYS="${WARN_DAYS:-14}"

# Discover domains either from args or from issued certs.
if [ $# -gt 0 ]; then
    DOMAINS=("$@")
else
    DOMAINS=()
    if [ -d certbot/conf/live ]; then
        while IFS= read -r d; do
            DOMAINS+=("$(basename "$d")")
        done < <(find certbot/conf/live -mindepth 1 -maxdepth 1 -type d ! -name '*-0*')
    fi
fi

if [ "${#DOMAINS[@]}" -eq 0 ]; then
    echo "No domains to check (no certbot/conf/live/* and no args)." >&2
    exit 1
fi

# Returns 0 if cert OK, 1 if missing or expiring soon.
check_one() {
    local domain="$1"
    local expiry expiry_epoch days_left

    expiry=$(echo \
        | openssl s_client -servername "$domain" -connect "${domain}:443" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | cut -d'=' -f2 || true)

    if [ -z "$expiry" ]; then
        echo "  ${domain}: FAILED to fetch cert" >&2
        return 1
    fi

    if expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null); then
        :
    elif expiry_epoch=$(date -j -f "%b %e %T %Y %Z" "$expiry" +%s 2>/dev/null); then
        :
    else
        echo "  ${domain}: could not parse expiry (${expiry})" >&2
        return 1
    fi

    days_left=$(( (expiry_epoch - $(date +%s)) / 86400 ))
    echo "  ${domain}: ${days_left} days (${expiry})"

    if [ "$days_left" -lt "$WARN_DAYS" ]; then
        echo "  ${domain}: WARNING — expires in less than ${WARN_DAYS} days" >&2
        return 1
    fi
    return 0
}

OVERALL=0
echo "Checking cert expiry (warn threshold: ${WARN_DAYS} days)"
for d in "${DOMAINS[@]}"; do
    if ! check_one "$d"; then
        OVERALL=1
    fi
done

if [ "$OVERALL" -ne 0 ]; then
    [ -n "${HEALTHCHECK_FAIL_URL:-}" ] && wget -q -O- "$HEALTHCHECK_FAIL_URL" >/dev/null || true
    exit 1
fi

[ -n "${HEALTHCHECK_URL:-}" ] && wget -q -O- "$HEALTHCHECK_URL" >/dev/null || true
