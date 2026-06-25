#!/bin/bash
# PIA VPN Monitor
# Unraid User Script — checks VPN connectivity for containers routing through PIA tunnels.
# Sends a native Unraid notification if a tunnel is down or a container loses connectivity.
# Recommended schedule: Every 15 minutes (*/15 * * * *)
#
# Prerequisites:
#   - /mnt/user/appdata/pia-wg-renewer/vpn-monitor.conf populated with tunnel:container pairs
#   - Containers listed in vpn-monitor.conf must be running and have curl available

# ============================================================
# CONFIG — adjust to your environment
# ============================================================

MONITOR_FILE="/mnt/user/appdata/pia-wg-renewer/vpn-monitor.conf"

# URL curled from inside each container to verify outbound internet connectivity.
# Must return a non-empty response when reachable. The default returns the
# container's public IP, which also confirms traffic is leaving via the VPN.
CHECK_URL="https://ipinfo.io/ip"

# curl timeout in seconds — keep this short so the script doesn't stall
CHECK_TIMEOUT=10

LOG_DIR="/mnt/user/appdata/pia-wg-renewer/logs"
LOG_FILE="${LOG_DIR}/monitor-last-run.log"

# ============================================================
# LOGGING SETUP
# ============================================================

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1

# ============================================================
# FUNCTIONS
# ============================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Send a native Unraid notification (bell icon + Notifications page).
# -i alert  → red/critical severity
send_notification() {
  local tunnel=$1
  local container=$2
  local reason=$3

  local subject="VPN tunnel ${tunnel} is down"
  local description="Container '${container}' lost VPN connectivity (${reason}). Run pia-wg-renewer to rotate credentials, then restart the tunnel via Unraid VPN Manager (toggle Off → On)."

  /usr/local/emhttp/webGui/scripts/notify \
    -e "PIA VPN Monitor" \
    -s "$subject" \
    -d "$description" \
    -i "alert"

  log "Notification sent: $subject — $reason"
}

# Check one tunnel:container pair.
# Returns 0 (pass) or 1 (fail). Sends a notification on failure.
check_entry() {
  local tunnel=$1
  local container=$2

  log "Checking $container via $tunnel..."

  # -- Check 1: WireGuard interface active --
  if ! wg show "$tunnel" &>/dev/null; then
    log "FAIL [$tunnel]: WireGuard interface is not active"
    send_notification "$tunnel" "$container" "WireGuard interface ${tunnel} is not active"
    return 1
  fi

  # -- Check 2: Container is running --
  # A stopped container is not a VPN problem — skip without sending a notification.
  local running
  running=$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)
  if [ "$running" != "true" ]; then
    log "SKIP [$container]: container is not running"
    return 0
  fi

  # -- Check 3: Outbound internet connectivity from inside the container --
  local result
  result=$(docker exec "$container" curl --max-time "$CHECK_TIMEOUT" -s "$CHECK_URL" 2>/dev/null)

  if [ -z "$result" ]; then
    log "FAIL [$container]: no response from $CHECK_URL (timeout or no route)"
    send_notification "$tunnel" "$container" "curl to ${CHECK_URL} returned no response"
    return 1
  fi

  log "OK   [$container]: connected via $tunnel — external IP: $result"
  return 0
}

# ============================================================
# MAIN
# ============================================================

log "=== PIA VPN Monitor Started ==="
log "Monitor config: $MONITOR_FILE"

if [ ! -f "$MONITOR_FILE" ]; then
  log "ERROR: Monitor config not found at $MONITOR_FILE"
  exit 1
fi

entry_count=$(grep -cE '^[^[:space:]#]' "$MONITOR_FILE" 2>/dev/null || echo 0)
if [ "$entry_count" -eq 0 ]; then
  log "ERROR: No active entries found in $MONITOR_FILE"
  exit 1
fi
log "Found $entry_count entr$([ "$entry_count" -eq 1 ] && echo y || echo ies) to check"

failures=0

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue

  IFS=':' read -r tunnel_name container_name <<< "$line"

  if ! check_entry "$tunnel_name" "$container_name"; then
    (( failures++ ))
  fi

done < "$MONITOR_FILE"

log "---"
if [ "$failures" -eq 0 ]; then
  log "All checks passed."
else
  log "$failures check(s) failed — notification(s) sent."
fi

log "=== PIA VPN Monitor Complete ==="
