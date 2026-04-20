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

     | Proto | Port  | Source       | Purpose                    |
     |-------|-------|--------------|----------------------------|
     | UDP   | 10999 | anywhere     | DST game traffic           |
     | UDP   | 8766  | anywhere     | Steam auth                 |
     | UDP   | 27016 | anywhere     | Steam master server        |
     | TCP   | 22    | your IP/CIDR | SSH                        |
     | TCP   | 8080  | your IP/CIDR | Admin panel                |
     | TCP   | 8090  | your IP/CIDR | Beszel UI (if installed)   |

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

SSH in as root (or a sudo user):

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

It then:

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

The admin panel has a **Download bootstrap.sh** button that bakes your
current `.env` into a self-contained copy of this script. That version
needs zero interactive input — paste it onto a new VPS and it restores
your whole setup (including R2 + cluster secrets) automatically. Use
that when migrating regions or rebuilding after a VPS failure.

## Idempotency

Running the script a second time on the same VPS:

- Keeps the existing `dst` user and repo checkout (just `git pull`s).
- Overwrites `.env` with the new prompt answers — so if you just want
  to rotate the admin password, rerunning is the fastest path.
- `podman build` / `podman compose up -d` both detect no-op builds and
  skip restarts when nothing changed.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `No controlling TTY` | You piped the script through `curl \| bash`. Don't — download first, then run `sudo ./bootstrap.sh`. |
| Podman rootless complains about subuid/subgid | `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 dst` then re-run. |
| DST container logs show "Waiting for cluster files" | Expected — open the admin panel and provision the cluster. |
| Admin panel returns 500 on every endpoint | `ADMIN_PASSWORD` ended up empty. Re-run bootstrap or edit `.env` by hand and `cd admin && podman compose restart`. |
| Beszel hub shows agent as "Down" | You haven't pasted the hub's per-agent SSH key yet. See `monitoring/README.md` step 3. |
