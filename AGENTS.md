# PIA WG Renewer — Agent Instructions

## Project Purpose

**PIA WG Renewer** automates the rotation of PIA WireGuard credentials for tunnels
managed by Unraid VPN Manager. It generates fresh `PrivateKey`, `Address`,
`PublicKey`, and `Endpoint` values using a purpose-built Docker container that runs
the official PIA manual-connections scripts, then patches the live wg conf files on
Unraid and restarts the tunnels.

---

## Repository Structure

```
pia-wg-renewer/
├── AGENTS.md                              ← Agent instructions (this file)
├── README.md                              ← GitHub-facing project overview
├── .gitignore                             ← Ignores *.env, *.bak, *.log, editor noise
├── .github/
│   └── workflows/
│       └── publish.yml                    ← Builds and publishes the Docker image to ghcr.io
├── container/
│   ├── Dockerfile                         ← pia-wg-renewer image definition
│   └── .dockerignore                      ← Excludes non-build files from the container context
└── unraid/
    ├── pia.env.template                   ← Credentials file template
    ├── tunnels.conf.template              ← Tunnel definitions template
    └── pia-wg-renewer.sh                  ← Unraid User Script (main script)
```

---

## Architecture

```
Unraid User Script (cron / on-demand)
  → Start pia-wg-renewer container (sleeping)
  → docker exec: run PIA manual-connections script inside container
  → Parse PrivateKey + Address (from [Interface]) and PublicKey + Endpoint (from [Peer])
  → sed -i patch wg1.conf (and optionally wg2.conf, wgN.conf) on Unraid host
  → wg-quick down/up to restart each tunnel
  → Stop container
```

The container image (`ghcr.io/<owner>/pia-wg-renewer:latest`) is built automatically
from this repository by the GitHub Actions workflow and published to ghcr.io.
It sleeps indefinitely (`CMD ["sleep", "infinity"]`) and is woken by the User Script
via `docker start` / `docker exec` / `docker stop`. It does NOT restart automatically
(`--restart no`).

---

## Key Files and Their Roles

### `.github/workflows/publish.yml`
GitHub Actions workflow that builds and pushes the `pia-wg-renewer` Docker image to
ghcr.io. Triggers on push to `main` when `container/Dockerfile` changes, or manually
via `workflow_dispatch`. Uses `context: container` so both `Dockerfile` and
`.dockerignore` are picked up from the `container/` directory. The image name is
derived from `github.repository` and resolves to:
`ghcr.io/<owner>/pia-wg-renewer:latest`

After publishing, make the package public:
GitHub → Packages → pia-wg-renewer → Package Settings → Change visibility → Public

### `container/Dockerfile`
Builds a Debian bookworm-slim image with:
- `wireguard-tools`, `curl`, `jq`, `git`, `bash`, `openssh-client`, `iproute2`
- The official PIA manual-connections repo cloned to `/opt/pia-manual-connections`
- Default CMD: `sleep infinity`

### `unraid/tunnels.conf.template`
Template for the tunnel definitions file. Users copy this to:
```
/mnt/user/appdata/pia-wg-renewer/tunnels.conf
```
Each non-comment line defines one tunnel in the format:
`tunnel_name:wg_conf_path:routing_table_number:pia_region`

The template includes format documentation, a list of common PIA region IDs, and
a command to query PIA's server list API for the full current list of region IDs.

### `unraid/pia.env.template`
Template for the credentials file. Users copy this to:
```
/mnt/user/appdata/pia-wg-renewer/pia.env
```
and populate `PIA_USER` and `PIA_PASS`. See storage path guidance below.

### `unraid/pia-wg-renewer.sh`
The main Unraid User Script. Handles the full rotation lifecycle for one or more tunnels.
See implementation details below.

---

## Storage Path Guidance (Unraid)

### Credentials file: `/mnt/user/appdata/pia-wg-renewer/pia.env`

Use **`/mnt/user/appdata/pia-wg-renewer/`** — NOT `/boot/config/pia-*`.

| Path | Verdict | Reason |
|---|---|---|
| `/boot/config/pia-rotator/` | ❌ Avoid | `/boot` is FAT32 — no Unix permissions, cannot `chmod 600`. Flash write endurance concern for log/credential files. |
| `/mnt/user/scripts/` | ⚠️ Acceptable | Works, but `appdata` is the Unraid convention for app-specific data. |
| `/mnt/user/appdata/pia-wg-renewer/` | ✅ Recommended | Array-backed, supports `chmod 600`, follows Unraid CA conventions, integrates with backup tools (CA Backup, Duplicati). |

**Note:** `/boot/config/` is NOT wiped by Unraid OS updates — that is a common
misconception. Updates only replace kernel/boot files. However, the FAT32 permission
limitation alone is reason enough to prefer the array for a credentials file.

**Note:** User Scripts always run after the array is mounted, so `/mnt/user/appdata/`
is reliably available for both scheduled and on-demand runs.

### WireGuard conf files: `/boot/config/wireguard/wgN.conf`

These **must** remain at `/boot/config/wireguard/` — this is where Unraid VPN Manager
reads and writes them. Do not move them.

