# Don't Starve Together dedicated server — container

SteamCMD + the DST dedicated server (`app_id 343050`) in a single image, with:
- Two-shard cluster: Master (overworld) + Caves (underground) launched together
- `app_update` on every start (stays current with Klei patches)
- Cloudflare R2 backup — inotify-triggered, 10 s debounced, covers both shards
- Graceful `c_save()` + `c_shutdown()` on `podman stop`, routed to both shards
- Workshop mod auto-update via `dedicated_server_mods_setup.lua`

**Target:** x86_64 Linux VPS (Vultr is the reference). macOS Apple Silicon builds/mounts fine but cannot actually run Steam binaries (Rosetta + kernel bug, see Troubleshooting). Mac is for plumbing validation only.

---

## Prerequisites

- **Podman** (recommended) or **Docker**. Verify: `podman --version` or `docker --version`.
- On macOS with Podman, make sure the VM is up: `podman machine start`.

---

## Default logins (after `bootstrap/vultr-bootstrap.sh`)

All three credentials are unified — same password across the board, set as `ADMIN_PASSWORD` in your `bootstrap.vars` (or in `/home/dst/steamCMD/.env` after install).

| Where | URL | Username | Password |
| --- | --- | --- | --- |
| DST admin panel | `http://<vps>:8080` | `dst` | `$ADMIN_PASSWORD` |
| Beszel monitoring | `http://<vps>:8090` | `admin@dst.local` | `$ADMIN_PASSWORD` |
| SSH (sudoer) | `ssh dst@<vps>` | `dst` | `$ADMIN_PASSWORD` |

