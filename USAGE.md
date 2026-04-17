# SteamCMD + DST container — usage

This container runs SteamCMD (currently) and will run the Don't Starve Together dedicated server (next step). The files in this repo are **host-universal**: same Dockerfile, compose, and scripts work on Linux and macOS. The container itself is x86_64 only — on ARM Macs it runs via QEMU emulation (works, just slower for world-gen and mod downloads).

---

## Prerequisites

- **Podman** (recommended) or **Docker**. Verify: `podman --version` or `docker --version`.
- On macOS with Podman, make sure the VM is up: `podman machine start`.

---

## Project layout

```
steamCMD/
├── Dockerfile
├── docker-compose.yml          # one launch option
├── run-steamcmd.sh             # compose-free launch option
├── entrypoint.sh
├── saves/                      # BIND-MOUNTED into container (edit freely)
│   └── qkation-cooperative/    # DST cluster folder
│       ├── cluster.ini
│       ├── cluster_token.txt   # ← secret
│       └── Master/
│           ├── server.ini
│           └── modoverrides.lua
└── mods/
    └── dedicated_server_mods_setup.lua   # list of Workshop mods to download
```

### The two persistent volumes (don't touch by hand)
- `steamcmd-home` → Steam install + auth cache. Lets you skip bootstrap on restart.
- `dst-server`    → the DST dedicated server install (~2 GB).

### The one bind-mounted folder (edit freely)
- `./saves/` → mounted at `/home/ubuntu/.klei` inside the container. This is where DST worlds, shard data, configs, and the cluster token live.

---

## Launching

Two equivalent entry points — pick one.

### Option A — compose

```bash
# Build + run (interactive steamcmd shell):
podman compose run --rm steamcmd steamcmd

# Anonymous one-off smoke test:
podman compose run --rm steamcmd steamcmd +login anonymous +quit

# Interactive bash inside container:
podman compose run --rm steamcmd bash
```

### Option B — plain `podman run` via the script

```bash
# Default: smoke test
./run-steamcmd.sh

# Run arbitrary commands:
./run-steamcmd.sh steamcmd +login anonymous +quit
./run-steamcmd.sh bash

# Point at a DIFFERENT host save folder:
SAVES_DIR=/path/to/my/saves ./run-steamcmd.sh bash
```

### Option C — raw `podman build` + `podman run` (no compose, no script)

```bash
# Build + tag (same step):
podman build --platform=linux/amd64 -t local/steamcmd:latest .

# One-shot run (anonymous smoke test):
mkdir -p saves mods
podman run --rm -it --platform=linux/amd64 \
  -v steamcmd-home:/home/ubuntu/.local/share/Steam \
  -v dst-server:/home/ubuntu/dst \
  -v "$(pwd)/saves:/home/ubuntu/.klei:U" \
  -v "$(pwd)/mods:/home/ubuntu/dst-mods:U" \
  local/steamcmd:latest \
  steamcmd +login anonymous +quit

# Interactive bash — same flags, just change the last argument:
podman run --rm -it --platform=linux/amd64 \
  -v steamcmd-home:/home/ubuntu/.local/share/Steam \
  -v dst-server:/home/ubuntu/dst \
  -v "$(pwd)/saves:/home/ubuntu/.klei:U" \
  -v "$(pwd)/mods:/home/ubuntu/dst-mods:U" \
  local/steamcmd:latest \
  bash

# Long-running named container you re-attach to:
podman run -dit --name dst --platform=linux/amd64 \
  -v steamcmd-home:/home/ubuntu/.local/share/Steam \
  -v dst-server:/home/ubuntu/dst \
  -v "$(pwd)/saves:/home/ubuntu/.klei:U" \
  -v "$(pwd)/mods:/home/ubuntu/dst-mods:U" \
  local/steamcmd:latest \
  sleep infinity

podman exec -it dst bash          # attach
podman stop dst && podman rm dst  # cleanup
```

