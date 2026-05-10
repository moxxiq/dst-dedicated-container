# CREATE.md — recreating this from scratch

How to rebuild a Don't Starve Together dedicated-server appliance with offsite backup, web admin on a fresh Ubuntu VPS. 
Cross-references live in [`AGENTS.md`](AGENTS.md) (decision history) and [`potential_issues.md`](potential_issues.md) (currently latent bugs).

---

## 1. What this is

A single-VPS appliance with three sibling components:

```
                 ┌──────────────────────────────────────────────────┐
                 │   Ubuntu 22.04 / 24.04 VPS  (Vultr is reference) │
                 │                                                  │
   :8080 ───────▶│  dst-admin (FastAPI)  ◀──── controls  ───┐       │
                 │                                          │       │
                 │  ┌──────────────────────────┐            │       │
                 │  │  dst container           │ ◀── podman │       │
                 │  │  (steamcmd:ubuntu-24)    │   socket   │       │
                 │  │  Master shard :10999     │            │       │
                 │  │  Caves shard  :10998     │            │       │
                 │  └────────────┬─────────────┘            │       │
                 └───────────────┼──────────────────────────┘       │
                                 │                                  │
                                 ▼  rclone (S3 API)                 │
                          ┌────────────────────┐                    │
                          │  Cloudflare R2     │                    │
                          │  clusters/<NAME>/  │                    │
                          │   history/*.zip    │ ◀──── admin ──────┘
                          │   history/*.json   │       restore /
                          └────────────────────┘       park-a-copy
```

- **DST container** runs the Linux dedicated server binary (`app_id 343050`) plus a 476-line entrypoint that orchestrates update → mods sync → cluster restore → launch → poll-trigger backup → graceful stop.
- **Admin panel** is a FastAPI single-page dashboard. Controls DST via the host's podman REST socket; edits cluster files through a shared bind mount; auto-refreshes status pills + log tails every 5 s.
- **Bootstrap** is a single shell command that turns a fresh `ssh root@vps` into the running stack in ~10 minutes.

---

## 2. Hard prerequisites

| What | Why | Where |
| --- | --- | --- |
| **Vultr Ubuntu 22.04 / 24.04 VPS, x86_64, ≥2 GB RAM** | DST idle ~1.2 GB; admin . Steam binaries are glibc x86_64-only, so no ARM, no Alpine. | https://my.vultr.com |
| **Klei cluster token** | DST dedicated server uses anonymous Steam login + a per-server token. | https://accounts.klei.com/account/game/servers → **Add New Server** → copy token |
| **Cloudflare R2 bucket + Object R/W token** | All save backups + first-boot restore. R2 is **mandatory** — entrypoint exits on launch if any of `R2_ACCOUNT_ID/R2_BUCKET/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY` is empty. | https://dash.cloudflare.com → R2 → create bucket → "Manage R2 API Tokens" → token with **Object Read & Write** scope, applied to your bucket |

R2 token gotcha: Cloudflare hands you four values in the creation dialog — Token (long opaque string), Access Key ID (~32 hex), Secret Access Key (~64 hex), Endpoint URL. **You want the access key + secret pair** (S3-compatible). The "Token" is for Cloudflare's own API, not S3 — pasting it as the access key gets you 403 with no useful error.

---

## 3. Bootstrap recreation (fresh VPS to running)

Three running modes — pick whichever fits your workflow. All three converge on the same idempotent script (`bootstrap/vultr-bootstrap.sh`).

### Mode A — Vultr Startup Script (zero SSH, fully unattended)

1. Open `bootstrap/vultr-startup-script.sh` in any editor.
2. Fill the **FILL IN THESE VARS** block at the top.
3. Vultr dashboard → **Startup Scripts → Add Script** → paste → save → attach when creating the VPS.

The admin panel's **Download bootstrap.sh** button generates a pre-filled equivalent from a running `.env`, so re-provisioning is one paste.

### Mode B — vars file (non-interactive SSH)

