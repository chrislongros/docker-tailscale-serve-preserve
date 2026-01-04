#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Watchtower with Tailscale Serve Preservation
# =============================================================================
# Runs Watchtower to update Docker containers while preserving Tailscale Serve
# configurations. Tailscale Serve ports are lost when the container restarts,
# so this script backs them up and restores them after updates.
#
# Usage: sudo ./watchtower-with-tailscale-serve.sh
#
# Configuration: Set environment variables or edit defaults below
# =============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/state}"
LOG_FILE="${STATE_DIR}/watchtower-tailscale.log"
SERVE_JSON="${STATE_DIR}/tailscale-serve.json"

WT_IMAGE="${WT_IMAGE:-containrrr/watchtower}"
WT_HOSTNAME="${WT_HOSTNAME:-Docker-Host}"
WT_ENV=(
  "-e" "TZ=${TZ:-UTC}"
  "-e" "WATCHTOWER_NOTIFICATIONS_HOSTNAME=${WT_HOSTNAME}"
  "-e" "WATCHTOWER_CLEANUP=true"
  "-e" "WATCHTOWER_INCLUDE_STOPPED=true"
)

# Time to wait for containers to stabilize after Watchtower (seconds)
CONTAINER_STABILIZE_WAIT="${CONTAINER_STABILIZE_WAIT:-60}"

# Maximum time to wait for Tailscale to be ready (seconds)
TAILSCALE_READY_TIMEOUT="${TAILSCALE_READY_TIMEOUT:-30}"

mkdir -p "$STATE_DIR"

# =============================================================================
# Functions
# =============================================================================
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
  # Method 1: Check for official Tailscale image
  container_name=$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -i 'tailscale/tailscale' | head -n1 | cut -f1)
  if [[ -n "$container_name" ]]; then
    echo "$container_name"
    return 0
  fi
  # Method 2: Check for container with 'tailscale' in the name
  container_name=$(docker ps --format '{{.Names}}' | grep -i tailscale | head -n1)
  if [[ -n "$container_name" ]]; then
    echo "$container_name"
    return 0
  fi
  # Method 3: Check for container with tailscale command
  while IFS= read -r name; do
    if docker exec "$name" which tailscale &>/dev/null; then
      echo "$name"
      return 0
    fi
  done < <(docker ps --format '{{.Names}}')
  return 1
}

if [[ -n "${TS_CONTAINER_NAME:-}" ]]; then
  log "Using manually specified container: $TS_CONTAINER_NAME"
else
  log "Auto-detecting Tailscale container..."
  TS_CONTAINER_NAME=$(detect_tailscale_container) || error "Could not auto-detect Tailscale container. Set TS_CONTAINER_NAME environment variable."
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
      cp "${SERVE_JSON}" "${SERVE_JSON}.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      # Keep only last 10 timestamped backups
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
    if docker exec "$TS_CONTAINER_NAME" tailscale serve --bg --https="$port" "$port" >> "$LOG_FILE" 2>&1; then
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

# =============================================================================
# Main
# =============================================================================
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

log "==> Waiting ${CONTAINER_STABILIZE_WAIT} seconds for containers to stabilize..."
sleep "$CONTAINER_STABILIZE_WAIT"

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