**Flag notes:**
- `--rm` auto-deletes the container on exit — drop it for long-running named containers.
- `-it` is needed for steamcmd to print output (see earlier "non-TTY swallows output" lesson).
- `--platform=linux/amd64` is a no-op on x86_64 Linux, an accurate declaration that this image won't work natively on ARM.
- `-v name:path` = named volume; `-v "$(pwd)/dir:path:U"` = bind mount with chown to UID 1000 (Podman only).

On the first launch of a fresh VPS, run `./run-steamcmd.sh steamcmd +login anonymous +quit` once to populate the cache volume. Subsequent launches skip the bootstrap (~3 s startup).

### ARM Mac: plumbing-only

On Apple Silicon, steamcmd **cannot** actually download Steam content through Podman — Podman's Fedora CoreOS kernel (6.13+) breaks both QEMU's and Rosetta 2's x86 futex translation in a way that segfaults the Steam client. Mac is useful for validating that the image builds, volumes mount, and bind mounts work; actual installs happen on the Linux VPS.

If you want Mac-native steamcmd, OrbStack works (different runtime, ships its own kernel). Not required.

---

## Saves — backing up and restoring ("forward and backward")

Saves live in `./saves/` on the host. It's a normal folder — use any host tool:

```bash
# BACKUP (forward to a friend, VPS, or cold storage):
tar czf dst-backup-$(date +%Y%m%d).tgz saves/

# RESTORE (backward — drop in someone else's save, or a backup):
rm -rf saves/qkation-cooperative            # remove current cluster folder
tar xzf dst-backup-20260418.tgz             # extract into ./saves/
# then start the server — it'll load the restored world

# SWAP to a fresh cluster without losing the old one:
mv saves/qkation-cooperative saves/qkation-cooperative.archived
# create or drop in a new cluster folder

# SYNC to a VPS:
rsync -av --delete saves/ user@vps:/home/user/steamCMD/saves/
```

**Permissions (Linux only):** if you copy a saves folder onto a Linux host from elsewhere, run `sudo chown -R 1000:1000 saves/` before launching — DST inside the container runs as UID 1000. On macOS + Podman, the `:U` mount flag handles this automatically.

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

## VPS deployment (when ready)

This whole folder is portable. On a fresh Linux x86_64 VPS:

```bash
# 1. Install podman (Ubuntu example):
sudo apt update && sudo apt install -y podman

# 2. Copy this folder:
rsync -av ./ user@vps:/home/user/steamCMD/

# 3. On the VPS:
cd /home/user/steamCMD
sudo chown -R 1000:1000 saves/      # UID 1000 is container user
./run-steamcmd.sh                   # first launch, bootstraps cache

# 4. Open DST ports in firewall (for the eventual DST run):
sudo ufw allow 10999/udp            # server
sudo ufw allow 8766/udp             # steam auth
sudo ufw allow 27016/udp            # steam master
```

On the VPS no `--platform` emulation happens — everything runs at native speed.

### ARM VPS (Graviton, Ampere, etc.)
Works but emulated. Fine for 1-4 players, noticeably slower world-gen and mod loads. Prefer x86_64 for DST.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `permission denied` writing to `saves/` | Linux: `sudo chown -R 1000:1000 saves/`. Podman: ensure `:U` is on the mount. |
| `Exiting on SPEW_ABORT` on Mac | First-run QEMU quirk — re-run the same command. |
| Second run re-downloads bootstrap | Your `steamcmd-home` volume got deleted. `podman volume ls` to check, don't `podman system prune -a`. |
| Can't see saves in Finder/Files | They're in `./saves/` on the host. If it's empty, the bind mount didn't attach — check for typos in the compose path. |
| Mod downloaded but not active in game | Missing `modoverrides.lua` entry, or `enabled = false`. |
| Server shows as offline in-game | Cluster token missing / wrong / regenerated. Refresh at Klei, overwrite `cluster_token.txt`. |
