# DST admin panel

FastAPI + Jinja2 single-page dashboard for managing the sibling DST container.

## Features

- Start / stop (graceful, 90 s) / restart the DST container.
- Manual R2 backup trigger (independent of DST container state).
- Upload cluster zip → parked slot (extracted and auto-flattened).
- Template wizard → writes a fresh cluster into `saves/` or `parked/`.
- Activate parked → swaps folders under the fixed `$CLUSTER_NAME` and restarts DST.
- Edit `adminlist.txt` (KU_ IDs only, non-KU_ lines stripped on save).
- Edit `dedicated_server_mods_setup.lua` and `Master/modoverrides.lua`.
- Download a freshly-baked `.env` or full `bootstrap.sh` for re-provisioning a new VPS in one paste.

## Auth

HTTP Basic. Username defaults to `admin`, override with `ADMIN_USER` in `.env`.
`ADMIN_PASSWORD` in `.env` is required — no password = admin endpoint returns 500 (fail-closed).

## Running

```bash
# From the repo root, after ../.env is populated:
cd admin
podman compose up -d
# then open http://<vps-ip>:8080
```

The admin container mounts:
- `..` (repo root) → `/data` — read/write access to `saves/`, `mods/`, `parked/`, `.env`.
- `$XDG_RUNTIME_DIR/podman/podman.sock` → `/run/podman/podman.sock` — so the panel can run `podman` against the host engine.

## How it talks to DST

No shared network; control is via the mounted podman socket and the `podman` CLI installed in this image. The panel runs `podman start/stop/restart dst` and inspects state via `podman inspect`.

When the panel writes to `saves/<cluster>/`, the DST container's running entrypoint (or its 5-second wait-for-cluster loop) picks the files up directly — no container restart needed unless you're swapping active clusters.

## Security posture

- Behind HTTP Basic; password in `.env`, never in git.
- Exposed on port 8080 TCP — put the Vultr firewall rule limited to your IP when possible.
- No TLS in this image (per design). If you need TLS, add Caddy in front on the VPS host, or a second compose service.
- `--privileged` is **not** used; only the podman socket is mounted.
