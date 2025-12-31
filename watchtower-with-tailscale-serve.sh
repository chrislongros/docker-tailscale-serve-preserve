#!/usr/bin/env bash
#
# watchtower-with-tailscale-serve.sh
#
# Runs Watchtower to update Docker containers while preserving Tailscale Serve configuration.
# Designed for TrueNAS Scale but works on any Docker + Tailscale setup.
#
# Usage:
#   1. Configure the variables below or set them as environment variables
#   2. Run via cron (e.g., daily at 3 AM)
#
# GitHub: https://github.com/chrislongros/docker-tailscale-serve-preserve
# License: MIT
#

set -euo pipefail

#######################################
# CONFIGURATION
# Override these via environment variables or edit directly
#######################################

# Directory to store state files (backups, logs) - REQUIRED
# Example: STATE_DIR="/opt/tailscale-serve-preserve"
# Example: STATE_DIR="/mnt/data/scripts/state"
STATE_DIR="${STATE_DIR:-}"

if [[ -z "$STATE_DIR" ]]; then
  echo "ERROR: STATE_DIR is not set. Please set it to your preferred directory." >&2
  echo "Example: STATE_DIR=/opt/tailscale-serve-preserve $0" >&2
  exit 1
fi

# Tailscale Serve backup file
SERVE_JSON="${SERVE_JSON:-${STATE_DIR}/tailscale-serve.json}"

# Log file location
LOG_FILE="${LOG_FILE:-${STATE_DIR}/watchtower-tailscale.log}"

# Watchtower image to use
# Example: WT_IMAGE="containrrr/watchtower"
WT_IMAGE="${WT_IMAGE:-containrrr/watchtower}"

# Timezone for Watchtower
# Example: TZ="America/New_York"
# Example: TZ="Europe/London"
TZ="${TZ:-UTC}"

# Watchtower notification hostname
# Example: WT_HOSTNAME="my-nas"
WT_HOSTNAME="${WT_HOSTNAME:-Docker-Host}"

# How long to wait for Tailscale to be ready (seconds)
TAILSCALE_READY_TIMEOUT="${TAILSCALE_READY_TIMEOUT:-30}"

# How long to wait after Watchtower for containers to stabilize (seconds)
STABILIZATION_WAIT="${STABILIZATION_WAIT:-60}"

# Tailscale container name (leave empty for auto-detection)
# The script will automatically find your Tailscale container by:
#   1. Looking for image name containing "tailscale/tailscale"
#   2. Looking for container name containing "tailscale"
#   3. Checking containers for the tailscale binary
# Only set this if auto-detection fails
# Example: TS_CONTAINER_NAME="tailscale"
# Example: TS_CONTAINER_NAME="ix-tailscale-tailscale-1"
TS_CONTAINER_NAME="${TS_CONTAINER_NAME:-}"

#######################################
# END CONFIGURATION
#######################################

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

WT_ENV=(
  "-e" "TZ=${TZ}"
  "-e" "WATCHTOWER_NOTIFICATIONS_HOSTNAME=${WT_HOSTNAME}"
  "-e" "WATCHTOWER_CLEANUP=true"
  "-e" "WATCHTOWER_INCLUDE_STOPPED=true"
)

mkdir -p "$STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
  log "ERROR: $*" >&2
  exit 1
}

if ! command -v docker &> /dev/null; then
  error "Docker command not found. PATH=$PATH"
fi

detect_tailscale_container() {
  local container_name
  
  # Try to find by image name first
  container_name=$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -i 'tailscale/tailscale' | head -n1 | cut -f1)
  if [[ -n "$container_name" ]]; then
    echo "$container_name"
    return 0
  fi
  
  # Try to find by container name
  container_name=$(docker ps --format '{{.Names}}' | grep -i tailscale | head -n1)
  if [[ -n "$container_name" ]]; then
    echo "$container_name"
    return 0
  fi
  
  # Last resort: check each container for tailscale binary
  while IFS= read -r name; do
    if docker exec "$name" which tailscale &>/dev/null; then
      echo "$name"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}')
  
  return 1
}

if [[ -n "${TS_CONTAINER_NAME}" ]]; then
  log "Using manually specified container: $TS_CONTAINER_NAME"
else
  log "Auto-detecting Tailscale container..."
  TS_CONTAINER_NAME=$(detect_tailscale_container) || error "Could not auto-detect Tailscale container. Set TS_CONTAINER_NAME manually."
  log "Detected Tailscale container: $TS_CONTAINER_NAME"
fi

ts() { 
  docker exec "$TS_CONTAINER_NAME" tailscale "$@"
}

