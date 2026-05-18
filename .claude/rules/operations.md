# Operations

## Cert expiry monitoring (required)

`certbot renew` can fail silently for 60+ days (token revoked, CF API
change, container OOM, the host's clock drifts). The flow has no built-in
notification on renewal failure. **External monitoring is not optional.**

Local cron, all-domains check:

```cron
0 9 * * * cd /path/to/project && ./check-cert-expiry.sh
```

With healthchecks.io (the cron itself can also fail silently):

```cron
0 9 * * * cd /path/to/project && \
    HEALTHCHECK_URL='https://hc-ping.com/...' \
    HEALTHCHECK_FAIL_URL='https://hc-ping.com/.../fail' \
    ./check-cert-expiry.sh
```

The script discovers domains from `certbot/conf/live/*` automatically. Pass
specific domains as args to override (`./check-cert-expiry.sh kao-bar.com`).

## Reading logs

```bash
docker logs nginx --tail 50           # request log + nginx notices
docker logs certbot --tail 50         # renewal attempts
docker logs certbot-watcher --tail 20 # reload signaling
cat certbot/logs/letsencrypt.log      # detailed certbot output
```

Nginx access logs go to stdout (docker `json-file` rotates at 10MB × 3).
For long-term retention or centralized logging, switch the nginx service's
logging driver — don't write a custom upload script.

## Forcing a renewal

```bash
docker compose exec certbot certbot renew --force-renewal \
    --dns-cloudflare \
    --dns-cloudflare-credentials /run/secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30
```

This burns a slot in Let's Encrypt's rate limit. Use sparingly.

## Backups

Back up `certbot/conf/` weekly. It contains the LE account key and all
issued certs. Losing it means re-registering, which during cert reissue
can run into rate limits.

```bash
tar czf certbot-backup-$(date +%Y%m%d).tar.gz certbot/conf
```

Push to S3 / B2 / wherever.

## Rotating the Cloudflare API token

```bash
$EDITOR .env                # update CF_API_TOKEN
./bootstrap.sh              # rewrites certbot/secrets/cloudflare.ini
docker compose restart certbot
```

The `certbot` container reads `cloudflare.ini` on each `certbot renew`
invocation, so it'll pick up the new token at the next renewal cycle even
without a restart. The restart just makes the change deterministic.

## Removing a domain

```bash
rm nginx/vhosts/<domain>.conf
docker compose up -d --force-recreate nginx
```

Optionally revoke and delete the cert:

```bash
docker compose exec certbot certbot revoke \
    --cert-path /etc/letsencrypt/live/<domain>/fullchain.pem \
    --reason cessationofoperation
docker compose exec certbot certbot delete --cert-name <domain>
```

Or just leave the cert in place — it'll expire naturally and stop renewing
if nothing references it (certbot still tries to renew via the `renewal/`
directory configs, so to actually stop renewal, also remove
`certbot/conf/renewal/<domain>.conf`).

## Restarting cleanly

```bash
docker compose down                   # stop and remove containers (volumes/data persist)
docker compose up -d                  # come back up
```

Bind-mounted dirs (`certbot/`, `nginx/`) survive `down -v` because they're
host paths, not docker volumes.

## When to nuke and recreate

If something feels wrong about the stack itself (not the host) — e.g.
mysterious socket errors, watcher can't reach docker-proxy — try:

```bash
docker compose down
docker compose pull
docker compose up -d
```

This re-pulls pinned images and recreates everything. Certs persist
(they're in `certbot/conf/`).

## Healthcheck flap debugging

If `docker compose ps` shows nginx alternating healthy/unhealthy:

```bash
docker inspect nginx --format='{{json .State.Health}}' | python3 -m json.tool
```

The `Log` array has the last few probe results. ExitCode 0 = healthy probe.
Non-zero with timing pattern usually means slow upstream or DNS resolution
delays inside the container. Increase `interval` or `timeout` in compose
if it's persistent.
