# Repository deep-dive

## What this is

`dst-dedicated-container` runs a Don't Starve Together dedicated server inside a podman container on a single Vultr Ubuntu VPS, with three sibling components that turn it into a managed appliance:

- **DST game server** — Klei's Linux dedicated binary (`app_id 343050`) plus an entrypoint that handles update/restore/launch/backup lifecycle for a two-shard cluster (overworld Master + underground Caves).
- **Admin web panel** — FastAPI app on `:8080` that controls the DST container via the host's podman REST socket and edits cluster files through a shared bind mount.
- **Beszel monitoring** — self-hosted hub + agent on `:8090`/`:45876` for VPS-wide system metrics + per-container charts.
- **Bootstrap script** — a single shell command turns a fresh `ssh root@vps` into a fully running stack in ~10 minutes.

The whole project is engineered around one assumption: **you push from Mac/laptop to the VPS and that's the only host that ever sees the DST binary.** macOS can't run the Steam binary at all (Rosetta + a kernel quirk), so `run-dst.sh` and the admin panel are the only realistic dev surface; production runs unattended on the VPS.

## File-system layout

```
steamCMD/
├── Dockerfile                  DST container image (steamcmd:ubuntu-24 + zip/unzip/rclone/inotify-tools/libcurl3-gnutls/tini)
├── entrypoint.sh               476 lines — full lifecycle orchestrator
├── run-dst.sh                  87 lines  — production launcher (--userns=keep-id, ports, named volumes, bind mounts)
├── docker-compose.yml          dev convenience only — `podman-compose run --rm dst bash` for smoke tests
├── .env / .env.example         secrets (CLUSTER_TOKEN, R2_*, ADMIN_PASSWORD)
│
├── saves/<CLUSTER_NAME>/       LIVE active cluster — bind-mounted into DST as /home/ubuntu/.klei/DoNotStarveTogether
│   ├── cluster.ini             [GAMEPLAY] [NETWORK] [SHARD] config
│   ├── cluster_token.txt       Klei auth token (re-derived from $CLUSTER_TOKEN on each launch)
│   ├── adminlist.txt           KU_ IDs, edited by the admin panel
│   ├── Master/                 overworld shard — server.ini, modoverrides.lua, save/, server_log.txt
│   └── Caves/                  underground shard — same shape
│
├── parked/                     non-active clusters (zip/tar.gz uploads, R2 park-a-copy, archived-on-activate)
├── mods/
│   ├── dedicated_server_mods_setup.lua   workshop IDs to download
│   └── user-mods/              sideloaded mod folders (admin /mods/upload extracts here; entrypoint copies to DST install)
│
├── admin/                      FastAPI panel — separate compose, separate image
│   ├── Dockerfile              python:3.12-slim + podman + rclone
│   ├── docker-compose.yml      bind-mounts ../ at /data, mounts the host podman socket
│   ├── requirements.txt        fastapi, uvicorn, jinja2, python-multipart
│   └── app/
│       ├── main.py             1485 lines — every endpoint + helpers
│       ├── templates/index.html   single-page dashboard, polls /api/status every 5 s
│       └── static/style.css
│
├── monitoring/                 Beszel — yet another compose
│   ├── docker-compose.yml      hub (image henrygd/beszel) + agent (henrygd/beszel-agent)
│   ├── autowire.sh             post-up automation: login → fetch hub pubkey → write to .env → restart agent → register system
│   └── README.md
│
└── bootstrap/                  Vultr provisioning
    ├── vultr-bootstrap.sh      411 lines — one shot from root@fresh-vps to running stack
    ├── vultr-startup-script.sh wrapper for Vultr's unattended-startup feature
    ├── bootstrap.vars.example  template for non-interactive runs
    └── README.md               three running modes (Vultr Startup / vars file / interactive)
```

## Data flow per concern

### Cluster lifecycle

1. **Empty VPS** — `saves/<CLUSTER_NAME>/` doesn't exist.
2. **Operator action** — either:
   - admin panel template wizard writes a fresh cluster (new world) into `saves/`, OR
   - admin panel zip/tar.gz upload drops a saved cluster into `parked/`, then **Activate** moves it into `saves/`, OR
   - admin panel R2 cloud-backups → **Restore** downloads from R2 history into `saves/`.
3. **DST entrypoint's inotify wait-for-cluster loop** detects the new directory immediately and proceeds past `cluster_ready`.
4. **launch_dst** opens FIFOs (one per shard, write-end held in the entrypoint), launches both shards reading those FIFOs as stdin, traps SIGTERM, starts the poll loop.
5. **Sim paused** in shard logs = ready for players.

