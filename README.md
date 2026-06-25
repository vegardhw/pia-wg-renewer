# PIA WG Renewer

Automated rotation of PIA WireGuard credentials for tunnels managed by **Unraid VPN Manager**.

Generates fresh `PrivateKey`, `Address`, `PublicKey`, and `Endpoint` values via a
purpose-built Docker container running the official
[PIA manual-connections](https://github.com/pia-foss/manual-connections) scripts,
then patches the live WireGuard conf files on Unraid and restarts the tunnels — all
from a single Unraid User Script.

The container image is built automatically from this repository and published to
GitHub Container Registry. No separate build step is required.

---

## How It Works

```
Unraid User Script (scheduled monthly or on-demand)
  → Start pia-wg-renewer container
  → docker exec: run PIA manual-connections inside container
  → Parse new PrivateKey, Address, PublicKey, Endpoint
  → Patch wg1.conf (and optionally wg2.conf …) on the Unraid host
  → wg-quick down/up to restart each tunnel
  → Stop container
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
    ├── tunnels.conf.template       # Tunnel definitions template
    └── pia-wg-renewer.sh           # Unraid User Script
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

### 3 — Install the User Script

1. Unraid → Settings → User Scripts → **Add New Script** → name it `pia-wg-renewer`
2. Paste the contents of `unraid/pia-wg-renewer.sh`
3. The script reads all tunnel definitions from `tunnels.conf` automatically —
   no edits to the script are needed
4. Set schedule to **Monthly** or leave as **On Demand**

### 4 — Verify PostUp/PostDown rules

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
cat /mnt/user/appdata/pia-wg-renewer/logs/last-run.log
```

---

## License

MIT