---

## `pia-wg-renewer.sh` Implementation Details

### CONFIG variables
| Variable | Default | Purpose |
|---|---|---|
| `CONTAINER_NAME` | `pia-wg-renewer` | Docker container to exec into |
| `ENV_FILE` | `/mnt/user/appdata/pia-wg-renewer/pia.env` | Credentials file |
| `TUNNELS_FILE` | `/mnt/user/appdata/pia-wg-renewer/tunnels.conf` | Tunnel definitions file |
| `LOG_DIR` | `/mnt/user/appdata/pia-wg-renewer/logs` | Directory for log files |
| `LOG_FILE` | `${LOG_DIR}/last-run.log` | Overwritten on every run |

### Logging setup
Immediately after `mkdir -p "$LOG_DIR"`, the script redirects all output:
```bash
exec > >(tee "$LOG_FILE") 2>&1
```
This tees **all** stdout and stderr — from every subsequent command and subshell —
to both the Unraid User Scripts UI (stdout) and `last-run.log` simultaneously.
`last-run.log` is overwritten on each run so it always reflects the most recent
execution. No log rotation is needed.

### TUNNELS_FILE and tunnel definitions
Tunnel definitions are read from `TUNNELS_FILE` at runtime — they are **not** inside
the script. This means regions and tunnel counts can be changed by editing one config
file without ever modifying or re-pasting the User Script.

Format of each line in `tunnels.conf`:
```
tunnel_name:wg_conf_path:routing_table_number:pia_region
```
Blank lines and lines beginning with `#` are skipped. Any number of tunnels is
supported — add one line per tunnel.

```
# tunnels.conf example
wg1:/boot/config/wireguard/wg1.conf:201:swiss
wg2:/boot/config/wireguard/wg2.conf:202:norway
wg3:/boot/config/wireguard/wg3.conf:203:france
```

`routing_table_number` is **documentation-only** — the script does not use it.
It is kept in the config so the operator can cross-reference the table numbers
used in the wg conf PostUp/PostDown rules without looking them up separately.

The script validates that `TUNNELS_FILE` exists and contains at least one active
(non-comment) line before starting the container.

**Querying PIA for valid region IDs:**
```bash
docker start pia-wg-renewer
docker exec pia-wg-renewer bash -c \
  "curl -s 'https://serverlist.piaservers.net/vpninfo/servers/v6' \
  | head -1 | jq -r '.regions[].id' | sort"
docker stop pia-wg-renewer
```

### `generate_pia_config(region)`
Wrapped in `timeout 120` to prevent hanging if PIA servers are unreachable.

Credentials are passed via `docker exec -e` flags — **not** interpolated into the
`bash -c` string. This prevents shell injection and correctly handles any special
characters in `PIA_PASS`:
```bash
timeout 120 docker exec \
  -e "PIA_USER=${PIA_USER}" \
  -e "PIA_PASS=${PIA_PASS}" \
  "$CONTAINER_NAME" bash -c "..."
```

Inside the container the exec block:
1. **Pre-cleanup:** runs `wg-quick down pia` to tear down any leftover interface
   from a previously interrupted run (prevents `run_setup.sh` failing on interface
   already exists)
2. Removes any leftover `/etc/wireguard/pia.conf`
3. Runs `run_setup.sh > /tmp/pia-setup.log 2>&1` — all PIA script output goes to
   a log file inside the container, keeping stdout clean for conf parsing
4. `cat /etc/wireguard/pia.conf` — outputs only the conf to stdout
5. **Post-cleanup:** `wg-quick down pia` + `rm pia.conf`

### `get_container_setup_log()`
Retrieves `/tmp/pia-setup.log` from inside the running container via `docker exec`.
Only called on failure — each line is prefixed with `[container]` and passed
through `log()` so it appears in both the UI and `last-run.log`. This surfaces the
full PIA script output (auth errors, region not found, network failures, etc.)
without polluting the normal success-path output.

### `parse_value(output, key)`
Parses a `Key = Value` line from the PIA-generated WireGuard conf (space-padded
`=` format). Uses `grep "^${key}"` + `awk '{print $3}'`. Called for all four keys:
- `PrivateKey` → `[Interface]`
- `Address` → `[Interface]`
- `PublicKey` → `[Peer]`
- `Endpoint` → `[Peer]`

### `update_conf(conf_path, new_address, new_privkey, new_pubkey, new_endpoint)`
Patches the Unraid wg conf file (which uses `Key=Value` format, no spaces) with
four `sed -i` replacements:
```bash
sed -i "s|^Address=.*|Address=${new_address}|"     "$conf_path"
sed -i "s|^PrivateKey=.*|PrivateKey=${new_privkey}|" "$conf_path"
sed -i "s|^PublicKey=.*|PublicKey=${new_pubkey}|"   "$conf_path"
sed -i "s|^Endpoint=.*|Endpoint=${new_endpoint}|"   "$conf_path"
```
`PublicKey=` and `Endpoint=` only appear in the `[Peer]` section so the patterns
are unambiguous. Always backs up to `${conf_path}.bak` before editing.