```bash
# As root on a fresh VPS
curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh -o bootstrap.sh
curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/bootstrap.vars.example -o bootstrap.vars
$EDITOR bootstrap.vars
chmod +x bootstrap.sh
sudo ./bootstrap.sh --vars /root/bootstrap.vars     # absolute path, NOT ~/
```

### Mode C — interactive SSH

`sudo ./bootstrap.sh` with no flags — prompts for cluster name, Klei token, admin password, R2 keys.

### What `bootstrap/vultr-bootstrap.sh` does

(411 lines, fully idempotent — re-runnable on partial failures.)

1. apt: `podman podman-compose passt slirp4netns fuse-overlayfs git rsync curl jq uidmap ufw dbus-user-session systemd-container`
2. Create `dst` user, set password (`openssl passwd -6` to bypass PAM password-quality), `usermod -aG sudo`, `loginctl enable-linger`, `systemctl --user --machine=dst@.host enable podman-restart.service` (so containers auto-restart on host reboot).
3. Install `/etc/systemd/system/podman-api-dst.service` running `podman system service` as the dst user — admin panel's socket source.
4. Clone repo into `/home/dst/steamCMD`, write `.env` from vars or prompts.
5. Build DST image (`local/steamcmd:latest`), start DST via `./run-dst.sh start`.
6. Build admin image, `podman-compose down && up -d` admin (down-first sweeps any zombies from a prior run).
8. UFW: open 22, 8080, 8090, plus DST gameplay UDP (10999, 10998, 8766, 8768, 27016, 27018). Agent port 45876 is intentionally NOT opened — both ends run on `127.0.0.1`.
9. Print summary with login URLs + unified credentials.

---

## 4. Architecture component-by-component

### DST container (`Dockerfile`, `entrypoint.sh`, `run-dst.sh`)

| File | Lines | Role |
| --- | --- | --- |
| `Dockerfile` | ~50 | `FROM steamcmd/steamcmd:ubuntu-24` + apt: `tini, locales, procps, curl, libcurl3-gnutls, rclone, inotify-tools, zip, unzip`. Pre-create `~ubuntu/.klei/DoNotStarveTogether`, symlinks for steamcmd. |
| `entrypoint.sh` | 476 | Lifecycle orchestrator. Functions: `r2_require`, `do_app_update`, `do_mods_sync`, `do_wait_for_cluster` (inotify-driven), `do_r2_restore_once`, `do_cluster_token`, `cluster_ready`, `do_backup`, `start_save_poller`, `graceful_stop`, `launch_dst`. Runs `./dontstarve_dedicated_server_nullrenderer_x64` per shard reading from a per-shard FIFO (fd 3 = Master, fd 4 = Caves). |
| `run-dst.sh` | 87 | Production launcher — `podman run -d --userns=keep-id:uid=1000,gid=1000 --restart unless-stopped --stop-timeout 90` + named volumes + bind mounts. NOT compose. |
| `docker-compose.yml` | small | Dev convenience only — interactive smoke tests. |

**Key invariants:**
- `--userns=keep-id:uid=1000,gid=1000` pins the container's `ubuntu` user (UID 1000) to the host's `dst` user (UID 1001). Admin's container `root` (UID 0) also maps to host UID 1001 by rootless default. Net: every file produced by any process lands at host UID 1001, no `:U` flags needed on shared bind mounts.
- Per-shard FIFOs are opened with `exec 3<>` (O_RDWR), NOT `exec 3>` (O_WRONLY). The latter blocks until a reader exists, but DST hasn't started yet — self-deadlock. See `entrypoint.sh:308` comment.
- `--stop-timeout 90` gives the SIGTERM trap headroom for `c_save()` + `c_shutdown(true)` per shard before `podman` escalates to SIGKILL.
- `restart: unless-stopped` is honored only while podman is up. Reboot recovery is `podman-restart.service` (user systemd unit; bootstrap enables it).

### Admin panel (`admin/`)

