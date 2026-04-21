# Vultr VPS bootstrap

One-shot script that takes a freshly created Ubuntu 22.04 / 24.04 Vultr VPS
from `ssh root@<ip>` to a running DST server + admin panel (+ optional
Beszel monitoring) in under ten minutes, most of it image build time.

## Before you run it

1. **Create the VPS**
   - Plan: Vultr Cloud Compute, regular performance, 2 GB RAM minimum
     (DST itself uses ~1.2 GB; admin + Beszel adds ~200 MB).
   - Region: wherever your players are.
   - OS: Ubuntu 22.04 LTS or 24.04 LTS (x86_64).
   - **No startup script** — we prompt interactively instead, to keep the
     cluster token out of Vultr's logs.
   - Deploy and wait for the "Running" state.

2. **Create the Cloud Firewall group** *(optional but recommended)*
   - Networking → Firewall → Add Firewall Group
   - Rules:

     | Proto | Port  | Source       | Purpose                              |
     |-------|-------|--------------|--------------------------------------|
     | UDP   | 10999 | anywhere     | DST Master shard (overworld) game    |
     | UDP   | 8766  | anywhere     | Steam auth (Master)                  |
     | UDP   | 27016 | anywhere     | Steam master server (Master)         |
     | UDP   | 10998 | anywhere     | DST Caves shard (underground) game   |
     | UDP   | 8768  | anywhere     | Steam auth (Caves)                   |
     | UDP   | 27018 | anywhere     | Steam master server (Caves)          |
     | TCP   | 22    | your IP/CIDR | SSH                                  |
     | TCP   | 8080  | your IP/CIDR | Admin panel                          |
     | TCP   | 8090  | your IP/CIDR | Beszel UI (if installed)             |

   - Both Master and Caves shards have to be reachable from the internet.
     Clients connect to Master on 10999; Caves 10998 is what teleports
     players between surface and caves underneath. Skip the caves rules
     and caves transitions silently break.

   - Linked Instances → add your VPS. Propagation is instant.

3. **Grab your Klei cluster token**
   - https://accounts.klei.com/account/game/servers → **Add New Server**
     → copy the token. You'll paste it into the script prompt.

4. **Create a Cloudflare R2 bucket + API token** *(required)*
   - R2 → Create bucket (any name, any region; "auto" works fine).
   - R2 → Manage API tokens → Create token with **Object Read & Write**.
   - You'll need: account ID, bucket name, access key ID, secret access
     key.
   - R2 is not optional. DST saves, restores, and first-boot cluster
     recovery all go through R2; the container refuses to launch if any
     of the four values is missing.

## Running the bootstrap

Three ways to run it — pick whichever fits your workflow:

### Option A — Vultr Startup Script (zero SSH, fully unattended)

1. Open `bootstrap/vultr-startup-script.sh` in any text editor.
2. Fill in your values in the **FILL IN THESE VARS** block at the top.
3. Vultr dashboard → **Startup Scripts → Add Script** → paste the whole
   filled-in file → Save.
4. Attach the script when creating the VPS. It runs as root on first boot.

> The admin panel's **Download bootstrap.sh** button generates an
> equivalent pre-filled script from your running `.env`, so re-provisioning
> a new VPS is a one-paste operation.

### Option B — vars file (non-interactive SSH, fresh VPS)

Works on a brand-new VPS with no repo checkout — both files come down via `curl`:

```bash
# 1. Download the script + vars template to an empty directory
curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh    -o bootstrap.sh
curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/bootstrap.vars.example -o bootstrap.vars

# 2. Fill in every value
$EDITOR bootstrap.vars           # or: nano bootstrap.vars

# 3. Run — no prompts
chmod +x bootstrap.sh
sudo ./bootstrap.sh --vars bootstrap.vars
```

`bootstrap.vars` is in `.gitignore` (once the bootstrap clones the repo) —
safe to keep alongside the checkout for re-runs.

### Option C — interactive SSH (original flow)

```bash
curl -fsSL https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh -o bootstrap.sh
chmod +x bootstrap.sh
sudo ./bootstrap.sh
```

The script asks for:

