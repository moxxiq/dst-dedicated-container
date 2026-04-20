# Beszel monitoring

Self-hosted system + container monitoring with a small web UI. Runs
alongside the DST and admin stacks on the same VPS.

- **Hub UI** on port `8090` — charts, alerts, multi-system dashboard.
- **Agent** on port `45876` — reports CPU, RAM, disk, net, and per-container
  stats by reading the host podman socket.

Both live in this one compose file. If you later add more VPSes, only the
agent needs to be deployed there — one hub can watch many hosts.

## First-run setup

```bash
cd monitoring
podman compose up -d
```

1. Open `http://<vps-ip>:8090` and create the first admin user.
2. Click **Add new system**. Use:
   - **Name**: anything, e.g. `dst-vps`
   - **Host/IP**: `localhost` (or the VPS's private IP if you split later)
   - **Port**: `45876`
3. The hub shows a one-off SSH public key. Copy it, then:

```bash
cp .env.example .env
# paste the key into BESZEL_AGENT_KEY=...
podman compose up -d     # recreates the agent with the new key
```

The system turns green within ~30 seconds. DST's container appears in the
container list automatically (as long as DST is running under the same
podman user).

## Memory footprint

Hub + agent together sit around 150–180 MB RSS on an idle VPS. Safe to
colocate with a 2 GB DST server.

## Firewall

The hub UI (`:8090`) should be reachable from your IP only. Add a Vultr
Cloud Firewall rule:

- **Protocol**: TCP
- **Port**: `8090`
- **Source**: your home IP / CIDR

The agent port (`:45876`) should **not** be exposed publicly — only the
hub needs to reach it, and since they share the host network here, the
connection is local. Leave that port out of your firewall rules.

## Teardown

```bash
cd monitoring
podman compose down
```

Data is kept in named podman volumes (`beszel_data`, `beszel_agent_data`).
To wipe, add `-v` to the `down` command.