### Backup pipeline (after this week's rewrite)

The pipeline used to be inotify-on-every-write with 10-second debounce, producing dozens of near-duplicate archives per day. Now it's poll-based with three meaningful triggers:

```
  [poll loop, 60s cadence]
       │
       │  c_eval into Master FIFO with a per-poll nonce
       │  → DST prints `ADMINBPOLL:<nonce>:<cycles>:<players>` to server_log.txt
       │
       └──▶  parse from log tail, compare to LAST_CYCLES / LAST_PLAYERS
              │
              ├── cycles advanced → do_backup day
              ├── players >0 → 0  → do_backup empty
              └── otherwise        → no-op

   [admin /backup/trigger]    →  do_backup manual

   do_backup(tag):
     1. zip -qrX cluster dir → /tmp/backup-<ts>.zip
     2. write_mods_sidecar    → /tmp/backup-<ts>.mods.json (workshop IDs greppped out of mods setup + modoverrides)
     3. rclone copyto    →  r2:<bucket>/clusters/<NAME>/history/<filename>
        - filename = day-NNNN-<utc-ts>-<tag>.zip   (when LAST_CYCLES known)
                   = <utc-ts>-<tag>.zip            (admin manual, no shared cycles)
     4. rclone copyto    →  ...history/<filename-stem>.mods.json
```

**No `latest.zip` pointer is maintained.** The admin UI and the entrypoint's first-boot R2 restore both list `history/`, filter to `.zip`/`.tar.gz`, lex-sort, take the last entry. The `day-NNNN-` prefix sorts after the legacy `<iso-ts>-` prefix, so newest-by-day always wins.

### Cross-process UID alignment (the trickiest piece)

Three processes touch the same files and need to agree on UID:
- DST entrypoint (inside DST container as `ubuntu`)
- Admin panel (inside admin container as `root`)
- Operator (on host as `dst`)

**The fix that took the longest to land**: `run-dst.sh` runs DST with `--userns=keep-id:uid=1000,gid=1000`. This pins the host's `dst` user (UID 1001) to the container's `ubuntu` user (UID 1000). With rootless podman, admin's container `root` (UID 0) also maps to host `dst` (1001) by default. Net effect: every file produced by any of the three lands at host UID 1001, regardless of which process wrote it. No `:U` flags needed on the bind mounts (and adding them would actively hurt because they'd race writes).

Before that fix: DST wrote files at host UID 166535 (subuid for container ubuntu without keep-id), admin wrote at 1001, the entrypoint then couldn't write `cluster_token.txt` to admin-produced cluster dirs → permission denied → restart loop.

### Podman socket plumbing

```
  Admin panel container          Host system
  ───────────────────             ──────────────────
  podman CLI                      /run/user/1001/podman/podman.sock  (Unix socket)
  CONTAINER_HOST=unix://...   →   ↑
  /run/podman/podman.sock         podman-api-dst.service (system unit)
                                  ExecStart=/usr/bin/podman system service --time=0 unix://...
                                  User=dst (rootless, runs as host UID 1001)
```

The system unit is bootstrap-installed. It survives reboots because `User=dst` + `Restart=on-failure` and it doesn't depend on a user-systemd dbus session. `ExecStartPre=-/bin/rm -rf …/podman.sock` cleans up any stub the bind-mount-auto-create may have left; `-rf` because podman sometimes auto-creates that path as a directory (we hit this).

### Container restart on host reboot

Rootless podman does NOT honor `--restart unless-stopped` across host reboots — that flag only works while podman is up. The bootstrap enables `podman-restart.service` for the dst user via `systemctl --user --machine=dst@.host enable …`. Combined with linger (`loginctl enable-linger dst`), this gets all containers back online on `sudo reboot`.

### Beszel autowire

```
  vultr-bootstrap.sh
   ├── compose-up monitoring (hub seeds admin user from ADMIN_PASSWORD on empty DB)
   └── ./autowire.sh
        ├── auth-with-password against /api/collections/_superusers/auth-with-password
        │   (fall back to /users for older Beszel)
        ├── fetch hub SSH pubkey, trying in order:
        │     1. authed /api/beszel/getkey
        │     2. unauthed /api/beszel/getkey   (older builds)
        │     3-8. 6 known on-disk paths via `podman exec beszel cat`
        │     9. wide find / -name id_ed25519.pub
        ├── write BESZEL_AGENT_KEY="<pubkey>" into monitoring/.env
        ├── POST /api/collections/systems/records  to register host as a system
        └── podman-compose up -d agent  (with XDG_RUNTIME_DIR=/run/user/$(id -u) forced
                                          because `su -` doesn't set it via PAM)
```