### `restart_tunnel(tunnel_name)`
Runs `wg-quick down <tunnel>` then `wg-quick up <tunnel>` on the Unraid host.

### `verify_tunnel(tunnel_name)`
Waits 5 seconds then checks `wg show <tunnel> latest-handshakes`. A non-zero
timestamp indicates a successful handshake.

---

## wg Conf File Format Notes

Unraid VPN Manager writes wg conf files in `Key=Value` format (no spaces around `=`):
```ini
[Interface]
PrivateKey=<base64>
Address=10.x.x.x/32
...
[Peer]
PublicKey=<base64>
Endpoint=x.x.x.x:1337
...
```

PIA manual-connections generates conf files in standard WireGuard `Key = Value` format
(spaces around `=`). The `parse_value` function accounts for this difference.

---

## PostUp/PostDown Route Order

After credential rotation, verify the PostUp/PostDown order in each wgN.conf.
Unraid VPN Manager may re-tattoo the conf on next "Apply". Always edit the conf
directly (`nano /boot/config/wireguard/wg1.conf`) and only toggle active/inactive
to restart — never hit Apply after adding custom routes.

Required order in `[Interface]`:
```ini
# VPN Manager tattooed lines (do not remove):
PostUp=ip -4 route flush table 201
PostUp=ip -4 route add default via <tunnel-address> dev wg1 table 201
PostUp=ip -4 route add 10.0.5.0/24 via 10.0.5.1 dev br0 table 201

# Custom lines (must come AFTER flush):
PostUp=ip -4 route add 10.0.1.0/24 via 10.0.5.1 dev br0 table 201
PostUp=ip -4 route add 10.0.2.0/24 via 10.0.5.1 dev br0 table 201
PostUp=ip -4 route add 100.64.0.0/10 via 10.0.5.10 dev br0 table 201

PostDown=ip -4 route flush table 201
PostDown=ip -4 route add unreachable default table 201
PostDown=ip -4 route add 10.0.5.0/24 via 10.0.5.1 dev br0 table 201
PostDown=ip -4 route add 10.0.1.0/24 via 10.0.5.1 dev br0 table 201
PostDown=ip -4 route add 10.0.2.0/24 via 10.0.5.1 dev br0 table 201
PostDown=ip -4 route add 100.64.0.0/10 via 10.0.5.10 dev br0 table 201
```
Table numbers: wg1=201, wg2=202, wg3=203, etc.

---

## Deployment Steps (Full)

### Step 1 — Publish the container image

The image is built and published automatically by GitHub Actions when `container/Dockerfile`
changes on `main`, or can be triggered manually via `workflow_dispatch`.

After the first successful build, make the package public:
GitHub → Packages → pia-wg-renewer → Package Settings → Change visibility → Public

The published image will be available at:
```
ghcr.io/<owner>/pia-wg-renewer:latest
```

### Step 2 — Deploy the container on Unraid

Via Unraid Docker UI or CLI:
```bash
docker run -d \
  --name pia-wg-renewer \
  --cap-add NET_ADMIN \
  --cap-add SYS_MODULE \
  --restart no \
  ghcr.io/<owner>/pia-wg-renewer:latest
```
Then immediately stop it:
```bash
docker stop pia-wg-renewer
```

### Step 3 — Set up credentials and tunnel definitions on Unraid

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

### Step 4 — Install the User Script

1. Install the **User Scripts** plugin from Community Applications
2. Unraid → Settings → User Scripts → Add New Script → name it `pia-wg-renewer`
3. Paste the contents of `unraid/pia-wg-renewer.sh`
4. The script reads tunnel definitions from `tunnels.conf` automatically —
   no changes to the script are needed
5. Set schedule to **Monthly** or leave as **On Demand**

### Step 5 — Verify PostUp/PostDown rules

After first run, inspect each conf file and verify route order as described above.

---

## Troubleshooting

**First step for any failure:**
- Check the last run log: `cat /mnt/user/appdata/pia-wg-renewer/logs/last-run.log`
- On config generation failure the log will include `[container]`-prefixed lines
  from the PIA setup script showing the exact error (auth failure, region issue, etc.)

**Container fails to generate config:**
- Check credentials: `cat /mnt/user/appdata/pia-wg-renewer/pia.env`
- Test manually: `docker start pia-wg-renewer && docker exec -it pia-wg-renewer bash`
- Run PIA script manually inside container to see full output

**Tunnel fails to restart after rotation:**
- Check conf: `cat /boot/config/wireguard/wg1.conf`
- Verify all four values were updated (Address, PrivateKey, PublicKey, Endpoint)
- Check PostUp/PostDown route order (flush must come before custom routes)
- Check handshake: `wg show wg1`

**VPN Manager re-tattoos and breaks route order:**
- Always edit conf directly via `nano`, never re-import via VPN Manager UI
- Only toggle active/inactive to restart — do not hit Apply

**Check active routes:**
```bash
ip route show table 201   # wg1
ip route show table 202   # wg2
```

**Run script manually from Unraid terminal:**
```bash
bash /tmp/user.scripts/tmpScripts/pia-wg-renewer/script
```