wait_for_tailscale() {
  local timeout=$1
  local elapsed=0
  log "Waiting for Tailscale to be ready (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    if ts status >/dev/null 2>&1; then
      log "Tailscale is ready"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  error "Tailscale did not become ready within ${timeout}s"
}

check_container() {
  if ! docker ps --format '{{.Names}}' | grep -q "^${TS_CONTAINER_NAME}$"; then
    error "Container '$TS_CONTAINER_NAME' is not running"
  fi
}

backup_serves() {
  log "==> Backing up current Tailscale Serve configuration"
  if ts serve status --json > "${SERVE_JSON}.tmp" 2>/dev/null; then
    if grep -q '"TCP"' "${SERVE_JSON}.tmp" && ! grep -q '"TCP": {}' "${SERVE_JSON}.tmp"; then
      mv "${SERVE_JSON}.tmp" "${SERVE_JSON}"
      port_count=$(grep -oP '"[0-9]+":' "${SERVE_JSON}" | wc -l)
      log "Backed up $port_count ports to ${SERVE_JSON}"
      
      # Keep last 10 timestamped backups
      cp "${SERVE_JSON}" "${SERVE_JSON}.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      find "$STATE_DIR" -name "tailscale-serve.json.*" -type f 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
    else
      log "WARN: No active Tailscale Serve ports found in JSON"
      rm -f "${SERVE_JSON}.tmp"
    fi
  else
    log "WARN: Could not backup serve config; continuing with existing backup"
    rm -f "${SERVE_JSON}.tmp"
  fi
}

restore_serves() {
  if [[ ! -f "${SERVE_JSON}" ]]; then
    log "WARN: No JSON backup found at ${SERVE_JSON} - skipping restore"
    return 0
  fi
  if [[ ! -s "${SERVE_JSON}" ]]; then
    log "WARN: JSON backup is empty - skipping restore"
    return 0
  fi
  
  local ports
  ports=$(grep -oP '"([0-9]+)":\s*\{' "${SERVE_JSON}" | grep -oP '[0-9]+' | sort -n | uniq)
  if [[ -z "$ports" ]]; then
    log "WARN: No ports found in JSON backup - skipping restore"
    return 0
  fi
  
  local port_count
  port_count=$(echo "$ports" | wc -l)
  log "==> Restoring Tailscale Serve configuration for $port_count ports"
  
  local success_count=0
  local fail_count=0
  
  for port in $ports; do
    # Use http://127.0.0.1:$port to proxy to localhost instead of binding to the port directly
    # This avoids conflicts with Docker containers that also bind to 0.0.0.0:$port
    if docker exec "$TS_CONTAINER_NAME" tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >> "$LOG_FILE" 2>&1; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
      log "WARN: Failed to configure port $port"
    fi
  done
  
  log "Configured $success_count of $port_count ports successfully"
  if [[ $fail_count -gt 0 ]]; then
    log "WARN: $fail_count ports failed to configure"
  fi
}

# Main execution
log "==> Starting Watchtower update with Tailscale Serve preservation"
log "==> Using Tailscale container: $TS_CONTAINER_NAME"

check_container

if ! ts version >/dev/null 2>&1; then
  error "Cannot communicate with Tailscale"
fi

backup_serves

log "==> Stopping Tailscale Serve listeners"
ts serve reset || log "WARN: Failed to reset serve (may not be configured)"

log "==> Running Watchtower (run-once)"
if ! docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  "${WT_ENV[@]}" \
  "$WT_IMAGE" --run-once 2>&1 | tee -a "$LOG_FILE"; then
  error "Watchtower failed"
fi

log "==> Waiting ${STABILIZATION_WAIT} seconds for containers to stabilize..."
sleep "$STABILIZATION_WAIT"

log "==> Re-detecting Tailscale container after update..."
NEW_CONTAINER=$(detect_tailscale_container) || error "Could not find Tailscale container after update"

if [[ "$NEW_CONTAINER" != "$TS_CONTAINER_NAME" ]]; then
  log "Container name changed: $TS_CONTAINER_NAME -> $NEW_CONTAINER"
  TS_CONTAINER_NAME="$NEW_CONTAINER"
else
  log "Container name unchanged: $TS_CONTAINER_NAME"
fi

check_container
wait_for_tailscale "$TAILSCALE_READY_TIMEOUT"
restore_serves

sleep 2
log "==> Checking Tailscale Serve status"
if ts serve status >/dev/null 2>&1; then
  log "==> Tailscale Serve is active"
  active_count=$(ts serve status --json 2>/dev/null | grep -oP '"[0-9]+":' | wc -l || echo 0)
  log "Active serves: $active_count ports"
else
  log "WARN: No Tailscale Serve configuration active"
fi

log "==> Script completed successfully"
exit 0