| File | Lines | Role |
| --- | --- | --- |
| `Dockerfile` | small | `FROM python:3.12-slim`, apt: `podman, rclone, ca-certificates`. |
| `docker-compose.yml` | small | Bind-mounts `..` → `/data` (no `:U` on purpose), bind-mounts host podman socket. |
| `requirements.txt` | 4 lines | `fastapi 0.115.0, uvicorn[standard] 0.32.0, jinja2 3.1.4, python-multipart 0.0.12`. |
| `app/main.py` | ~1500 | All endpoints + helpers in one file. Sections: env helpers, cluster IO, parked listing, R2 backup/list/restore/park, R2 history + sidecar, FastAPI routes. |
| `app/templates/index.html` | ~340 | Single-page dashboard. JS poll loop hits `/api/status` every 5 s, plus an event-driven R2 history drill-in. |
| `app/static/style.css` | small | Dark theme. |

**Talks to DST via:** the host's `/run/user/1001/podman/podman.sock`, exposed by `podman-api-dst.service`. The admin container has `CONTAINER_HOST=unix:///run/podman/podman.sock` so the in-container `podman` CLI speaks the REST API to the host daemon.

**Talks to cluster files via:** `..:/data` bind mount — admin reads/writes `saves/`, `parked/`, `mods/`, `.env` directly. No restart needed when admin writes cluster files; DST's `do_wait_for_cluster` (inotify-based) picks them up immediately.

**Authentication:** HTTP Basic. `ADMIN_USER` defaults to `dst`, override via `.env`. `ADMIN_PASSWORD` from `.env` is required — missing = endpoint returns 500 (fail-closed).

**Active-cluster wizard:** form values prefill from the live `cluster.ini` via `read_active_cluster_settings()` (`configparser`-based). Uses `WIZARD_DEFAULTS` when no active cluster exists.


### Bootstrap (`bootstrap/vultr-bootstrap.sh`, 411 lines)

Sequencing matters — every step has a reason:
1. **apt before user creation** so we can run as root through the install.
2. **`loginctl enable-linger dst` before any user-systemd interaction** so user systemd actually persists across logout.
3. **`systemctl --user --machine=dst@.host enable podman-restart.service` before clone/build** so the unit exists by the time we start containers; reboot recovery works on first boot.
4. **System service for podman socket BEFORE compose up** — admin container needs the socket present at start, not after.
5. **`podman-compose down` BEFORE `up -d`** for re-runs — avoids podman-compose 1.0.6 falling back to `podman start <stale>` on name collision.
6. **`set -a; . ../.env; set +a;`** subshell sourcing before every `podman-compose up -d` — `env_file:` injects into the container at runtime, NOT into the compose process for parse-time `${VAR}` substitution.
7. **Pre-touch `monitoring/.env`** before Beszel compose-up — the agent service has `env_file: - .env` which becomes `podman run --env-file …`, which errors if the file doesn't exist. `autowire.sh` writes the real content later.

---

## 5. Data flow

### Cluster lifecycle

```
empty VPS
   │
   ├── operator: template wizard ────▶ saves/<NAME>/    ◀── DST inotify-detects → launches
   ├── operator: zip/tar.gz upload ──▶ parked/<X>/      ◀── operator: Activate → moves to saves/
   └── operator: R2 restore ─────────▶ saves/<NAME>/    ◀── auto-launches
```

### Backup pipeline (current, post-`f7ebe26`)

```
poll loop (60 s cadence)            admin "Backup to R2 now"
       │                                     │
       │ c_eval into Master FIFO             │
       │   → ADMINBPOLL:<nonce>:cycles:players in server_log
       ▼                                     ▼
  parse, compare LAST_*                  run_backup("manual")
       │                                     │
       ├── cycles advanced → do_backup day   │
       └── players >0→0   → do_backup empty  │
                                             │
                  ▼                          ▼
              do_backup(tag):
                  zip -qrX cluster_dir       (tarfile in admin)
                  write_mods_sidecar         (workshop IDs greppped)
                  rclone copyto archive
                  rclone copyto sidecar
                  → r2:<bucket>/clusters/<NAME>/history/
                       day-NNNN-<utc-ts>-<tag>.zip
                       day-NNNN-<utc-ts>-<tag>.mods.json
                       <utc-ts>-manual.zip       (no day prefix — admin can't query cycles)
                       <utc-ts>-manual.mods.json
```

