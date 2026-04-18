# Hosting requirements

Sized for the `qkation-cooperative` cluster as currently configured:
6-player relaxed/cooperative, single Master shard (caves disabled in `cluster.ini`),
anonymous steamcmd, Podman-based deployment, small-to-moderate mod list.

---

## Hardware / VM spec

| Resource | Minimum | Recommended | Why |
|---|---|---|---|
| **vCPU** | 2 | 2 | DST is single-threaded per shard. 1 core for Master shard, 1 for OS/IO. Adding caves (future) bumps this to 3. |
| **RAM** | 2 GB | 4 GB | Idle Master: ~500 MB. Aged world + 5–10 mods + 6 players active: 1.2–1.8 GB. Leave headroom for `steamcmd` updates (brief ~500 MB spike) and the OS. |
| **Disk** | 10 GB | 20 GB | DST server install ~2.5 GB, mod cache up to 1–2 GB, saves grow 10–50 MB/day, logs/backups need room. 20 GB handles a year of play without babysitting. |
| **Disk type** | Any SSD | NVMe SSD | World saves are chunky writes on autosave; spinning rust causes visible stutter. Any cloud SSD is fine. |
| **Network out** | 10 Mbps | 100 Mbps | Gameplay is ~50–100 kbps per player; steamcmd/mod downloads want burst bandwidth, not sustained. |
| **Public IPv4** | Required | Required | Steam server browser needs a reachable IP. NAT-only VPS won't show up. |

### Do NOT
- Use ARM (Graviton / Ampere / Raspberry Pi) — Steam is x86_64 only, emulation is the same class of bug we hit on Mac.
- Use shared/burstable CPU tiers (AWS `t2.nano`, some "low-end" VPS). World gen and mod loads sustain full CPU for 30–120 s and will get throttled.
- Use OpenVZ containers — steamcmd's 32-bit bootstrap has issues on non-KVM kernels.

---

## OS

**Required:** x86_64 Linux, kernel ≥5.4.

**Verified good:**
- Ubuntu 22.04 LTS, 24.04 LTS
- Debian 12, 13
- Rocky / AlmaLinux 9

**Not recommended:**
- Alpine (musl libc incompatible with Steam binaries)
- CentOS 7 / RHEL 7 (EOL glibc)
- Any distro where Podman is older than 4.0

---

## Software

- **Podman ≥4.0** (5.x preferred for `:U` mount flag reliability). Docker also works — drop `:U` and `chown -R 1000:1000 saves/` once instead.
- **git** (to clone this repo onto the box)
- **rsync** (for save backups to a remote)
- That's it. No extra Steam/DST dependencies — the container has everything.

Install on a fresh Ubuntu/Debian:
```bash
sudo apt update
sudo apt install -y podman git rsync ufw
```

---

## Network / firewall

DST is all UDP. Open these from the public internet:

| Port | Proto | What | Notes |
|---|---|---|---|
| 10999 | UDP | DST server | From `Master/server.ini`. Add one per extra shard (+1 for Caves if enabled). |
| 8766 | UDP | Steam auth | Klei/Steam check-ins |
| 27016 | UDP | Steam master query | Server browser visibility |
| 22 | TCP | SSH | Restrict to your IP if possible |

Outbound — allow everything, or at minimum 443/tcp, 80/tcp, 27015–27050/udp (Steam CDN + master).