- **Cluster name** (defaults to `qkation-cooperative`)
- **Klei cluster token**
- **Admin panel username** (defaults to `admin`)
- **Admin panel password** (typed twice, minimum 8 chars)
- **Cloudflare R2** account ID / bucket / access key ID / secret
  (all four required — the script re-prompts on empty input)
- **Beszel monitoring** y/N

All three modes then:

- Installs `podman`, `git`, rootless support packages
- Creates a `dst` Linux user (with lingering so rootless podman survives
  SSH disconnects)
- Clones this repo to `/home/dst/steamCMD`
- Writes `.env` with the secrets (mode 0600, owned by `dst`)
- Builds the DST image and starts the DST container
- Builds the admin panel image and starts it on :8080
- (Optionally) starts the Beszel hub+agent on :8090

At the end it prints a summary with URLs and a firewall checklist.

## What the bootstrap does *not* do

- **Does not create a starting cluster.** DST enters a wait loop until
  you either upload a cluster zip or run the template wizard in the
  admin panel at `http://<vps-ip>:8080`. That's deliberate — no
  auto-generated world that you'd have to throw away.
- **Does not touch the Vultr firewall.** Vultr's firewall lives at the
  cloud-network layer and has to be managed in their dashboard. The
  script prints the rules you need.
- **Does not install UFW or iptables rules.** Stacking two firewalls
  creates two places to debug. Use Vultr's only.

## Re-running on a new VPS

The admin panel has a **Download bootstrap.sh** button that generates a
pre-filled Vultr Startup Script from your running `.env`. Paste it into
Vultr's Startup Scripts UI when creating the replacement VPS, or just
paste it directly into the SSH terminal — no extra typing needed. R2
stores all cluster saves, so the new VPS picks up exactly where the old
one left off after DST's first-boot restore.

## Idempotency

Running the script a second time on the same VPS:

- Keeps the existing `dst` user and repo checkout (just `git pull`s).
- Overwrites `.env` with the new prompt answers — so if you just want
  to rotate the admin password, rerunning is the fastest path.
- `podman build` / `podman-compose up -d` both detect no-op builds and
  skip restarts when nothing changed.

### Partial re-runs (when the bootstrap half-succeeded)

If the bootstrap failed mid-way (image build error, missing package, etc.)
and you just want to retry specific steps without starting over, run them
**as the `dst` user** — `podman` is rootless and state is per-user:

```bash
# Refresh the checkout
sudo -u dst -H bash -c "cd ~/steamCMD && git pull"

# Rebuild the DST image
sudo -u dst -H bash -c "cd ~/steamCMD && podman build --platform=linux/amd64 -t local/steamcmd:latest ."

# Restart DST
sudo -u dst -H bash -c "cd ~/steamCMD && ./run-dst.sh restart"

# Rebuild + (re)start the admin panel
sudo -u dst -H bash -c "cd ~/steamCMD/admin && podman build --platform=linux/amd64 -t local/dst-admin:latest . && podman-compose up -d"
```

Running `podman build` or `podman-compose` as `root` directly will NOT
help — rootless podman keeps all state (images, containers, volumes) under
the `dst` user's XDG_RUNTIME_DIR. The safest way to recover from a broken
state is simply to re-run the full bootstrap, which is idempotent.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No controlling TTY` | You piped the script through `curl \| bash`. Don't — download first, then run `sudo ./bootstrap.sh`. |
| Podman rootless complains about subuid/subgid | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 dst` then re-run. |
| DST container logs show "Waiting for cluster files" | Expected — open the admin panel and provision the cluster. |
| Admin panel returns 500 on every endpoint | `ADMIN_PASSWORD` ended up empty. Re-run bootstrap or edit `.env` by hand and `sudo -u dst -H bash -c "cd ~/steamCMD/admin && podman-compose restart"`. |
| `podman compose: command not found` | The bootstrap installs `podman-compose` (Python wrapper with a dash). If you see `podman compose` (space) instead, you're on an old copy of the bootstrap — re-pull with `curl`, or `apt install podman-compose`. |
| Beszel hub shows agent as "Down" | You haven't pasted the hub's per-agent SSH key yet. See `monitoring/README.md` step 3. |