## Security model

- **HTTP Basic** for the admin panel; password is the unified `$ADMIN_PASSWORD` shared with SSH `dst` and Beszel admin.
- **No HTTPS in-image.** Reverse-proxy guidance lives in `admin/README.md`.
- **R2 credentials** are stored in `/home/dst/steamCMD/.env` (mode 600, owned by dst). The DST container reads via `--env-file`; admin reads via `read_env_file` over its `/data` bind mount.
- **Ports opened by UFW** (bootstrap-managed): 22 SSH, 8080 admin, 8090 Beszel, plus DST gameplay UDP (10999, 10998, 8766, 8768, 27016, 27018). Agent port 45876 is intentionally NOT opened — hub and agent both run on the same VPS, so 127.0.0.1 is enough.
- **Path-traversal guards** on every archive input (zip + tar.gz). `__MACOSX`, `.DS_Store`, `Thumbs.db`, `desktop.ini` are stripped recursively after extraction.
- **Bootstrap downloads** (admin panel "Download .env" / "Download bootstrap.sh") return 409 if R2 isn't configured — we won't hand out a half-baked re-provisioning script.

## What the user sees in the UI

Top-down on the dashboard:
1. **Status pills** (auto-refresh 5 s): DST state, shards count, uptime, cluster ready/empty, per-shard live/loading/booting/missing, R2 configured/NOT-SET.
2. **Server control** — Start / Graceful stop / Restart / Backup to R2 now.
3. **Live status** — three log panes: entrypoint, Master shard log, Caves shard log.
4. **Template wizard** — fields prefill from the live `cluster.ini`, target dropdown picks active vs parked.
5. **Park a cluster (zip / tar.gz upload)** — accepts both formats, auto-flattens single-wrapper-dir, strips Mac/Windows archive junk.
6. **Parked clusters table** — Activate / Delete; validation column confirms cluster.ini + Master/server.ini + Caves/server.ini all present.
7. **R2 cloud backups table** — newest-per-cluster summary, with a per-row history button that drills in to a sub-table of every backup with show-mods toggle, Restore-this-specific, Park-this-specific.
8. **Admins** — KU_ ID textarea, non-KU lines silently stripped on save.
9. **Mods** — currently-configured workshop IDs as Steam links + sideloaded folder names + Save / Save+Restart buttons + custom-mods zip upload.
10. **Bootstrap** — Download .env / Download bootstrap.sh links for re-provisioning.

## Recent (this-session) major changes

- `5f15fa1` — FIFO opened O_RDWR not O_WRONLY (DST self-deadlock fix)
- `78e77ad` — live status panel + 5 s polling
- `7d89d9c` — sudo for dst, inotify cluster-wait, process-level live status
- `9ba0d1e` — Beszel zero-click admin user + auto-register agent
- `b1b9e80` — UFW + unified dst credentials
- `c9bd761` — system service for rootless podman API socket
- `1720286` — libcurl3-gnutls in image (DST shared-lib crash)
- `cbd7774` — keep-id userns (the UID alignment fix)
- `b7887eb` — podman-restart.service for reboot recovery
- `2d2bbfb` — UID audit cleanup
- `d6b4cad` — R2 cluster catalog (initial)
- `8917c1d` — poll-based backups, day-prefixed history
- `fa2c2ed` — tar.gz upload accept
- `a9aa887` — autowire 6-path pubkey fallback + verbose diagnostics
- `8054b3a` — wizard prefill from live cluster.ini
- `4566f65` — operations cheatsheet
- `0970488` — `__MACOSX` / `.DS_Store` strip + flatten ignores junk
- `f7ebe26` — poll-only backups (drop shutdown/exit), zip format, R2 history browser, mods overhaul
- `6eb3f0b` — docs sync

## What's still soft

- **Vulnerabilities**: GitHub flags 6 (2 high, 4 moderate). Likely in the pinned admin requirements (FastAPI 0.115.0, Jinja2 3.1.4 — both have CVEs that landed Q1 2026). Unaddressed.
- **No tests.** Everything shipped in the last week is "I think this works" code.
- **Single-cluster.** `CLUSTER_NAME` is global; running multiple clusters per VPS isn't supported.
- **Mods textareas don't validate Lua.** A typo in modoverrides crashes DST silently on next start.
- **Manual backups don't carry day prefix.** Admin can't query DST cycles without a podman exec round-trip; for now manual backups sort under day-prefixed entries (which is correct because they're definitionally "between days") but the filename doesn't say which day.

