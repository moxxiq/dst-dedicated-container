# Don't Starve Together dedicated server — container

SteamCMD + the DST dedicated server (`app_id 343050`) in a single image, with:
- `app_update` on every start (stays current with Klei patches)
- Cloudflare R2 backup — inotify-triggered, 10 s debounced
- Graceful `c_save()` + `c_shutdown()` on `podman stop`
- Workshop mod auto-update via `dedicated_server_mods_setup.lua`

**Target:** x86_64 Linux VPS (Vultr is the reference). macOS Apple Silicon builds/mounts fine but cannot actually run Steam binaries (Rosetta + kernel bug, see Troubleshooting). Mac is for plumbing validation only.

---

## Prerequisites

- **Podman** (recommended) or **Docker**. Verify: `podman --version` or `docker --version`.
- On macOS with Podman, make sure the VM is up: `podman machine start`.

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
│       ├── cluster.ini
│       ├── cluster_token.txt   # secret — or set $CLUSTER_TOKEN in .env
│       ├── adminlist.txt       # KU_... IDs, one per line (admin web panel will edit this)
│       └── Master/
│           ├── server.ini
│           └── modoverrides.lua
└── mods/
    └── dedicated_server_mods_setup.lua    # ServerModSetup() list; entrypoint copies into DST install
```

### Two persistent named volumes (don't touch by hand)
- `steamcmd-home` → Steam install + auth cache.
- `dst-server`    → DST dedicated server install (~2 GB).

### Two bind-mounted folders (edit freely on host)
- `./saves/` → `/home/ubuntu/.klei/DoNotStarveTogether` — one subdir per cluster.
- `./mods/`  → `/home/ubuntu/user-mods` — the entrypoint copies `dedicated_server_mods_setup.lua` into the DST install on each start.

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
./run-dst.sh stop         # graceful stop: c_save → c_shutdown → final R2 push → exit
./run-dst.sh restart      # stop + start
```

Under the hood: `podman run -d --name dst --restart unless-stopped -p 10999:10999/udp ... local/steamcmd:latest dst`.

First launch downloads DST (~2 GB) into the `dst-server` volume — takes a few minutes. Subsequent launches just run `app_update` (~5 s when nothing's changed) and start immediately.

### 4. Dev / debug (optional)

`run-steamcmd.sh` and `docker-compose.yml` are dev conveniences — interactive shells, ad-hoc steamcmd, one-off smoke tests. They do **not** apply restart policy, ports, or the env file automatically.

```bash
./run-steamcmd.sh                                   # anonymous smoke test
./run-steamcmd.sh bash                              # interactive shell
./run-steamcmd.sh steamcmd +login anonymous +quit   # explicit steamcmd

podman compose run --rm dst bash                    # compose equivalent of the shell
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
2. **Automatic R2 backups** — R2 is required; the entrypoint watches for every DST save (autosave, `c_save()`, day change) via inotify, debounces 10 s, tars the cluster, and uploads to:
   - `r2://<bucket>/clusters/<cluster>/latest.tar.gz` (overwritten each time)
   - `r2://<bucket>/clusters/<cluster>/history/<ISO-timestamp>-<tag>.tar.gz` (kept)
3. **Graceful-stop backup** — `./run-dst.sh stop` runs `c_save()` + `c_shutdown(true)` inside the server, waits for clean exit, then does a final R2 push tagged `shutdown`.

**Fresh VPS, saves folder empty?**
- If `clusters/<cluster>/latest.tar.gz` exists in R2 → entrypoint restores it automatically, then launches. No manual pull.
- If R2 is empty too → entrypoint **waits** (5 s poll, heartbeat every 60 s) for the admin panel to provision the cluster. It does **not** auto-generate a fresh world. Two creation paths (Phase 3):
  - **Upload cluster zip** — park-and-pick. The zip sits in `saves/<cluster>/` and the waiting container picks it up on the next poll.
  - **Template-server wizard** — form (name, password, max players, game mode, pvp, description) → writes cluster.ini / server.ini / modoverrides.lua → container launches.

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

Quick-start on a fresh x86_64 Vultr VPS (full automated bootstrap is Phase 5):

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
#      UDP   10999    from anywhere    DST game
#      UDP   8766     from anywhere    Steam auth
#      UDP   27016    from anywhere    Steam master
#      TCP   22       from your IP     SSH
#    (Phase 3 adds TCP 8080 for the admin panel; Phase 4 adds TCP 8090 for Beszel.)

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
