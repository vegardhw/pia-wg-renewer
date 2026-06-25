#!/bin/bash
# PIA WG Renewer
# Unraid User Script — rotates PIA WireGuard credentials for VPN Manager tunnels.
# Recommended schedule: Monthly (or on-demand when a tunnel stops working)
#
# Prerequisites:
#   - pia-wg-renewer container deployed and stopped on Unraid (--restart no)
#   - /mnt/user/appdata/pia-wg-renewer/pia.env populated with credentials
#   - wgN.conf files already configured in Unraid VPN Manager

# ============================================================
# CONFIG — adjust to your environment
# ============================================================

CONTAINER_NAME="pia-wg-renewer"
ENV_FILE="/mnt/user/appdata/pia-wg-renewer/pia.env"
TUNNELS_FILE="/mnt/user/appdata/pia-wg-renewer/tunnels.conf"
LOG_DIR="/mnt/user/appdata/pia-wg-renewer/logs"
LOG_FILE="${LOG_DIR}/last-run.log"

# ============================================================
# LOGGING SETUP
# All output (stdout + stderr) is tee'd to last-run.log AND printed to
# stdout so the Unraid User Scripts UI also displays it in real time.
# last-run.log is overwritten on each run — it always reflects the last run.
# ============================================================

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1

# ============================================================
# FUNCTIONS
# ============================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_exit() {
  log "ERROR: $1"
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  exit 1
}