UFW recipe:
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 10999/udp
sudo ufw allow 8766/udp
sudo ufw allow 27016/udp
sudo ufw enable
```

---

## Geography / latency

Pick a region **close to the player with the worst connection**, not the majority. DST is real-time co-op; one laggy player drags everyone.

| Player ping | Experience |
|---|---|
| <50 ms | Indistinguishable from local |
| 50–100 ms | Fine |
| 100–180 ms | Playable, occasional desync on combat |
| 180–300 ms | Frustrating, items drift |
| >300 ms | Don't bother |

Run a quick `mtr` or `ping` from each player's location to the candidate VPS before committing.

---

## Provider picks (as of April 2026)

Rough ranking for this workload. Prices approximate USD.

| Provider | Plan | Specs | ~Cost | Notes |
|---|---|---|---|---|
| **Hetzner Cloud** | CX22 | 2 vCPU / 4 GB / 40 GB NVMe | €4/mo | Best price/perf in EU. Pick Falkenstein/Nuremberg for EU or Ashburn/Hillsboro for US. |
| **Hetzner Cloud** | CPX21 | 3 vCPU / 4 GB / 80 GB, AMD EPYC | €7/mo | Upgrade tier if caves + heavy mods. |
| **Vultr High Frequency** | HF 2GB | 1 vCPU / 2 GB / 64 GB NVMe | $12/mo | Strong single-core clock — matters for DST. |
| **DigitalOcean** | Basic Regular | 2 vCPU / 2 GB / 60 GB | $18/mo | Fine if you already have DO. Overpriced for this. |
| **OVH VPS** | Value | 2 vCPU / 4 GB / 80 GB | €6/mo | Decent, watch for DDoS-protection latency spikes. |
| **Oracle Cloud Free** | VM.Standard.E2.1.Micro | 1 vCPU / 1 GB | $0 | Too small. Avoid. |
| **Oracle Cloud Free** | VM.Standard.A1.Flex | ARM | $0 | **DO NOT** — it's ARM. |

**Recommendation for this project:** Hetzner CX22 in the region nearest your players. Hits the spec sweet spot at the lowest price.

---

## Security baseline

Minimum bar before exposing a DST server to the internet:

```bash
# 1. Non-root user with sudo
sudo adduser dst
sudo usermod -aG sudo dst
# copy your authorized_keys to /home/dst/.ssh/

# 2. SSH keys only — disable password login
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo systemctl restart ssh

# 3. Automatic security updates
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades

# 4. Fail2ban on SSH
sudo apt install -y fail2ban
sudo systemctl enable --now fail2ban
```

Don't expose the Podman socket. Don't run the container `--privileged`. Don't commit `saves/cluster_token.txt` (already gitignored).

---

## Backup strategy

Saves are the only thing worth backing up — everything else is reproducible from the repo + steamcmd.

Minimum: a daily cron on the VPS tarballing `saves/` to a second location.

```bash
# /etc/cron.daily/dst-backup
#!/bin/sh
DEST=/home/dst/backups
mkdir -p "$DEST"
cd /home/dst/steamCMD || exit 1
tar czf "$DEST/saves-$(date +%Y%m%d).tgz" saves/
# keep last 14 days
find "$DEST" -name 'saves-*.tgz' -mtime +14 -delete
```

Better: `rclone`/`restic` to S3/Backblaze/Wasabi so a VPS failure doesn't take the world with it. Cost is pennies per month.

---

## Uptime / auto-start

Want the server to survive reboots? Create a systemd unit that runs your container:

```ini
# /etc/systemd/system/dst.service
[Unit]
Description=Don't Starve Together dedicated server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dst
WorkingDirectory=/home/dst/steamCMD
ExecStart=/usr/bin/podman run --rm --name dst \
  --platform=linux/amd64 \
  -p 10999:10999/udp -p 8766:8766/udp -p 27016:27016/udp \
  -v steamcmd-home:/home/ubuntu/.local/share/Steam \
  -v dst-server:/home/ubuntu/dst \
  -v /home/dst/steamCMD/saves:/home/ubuntu/.klei \
  -v /home/dst/steamCMD/mods:/home/ubuntu/dst-mods \
  local/steamcmd:latest \
  sleep infinity
ExecStop=/usr/bin/podman stop -t 30 dst
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

Enable: `sudo systemctl enable --now dst.service`. (The container command above is a placeholder — the actual DST launch command is the next step of the project.)

---

## Cost summary — realistic monthly

| Item | Cost |
|---|---|
| Hetzner CX22 VPS | €4 |
| Backblaze B2 for saves (<1 GB) | ~$0.01 |
| Domain (optional, for friends to remember) | ~$1 |
| **Total** | **~€5 / month** |

---

## Pre-flight checklist

Before spinning up, confirm:

- [ ] Host OS is x86_64 Linux (NOT ARM)
- [ ] 2+ vCPU, 2+ GB RAM, 10+ GB SSD
- [ ] Public IPv4 reachable
- [ ] Podman ≥4.0 installed
- [ ] UDP 10999, 8766, 27016 open inbound
- [ ] Non-root user with SSH key auth
- [ ] Backup destination configured
- [ ] Cluster token in `saves/qkation-cooperative/cluster_token.txt`
- [ ] Region picked with acceptable ping to all players