**Three triggers, no others.** SIGTERM/graceful-stop and both-shards-exit triggers were dropped (commit `f7ebe26`) — they produced near-duplicates with no extra recoverable state.

**No `latest.zip` pointer is maintained.** Admin and entrypoint both lex-sort the `history/` dir and take the last entry. `day-NNNN-` prefix sorts after legacy iso-ts prefix, so newest-by-day always wins. Both `.zip` and `.tar.gz` are recognised on read (legacy backups still restore).

### Mods plumbing

```
admin /mods (textarea save)
   │ writes mods/dedicated_server_mods_setup.lua + per-shard modoverrides.lua
   │
   │ (optional: restart=1)
   ▼
podman restart dst → entrypoint → do_mods_sync:
   1. install -m 0644 mods/dedicated_server_mods_setup.lua → DST install/mods/
   2. for each dir in mods/user-mods/<X>/ → cp -r into DST install/mods/<X>/
                                            (sideload — non-Workshop mods)

admin /mods/upload (zip)
   │ extracts top-level entries into mods/user-mods/<X>/
   │ each entry must contain modinfo.lua
   │
   ▼  same do_mods_sync path on next DST start
```

### R2 layout

```
r2://<bucket>/clusters/<NAME>/history/
    day-0001-2026-04-25T231500Z-day.zip
    day-0001-2026-04-25T231500Z-day.mods.json   ← {workshop_ids[], in_game_day, captured_at}
    day-0002-….zip
    day-0002-….mods.json
    …
```

Sidecar JSON is small (a few hundred bytes) — admin's "show mods" UI fetches it lazily via `/api/r2/mods/<cluster>/<sidecar>` rather than downloading the whole archive.

---

## 6. Visible features vs hidden mechanics

### Visible (operator-facing)

- Server control: Start / Graceful stop / Restart / Backup to R2 now.
- Live status: 3 log panes (entrypoint, Master, Caves), tail-and-poll.
- Template wizard
- Park a cluster: zip OR tar.gz upload
- Parked clusters: Activate / Delete, validation column.
- R2 cloud backups: per-cluster newest summary + drill-in to history with show-mods toggle, per-row Restore + Park.
- Adminlist: KU_ IDs, non-KU_ stripped on save.
- Mods: currently-configured (Steam Workshop links) + Save / Save+Restart + sideload zip upload.
- Bootstrap re-download: `.env` + `bootstrap.sh` for re-provisioning.

### Hidden mechanics (not directly UI-visible)

- **`--userns=keep-id:uid=1000,gid=1000`** — host dst (1001) → container ubuntu (1000). Without it, DST writes at subuid 166535 and admin writes at 1001; permission-denied loop.
- **Per-shard FIFO opened O_RDWR** — bash `exec 3<>` not `>`. O_WRONLY would block forever waiting for a reader. (commit `5f15fa1`)
- **Mods sidecar JSON** next to each backup zip — workshop IDs greppped from `dedicated_server_mods_setup.lua` + both `modoverrides.lua`. UI lazy-fetches via `/api/r2/mods/...`.
- **`ARCHIVE_JUNK` filter + `_strip_archive_junk()`** on every extract — removes `__MACOSX/`, `.DS_Store`, `Thumbs.db`, `desktop.ini` so Mac/Windows-zipped uploads don't break flatten.
- **`set -a; . ../.env; set +a;`** subshell wrapping for every compose invocation — without it, parse-time `${ADMIN_PASSWORD:?}` substitution fails because `env_file:` only injects at runtime, not parse-time
- **Compose `down` before `up -d`** in bootstrap — avoids podman-compose 1.0.6 falling back to `podman start <stale-container>` on name collision (which would start the OLD container with OLD bind mounts)

