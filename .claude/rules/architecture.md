# Architecture rules

## The four containers and why

| Container | Why it exists |
|-----------|---------------|
| `nginx` | The only public-facing surface. TLS termination + reverse proxy. |
| `certbot` | Long-lived renewal loop. Decoupled from nginx so renewal can happen even if nginx is restarting. |
| `docker-proxy` | Whitelist proxy in front of `/var/run/docker.sock`. The watcher needs `docker exec`, but giving it the full daemon socket is root-on-host. |
| `certbot-watcher` | Single responsibility: when `certbot` says "I renewed something," tell nginx to reload. |

If you ever feel tempted to collapse `certbot-watcher` into `certbot` (because
"why not just let certbot reload nginx directly?"), the answer is: certbot's
container has no docker CLI, no docker socket access, and we don't want it
to. The watcher's narrow job is the right separation.

## Inter-container communication

Containers do **not** talk over the network for renewal coordination. They
talk through the filesystem (`certbot/signal/reload`). Reasons:

- It survives container restarts — the flag persists on disk.
- It works without any service discovery between certbot and watcher.
- It is trivially observable from the host (`ls certbot/signal/`).

The watcher's only network coupling is to `docker-proxy` (TCP, internal
`watcher-net`). nginx and certbot are isolated from that network.

## What the watcher's `docker-proxy` allows

```
CONTAINERS: 1   # /containers/* — needed to resolve "nginx" container by name
POST: 1         # POST methods — needed for exec
EXEC: 1         # /containers/.../exec — the actual reload call
```

It explicitly does NOT allow `IMAGES`, `NETWORKS`, `VOLUMES`, `BUILD`,
`INFO`, etc. If a compromised watcher tried to pull images, create containers,
or read the daemon's full state, the proxy returns 403.

## Reload protocol

```
[certbot] certbot renew  --post-hook... 
  → success → renewal-hooks/post/reload-nginx.sh
  → /signal/reload  (touch on shared volume)

[watcher]  loop every 30s
  → if /signal/reload exists:
      docker exec nginx nginx -s reload   (via docker-proxy)
      if exit 0: rm /signal/reload
      if exit !=0: leave flag, log, retry next cycle
```

The "leave the flag on failure" piece is load-bearing. Removing it would
mean a single transient reload failure causes a 60-day silent staleness
window before the next renewal.

## What lives outside the containers

- `certbot/conf/` — persistent cert store. Lose this = re-register account.
- `certbot/secrets/cloudflare.ini` — API token. NOT in `certbot/conf/`
  because nginx mounts `certbot/conf` read-only and we don't want the token
  reachable from inside nginx.
- `certbot/signal/` — the renewal flag's home.
- `.env` — `EMAIL` and `CF_API_TOKEN`. Parsed by bash regex, not `source`.
- `nginx/snippets/` and `nginx/vhosts/` — bind-mounted read-only into nginx.

## Removing a container is also a decision

Removing `certbot-watcher` would mean nginx doesn't reload after a
renewal, so users would see expired certs until manual intervention.
Removing `docker-proxy` and bind-mounting the docker socket into the
watcher restores the host-root blast radius. Removing `certbot` removes
auto-renewal entirely. None of these should happen without an explicit
discussion of what replaces them.
