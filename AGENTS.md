# AGENTS.md — Rules, Corrections, and Thinking Log

This file captures durable rules, user corrections, and the reasoning behind non-obvious choices for this project (SteamCMD container → Don't Starve Together dedicated server). Future agents and future-me should read this before making architectural choices.

---

## Project goal

A reproducible container image that runs SteamCMD, with enough structure to host a **Don't Starve Together (DST) dedicated server** as the next step. Requirements:

- Persistent Steam login/auth between container launches (avoid re-Steam-Guarding every run).
- Persistent game-server installation (avoid re-downloading ~2 GB every launch).
- Ability to **mount a host folder** as the server save directory, or alternatively **upload a user-supplied save folder** into the container.
- Mod support.
- Runs on Linux (target: VPS) and testable on macOS via **Podman**.
- User runs Apple Silicon (ARM) but targets Linux x86_64. Cross-arch is expected.

---

## Hard constraints (do not violate)

1. **Steam has no ARM builds.** SteamCMD, Steam client libs, and DST dedicated server are x86_64 only. Any ARM host (Apple Silicon, Graviton, Ampere) requires emulation. Build images `--platform=linux/amd64` and document the emulation cost.
2. **SteamCMD needs 32-bit (i386) libraries** even when running the 64-bit DST binary, because steamcmd's own bootstrap is 32-bit. The official `steamcmd/steamcmd` image already installs these — don't strip them out.
3. **DST can and should run the 64-bit server binary** (`dontstarve_dedicated_server_nullrenderer_x64`). Don't default to the 32-bit one.
4. **Never bake Steam credentials into the image.** Pass them at runtime via `-e` / env file, or prompt. Sentry / auth files live on a named volume.
5. **Don't run as root inside the container.** Use the `steam` user that ships with the base image (UID 1000 by default).

---

## Base image decision

**Chosen:** `steamcmd/steamcmd:ubuntu-24` (Ubuntu 24.04 LTS, maintained by CM2Network on Docker Hub). Pinned to a specific tag rather than `:latest` for reproducibility — check https://hub.docker.com/r/steamcmd/steamcmd/tags before bumping. As of 2026-04-18 the `ubuntu-24`, `debian-13`, and `latest` tags are all refreshed within the last few days.

**Why this one (ranked comparison):**

| Option | Verdict | Reasoning |
|---|---|---|
| `steamcmd/steamcmd:latest` | ✅ chosen | steamcmd pre-installed; i386 multiarch already enabled; non-root `steam` user at `/home/steam`; actively maintained; widely used for DST/Palworld/etc. |
| `cm2network/steamcmd:latest` | Equivalent | Same maintainer — essentially mirrors the above. Would also work. |
| `ubuntu:22.04` + manual install | Rejected | Reinvents what the official image gives for free: `dpkg --add-architecture i386`, lib32gcc-s1, locales, tini, user creation. No upside. |
| `debian:bookworm-slim` + manual | Rejected | Smaller base, but multiarch i386 on slim Debian is finicky and saves maybe 50 MB — not worth the maintenance. |
| Alpine-based | **Rejected outright** | Alpine uses musl libc. Steam binaries are glibc-only. Hard incompatibility; attempting this wastes hours. |

---

## Volume / persistence strategy

Three separate named volumes (one bind mount optional):

| Volume | Container path | Purpose |
|---|---|---|
| `steamcmd-home` | `/home/steam/Steam` | steamcmd install dir + **Steam auth sentry** (enables persistent login) |
| `dst-server` | `/home/steam/dst` | DST dedicated server install (~2 GB, re-downloaded if lost) |
| `dst-saves` | `/home/steam/.klei/DoNotStarveTogether` | DST server worlds/saves/mods config — **this is what the user wants to back up or swap** |

**Decision (2026-04-18, per user):** the saves path is a **bind mount** to `./saves` by default. User wants to pick the folder, edit files on host, upload their own saves. Named volumes for steamcmd-home and dst-server because they're opaque and fast.

**Named volume vs bind mount — when to use which:**
| Property | Named volume | Bind mount |
|---|---|---|
| Host-visible files | No (inside Podman VM on Mac) | Yes |
| Backup with host tools | Awkward (`podman volume export`) | Trivial (`cp -r`, rsync) |
| I/O speed on Mac | Faster | Slower (goes through VM FS sharing) |
| I/O speed on Linux | Same | Same |
| UID/permission issues | None | Host dir must be UID 1000 |
| Use for | Steam auth cache, server install | User-editable saves, custom mods, configs |

**Permissions gotcha (bind mount only):** host directory must be writable by UID 1000.
- On Linux: `chown -R 1000:1000 ./saves`
- On macOS + Podman: the VM handles UID translation automatically, usually no chown needed.

---

## Launch mechanism: compose vs raw `podman run`

**Compose is optional.** Two equivalent entry points:
- [docker-compose.yml](docker-compose.yml) — convenient defaults, one command: `podman-compose up`
- [run-steamcmd.sh](run-steamcmd.sh) — compose-free `podman run` one-liner, takes `SAVES_DIR` env override

Either works. User preference (2026-04-18): keep a single-file launch path as a goal but compose is fine for now.

---

## Mac/Podman specifics

- Podman on macOS runs a Linux VM (`podman machine`). First-time setup: `podman machine init` + `podman machine start`.
- `podman-compose` (Python wrapper, from apt) is what the bootstrap uses; `podman compose` (4.x subcommand) also works if installed but prefers `docker-compose` v2 syntax.
- On Apple Silicon, QEMU x86_64 emulation is automatic; no manual qemu setup.
- Performance: DST server idle is fine under emulation; world generation and mod loads are noticeably slower but functional for testing.

---

## Thought-shift log (big pivots to flag to the user)

- **2026-04-18:** Initial plan was `--platform=linux/amd64` unconditional. User asked about ARM native / 64-bit. Clarified: Steam is x86_64-only (no ARM option ever), so amd64 is unavoidable on ARM hosts. 64-bit DST binary is still what we run; i386 libs only serve steamcmd itself.
- **2026-04-18:** Shifted saves from named volume to bind mount per user request ("save folder that user can pick"). Kept steamcmd-home and dst-server as named volumes.
- **2026-04-18:** Bumped base tag from `:latest` (Ubuntu 22.04 assumption) to explicit `:ubuntu-24`. More reproducible; also happens to be the freshest current tag.
- **2026-04-18:** Discovered the `ubuntu-24` tag has **no `steam` user** — it uses `ubuntu` (UID 1000). Also discovered the `steamcmd` wrapper from the Ubuntu package deliberately relocates Steam state from `$HOME/Steam` to `$HOME/.local/share/Steam`, so that's the correct volume mount path. Symlinks `~/.steam/root` and `~/.steam/steam` both point there.
- **2026-04-18:** Confirmed QEMU emulation flakiness on ARM Mac: first-run steamcmd sometimes aborts with `Exiting on SPEW_ABORT` or `Unable to determine CPU Frequency`. Retry succeeds. Does not affect native x86_64 Linux targets. Documented as Mac-only warning.
- **2026-04-18 (CORRECTION):** The "retry works" claim above was WRONG — earlier tests showed exit=0 from pipeline tail, not from steamcmd itself. When actually captured, steamcmd fails every time on ARM Mac with libkrun/QEMU. Two distinct bugs:
  1. `Exiting on SPEW_ABORT` → fixed by `CPU_MHZ=3000` env var (baked into Dockerfile).
  2. `Fatal error: futex robust_list not initialized by pthreads` → NOT fixable by env; it's a QEMU futex emulation bug. Requires switching to `applehv` VM type + Rosetta 2, OR deploying on real x86_64 Linux.
- **2026-04-18 (FINAL on Mac ARM):** Tried to fix (2) by switching the Podman machine from `libkrun` (QEMU) to `applehv` with Rosetta 2. Found that `podman-machine-os:5.8` intentionally disables Rosetta on kernel 6.13+ because it's broken — they ship `/etc/containers/enable-rosetta` as an opt-in escape hatch. Forced Rosetta on (kernel was 6.19), properly registered `/mnt/rosetta` as the x86_64 binfmt handler, unregistered QEMU. **Steamcmd still hits the same `futex robust_list` segfault under Rosetta.** Conclusion: this is a kernel/translator/Steam glibc three-way incompatibility, unfixable at container or Podman layer on current macOS + current Fedora CoreOS kernel. Alternatives would be an older-kernel VM image, OrbStack (bundles its own kernel), or deploying on native x86_64 Linux. **Decision: stop chasing Mac-native steamcmd execution.** Mac has fully validated the container plumbing (image builds, volumes, bind mounts, cluster files). Actual `app_update` / DST install happens on the Linux VPS.
- **2026-04-18 (cleanup):** Per user request, removed emulation-specific hacks now that we've committed to Linux deployment. Dropped `CPU_MHZ=3000` env from Dockerfile. Collapsed the long "ARM Mac limitation" section in README.md down to two sentences — the full investigation remains here in AGENTS.md for historical reference. Kept `--platform=linux/amd64` everywhere: that's not a hack, it's an accurate declaration of the image's required arch.
- **2026-04-18 (terminology correction):** I was sloppy labeling the bugs "QEMU bugs" in later messages. Since we swapped the machine to `applehv` + `rosetta=true` + forced `/etc/containers/enable-rosetta`, QEMU is unregistered and **Rosetta is the ONLY x86_64 binfmt handler** on this Mac (verified with `cat /proc/sys/fs/binfmt_misc/rosetta` → enabled; `qemu-x86_64` → No such file). The `SPEW_ABORT` and `futex robust_list` failures are both **Rosetta + kernel 6.19** issues, not QEMU. `CPU_MHZ=3000` is a Rosetta workaround. This matches the Fedora CoreOS comment verbatim: "Rosetta is not functional on kernel 6.13 or newer."
- **2026-04-18:** Bind-mount permissions on rootless Podman required `:U` flag to chown the mount to container UID 1000. Without it, container writes fail. Docker does not support `:U` — Docker users must manually `chown -R 1000:1000` the host dir.

---

## User preferences / corrections log

*(Append new entries here when the user corrects a choice. Format: date — what was corrected — what to do instead — why.)*

- **2026-04-18** — Pin base image to a dated tag, not `:latest`. **Why:** reproducibility; also so an upstream bump doesn't silently break a running server. **How to apply:** any future base-image change goes through an explicit tag bump + shift-log entry.
- **2026-04-18** — Saves folder is a bind mount the user picks, not a named volume. **Why:** user wants to edit, back up, and swap save folders with host tools. **How to apply:** always default `./saves` as a bind mount; named volumes only for state the user never touches by hand.
- **2026-04-18** — Compose is optional convenience, not required. **Why:** user wants the option of a single-command launch without compose. **How to apply:** maintain `run-steamcmd.sh` in lockstep with `docker-compose.yml` — if one changes, update the other.
- **2026-04-18** — DST server runs **anonymous** (no Steam login). **Why:** DST dedicated server supports anonymous mode via a cluster token; avoids credential handling and 2FA in the container. **How to apply:** never add a Steam login step for the server. The cluster token is a separate secret, generated from klei.com/account, stored in `cluster_token.txt` inside the save folder.
- **2026-04-18** — Bind-mount volumes need `:U` flag on Podman. **Why:** rootless Podman maps container UID 1000 to a different host UID, so host dir is not writable by default. **How to apply:** keep `:U` on every bind mount in compose and `run-steamcmd.sh`. For Docker users (no `:U`), manual chown is documented inline.
- **2026-04-18** — "Universal image" is not achievable for Steam content (no ARM builds), but the **launcher files are host-universal**. **Why:** user asked for portability; we can't multi-arch the image, but we can guarantee `./run-steamcmd.sh` and `docker-compose.yml` work unchanged on Mac (emulated) and Linux (native). **How to apply:** keep `--platform=linux/amd64` embedded in Dockerfile, compose, and script — it's a no-op on x86_64 hosts and required on ARM.
- **2026-04-18** — Never claim steamcmd "works" on a platform without capturing its real exit code and output on a TTY. **Why:** non-TTY pipelines can silently hide steamcmd failures behind a trailing `tail | cat` exit 0. **How to apply:** when smoke-testing, always use `podman run -t ...` and read `${PIPESTATUS[0]}` or the un-piped exit code, not the pipeline's final stage.

---

## Open questions to confirm with the user

- [x] ~~Podman vs Docker Desktop~~ — **Podman 5.8.1 already installed** at `/opt/podman/bin/podman`, machine running (libkrun, 8 CPU / 15 GiB / 87 GiB).
- [x] ~~Steam account~~ — **anonymous** (DST cluster token model).
- [x] ~~Save-folder strategy~~ — **bind mount** to a user-chosen host folder (default `./saves`).

---

## Phase 1 architecture (DST baked in, 2026-04-20)

**Stack split (user-directed):**
- DST dedicated server → standalone `podman run` via `run-dst.sh`, built from this Dockerfile. Not in compose.
- Admin web panel (FastAPI, Phase 3) + Beszel monitoring (Phase 4) → their own compose stack in a sibling folder (not yet written).
- `docker-compose.yml` retained but demoted to dev convenience (smoke tests, interactive debug).

**VPS target (user-directed):** Vultr. No UFW — Vultr Cloud Firewall groups. Backups + state secrets on Cloudflare R2.

**Entrypoint responsibilities** (replaced the old `exec "$@"`):
1. Dispatch on first arg: `dst` → full lifecycle, anything else → passthrough (keeps image useful for ad-hoc `steamcmd`/`bash`).
2. `dst` lifecycle:
   - `steamcmd +app_update 343050 validate` on every start if `AUTO_UPDATE=1` (Klei pushes patches; mismatched servers can't accept players).
   - Copy `user-mods/dedicated_server_mods_setup.lua` into `$DST_DIR/mods/` (bind-mount target is a separate dir, not the DST install itself, to avoid clobbering the named volume).
   - If cluster dir is empty and R2 is configured, `rclone copyto r2:.../latest.tar.gz` + extract. Otherwise let DST generate a fresh world.
   - If `$CLUSTER_TOKEN` is set and `cluster_token.txt` is empty, write the file.
   - Start `inotifywait -m -e close_write -r <save_session_dir>` with a 10s kill-and-restart debounce. Each debounce tick: `tar cz + rclone copyto` to `clusters/<cluster>/latest.tar.gz` plus a timestamped `history/<ts>-<tag>.tar.gz`.
   - Launch DST reading from a FIFO (`/tmp/dst.stdin`); the entrypoint holds the write end open via `exec 3>`.
   - On SIGTERM/SIGINT: write `c_save()` then `c_shutdown(true)` into fd 3, wait up to 60s, escalate to KILL if needed, kill inotify watcher, do one final R2 push.

**Backup trigger decision (2026-04-20, per user):** inotify only. **No** safety-net cron. Rationale: every real autosave + every `c_save()` already fires inotify; a cron would just duplicate uploads. If DST goes silent for hours (no saves written), that's itself a signal something's wrong, not something to paper over.

**Save-path bug fix (2026-04-20):** old bind was `./saves → /home/ubuntu/.klei`, which required launching DST with a non-default `-conf_dir .` to find `./saves/<cluster>/`. Fixed: bind is now `./saves → /home/ubuntu/.klei/DoNotStarveTogether`. Host layout stays `./saves/<cluster>/`; DST's default `-conf_dir DoNotStarveTogether` resolves correctly.

**Mods bind-mount fix (2026-04-20):** old bind was `./mods → /home/ubuntu/dst-mods`, which DST ignored (it reads from `$DST_DIR/mods/`). Fixed: bind is now `./mods → /home/ubuntu/user-mods` (a neutral staging dir), and entrypoint copies `dedicated_server_mods_setup.lua` into the DST install at launch. Avoids clobbering the `dst-server` named volume.

**Secret flow (2026-04-20, per user):**
- First VPS boot: user SSHes in, runs interactive bootstrap, fills `.env` (cluster token, R2 creds, admin password). `.env` never leaves the VPS.
- Going forward: Phase 3 admin panel regenerates a downloadable bootstrap script (with `.env` baked in) for re-provisioning.
- `CLUSTER_TOKEN` in `.env` → entrypoint writes `cluster_token.txt` if missing. Either-or: keep token in file OR env, not both.

**Backup object layout in R2** (confirmed with user):
```
r2://<bucket>/
  clusters/<cluster>/
    latest.tar.gz                ← overwritten every save
    history/<ts>-<tag>.tar.gz    ← kept, retention TBD
  parked/                        ← Phase 3: zips uploaded via web panel
  env/                           ← Phase 3: regeneratable bootstrap.env
```

**Graceful-stop timing:** `run-dst.sh` uses `--stop-timeout 90` so `podman stop` gives the entrypoint's trap enough headroom for `c_save()` + `c_shutdown()` + final R2 push before SIGKILL.

**Research references (Phase 0, 2026-04-20):**
- DST app_id = 343050, anonymous login, `force_install_dir + app_update + validate + quit` is the canonical invocation.
- `dedicated_server_mods_setup.lua` re-read on every boot; DST handles Workshop version deltas itself (no special flag).
- No reliable single-line "save success" log marker documented by Klei. inotify on the save tree is the honest signal.
- Beszel defaults: hub on :8090, agent on :45876; 150–180 MB RAM total.

---

## Working with the agent — anti-defensive prompting

By training default the agent leans **defensive**: extra `try/except`, fallback paths for cases that can't actually happen, validation of internal trusted data, redundant null-checks. This produces busywork code and hides real bugs behind silent error-swallowing. See `potential_issues.md` for a catalog of where this happened on this repo.

The user has noticed and explicitly granted permission to drop the defaults. **Phrases that worked**, and what they unlock:

- *"it's okay to say that"* / *"good boy"* / *"nice"* — confirms an honest self-critique was wanted, not a defensive deflection. Future audits get sharper.
- *"trust the input"* — drop input-validation guards on internal callers; only validate at system boundaries (HTTP forms, archive contents, external APIs).
- *"let it crash"* / *"don't catch that"* — exception bubbles up; user wants to see real failures, not a fake-success redirect.
- *"no fallback"* — when the agent's about to add a 3-path fallback chain "just in case", the user prefers one path that fails loudly.
- *"don't import again"* / *"use the module-level X"* — pulls the agent off reflexive function-local imports.

Concrete patterns the agent should NOT add to this codebase:
- `try: X except Exception: pass` on internal calls. If `X` can fail, propagate.
- `os.environ.copy()` when 2-3 specific keys would do.
- `errors="ignore"` on text reads of files we just wrote ourselves.
- `2>/dev/null` on commands where the stderr would be informative.
- Filtering "junk" in places where junk shouldn't appear (the bug is upstream).
- "Best-effort" silent retries that don't tell the user a step failed.

Concrete patterns that ARE correct:
- `try: tmp.unlink() except FileNotFoundError` in finally blocks where the temp may not have been created.
- `shutil.rmtree(..., ignore_errors=True)` on partial-extraction cleanup whose goal is "leave the slot reusable".
- Explicit fallback chains where the user has signed off on the alternative paths (e.g. autowire's pubkey discovery — six paths because we genuinely don't know where the key lives across Beszel versions).

When in doubt, ask: **"what specific scenario does this protect against, and is it actually possible?"** If the honest answer is "I'm not sure, just being safe", strip it.

---

## User preferences / corrections log (Phase 1 additions)

- **2026-04-20** — Vultr Cloud Firewall only; do NOT install UFW. **Why:** user runs Vultr and already has their own firewall conventions at the cloud level. Two firewalls = more breakage surface. **How to apply:** `REQUIREMENTS.md`'s UFW recipe is for non-Vultr deployments; Phase 5 bootstrap script must NOT install or enable UFW.
- **2026-04-20** — R2 only; no S3/Backblaze. **Why:** user's existing stack. **How to apply:** rclone config uses S3-compatible endpoint `https://<account>.r2.cloudflarestorage.com`, provider = Cloudflare, region = auto.
- **2026-04-20** — DST runs via `podman run` (not compose). Compose is reserved for admin panel + Beszel. **Why:** user directive "on dedicated server use dockerfile separately, on monitoring/webserver use compose". **How to apply:** keep `run-dst.sh` authoritative; `docker-compose.yml` stays for dev convenience but is not the production path.
- **2026-04-20** — FastAPI for the admin panel, not Flask. **Why:** user preference for modern stack.
- **2026-04-20** — Admin panel password is interactive during bootstrap, not passed via Vultr user-data. **Why:** Vultr's startup script field is visible in the dashboard forever; that's the wrong place for secrets.
- **2026-04-20** — Cluster uploads are "park-and-pick" (zip sits next to current cluster, user chooses which to launch). **Why:** forgiving UX; accidental upload doesn't nuke the running world.
- **2026-04-20** — adminlist.txt is KU_ ID only (no name labels). **Why:** user choice; keeps the file DST-native without wrapper tooling.
- **2026-04-20** — Backup trigger is inotify only; no cron safety net. **Why:** redundant uploads without real signal value. **How to apply:** entrypoint's `start_inotify_watcher` is the single trigger.
- **2026-04-20** — **Do NOT auto-generate a fresh world** when local saves dir is empty and R2 has no backup. **Why:** user wants admin-action-gated cluster creation via the web panel (upload zip OR template wizard). An auto-generated world silently running under the user's picked cluster name is confusing at best, destructive at worst (overwrites anything that arrives later). **How to apply:** entrypoint enters a poll-sleep loop (`do_wait_for_cluster`) until `cluster.ini` + `Master/server.ini` appear; heartbeat log every 60 s; no timeout (user may provision the box hours before configuring the cluster). Phase 3 admin panel provides the two creation paths: (a) park-and-pick zip upload, (b) template-server wizard that writes cluster.ini/server.ini/modoverrides.lua from a form.

### Phase 3 requirement (new): template-server wizard
The admin panel MUST offer a "create template server" flow in addition to zip upload. Form fields at minimum: cluster_name (default `qkation-cooperative`), password, max_players, game_mode (relaxed/survival/endless/wilderness), pvp (bool), cluster_description. On submit, the panel writes `saves/<cluster_name>/{cluster.ini,Master/server.ini,Master/modoverrides.lua}` from templates, sources `cluster_token.txt` from `$CLUSTER_TOKEN` in `.env`, then the waiting DST container picks it up automatically on the next 5 s poll tick (no manual restart needed).

