# docker-cloudflare-dns-ssl-nginx

A small, opinionated stack for running Nginx with Let's Encrypt SSL on a single
Docker host (ARM or x86). It uses Cloudflare DNS-01 validation so it supports
**wildcard certs** and **origins that aren't reachable from the public internet**
(internal services, EC2 behind a strict security group, etc.).

This repo is intentionally scoped to be a learning-grade scaffold — not a
turnkey product. If you just want "set it and forget it," consider Caddy. If
you want to understand how nginx + certbot + reverse proxying actually fit
together, this is for you.

## What you get

- Nginx serving any number of vhosts, each in its own `nginx/vhosts/<domain>.conf`
- Wildcard Let's Encrypt certs via Cloudflare DNS-01, refreshed automatically
- Self-healing renewal flow with a docker-socket-proxy in front of the reload watcher
- A reverse-proxy pattern for forwarding to apps on the host (`host.docker.internal:<port>`)
- An external cert-expiry probe (`check-cert-expiry.sh`) for catching silent failures

## Prerequisites

- Docker and Docker Compose v2 (`docker compose`)
- A domain on Cloudflare
- A Cloudflare API token scoped to `Zone:DNS:Edit` for that zone (NOT the Global API Key)

## Running it

### Fresh deploy

```bash
git clone <repo> && cd docker-cloudflare-dns-ssl-nginx

# 1. Set secrets
cp .env.example .env
$EDITOR .env                          # EMAIL, CF_API_TOKEN

# 2. One-time bootstrap (dirs + cloudflare.ini + renewal hook + sample html)
./bootstrap.sh

# 3. Add your first domain (issues wildcard cert + scaffolds the vhost)
./add-domain.sh example.com           # defaults: host.docker.internal:3000

# 4. (optional) Review and edit the generated vhost
$EDITOR nginx/vhosts/example.com.conf

# 5. Start the stack
docker compose up -d
```

Before opening port 443 to the public internet:
- AWS / firewall: allow inbound 80 and 443 to this host
- Cloudflare DNS: point your domain at this host's IP
  - "Proxied" (orange cloud): set SSL/TLS mode to **Full (strict)** in CF
  - "DNS only" (gray cloud): simpler, but exposes the origin IP

### Updating after a `git pull`

```bash
cd ~/<project-dir>
git pull

# Compose definition changes (image versions, healthcheck, etc.):
docker compose up -d

# Pure config changes (snippets, vhosts) — compose can't see them since
# they're bind-mounted, so force-recreate nginx to re-read:
docker compose up -d --force-recreate nginx
```

When in doubt, `--force-recreate nginx` is always safe.

### Adding another domain to a running stack

```bash
./add-domain.sh another.example.com --upstream-port 4000
$EDITOR nginx/vhosts/another.example.com.conf
docker compose up -d --force-recreate nginx
```

### Verifying the deploy

```bash
# All four containers up, nginx is "healthy"
docker compose ps

# Nginx config parses cleanly inside the container
docker exec nginx nginx -t

# Healthcheck history
docker inspect nginx --format='{{json .State.Health}}' | python3 -m json.tool

# Internal liveness probe (doesn't hit the upstream)
curl -kI https://localhost/health -H "Host: example.com"

# Real cert path through public DNS
curl -I https://example.com
```

If nginx is `unhealthy`, check `docker logs nginx`. If `curl https://example.com`
returns `403 server: cloudflare`, see Troubleshooting below — the most common
cause is **not** Cloudflare bot protection.

### Customizing the upstream

```bash
# Different port on the host
./add-domain.sh app.example.com --upstream-port 8080

# Another container (must share a docker network with nginx)
./add-domain.sh api.example.com --upstream-host api-svc --upstream-port 8080

# Internal IP on another machine
./add-domain.sh foo.com --upstream-host 10.0.0.5 --upstream-port 8080

# Append a sub-path to the upstream URL (request /users → upstream /v1/users)
./add-domain.sh foo.com --upstream-port 3000 --upstream-path /v1/

# All flags combined
./add-domain.sh foo.com \
    --upstream-host 10.0.0.5 \
    --upstream-port 8080 \
    --upstream-path /api/
```