Override the Beszel email via `BESZEL_USER_EMAIL` in `.env` before first hub boot (it's a one-shot — Beszel only seeds the admin user when the DB is empty).

---

## Operations cheatsheet

All commands run on the VPS as the `dst` user (`ssh dst@<vps>`). Escalating in severity within each service: **restart** (graceful) → **cold cycle** (stop + start) → **kill** (force, when graceful hangs) → **rebuild** (re-create from current image / compose).

### DST game server

| Action | Command |
| --- | --- |
| Restart (graceful — `c_save` + final R2 push, ~90 s) | from web UI: *Restart*, or `podman stop -t 90 dst && podman start dst` |
| Cold cycle (no graceful save, fast) | `podman restart -t 0 dst` |
| Force-kill (when stop hangs past timeout) | `podman kill dst && podman start dst` |
| Rebuild image after `git pull` | `cd ~/steamCMD && podman build --platform=linux/amd64 -t local/steamcmd:latest . && ./run-dst.sh restart` |
| Recreate container (new flags / env) | `cd ~/steamCMD && ./run-dst.sh start` (the script does `podman rm -f` first) |

### Admin panel

| Action | Command |
| --- | --- |
| Restart | `podman restart dst-admin` |
| Cold cycle | `podman stop dst-admin && podman start dst-admin` |
| Force-kill | `podman kill dst-admin && podman start dst-admin` |
| Rebuild image after `git pull` | `cd ~/steamCMD/admin && podman build --platform=linux/amd64 -t local/dst-admin:latest . && podman-compose down && set -a && . ~/steamCMD/.env && set +a && podman-compose up -d` |

### Beszel monitoring

| Action | Command |
| --- | --- |
| Restart hub | `podman restart beszel` |
| Restart agent (after editing `BESZEL_AGENT_KEY`) | `cd ~/steamCMD/monitoring && set -a && . ~/steamCMD/.env && set +a && podman-compose up -d agent` |
| Re-pair (regenerate key + system record) | `cd ~/steamCMD/monitoring && ./autowire.sh` |
| Whole stack down + up | `cd ~/steamCMD/monitoring && podman-compose down && set -a && . ~/steamCMD/.env && set +a && podman-compose up -d` |

### Host-level (run as root with `sudo`)

| Action | Command |
| --- | --- |
| Bounce the rootless podman REST socket (admin uses this) | `sudo systemctl restart podman-api-dst.service` |
| Verify socket is listening | `sudo systemctl status podman-api-dst.service --no-pager` |
| Whole-host reboot (cleanest reset; containers come back via `podman-restart.service`) | `sudo reboot` |

### Diagnostics

| Question | Command |
| --- | --- |
| Are all containers up? | `podman ps --format '{{.Names}} {{.Status}}'` |
| What does the DST entrypoint say? | `podman logs --tail 60 dst` |
| What does the master shard say? | `podman exec dst tail -60 /home/ubuntu/.klei/DoNotStarveTogether/$CLUSTER_NAME/Master/server_log.txt` |
| Is `podman ps` hanging? | one stuck `podman ps` holds the sqlite lock and freezes others. `pkill -9 -f 'podman ps'` and retry. |

---

## Project layout

```
steamCMD/
├── Dockerfile
├── entrypoint.sh             # orchestrator: update → mods → restore → launch → backup → graceful stop
├── run-dst.sh                # PRODUCTION launcher (detached, ports, restart policy, env file)
├── run-steamcmd.sh           # DEV launcher (interactive smoke test / shell)
├── docker-compose.yml        # DEV convenience only (smoke tests, interactive debug)
├── .env.example              # copy to .env and fill in (CLUSTER_TOKEN, R2_*, etc.)
├── saves/                    # bind-mounted at /home/ubuntu/.klei/DoNotStarveTogether
│   └── qkation-cooperative/    # one subdir per cluster
│       ├── cluster.ini         # [SHARD] shard_enabled=true, master_ip=127.0.0.1, …
│       ├── cluster_token.txt   # secret — or set $CLUSTER_TOKEN in .env
│       ├── adminlist.txt       # KU_... IDs, one per line (admin web panel will edit this)
│       ├── Master/             # overworld shard
│       │   ├── server.ini      # is_master=true, name=Master, server_port=10999
│       │   └── modoverrides.lua
│       └── Caves/              # underground shard
│           ├── server.ini      # is_master=false, name=Caves, server_port=10998
│           └── modoverrides.lua
└── mods/
    └── dedicated_server_mods_setup.lua    # ServerModSetup() list; entrypoint copies into DST install
```

### Two persistent named volumes (don't touch by hand)
- `steamcmd-home` → Steam install + auth cache.
- `dst-server`    → DST dedicated server install (~2 GB).

### Two bind-mounted folders (edit freely on host)
- `./saves/` → `/home/ubuntu/.klei/DoNotStarveTogether` — one subdir per cluster.
- `./mods/`  → `/home/ubuntu/user-mods` — the entrypoint copies `dedicated_server_mods_setup.lua` into the DST install on each start, plus every directory under `mods/user-mods/` (sideloaded custom mod folders that aren't on Steam Workshop).

---

## Launching

### 1. Build the image

```bash
podman build --platform=linux/amd64 -t local/steamcmd:latest .
```

### 2. Configure secrets

```bash
cp .env.example .env
$EDITOR .env     # paste CLUSTER_TOKEN, R2_* keys; pick CLUSTER_NAME
```

Required in `.env`:
- `CLUSTER_NAME`
- `CLUSTER_TOKEN` (or a pre-populated `saves/<cluster>/cluster_token.txt`)
- **All four `R2_*` keys.** Cloudflare R2 is not optional — the entrypoint exits on launch if any are missing. Saves, restores, and the first-boot wait-for-cluster path all depend on it. Create a bucket + Object R/W token at https://dash.cloudflare.com → R2.

### 3. Run the server (production)

```bash
./run-dst.sh              # start DST (detached, ports open, restart policy)
./run-dst.sh logs         # follow logs
./run-dst.sh stop         # graceful stop: c_save → c_shutdown → exit (R2 push happens via the next poll trigger; use the admin "Backup to R2 now" button if you want a guaranteed snapshot before stopping)
./run-dst.sh restart      # stop + start
```

### Backup model

Backups are zip archives pushed only on three events — no per-save churn:

1. **In-game day rollover** — poll loop in the entrypoint c_evals into the master shard via FIFO every 60 s, tracks `TheWorld.state.cycles`, fires `do_backup day` when it advances.
2. **Empty server** — same loop watches `#AllPlayers`; fires `do_backup empty` on the >0 → 0 transition.
3. **Manual** — admin panel **Backup to R2 now** button, or POST `/backup/trigger`.

R2 layout (per cluster):
```
r2:<bucket>/clusters/<CLUSTER_NAME>/history/
  day-0001-2026-04-25T231500Z-day.zip
  day-0001-2026-04-25T231500Z-day.mods.json    (sidecar — workshop IDs)
  day-0002-…-day.zip
  …
  2026-04-25T230000Z-manual.zip
  2026-04-25T230000Z-manual.mods.json
```

No `latest.zip` pointer is maintained. The admin UI and the entrypoint's first-boot R2 restore both scan the `history/` directory and pick the lexicographically newest entry — which is the in-game-time newest because of the `day-NNNN-` prefix. Legacy `.tar.gz` backups (from before this scheme) are still recognized on read.

Under the hood: `podman run -d --name dst --restart unless-stopped -p 10999:10999/udp ... local/steamcmd:latest dst`.

First launch downloads DST (~2 GB) into the `dst-server` volume — takes a few minutes. Subsequent launches just run `app_update` (~5 s when nothing's changed) and start immediately.

### 4. Dev / debug (optional)

`run-steamcmd.sh` and `docker-compose.yml` are dev conveniences — interactive shells, ad-hoc steamcmd, one-off smoke tests. They do **not** apply restart policy, ports, or the env file automatically.

```bash
./run-steamcmd.sh                                   # anonymous smoke test
./run-steamcmd.sh bash                              # interactive shell
./run-steamcmd.sh steamcmd +login anonymous +quit   # explicit steamcmd

podman-compose run --rm dst bash                    # compose equivalent of the shell
```

### Flag notes
- `--rm` auto-deletes the container on exit (used by the dev scripts, not production).
- `-it` is required for steamcmd to emit output on a TTY.
- `--platform=linux/amd64` is a no-op on x86_64 Linux and an accurate arch declaration on ARM hosts.
- `-v name:path` = named volume; `-v "$(pwd)/dir:path:U"` = bind mount with Podman UID-1000 chown.

### ARM Mac: plumbing-only

On Apple Silicon, steamcmd **cannot** actually run through Podman — kernel 6.13+ breaks both QEMU's and Rosetta 2's x86 futex translation in a way that segfaults the Steam client. Mac validates that the image builds, volumes mount, and bind mounts work; the actual `app_update` and server launch happen on the Linux VPS.

If you want Mac-native steamcmd, OrbStack works (different runtime, ships its own kernel). Not required.

---

## Saves — backing up and restoring ("forward and backward")

Three layers of save handling:

1. **Host folder `./saves/`** — a normal directory; use any host tool (below).
2. **Automatic R2 backups** — R2 is required; the entrypoint watches for every DST save across **both Master and Caves** shards (autosave, `c_save()`, day change) via inotify, debounces 10 s across both, tars the whole cluster (Master + Caves), and uploads to:
   - `r2://<bucket>/clusters/<cluster>/latest.tar.gz` (overwritten each time)
   - `r2://<bucket>/clusters/<cluster>/history/<ISO-timestamp>-<tag>.tar.gz` (kept)
3. **Graceful-stop backup** — `./run-dst.sh stop` runs `c_save()` + `c_shutdown(true)` inside the server, waits for clean exit, then does a final R2 push tagged `shutdown`.

**Fresh VPS, saves folder empty?**
- If `clusters/<cluster>/latest.tar.gz` exists in R2 → entrypoint restores it automatically, then launches. No manual pull.
- If R2 is empty too → entrypoint **waits** (5 s poll, heartbeat every 60 s) for the admin panel to provision the cluster. It does **not** auto-generate a fresh world. "Ready" means `cluster.ini` + `Master/server.ini` + `Caves/server.ini` all exist. Two creation paths (Phase 3):
  - **Upload cluster zip** — park-and-pick. The zip sits in `saves/<cluster>/` (must include both `Master/` and `Caves/` subdirs) and the waiting container picks it up on the next poll.
  - **Template-server wizard** — form (name, password, max players, game mode, pvp, description) → writes cluster.ini + both shards' server.ini / modoverrides.lua → container launches.

Manual host-side shuffling still works:
```bash
# BACKUP to a local tarball:
tar czf dst-backup-$(date +%Y%m%d).tgz saves/

# RESTORE from a tarball:
rm -rf saves/qkation-cooperative
tar xzf dst-backup-20260420.tgz

# SWAP without losing the old cluster:
mv saves/qkation-cooperative saves/qkation-cooperative.archived

# SYNC to another VPS:
rsync -av --delete saves/ user@vps:/home/user/steamCMD/saves/
```

### Host-side permission gotcha (unzip / extract into `saves/`)

`:U` in the bind mount chowns `saves/` to the container's UID 1000 on every launch. That chown is reflected back to the host through virtiofs (macOS) or directly (Linux rootless), and your login user may no longer own the folder afterwards. You'll then hit `permission denied` extracting a zip/tar into it.

**Symptom:**
```
$ unzip backup.zip -d saves/
checkdir: cannot create extraction directory: saves/...
           Permission denied
```

**Diagnose:**
```bash
ls -la saves/
ls -la saves/qkation-cooperative/
```

**Fix (take ownership back, then extract):**
```bash
# macOS
sudo chown -R "$(whoami):staff" saves/
chmod -R u+rwX saves/

# Linux
sudo chown -R "$(whoami):$(id -gn)" saves/
chmod -R u+rwX saves/

# then extract
unzip -o backup.zip -d saves/
# or
tar xzf backup.tgz -C saves/
```

**Prevent it coming back** (two options):
1. Drop `:U` from the bind mount and chown once to UID 1000:
   ```bash
   sudo chown -R 1000:1000 saves/   # Linux or macOS Terminal — Finder can't do this
   ```
   Then edit `docker-compose.yml` / `run-dst.sh` / `run-steamcmd.sh` to remove `:U` from the `saves` line.
2. Always drop files into `saves/` **through the container** (doesn't fight the chown):
   ```bash
   podman run --rm -i --platform=linux/amd64 \
     -v "$(pwd)/saves:/home/ubuntu/.klei/DoNotStarveTogether:U" \
     local/steamcmd:latest \
     bash -c 'cd /home/ubuntu/.klei/DoNotStarveTogether && unzip -o /dev/stdin' < backup.zip
   ```

On the Linux VPS this hurts less — a one-time `sudo chown -R 1000:1000 saves/` after any host-side extract is enough.

---

## Mods — adding, configuring, updating

DST mods are Workshop items. Each mod needs **two** edits:

### 1. Tell the server to download the mod
Edit `mods/dedicated_server_mods_setup.lua`. Add one `ServerModSetup("<workshop_id>")` line per mod:

```lua
ServerModSetup("378160973")   -- Global Positions
ServerModSetup("458140854")   -- Show Me
```

Find Workshop IDs in the URL: `steamcommunity.com/sharedfiles/filedetails/?id=378160973` → ID is `378160973`.

### 2. Tell the cluster to enable + configure the mod
Edit `saves/qkation-cooperative/Master/modoverrides.lua`:

```lua
return {
  ["workshop-378160973"] = {
    enabled = true,
    configuration_options = {
      PLAYER_ICON_OVERRIDE = false,
      SHARE_FIRE_PITS      = true,
    },
  },
  ["workshop-458140854"] = {
    enabled = true,
    configuration_options = {},
  },
}
```

Note the `"workshop-"` prefix on the key. Config option names come from each mod's `modinfo.lua` — grab them from the mod's Workshop page or source.

### 3. Restart the server
On next launch, the server downloads any new mods, updates existing ones, and applies `modoverrides.lua`. No manual file copying needed.

**Local-only / non-Workshop mods:** drop the mod folder into `saves/mods/<modname>/` (will be mounted into the server install). Reference it in `modoverrides.lua` with the key `"workshop-<name>"` or the raw folder name depending on the mod.

---

## Cluster info (this server)

| Field | Value |
|---|---|
| Cluster name | `qkation-cooperative` |
| Password | `qkation-cooperative` |
| Max players | 6 |
| Playstyle | relaxed / cooperative |
| Description | This server is super duper! |
| Token file | `saves/qkation-cooperative/cluster_token.txt` |

The token is a secret. Don't commit `saves/` to git (the included `.gitignore` already excludes it). To rotate: regenerate at https://accounts.klei.com/account/game/servers and overwrite the file.

---

## VPS deployment (Vultr)

### Fastest path: one-shot bootstrap

On a fresh Ubuntu 22.04 / 24.04 Vultr VPS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

Prompts for admin password, cluster token, and R2 keys; installs podman, clones the repo, builds images, and brings up DST + admin panel (+ optional Beszel). See [`bootstrap/README.md`](./bootstrap/README.md) for the firewall rules it tells Vultr to enforce and the re-provisioning flow.

### Manual path

```bash
# 1. Install podman, git:
sudo apt update && sudo apt install -y podman git

# 2. Clone and configure:
git clone <this repo> /home/dst/steamCMD
cd /home/dst/steamCMD
sudo chown -R 1000:1000 saves/ mods/   # UID 1000 is the container user
cp .env.example .env
$EDITOR .env                           # paste CLUSTER_TOKEN, R2_* secrets

# 3. Open Vultr Cloud Firewall (in Vultr dashboard, not ufw):
#    Firewall → your group → Add rule:
#      UDP   10999    from anywhere    DST Master (overworld) game
#      UDP   10998    from anywhere    DST Caves game
#      UDP   8766     from anywhere    Master Steam auth
#      UDP   8768     from anywhere    Caves Steam auth
#      UDP   27016    from anywhere    Master Steam master query
#      UDP   27018    from anywhere    Caves Steam master query
#      TCP   22       from your IP     SSH
#      TCP   8080     from your IP     admin panel
#      TCP   8090     from your IP     Beszel UI (if installed)

# 4. Build and launch:
podman build --platform=linux/amd64 -t local/steamcmd:latest .
./run-dst.sh
./run-dst.sh logs    # watch world-gen / first app_update
```

On the VPS no `--platform` emulation happens — everything runs at native speed.

### Vultr Cloud Firewall — why not UFW

Vultr's firewall runs at the cloud-network layer, before packets reach the instance. Stacking UFW on top creates two places to debug when something breaks. Pick one; for Vultr, pick theirs.

### ARM VPS (Graviton, Ampere, etc.)
Emulated only. Prefer x86_64 for DST.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied` unzipping / extracting into `saves/` | `:U` chowned it away from your login user. See "Host-side permission gotcha" above. |
| `Exiting on SPEW_ABORT` on Mac | Rosetta can't expose `cpu MHz`; workaround is `-e CPU_MHZ=3000`, but futex bug still follows. **Use Linux.** |
| `Fatal error: futex robust_list not initialized` on Mac | Rosetta + kernel 6.13+ incompat. Not fixable on Mac. **Use Linux.** |
| Second run re-downloads bootstrap | Your `steamcmd-home` volume got deleted. `podman volume ls` to check, don't `podman system prune -a`. |
| Can't see saves in Finder/Files | They're in `./saves/` on the host. If it's empty, the bind mount didn't attach — check for typos in the compose path. |
| Mod downloaded but not active in game | Missing `modoverrides.lua` entry, or `enabled = false`. |
| Server shows as offline in-game | Cluster token missing / wrong / regenerated. Refresh at Klei, overwrite `cluster_token.txt`. |
