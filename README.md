# PIA WG Renewer

Automated rotation of PIA WireGuard credentials for tunnels managed by **Unraid VPN Manager**.

Generates fresh `PrivateKey`, `Address`, `PublicKey`, and `Endpoint` values via a
purpose-built Docker container running the official
[PIA manual-connections](https://github.com/pia-foss/manual-connections) scripts,
then patches the live WireGuard conf files on Unraid — ready for the operator to
restart each tunnel via Unraid VPN Manager.

A companion **monitor script** periodically checks that containers routing through
each VPN tunnel still have working internet connectivity, and sends a native Unraid
notification when a tunnel needs to be renewed.

The container image is built automatically from this repository and published to
GitHub Container Registry. No separate build step is required.

---

## How It Works

```
pia-wg-renewer  (monthly / on-demand)
  → Start pia-wg-renewer container
  → docker exec: run PIA manual-connections inside container
  → Parse new PrivateKey, Address, PublicKey, Endpoint
  → Patch wg1.conf (and optionally wg2.conf …) on the Unraid host
  → Stop container
  → Operator restarts each tunnel via Unraid VPN Manager (toggle off → on)

pia-vpn-monitor  (every 15 minutes)
  → For each configured tunnel + container pair:
      Check WireGuard interface is active
      docker exec: curl connectivity test inside the container
  → On failure: send native Unraid notification
```

The `pia-wg-renewer` container sleeps between runs and is never left active.
Credential generation is ephemeral and fully automated.

---

## Repository Contents

```
pia-wg-renewer/
├── .github/workflows/publish.yml   # Builds and publishes the Docker image
├── container/
│   ├── Dockerfile                  # pia-wg-renewer image definition
│   └── .dockerignore
└── unraid/
    ├── pia.env.template            # Credentials file template
    ├── tunnels.conf.template       # Tunnel definitions template (renewer)
    ├── vpn-monitor.conf.template   # Monitor config template
    ├── pia-wg-renewer.sh           # User Script — credential rotation
    └── pia-vpn-monitor.sh          # User Script — connectivity monitor
```

---

## Prerequisites

- Unraid with **VPN Manager** and at least one WireGuard tunnel configured
- **User Scripts** plugin installed (available in Community Applications)
- A valid PIA subscription

---

## Setup

Full step-by-step instructions including troubleshooting are in [AGENTS.md](./AGENTS.md).

### 1 — Deploy the container on Unraid

Pull and create the container using the image published from this repository:

```bash
docker run -d \
  --name pia-wg-renewer \
  --cap-add NET_ADMIN \
  --cap-add SYS_MODULE \
  --restart no \
  ghcr.io/<owner>/pia-wg-renewer:latest

docker stop pia-wg-renewer
```

> Replace `<owner>` with the GitHub username of this repository.
> The container is stopped immediately after creation — it is only started
> when the User Script runs.

### 2 — Set up credentials and tunnel definitions

```bash
mkdir -p /mnt/user/appdata/pia-wg-renewer

# Credentials
cp unraid/pia.env.template /mnt/user/appdata/pia-wg-renewer/pia.env
chmod 600 /mnt/user/appdata/pia-wg-renewer/pia.env
nano /mnt/user/appdata/pia-wg-renewer/pia.env

# Tunnel definitions
cp unraid/tunnels.conf.template /mnt/user/appdata/pia-wg-renewer/tunnels.conf
nano /mnt/user/appdata/pia-wg-renewer/tunnels.conf
```

Each line in `tunnels.conf` defines one WireGuard tunnel to rotate:
```
tunnel_name:wg_conf_path:routing_table_number:pia_region
```
Add as many lines as you have tunnels. Comment out any tunnel with `#` to skip it
without removing the definition. See `tunnels.conf.template` for the full format
description, list of common PIA region IDs, and how to query PIA for the
complete current region list.

> **Why `/mnt/user/appdata/` and not `/boot/config/`?**
> The `/boot` filesystem is FAT32 — it does not support Unix file permissions,
> so `pia.env` cannot be secured with `chmod 600`. Array-backed `appdata` is also
> the Unraid community convention for persistent application data and integrates
> with backup tools. The WireGuard conf files themselves remain at
> `/boot/config/wireguard/` where Unraid VPN Manager expects them.

### 3 — Install the renewer User Script

1. Unraid → Settings → User Scripts → **Add New Script** → name it `pia-wg-renewer`
2. Paste the contents of `unraid/pia-wg-renewer.sh`
3. The script reads all tunnel definitions from `tunnels.conf` automatically —
   no edits to the script are needed
4. Set schedule to **Monthly** or leave as **On Demand**

After each run, restart tunnels via **Unraid → Settings → WireGuard → toggle each
tunnel Off, then On**. The script patches only the conf files — it does not touch
the host network.

### 4 — Install the monitor User Script

```bash
cp unraid/vpn-monitor.conf.template /mnt/user/appdata/pia-wg-renewer/vpn-monitor.conf
nano /mnt/user/appdata/pia-wg-renewer/vpn-monitor.conf
```

Each line maps a WireGuard tunnel to a container whose connectivity should be checked:
```
tunnel_name:container_name
```

Then in User Scripts:
1. Unraid → Settings → User Scripts → **Add New Script** → name it `pia-vpn-monitor`
2. Paste the contents of `unraid/pia-vpn-monitor.sh`
3. Set schedule to **Every 15 minutes** (`*/15 * * * *`)

The monitor checks that the WireGuard interface is active and that a `curl` from
inside each container reaches the internet. On failure it sends a native Unraid
notification (bell icon + Notifications page) prompting you to run the renewer.

### 5 — Verify PostUp/PostDown rules

After the first run, inspect each conf file and verify the PostUp/PostDown route
order. See [AGENTS.md](./AGENTS.md) for the required rule ordering.

---

## Running Manually

Unraid → Settings → User Scripts → `pia-wg-renewer` → **Run Script**

Or from the Unraid terminal:
```bash
bash /tmp/user.scripts/tmpScripts/pia-wg-renewer/script
```

Last run output is always available at:
```bash
cat /mnt/user/appdata/pia-wg-renewer/logs/last-run.log          # renewer
cat /mnt/user/appdata/pia-wg-renewer/logs/monitor-last-run.log  # monitor
```

---

## License

MIT