---

## 7. Rakes we stepped on (historical bugs, fixed)

These are load-bearing for "why is X like that today". Listed roughly chronologically.

| What broke | Symptom | Fix | Commit |
| --- | --- | --- | --- |
| Ubuntu 24.04 podman 4.9 defaults to `pasta` networking, package not pulled | `podman build` fails: `pasta: executable file not found` | Add `passt` to apt list | `bccd9d4` |
| DST binary needs `libcurl-gnutls.so.4` at runtime | `cannot open shared object file` immediately on every launch → crash loop | Add `libcurl3-gnutls` to Dockerfile apt | `1720286` |
| `exec 3>` on a FIFO blocks until a reader exists; we open the FIFO before launching DST | Entrypoint hangs at FIFO setup, container never reaches DST launch | Open with `exec 3<>` (O_RDWR) | `5f15fa1` |
| `env_file:` in compose injects into container at runtime, not into the compose process for parse-time `${VAR}` substitution | Beszel: `RuntimeError: ADMIN_PASSWORD must be set in ../.env` even though it IS set | `set -a; . ../.env; set +a;` subshell wrapping every `podman-compose up` | `2752162` |
| Rootless podman socket: `systemctl --user enable --now podman.socket` needs PAM dbus, which `su -` and sudo don't set up | Admin panel: `connection refused: unix:///run/podman/podman.sock` | System unit `podman-api-dst.service` running `podman system service` as dst user — no user dbus needed | `c9bd761` |
| Compose bind-mount with non-existent source path: podman auto-creates as a directory | `bind() can't use a directory as a socket`, podman-api-dst.service crash-loops with exit 125 | `ExecStartPre=-/bin/rm -rf` (with `-rf`, not `-f`) before bind; fix existing dirs by hand | `e75dc72` |
| Heredoc `<<UNIT` (unquoted) expands backticks as command substitution | `bash: line N: -: command not found` (cosmetic; comment text was lost in the unit file but Exec lines survived) | Remove backticks from comment, or use `<<'UNIT'` (but we need `${DST_USER}` to interpolate) | `bd976c3` |
| DST container `ubuntu` user (UID 1000) maps to host subuid 166535 by rootless default; admin container `root` maps to host dst (1001); files written by one user can't be written by the other | Activated parked cluster crash-loops with `cluster_token.txt: Permission denied` | `--userns=keep-id:uid=1000,gid=1000` aligns DST's container ubuntu with host dst | `cbd7774` |
| `--restart unless-stopped` only honors the running podman; on host reboot rootless containers come up in `Created` state and stay there | Containers don't restart after `sudo reboot` | `systemctl --user --machine=dst@.host enable podman-restart.service` (with linger, this fires on host boot) | `b7887eb` |
| macOS Finder's Compress feature embeds `__MACOSX/` metadata + `.DS_Store` files in zips; the flatten logic counts non-dot children and saw `[__MACOSX, real_folder]` → length 2 → skipped flattening | Uploaded clusters appear invalid (Master/Caves columns dashes) — files nested at `parked/<name>/<inner>/cluster.ini` instead of `parked/<name>/cluster.ini` | `_strip_archive_junk()` recursive walk + `_flatten_single_top_dir()` ignores `ARCHIVE_JUNK` when counting children | `0970488` |
| Sticky podman-ps locks: an old `podman ps` invocation that never returned holds the sqlite db lock | New `podman ps` calls hang silently | `pkill -9 -f 'podman ps'` then retry. Worst case `sudo reboot` (clears all locks) | (no fix; documented in cheatsheet) |
| Mods textareas save fine but DST doesn't re-read them until restart | "Saving mods doesn't work" — actually saving works, taking-effect doesn't | Add **Save and restart DST** button alongside **Save**. The original button still exists for offline edits | `f7ebe26` |
| `mods/user-mods/` (DST install path) vs `mods/user-mods/user-mods/` (sideload root after admin upload) — naming collision | DST didn't pick up sideloaded mods because `do_mods_sync` looked at the wrong dir | `do_mods_sync` reads `$HOME/user-mods/user-mods/<X>/` — admin uploads land there, sync copies to DST install | `f7ebe26` |

