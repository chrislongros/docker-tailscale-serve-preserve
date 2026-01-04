#!/usr/bin/env bash
#
# tailscale-serve-startup.sh
#
# Startup script to restore Tailscale Serve configuration after system reboot.
# Designed to run as a systemd service or init script on TrueNAS Scale.
#
# Features:
# - Waits for Tailscale container to be ready
# - Fixes init container restart policies
# - Restarts crashed app containers
# - Restores Tailscale Serve configuration from backup
#
# Requirements:
# - TrueNAS Scale 24.10+ (Electric Eel) with Docker-based apps
# - Tailscale app installed
# - Backup file created by truenas-apps-update.sh
#
# Usage:
#   ./tailscale-serve-startup.sh
#
# Systemd Integration:
#   See README.md for systemd service unit example.
#
# License: BSD-3-Clause
#

set -uo pipefail

# ============================================================================
# User Configuration - Modify these values for your setup
# ============================================================================

# Directory for state files and logs (must match truenas-apps-update.sh)
STATE_DIR="/mnt/tank/scripts/state"

# Tailscale Serve backup file
SERVE_JSON="${STATE_DIR}/tailscale-serve.json"

# Log file location
LOG_FILE="${STATE_DIR}/tailscale-serve-startup.log"

# How long to wait for Tailscale container to appear (seconds)
TAILSCALE_CONTAINER_TIMEOUT=180

# How long to wait for containers to start before applying serves (seconds)
CONTAINER_STARTUP_WAIT=90

# Interval between checks (seconds)
CHECK_INTERVAL=5

# ============================================================================
# End of User Configuration
# ============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

mkdir -p "$STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

detect_tailscale_container() {
  # Try to find by image name first
  local container
  container=$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null | grep -i 'tailscale/tailscale' | head -n1 | cut -f1)
  if [[ -n "$container" ]]; then
    echo "$container"
    return 0
  fi
  # Fall back to name matching
  container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i tailscale | head -n1)
  if [[ -n "$container" ]]; then
    echo "$container"
    return 0
  fi
  return 1
}

wait_for_tailscale_container() {
  local timeout=$1
  local elapsed=0
  log "Waiting for Tailscale container (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    if TS_CONTAINER=$(detect_tailscale_container) && [[ -n "$TS_CONTAINER" ]]; then
      log "Detected Tailscale container: $TS_CONTAINER"
      return 0
    fi
    sleep $CHECK_INTERVAL
    elapsed=$((elapsed + CHECK_INTERVAL))
  done
  return 1
}

get_ports_from_backup() {
  [[ -f "$SERVE_JSON" ]] && grep -oP '"([0-9]+)":\s*\{' "$SERVE_JSON" | grep -oP '[0-9]+' | sort -n | uniq
}

# ============================================================================
# Init Container Restart Policy Fix
# ============================================================================
fix_init_container_restart_policies() {
  log "Fixing init container restart policies..."
  local fixed=0
  local containers
  containers=$(docker ps -a --format '{{.Names}}' | grep -E '(permissions|upgrade|init)' || true)
  
  if [[ -z "$containers" ]]; then
    log "No init containers found"
    return 0
  fi
  
  for container in $containers; do
    local current_policy
    current_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null || echo "unknown")
    
    if [[ "$current_policy" != "no" && "$current_policy" != "" ]]; then
      if docker update --restart=no "$container" >/dev/null 2>&1; then
        log "  Fixed $container: $current_policy -> no"
        fixed=$((fixed + 1))
      else
        log "WARN: Failed to fix $container"
      fi
    fi
  done
  
  if [[ $fixed -gt 0 ]]; then
    log "Fixed restart policy on $fixed init container(s)"
  else
    log "All init containers have correct restart policy"
  fi
}

restart_crashed_containers() {
  log "Checking for crashed containers..."
  local crashed
  crashed=$(docker ps -a --filter "status=exited" --format '{{.Names}}' | grep -E '^ix-' | grep -Ev 'permissions|upgrade|init|config' || true)
  if [[ -n "$crashed" ]]; then
    local count
    count=$(echo "$crashed" | wc -l)
    log "Found $count crashed containers, restarting..."
    echo "$crashed" | xargs -r docker start >> "$LOG_FILE" 2>&1 || true
    log "Restarted containers"
  else
    log "No crashed containers found"
  fi
}

# ============================================================================
# Main
# ============================================================================

log "=========================================="
log "==> Tailscale Serve Startup Script"
log "=========================================="

# Wait for Tailscale container
if ! wait_for_tailscale_container "$TAILSCALE_CONTAINER_TIMEOUT"; then
  log "ERROR: Tailscale container not found after ${TAILSCALE_CONTAINER_TIMEOUT}s"
  exit 1
fi

# Wait for Tailscale daemon to be ready
log "Waiting for Tailscale to be ready..."
for i in {1..30}; do
  if docker exec "$TS_CONTAINER" tailscale status >/dev/null 2>&1; then
    log "Tailscale is ready"
    break
  fi
  sleep 2
done

# Reset existing serves to free ports
log "Resetting Tailscale Serve to free ports..."
docker exec "$TS_CONTAINER" tailscale serve reset >> "$LOG_FILE" 2>&1 || true

# Fix init container restart policies BEFORE waiting
log "==> Fixing init container restart policies..."
fix_init_container_restart_policies

# Wait for containers to start
log "Waiting ${CONTAINER_STARTUP_WAIT}s for containers to start..."
sleep "$CONTAINER_STARTUP_WAIT"

# Fix again and restart crashed containers
fix_init_container_restart_policies
restart_crashed_containers
sleep 30

# Final check
fix_init_container_restart_policies
restart_crashed_containers

# Apply Tailscale Serve configuration
ports=$(get_ports_from_backup)
if [[ -z "$ports" ]]; then
  log "ERROR: No ports found in backup file: $SERVE_JSON"
  exit 1
fi

log "Applying serves for ports: $(echo $ports | tr '\n' ' ')"

success=0
fail=0
for port in $ports; do
  if docker exec "$TS_CONTAINER" tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >/dev/null 2>&1; then
    success=$((success + 1))
  else
    fail=$((fail + 1))
    log "WARN: Failed to configure port $port"
  fi
done

log "Configured $success ports ($fail failed)"
log "==> Startup script completed successfully"
exit 0