For more complex layouts (mix static + proxy, route paths to different
backends, rate limiting, IP allowlists), the generated vhost includes a
cookbook of commented examples — uncomment and edit them.

### Adding more domains later

```bash
./add-domain.sh another-domain.com --upstream-port 4000
$EDITOR nginx/vhosts/another-domain.com.conf
docker compose up -d --force-recreate nginx       # picks up new vhost
```

Each call to `add-domain.sh`:
- issues a wildcard cert (skipped if one already exists; `--force` to override)
- scaffolds `nginx/vhosts/<domain>.conf` from `nginx/vhosts/_example.conf.example`
- never overwrites an existing vhost file (use `--force-vhost` for that)

### Testing without burning rate limit

```bash
./add-domain.sh test.example.com --staging
```

Staging certs aren't browser-trusted but you can issue them unlimited times.
When you're happy with the flow, clear the staging cert and reissue without
`--staging`:

```bash
rm -rf certbot/conf/live/test.example.com \
       certbot/conf/archive/test.example.com \
       certbot/conf/renewal/test.example.com.conf
./add-domain.sh test.example.com
```

## Architecture

Four containers:

| Container | Image | Role |
|-----------|-------|------|
| `nginx` | `nginx:1.30-alpine` | Public-facing HTTP(S); loads `nginx/vhosts/*.conf` and includes `nginx/snippets/*.conf` |
| `certbot` | `certbot/dns-cloudflare:v5.10.0` | Every 12h runs `certbot renew` (DNS-01) |
| `docker-proxy` | `tecnativa/docker-socket-proxy:3.4` | Whitelist proxy in front of `/var/run/docker.sock` |
| `certbot-watcher` | `docker:29-cli` | Detects renewal signal, asks docker-proxy to `nginx -s reload` |

Renewal flow:

```
certbot renew (success)
  → certbot/conf/renewal-hooks/post/reload-nginx.sh
  → touch /signal/reload (shared volume between certbot and watcher)
  → watcher polls every 30s
  → docker exec nginx nginx -s reload  (via docker-proxy)
  → on success, rm /signal/reload  (on failure, leave it for next cycle)
```

### Why a docker-socket-proxy?

Bind-mounting `/var/run/docker.sock` directly into the watcher gives it root
on the host. The proxy is a tiny daemon that whitelists only the API endpoints
the watcher actually needs (`CONTAINERS`, `POST`, `EXEC`). If the watcher is
compromised, the blast radius is "can run `docker exec`," not "can do
anything to the daemon."

### Why per-domain config files?

Nginx natively `include`s `/etc/nginx/conf.d/*.conf`, so giving each domain
its own file is the standard pattern. Adding a new domain becomes
"new file" instead of "edit a shared template," with no risk of breaking
existing vhosts.

Common settings (SSL, security headers, gzip, proxy headers) live in
`nginx/snippets/*.conf` and are pulled in via `include`. A new vhost is
roughly 25 lines of glue.

## Reverse proxy to host apps

`nginx/vhosts/_example.conf.example` proxies to `http://host.docker.internal:<port>`.
On Linux, that name only resolves because `docker-compose.yml` maps it to
`host-gateway` via `extra_hosts`.

**Your upstream service must bind to `0.0.0.0` (or to the docker bridge IP),
not to `127.0.0.1`.** The host's loopback is not visible to processes inside
the nginx container. Check with:

```bash
ss -tlnp | grep :3000
# Good:  0.0.0.0:3000  /  :::3000
# Bad:   127.0.0.1:3000
```

Rely on your firewall (AWS security group, ufw, etc.) to block external
access to the upstream port — don't lean on `127.0.0.1` binding for security
once nginx is in the picture.

## Cert expiry monitoring (do not skip)

`certbot renew` can fail silently for 60+ days (revoked token, Cloudflare API
change, container OOM). `check-cert-expiry.sh` is an out-of-band probe.

```bash
chmod +x check-cert-expiry.sh

# Local cron — checks every cert in certbot/conf/live/ daily at 9am
crontab -e
0 9 * * * cd /path/to/project && ./check-cert-expiry.sh
```

With [healthchecks.io](https://healthchecks.io) (recommended — the cron
itself can fail silently):