---

## 8. Currently latent bugs

See `potential_issues.md` for the full catalog.

---

## 9. Tech choices: chosen vs rejected

Compact decision matrix; full reasoning in `AGENTS.md`.

| Decision | Chosen | Rejected | Why |
| --- | --- | --- | --- |
| Container engine | Podman (rootless) | Docker | User preference; rootless avoids dockerd; podman-compose 1.0.6 in apt covers our needs |
| Base image | `steamcmd/steamcmd:ubuntu-24` | `ubuntu:24.04 + manual install`; Alpine | Maintainer ships i386 multiarch + non-root user; Alpine is musl, Steam is glibc-only |
| Save folder | bind mount | named volume | User wants host-editable, host-backupable |
| Auth backend | HTTP Basic | OAuth, sessions | Simplicity; admin has one user; Vultr cloud firewall scopes IP |
| Web framework | FastAPI | Flask | User preference; modern stack; built-in pydantic |
| Backup destination | Cloudflare R2 | S3, B2 | User has it; cheap egress; S3-compatible API works with rclone |
| Backup format | zip (post-`f7ebe26`) | tar.gz | Easier to open on Win/Mac without CLI; rclone+admin still accept tar.gz on read |
| Backup trigger | poll-loop (cycles + players) | inotify-on-every-write | Used to be inotify with 10 s debounce; produced ~50 archives/day. Poll captures meaningful events only |
| `latest.zip` pointer | Dropped (post-`f7ebe26`) | Maintained | Newest history file IS the latest. Saves an upload per backup |
| Mod metadata | sidecar JSON next to each archive | embed in archive header | Lazy-fetchable from R2; avoids download for show-mods UI |
| Cluster create | template wizard + zip/tar.gz upload | auto-generate on empty | User-directive: explicit operator action only |
| Monitoring | Beszel | Grafana+Prometheus, Netdata | 150 MB total; one binary; web UI works out-of-box |
| HTTPS | None (plaintext on `:8080`/`:8090`) | Caddy in front, built-in TLS | Vultr Cloud Firewall scopes by IP; reverse-proxy guidance documented |
| Userns | `keep-id:uid=1000,gid=1000` | default subuid mapping | Aligns container ubuntu with host dst → no `:U` race between DST and admin |
| Reboot recovery | `podman-restart.service` user unit | per-container `podman generate systemd`, Quadlet | Stock unit, single enable command, less drift |

---

## 10. Rules / load-bearing invariants

Never break these without an explicit corrections-log entry in `AGENTS.md`:

1. **R2 is mandatory** — entrypoint exits if any of the four R2 vars is empty. Saves, restores, and first-boot recovery all go through R2.
2. **DST runs `--platform=linux/amd64`**
3. **DST runs `--userns=keep-id:uid=1000,gid=1000`**. Don't drop this unless you also chown a million paths.
4. **No `:U` flag on bind mounts shared with admin** (`saves/`, `mods/`, `parked/`, `..`). Admin's `:U` would re-chown the whole tree on every `up -d` and race DST writes.
5. **`set -a; . .env; set +a;` before any `podman-compose` invocation** that needs `${VAR:?}` substitution. `env_file:` is runtime-only.
6. **One `ADMIN_PASSWORD`** — used for SSH `dst`, web admin, Beszel admin. Single source of truth, set once.
7. **Bootstrap is idempotent**. Re-running on an existing host re-applies state without breakage. Test: run twice, second run should report mostly skips.
8. **Docker compose CONFIG files are read-only assets**. Don't write to them at runtime — `monitoring/.env` is the exception (autowire writes the agent key there).
9. **Per-shard FIFOs MUST be O_RDWR** (`exec 3<>`). Don't change to `>`.
10. **No new defensive code without justification** — see `AGENTS.md → Working with the agent — anti-defensive prompting`.

---
