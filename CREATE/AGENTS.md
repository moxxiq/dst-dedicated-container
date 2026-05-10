# AGENTS.md — Rules, Corrections, Thinking Log

Captures durable rules, user corrections, reasoning behind non-obvious choices. Project: SteamCMD container → Don't Starve Together (DST) dedicated server. Future agents and future-me read before architectural choices.

---

## Project goal

Reproducible container image. Runs SteamCMD. Hosts DST dedicated server next step. Requirements:

- Persistent game-server install (no re-download ~2 GB per launch).
- Mount host folder as save dir, OR upload user save folder into container.
- Mod support.
- Linux (target: VPS).

---

## Hard constraints (do not violate)

1. **Steam has no ARM builds.** SteamCMD, Steam client libs, DST server are x86_64 only. Any ARM host (Apple Silicon, Graviton, Ampere) needs emulation. Build images `--platform=linux/amd64`. Document emulation cost.
2. **SteamCMD needs 32-bit (i386) libraries** even running the 64-bit DST binary — steamcmd's own bootstrap is 32-bit. Official `steamcmd/steamcmd` image installs them. Don't strip.
3. **DST runs 64-bit server binary** (`dontstarve_dedicated_server_nullrenderer_x64`). Don't default to 32-bit.
4. **Never bake Steam credentials into image.**
5. **Don't run as root inside container.** Use `steam` user from base image (UID 1000).

---

## Base image decision

**Chosen:** `steamcmd/steamcmd:ubuntu-24` (Ubuntu 24.04 LTS, maintained by CM2Network on Docker Hub). Pin to specific tag, not `:latest`, for reproducibility — check https://hub.docker.com/r/steamcmd/steamcmd/tags before bump. As of 2026-04-18 `ubuntu-24`, `debian-13`, `latest` tags all refreshed within last few days.

---

## Volume / persistence strategy

Three named volumes (one bind mount optional):

| Volume | Container path | Purpose |
|---|---|---|
| `steamcmd-home` | `/home/steam/Steam` | steamcmd install dir + **Steam auth sentry** (persistent login) |
| `dst-server` | `/home/steam/dst` | DST dedicated server install (~2 GB, re-downloaded if lost) |
| `dst-saves` | `/home/steam/.klei/DoNotStarveTogether` | DST worlds/saves/mods config — **user backs up or swaps this** |

**Decision (2026-04-18, per user):** saves path = **bind mount** to `./saves` by default. User wants to pick folder, edit files on host, upload own saves. Named volumes for steamcmd-home and dst-server — opaque, fast.

**Permissions gotcha (bind mount only):** host dir must be writable by UID 1000.
- Linux: `chown -R 1000:1000 ./saves`
- macOS + Podman: VM handles UID translation automatically, usually no chown needed.

---

## Launch mechanism: compose

**Compose is goal for now.**
- [docker-compose.yml](docker-compose.yml) — convenient defaults, one command: `podman-compose up`

---

## Podman specifics

- `podman compose` preferred way

---

## User preferences / corrections log

*(Append new entries when user corrects choice. Format: date — what was corrected — what to do instead — why.)*

- **2026-04-18** — DST server runs **anonymous** (no Steam login). **Why:** DST dedicated server supports anonymous mode via cluster token; avoids credential handling and 2FA in container. **How to apply:** never add Steam login step for server. Cluster token is separate secret, generated from klei.com/account, stored in `cluster_token.txt` inside save folder.
- **2026-04-18** — Bind-mount volumes need `:U` flag on Podman. **Why:** rootless Podman maps container UID 1000 to different host UID, so host dir not writable by default. **How to apply:** keep `:U` on every bind mount in compose and `run-steamcmd.sh`. Docker users (no `:U`): manual chown documented inline.
- **2026-04-18** — Never claim steamcmd "works" on a platform without capturing real exit code and output on a TTY. **Why:** non-TTY pipelines can silently hide steamcmd failures behind trailing `tail | cat` exit 0. **How to apply:** smoke-test with `podman run -t ...`, read `${PIPESTATUS[0]}` or un-piped exit code, not pipeline's final stage.

---

## Phase 1 architecture (DST baked in, 2026-04-20)

**VPS target (user-directed):** Vultr. Backups + state secrets on Cloudflare R2.

**Entrypoint responsibilities** (replaced old `exec "$@"`):
1. Dispatch on first arg: `dst` → full lifecycle; anything else → passthrough (keeps image useful for ad-hoc `steamcmd`/`bash`).
2. `dst` lifecycle:
   - `steamcmd +app_update 343050 validate` on every start if `AUTO_UPDATE=1` (Klei pushes patches; mismatched servers can't accept players).
   - If `$CLUSTER_TOKEN` set and `cluster_token.txt` empty, write the file.
   - On SIGTERM/SIGINT: write `c_save()` then `c_shutdown(true)` into fd 3, wait up to 60s, escalate to KILL if needed, kill inotify watcher, do one final R2 push.

**Secret flow (2026-04-20, per user):**
- First VPS boot: user SSHes in, runs interactive bootstrap, fills `.env` (cluster token, R2 creds, admin password). `.env` never leaves VPS.

**Backup object layout in R2** (confirmed with user):
```
r2://<bucket>/
  clusters/<cluster>/
    history/<ts>-<tag>.tar.gz    ← kept, retention TBD
```

**Research references (Phase 0, 2026-04-20):**
- DST app_id = 343050, anonymous login, `force_install_dir + app_update + validate + quit` is canonical invocation.

---

Concrete patterns the agent should NOT add to this codebase:

- `os.environ.copy()` when 2-3 specific keys would do.
- `errors="ignore"` on text reads of files we just wrote ourselves.
- `2>/dev/null` on commands where stderr would be informative.
- Filtering "junk" in places where junk shouldn't appear (bug is upstream).

Concrete patterns that ARE correct:
- `try: tmp.unlink() except FileNotFoundError` in finally blocks where temp may not have been created.


When in doubt, ask: **"what specific scenario does this protect against, and is it actually possible?"** If honest answer is "not sure, just being safe", strip it.

---

## User preferences / corrections log (Phase 1 additions)

- **2026-04-20** — R2 only; no S3/Backblaze. **Why:** user's existing stack. **How to apply:** rclone config uses S3-compatible endpoint `https://<account>.r2.cloudflarestorage.com`, provider = Cloudflare, region = auto.
- **2026-04-20** — FastAPI for admin panel, not Flask. **Why:** user preference for modern stack.
- **2026-04-20** — Cluster uploads are "park-and-pick" (zip sits next to current cluster, user chooses which to launch). **Why:** forgiving UX; accidental upload doesn't nuke running world.
- **2026-04-20** — adminlist.txt is KU_ ID only (no name labels). **Why:** user choice; keeps file DST-native, no wrapper tooling.
- **2026-04-20** — **Do NOT auto-generate fresh world** when local saves dir empty and R2 has no backup. **Why:** user wants admin-action-gated cluster creation via web panel (upload zip OR template wizard).
