# Beszel monitoring

Self-hosted system + container monitoring with a small web UI. Runs
alongside the DST and admin stacks on the same VPS.

- **Hub UI** on port `8090` — charts, alerts, multi-system dashboard.
- **Agent** on port `45876` — reports whole-VPS CPU, RAM, disk, network,
  temps, plus per-container stats by reading the host podman socket.

Both live in this one compose file. If you later add more VPSes, only
the agent needs to be deployed on each one — a single hub can watch
many hosts.

## Zero-click first-run (via `vultr-bootstrap.sh`)

When you let the bootstrap install Beszel (`INSTALL_BESZEL=y`):

1. `podman-compose up -d` brings up hub + agent.
2. The hub seeds its admin user from `ADMIN_PASSWORD` in the project
   `.env` — `USER_EMAIL`/`USER_PASSWORD` env vars are a PocketBase
   one-shot: it creates the first user on an empty DB and silently
   ignores these vars on all subsequent boots.
3. `autowire.sh` logs in via the REST API, fetches the hub's SSH
   public key, creates a `systems` record pointing at
   `127.0.0.1:45876`, and writes the key to `monitoring/.env`.
4. Agent restarts with `BESZEL_AGENT_KEY` set and starts accepting
   hub connections — metrics appear in the UI within ~30 s.

Log in at `http://<vps-ip>:8090`:

- **Email:** `admin@dst.local` (override with `BESZEL_USER_EMAIL` in `../.env`)
- **Password:** your `ADMIN_PASSWORD` — the same credential as the DST
  admin panel and the `dst` Linux user.

## Manual first-run (if you're not using the bootstrap)

```bash
cd monitoring
podman-compose up -d              # hub creates admin user from ADMIN_PASSWORD
./autowire.sh                      # key + system record + agent restart
```

`autowire.sh` needs `jq` and `curl` on the host. The bootstrap installs
both; on a bare machine: `sudo apt install jq curl`.

If you want to do the wiring by hand instead:

1. Open `http://<vps-ip>:8090`, log in as `admin@dst.local`.
2. **Add new system** → name it (e.g. `dst-vps`), host `127.0.0.1`,
   port `45876`.
3. Copy the SSH public key the hub displays.
4. In `monitoring/.env` set `BESZEL_AGENT_KEY="<paste>"`.
5. `podman-compose up -d` to restart the agent with the key.

## Re-running `autowire.sh`

Safe and idempotent. It skips creating a system record that already
exists and overwrites `BESZEL_AGENT_KEY` in-place if the hub regenerated
its key (e.g. after wiping `beszel_data`).

## Whole-system metrics

`network_mode: host` is what lets the agent read the VPS's real
interfaces/routes/stats rather than a podman bridge namespace. CPU,
RAM, disk (`/`), network, and temperatures (if the kernel exposes
sensors via `/sys/class/hwmon`) all work out of the box with no extra
mounts.

Per-container stats (DST, admin, beszel itself) come from the mounted
podman socket via the Docker-compatible API — `CONTAINER_DETAILS=true`
is the hub default so you get per-container CPU/mem charts plus a log
viewer in the UI.

## Memory footprint

Hub + agent together sit around 150–180 MB RSS on an idle VPS. Safe to
colocate with a 2 GB DST server.

## Firewall

The bootstrap's UFW rules already open `8090/tcp` when
`INSTALL_BESZEL=y`. Agent port `45876` is **not** opened — the hub
reaches it over `127.0.0.1` because both run on the same VPS.

If you want to restrict the hub UI to your home IP, layer a Vultr
Cloud Firewall on top (UFW alone accepts any source).

## Teardown

```bash
cd monitoring
podman-compose down
```

Data lives in named podman volumes (`beszel_data`, `beszel_agent_data`).
Add `-v` to the `down` command to wipe them. Note that wiping
`beszel_data` regenerates the hub's SSH key, so you'll need to re-run
`autowire.sh` to re-pair the agent.