```bash
0 9 * * * cd /path/to/project && \
    HEALTHCHECK_URL='https://hc-ping.com/...' \
    HEALTHCHECK_FAIL_URL='https://hc-ping.com/.../fail' \
    ./check-cert-expiry.sh
```

## Logging

Docker's `json-file` driver is configured for nginx with 10 MB × 3 file
rotation. For centralized logging, prefer a Docker logging driver or a
sidecar over hand-rolled upload scripts:

- AWS CloudWatch → `awslogs` driver
- Loki → `loki` driver
- Generic → fluent-bit / Vector as a sidecar

## Troubleshooting

### Nginx won't start, complains about a missing cert

You probably skipped `./add-domain.sh` for one of the domains referenced in a
vhost file. Check `ls certbot/conf/live/`.

### `HTTP/2 403` with `server: cloudflare`, `cf-mitigated: challenge`

This is almost never Cloudflare's bot detection. The far more common cause
is that **Cloudflare can't reach your origin** — your security group blocks
inbound 443 — so Cloudflare returns its own error page. Check first:

```bash
nc -zv <ec2-ip> 443    # from outside the host
```

If that fails, open inbound 443 in the AWS security group (or equivalent).

### Renewal doesn't happen

```bash
docker logs certbot
cat certbot/logs/letsencrypt.log
```

The common cause is an API token without `Zone:DNS:Edit` permission for the
zone being renewed.

### Reload doesn't happen after renewal

```bash
docker logs certbot-watcher
```

If you see connection refused, `docker-proxy` isn't healthy:
`docker compose restart docker-proxy`.

### Force a renewal for testing

```bash
docker compose exec certbot certbot renew --force-renewal \
    --dns-cloudflare \
    --dns-cloudflare-credentials /run/secrets/cloudflare.ini \
    --dns-cloudflare-propagation-seconds 30
```

### Rate-limited by Let's Encrypt

Production allows 5 duplicate certs per registered domain per week. While
debugging, always use `--staging` first. See issued certs at
[crt.sh](https://crt.sh).

## Security checklist

- `.env` is `chmod 600` and gitignored
- `cloudflare.ini` lives in `certbot/secrets/`, NOT `certbot/conf/` — nginx
  mounts `certbot/conf` read-only, so a compromised nginx container can read
  whatever is in there; the token belongs elsewhere
- `docker-proxy` whitelists exactly the API endpoints the watcher uses
- Cloudflare API token is zone-scoped, not a Global API Key
- Firewall opens only 80 (for ACME HTTP-01 fallback / HTTP-to-HTTPS redirect)
  and 443
- HSTS (`max-age=63072000`) is set in `security-headers.conf` — appropriate
  once you've verified everything works, but be aware browsers will refuse
  plain HTTP for two years afterward

## File map

```
.
├── .env.example                       # template for .env (EMAIL, CF_API_TOKEN)
├── .env                               # actual secrets (gitignored, chmod 600)
├── docker-compose.yml                 # the four-container stack
├── bootstrap.sh                       # one-time: dirs, cloudflare.ini, hook
├── add-domain.sh                      # per-domain: cert + vhost scaffold
├── check-cert-expiry.sh               # cron probe for silent renewal failure
├── nginx/
│   ├── snippets/                      # shared, included by vhosts
│   │   ├── ssl-common.conf
│   │   ├── security-headers.conf
│   │   ├── gzip.conf
│   │   ├── proxy-headers.conf
│   │   └── acme-challenge.conf
│   ├── vhosts/                        # mounted to /etc/nginx/conf.d
│   │   ├── 00-http-globals.conf       # http-scope helpers (loaded first)
│   │   ├── _example.conf.example      # skeleton (not loaded by nginx)
│   │   └── <domain>.conf              # generated by add-domain.sh
│   └── html/                          # static fallback (gitignored)
└── certbot/                           # gitignored entirely
    ├── conf/                          # certs (nginx mounts this read-only)
    ├── secrets/cloudflare.ini         # CF token (chmod 600, certbot only)
    ├── signal/                        # IPC between certbot and watcher
    ├── www/                           # ACME HTTP-01 challenge dir (unused with DNS-01)
    └── logs/
```
