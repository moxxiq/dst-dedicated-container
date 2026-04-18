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
- [docker-compose.yml](docker-compose.yml) — convenient defaults, one command: `podman compose up`
- [run-steamcmd.sh](run-steamcmd.sh) — compose-free `podman run` one-liner, takes `SAVES_DIR` env override

Either works. User preference (2026-04-18): keep a single-file launch path as a goal but compose is fine for now.

---

## Mac/Podman specifics

- Podman on macOS runs a Linux VM (`podman machine`). First-time setup: `podman machine init` + `podman machine start`.
- `podman compose` works but prefers `docker-compose` v2 syntax.
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
- [x] ~~Cluster token~~ — provided 2026-04-18, stored at `saves/qkation-cooperative/cluster_token.txt`. Cluster "qkation-cooperative", password "qkation-cooperative", 6 players, relaxed/cooperative. Token was pasted in chat — user aware, can rotate at klei.com/account.
- [ ] VPS target: x86_64 (fast path) or ARM (emulated, discouraged for DST)?

## Cluster + mod file layout (reference)

```
./saves/qkation-cooperative/
  cluster.ini              # cluster-wide config (see Cluster info table)
  cluster_token.txt        # secret from klei.com/account — DO NOT COMMIT
  Master/
    server.ini             # shard config (master shard only — caves disabled)
    modoverrides.lua       # per-shard mod enable + configuration_options
./mods/
  dedicated_server_mods_setup.lua   # ServerModSetup() calls — what to download
```

**Mods need TWO entries** to work: a `ServerModSetup(id)` in `dedicated_server_mods_setup.lua` (downloads from Workshop) AND an `["workshop-<id>"] = { enabled = true, ... }` entry in `modoverrides.lua` (enables + configures in the world).