generate_pia_config() {
  local region=$1

  log "Generating PIA config for region: $region"

  # Credentials are passed via docker exec -e flags so they are injected as true
  # environment variables and never interpolated into the bash -c string. This
  # safely handles any special characters that may appear in the password.
  local output
  output=$(timeout 120 docker exec \
    -e "PIA_USER=${PIA_USER}" \
    -e "PIA_PASS=${PIA_PASS}" \
    "$CONTAINER_NAME" bash -c "
      cd /opt/pia-manual-connections

      # Pre-cleanup: bring down any leftover pia interface from a previous
      # interrupted run before attempting to generate a new config.
      wg-quick down pia 2>/dev/null || true
      rm -f /etc/wireguard/pia.conf

      VPN_PROTOCOL=wireguard \
      PIA_PF=false \
      DISABLE_IPV6=yes \
      PREFERRED_REGION=${region} \
      bash run_setup.sh > /tmp/pia-setup.log 2>&1

      # Output only the generated conf to stdout for parsing by the host script.
      cat /etc/wireguard/pia.conf 2>/dev/null

      # Post-cleanup
      wg-quick down pia 2>/dev/null || true
      rm -f /etc/wireguard/pia.conf
    " 2>&1)

  echo "$output"
}

# Retrieve the PIA setup log from inside the container.
# Called when config generation fails to surface the reason.
get_container_setup_log() {
  docker exec "$CONTAINER_NAME" cat /tmp/pia-setup.log 2>/dev/null \
    || echo "(no setup log available in container)"
}

# Parse a value from a PIA-generated conf line (format: "Key = Value")
parse_value() {
  local output=$1
  local key=$2
  echo "$output" | grep "^${key}" | awk '{print $3}' | tr -d '[:space:]'
}

# Patch the Unraid wg conf file (format: "Key=Value") with all four new values.
# Always backs up the existing conf to conf.bak before making changes.
update_conf() {
  local conf_path=$1
  local new_address=$2
  local new_privkey=$3
  local new_pubkey=$4
  local new_endpoint=$5

  if [ ! -f "$conf_path" ]; then
    error_exit "Config file not found: $conf_path"
  fi

  cp "$conf_path" "${conf_path}.bak"
  log "Backed up existing config to ${conf_path}.bak"

  # [Interface] fields
  sed -i "s|^Address=.*|Address=${new_address}|"         "$conf_path"
  sed -i "s|^PrivateKey=.*|PrivateKey=${new_privkey}|"   "$conf_path"

  # [Peer] fields — PublicKey and Endpoint appear only once, in [Peer]
  sed -i "s|^PublicKey=.*|PublicKey=${new_pubkey}|"      "$conf_path"
  sed -i "s|^Endpoint=.*|Endpoint=${new_endpoint}|"      "$conf_path"

  log "Updated $conf_path"
  log "  Address=${new_address}"
  log "  PrivateKey=<redacted>"
  log "  PublicKey=${new_pubkey}"
  log "  Endpoint=${new_endpoint}"
}

restart_tunnel() {
  local tunnel=$1

  log "Restarting tunnel $tunnel..."
  wg-quick down "$tunnel" 2>/dev/null || true
  sleep 2
  wg-quick up "$tunnel"

  if [ $? -eq 0 ]; then
    log "Tunnel $tunnel restarted successfully"
  else
    log "WARNING: Tunnel $tunnel failed to restart — check config manually"
  fi
}

verify_tunnel() {
  local tunnel=$1

  sleep 5
  local handshake
  handshake=$(wg show "$tunnel" latest-handshakes 2>/dev/null | awk '{print $2}')

  if [ -n "$handshake" ] && [ "$handshake" != "0" ]; then
    log "Tunnel $tunnel verified — handshake received"
    return 0
  else
    log "WARNING: Tunnel $tunnel — no handshake received yet (may still be connecting)"
    return 1
  fi
}

# ============================================================
# MAIN
# ============================================================

log "=== PIA WG Renewer Started ==="
log "Log: $LOG_FILE"

# Load credentials
if [ ! -f "$ENV_FILE" ]; then
  error_exit "Credentials file not found at $ENV_FILE"
fi
source "$ENV_FILE"

if [ -z "$PIA_USER" ] || [ -z "$PIA_PASS" ]; then
  error_exit "PIA_USER or PIA_PASS not set in $ENV_FILE"
fi

# Validate tunnels config
if [ ! -f "$TUNNELS_FILE" ]; then
  error_exit "Tunnels config not found at $TUNNELS_FILE"
fi

tunnel_count=$(grep -cE '^[^[:space:]#]' "$TUNNELS_FILE" 2>/dev/null || echo 0)
if [ "$tunnel_count" -eq 0 ]; then
  error_exit "No active tunnel definitions found in $TUNNELS_FILE"
fi
log "Found $tunnel_count tunnel(s) to process"

# Start container
log "Starting $CONTAINER_NAME container..."
docker start "$CONTAINER_NAME" || error_exit "Failed to start container $CONTAINER_NAME"
sleep 3

# Process each tunnel defined in tunnels.conf
# Skips blank lines and lines starting with #
while IFS= read -r tunnel_config || [[ -n "$tunnel_config" ]]; do
  [[ "$tunnel_config" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${tunnel_config//[[:space:]]/}" ]] && continue

  IFS=':' read -r tunnel_name conf_path table_number region <<< "$tunnel_config"

  log "--- Processing tunnel: $tunnel_name ($region) ---"

  PIA_OUTPUT=$(generate_pia_config "$region")

  # Parse all four values from PIA-generated conf (Key = Value format)
  NEW_ADDRESS=$(parse_value "$PIA_OUTPUT" "Address")
  NEW_PRIVKEY=$(parse_value "$PIA_OUTPUT" "PrivateKey")
  NEW_PUBKEY=$(parse_value "$PIA_OUTPUT" "PublicKey")
  NEW_ENDPOINT=$(parse_value "$PIA_OUTPUT" "Endpoint")

  if [ -z "$NEW_ADDRESS" ] || [ -z "$NEW_PRIVKEY" ] || [ -z "$NEW_PUBKEY" ] || [ -z "$NEW_ENDPOINT" ]; then
    log "WARNING: Incomplete config generated for $tunnel_name — skipping"
    log "  Address='${NEW_ADDRESS}' PrivateKey='${NEW_PRIVKEY:+<set>}' PublicKey='${NEW_PUBKEY}' Endpoint='${NEW_ENDPOINT}'"
    log "PIA setup log from container:"
    get_container_setup_log | while IFS= read -r line; do log "  [container] $line"; done
    continue
  fi

  update_conf "$conf_path" "$NEW_ADDRESS" "$NEW_PRIVKEY" "$NEW_PUBKEY" "$NEW_ENDPOINT"

  restart_tunnel "$tunnel_name"

  verify_tunnel "$tunnel_name"

  log "--- Done with $tunnel_name ---"
  sleep 2
done < "$TUNNELS_FILE"

# Stop container
log "Stopping $CONTAINER_NAME container..."
docker stop "$CONTAINER_NAME"

log "=== PIA WG Renewer Complete ==="
