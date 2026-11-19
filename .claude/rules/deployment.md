# Deployment

## First-time deploy on a fresh host

```bash
git clone <repo> && cd <repo>

cp .env.example .env
$EDITOR .env                                          # EMAIL, CF_API_TOKEN

./bootstrap.sh                                        # one-time
./add-domain.sh <domain> --upstream-port <N>          # per-domain
$EDITOR nginx/vhosts/<domain>.conf                    # customize proxy target

docker compose up -d
```

Before adding a domain in **production**, smoke-test with `--staging`:

```bash
./add-domain.sh <domain> --staging
# verify the cert lands and the vhost works structurally
rm -rf certbot/conf/live/<domain> \
       certbot/conf/archive/<domain> \
       certbot/conf/renewal/<domain>.conf
./add-domain.sh <domain>                              # production now
```

Staging certs are untrusted by browsers but unlimited in number; production
is 5 duplicate certs/week/domain. Hit that limit and you're locked out for
seven days.

## Updating an existing deploy

```bash
cd ~/<project-dir>
git pull
docker compose up -d                                   # picks up compose changes
# or, if only a vhost or snippet changed:
docker compose up -d --force-recreate nginx
```

`docker compose up -d` recreates only containers whose definition changed.
For changes to `nginx/snippets/*.conf` or `nginx/vhosts/*.conf`, compose
won't detect the diff (the files are bind-mounted, not part of the image),
so `--force-recreate nginx` is required to re-read them.

Alternative for vhost/snippet changes without recreation:
`docker exec nginx nginx -s reload` — but recreate is more reliable for
catching configuration errors (a broken config prevents the new container
from starting, which is highlighted by `docker compose ps`).

## Adding a new domain on an already-deployed host

```bash
./add-domain.sh <new-domain> --upstream-port <N>
$EDITOR nginx/vhosts/<new-domain>.conf
docker compose up -d --force-recreate nginx
```

The cert issuance is a one-shot `docker run` — it doesn't disturb the running
`certbot` container.

## AWS-specific gotchas

- **Security group must allow inbound 443 (and 80 for HTTP→HTTPS redirect).**
  Symptoms: domains pointed at Cloudflare with proxy mode on return
  `HTTP/2 403 ... cf-mitigated: challenge ... server: cloudflare`. That
  looks like Cloudflare bot protection but is actually CF being unable to
  reach the origin.
- **Cloudflare proxy mode (orange cloud)**: SSL/TLS encryption mode must
  be `Full (strict)` to validate our LE cert. Otherwise CF returns 521 /
  525 / 526.
- **ARM image compatibility**: all pinned images (`nginx:1.30-alpine`,
  `certbot/dns-cloudflare:v5.10.0`, `docker:29-cli`,
  `tecnativa/docker-socket-proxy:3.4`) ship multi-arch manifests.

## Verifying a deploy

```bash
docker compose ps                                      # all 4 up, nginx healthy
docker exec nginx nginx -t                             # no warnings, syntax OK
docker inspect nginx --format='{{json .State.Health}}' | python3 -m json.tool

# Health endpoint (skips upstream)
curl -kI https://localhost/health -H "Host: <domain>"  # 200

# Through DNS (real cert path)
curl -I https://<domain>                               # whatever upstream returns
```

If `docker compose ps` shows nginx as `unhealthy`, the most common reasons:

1. Upstream is bound to `127.0.0.1` instead of `0.0.0.0` →
   `/health` works (it's internal) but `location /` 502s →
   actually, healthcheck should still pass since `/health` doesn't proxy.
   So if healthcheck fails, it's something else.
2. `nginx -t` fails inside the container (config error) → check
   `docker logs nginx`.
3. Healthcheck command can't reach 443 → unlikely unless `wget` was removed
   from the image.

## Rolling back

```bash
git log --oneline                                      # find the previous good commit
git checkout <sha>
docker compose up -d --force-recreate nginx
```

Certs are persisted in `certbot/conf/` (outside git), so rollback is purely
config rollback. Going back to a vhost that referenced a deleted upstream is
fine; nginx will start and return 502 until the upstream is back.
