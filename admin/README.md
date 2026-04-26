# DST admin panel

FastAPI + Jinja2 single-page dashboard for managing the sibling DST container. Live status pills + log tails update every 5 s without a page reload.

## Features

### Server control
- Start / stop (graceful, 90 s `c_save` + `c_shutdown`) / restart the DST container.
- Manual R2 backup trigger (independent of DST container state).
- Live status panel — DST state, shards, uptime, R2 readiness, log tails for entrypoint + Master + Caves shards, all auto-refreshing every 5 s.

### Clusters
- **Template wizard** — writes a fresh two-shard cluster (Master + Caves) into `saves/` or `parked/`, generating a random `cluster_key` and a `DST_CAVE` worldgenoverride. **Form prefills from the live `cluster.ini`** when an active cluster exists, so editing fields and submitting `target=active` updates the running game's settings.
- **Park a cluster (zip / tar.gz upload)** — accepts both formats; magic-byte detection, not extension-based. macOS-made zips with `__MACOSX/` sidecar metadata are auto-cleaned. A single top-level wrapper folder is auto-flattened.
- **Parked clusters table** — Activate / Delete; Activate stops DST, archives the live cluster into parked/ with a timestamp, swaps in the chosen parked slot, restarts.
- **R2 cloud backups table** — every cluster name found under `r2:<bucket>/clusters/<name>/history/`, with size + UTC mtime of the newest backup, a history-count button to drill in, and per-row Restore-newest / Park-a-copy buttons. The drill-in panel lists every historic archive with a "show mods" toggle that fetches a small sidecar JSON.

### Mods
- **Currently configured** — workshop IDs (linked to Steam workshop pages) parsed out of `dedicated_server_mods_setup.lua` + both shards' `modoverrides.lua`. Sideloaded mod folder names listed too.
- **Save** vs **Save and restart DST** — both buttons. The common "mods aren't applying" confusion was that workshop downloads only happen on DST start; the second button bounces the container so changes land immediately.
- **Sideload custom mods (zip)** — for non-Steam-Workshop mods. Upload a zip whose top-level entries are mod folders (each containing `modinfo.lua`); they go into `mods/user-mods/`, and the DST entrypoint's `do_mods_sync` copies them into the install on next boot.

### Other
- Edit `adminlist.txt` (KU_ IDs only, non-KU_ lines stripped on save).
- Download a freshly-baked `.env` or full `bootstrap.sh` for re-provisioning a new VPS in one paste.
- Prominent red banner when Cloudflare R2 credentials aren't set — R2 is required, not optional, and the DST container refuses to launch without it.
- Bootstrap download endpoints return 409 Conflict if R2 isn't configured (rather than generating a broken script).

## Auth

HTTP Basic. Username defaults to `dst`, override with `ADMIN_USER` in `.env`.
`ADMIN_PASSWORD` in `.env` is required — no password = endpoint returns 500 (fail-closed). The same password is used for the SSH `dst` user and the Beszel admin login (unified credential set by the bootstrap).

## Running

```bash
# From the repo root, after ../.env is populated:
cd admin
podman-compose up -d
# then open http://<vps-ip>:8080
```

The admin container mounts:
- `..` (repo root) → `/data` — read/write access to `saves/`, `mods/`, `parked/`, `.env`.
- `$XDG_RUNTIME_DIR/podman/podman.sock` → `/run/podman/podman.sock` — so the panel can run `podman` against the host engine.

The `:U` flag is intentionally NOT on the project-root mount. Today's UID alignment (rootless dst → admin container root → host UID 1001, also matched by DST's `--userns=keep-id:uid=1000,gid=1000`) means everything writes at UID 1001 already. Adding `:U` would re-chown the entire tree on every `up -d` and could race DST writes mid-game.

## How it talks to DST

No shared network; control is via the mounted podman socket and the `podman` CLI installed in this image. The panel runs `podman start/stop/restart dst` and inspects state via `podman inspect`. The host's `podman-api-dst.service` system unit provides the listening socket — installed by the bootstrap.

When the panel writes to `saves/<cluster>/`, the DST entrypoint's inotify-based cluster wait picks the files up immediately and proceeds to launch — no container restart needed unless you're swapping active clusters.

## Security posture

- HTTP Basic; password in `.env`, never in git.
- Exposed on port 8080 TCP — put a Vultr firewall rule limited to your IP when possible.
- No TLS in this image (per design). If you need TLS, add Caddy in front on the VPS host, or a second compose service.
- `--privileged` is **not** used; only the podman socket is mounted.
- Path-traversal guards on all archive inputs (zip + tar.gz). `__MACOSX`, `.DS_Store`, `Thumbs.db`, `desktop.ini` are stripped after extraction.
