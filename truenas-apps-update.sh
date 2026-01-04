#!/usr/bin/env bash
#
# truenas-apps-update.sh
#
# Updates TrueNAS Scale apps (Docker-based) and Docker images while preserving
# Tailscale Serve configuration.
#
# Features:
# - Sequential app updates (prevents system overload)
# - Automatic init container restart policy fixes
# - Tailscale Serve backup and restore
# - Stuck app detection and recovery
# - Optional Watchtower integration for Docker image updates
#
# Requirements:
# - TrueNAS Scale 24.10+ (Electric Eel) with Docker-based apps
# - Tailscale app installed (optional, for Tailscale Serve features)
# - jq installed (usually pre-installed on TrueNAS)
#
# Usage:
#   ./truenas-apps-update.sh
#
# Configuration:
#   Edit the variables in the "User Configuration" section below.
#
# License: BSD-3-Clause
#

set -euo pipefail

# ============================================================================
# User Configuration - Modify these values for your setup
# ============================================================================

# Directory for state files and logs (must be on persistent storage)
STATE_DIR="/mnt/tank/scripts/state"

# Log file location
LOG_FILE="${STATE_DIR}/truenas-apps-update.log"

# Tailscale Serve backup file
SERVE_JSON="${STATE_DIR}/tailscale-serve.json"

# Enable Tailscale Serve backup/restore (set to false if not using Tailscale)
ENABLE_TAILSCALE_SERVE=true

# Enable Watchtower for Docker image updates (set to false to skip)
ENABLE_WATCHTOWER=true

# Watchtower image to use
WATCHTOWER_IMAGE="containrrr/watchtower"

# Watchtower environment variables
WATCHTOWER_TZ="UTC"
WATCHTOWER_CLEANUP=true
WATCHTOWER_INCLUDE_STOPPED=true

# ============================================================================
# Timeout Configuration
# ============================================================================

MIDCLT_TIMEOUT=60           # Timeout for midclt API calls (seconds)
APP_DEPLOY_TIMEOUT=300      # Max time to wait for app deployment (seconds)
APP_STOP_TIMEOUT=60         # Max time to wait for app to stop (seconds)
TAILSCALE_READY_TIMEOUT=30  # Max time to wait for Tailscale (seconds)
STABILIZATION_WAIT=60       # Time to wait after updates for stabilization (seconds)
STUCK_APP_RETRY_DELAY=10    # Delay between stuck app recovery attempts (seconds)

# ============================================================================
# End of User Configuration
# ============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

mkdir -p "$STATE_DIR"

# Logging functions
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
  log "ERROR: $*" >&2
  exit 1
}

warn() {
  log "WARN: $*"
}

# Check dependencies
if ! command -v docker &> /dev/null; then
  error "Docker command not found"
fi

if ! command -v jq &> /dev/null; then
  error "jq command not found"
fi

# ============================================================================
# Init Container Restart Policy Fix
# 
# CRITICAL: Init containers (permissions, upgrade, init) must NOT have
# restart=always, otherwise they loop forever and block main containers.
# ============================================================================
fix_init_container_restart_policies() {
  log "==> Fixing init container restart policies..."
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
        warn "  Failed to fix $container"
      fi
    fi
  done
  
  if [[ $fixed -gt 0 ]]; then
    log "Fixed restart policy on $fixed init container(s)"
  else
    log "All init containers have correct restart policy"
  fi
}

# Wrapper for midclt with timeout
midclt_call() {
  local timeout="${MIDCLT_TIMEOUT}"
  if timeout "$timeout" midclt call "$@" 2>/dev/null; then
    return 0
  else
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
      warn "midclt call timed out after ${timeout}s: $*"
    fi
    return $exit_code
  fi
}

# Get app state
get_app_state() {
  local app_name="$1"
  midclt_call app.query | jq -r --arg name "$app_name" '.[] | select(.name == $name) | .state' 2>/dev/null || echo "UNKNOWN"
}

# Get all apps in a specific state
get_apps_in_state() {
  local state="$1"
  midclt_call app.query | jq -r --arg state "$state" '.[] | select(.state == $state) | .name' 2>/dev/null || true
}

# Wait for app to reach target state
wait_for_app_state() {
  local app_name="$1"
  local target_state="$2"
  local timeout="$3"
  local elapsed=0
  local check_interval=5

  log "  Waiting for $app_name to reach $target_state (timeout: ${timeout}s)..."
  
  while [[ $elapsed -lt $timeout ]]; do
    local current_state
    current_state=$(get_app_state "$app_name")
    
    if [[ "$current_state" == "$target_state" ]]; then
      log "  $app_name is now $target_state"
      return 0
    elif [[ "$current_state" == "STOPPED" && "$target_state" == "RUNNING" ]]; then
      warn "$app_name stopped unexpectedly"
      return 1
    else
      log "  $app_name: $current_state (${elapsed}s/${timeout}s)"
      sleep "$check_interval"
    fi
    
    elapsed=$((elapsed + check_interval))
  done
  
  warn "$app_name did not reach $target_state within ${timeout}s"
  return 1
}

# Restart a stuck app
restart_stuck_app() {
  local app_name="$1"
  
  log "  Attempting to restart stuck app: $app_name"
  
  # Fix init containers for this app
  local app_init_containers
  app_init_containers=$(docker ps -a --format '{{.Names}}' | grep -E "^ix-${app_name}-.*(permissions|upgrade|init)" || true)
  for container in $app_init_containers; do
    docker update --restart=no "$container" >/dev/null 2>&1 || true
  done
  
  # Try stop/start
  log "  Stopping $app_name..."
  if midclt_call app.stop "$app_name" >> "$LOG_FILE" 2>&1; then
    if wait_for_app_state "$app_name" "STOPPED" "$APP_STOP_TIMEOUT"; then
      sleep 3
      log "  Starting $app_name..."
      if midclt_call app.start "$app_name" >> "$LOG_FILE" 2>&1; then
        if wait_for_app_state "$app_name" "RUNNING" "$APP_DEPLOY_TIMEOUT"; then
          log "  Successfully restarted $app_name"
          return 0
        fi
      fi
    fi
  fi
  
  # Try redeploy as fallback
  log "  Stop/start failed, trying redeploy for $app_name..."
  if midclt_call app.redeploy "$app_name" >> "$LOG_FILE" 2>&1; then
    if wait_for_app_state "$app_name" "RUNNING" "$APP_DEPLOY_TIMEOUT"; then
      log "  Successfully redeployed $app_name"
      return 0
    fi
  fi
  
  warn "Could not restart $app_name"
  return 1
}

# Handle stuck deploying apps
handle_stuck_deploying_apps() {
  log "==> Checking for apps stuck in DEPLOYING state..."
  
  local stuck_apps
  stuck_apps=$(get_apps_in_state "DEPLOYING")
  
  if [[ -z "$stuck_apps" ]]; then
    log "No apps stuck in DEPLOYING state"
    return 0
  fi
  
  local stuck_count
  stuck_count=$(echo "$stuck_apps" | wc -l)
  log "Found $stuck_count app(s) stuck in DEPLOYING: $(echo $stuck_apps | tr '\n' ' ')"
  
  for app in $stuck_apps; do
    log "Handling stuck app: $app"
    restart_stuck_app "$app" || warn "Failed to recover $app - may need manual intervention"
    sleep "$STUCK_APP_RETRY_DELAY"
  done
}

# ============================================================================
# Tailscale Functions
# ============================================================================

TS_CONTAINER_NAME=""

detect_tailscale_container() {
  local container_name
  # Try to find by image name first
  container_name=$(docker ps --format '{{.Names}}\t{{.Image}}' | grep -i 'tailscale/tailscale' | head -n1 | cut -f1)
  if [[ -n "$container_name" ]]; then
    echo "$container_name"
    return 0
  fi
  # Fall back to name matching
  container_name=$(docker ps --format '{{.Names}}' | grep -i tailscale | head -n1)
  if [[ -n "$container_name" ]]; then
    echo "$container_name"
    return 0
  fi
  return 1
}

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

check_tailscale_container() {
  if ! docker ps --format '{{.Names}}' | grep -q "^${TS_CONTAINER_NAME}$"; then
    error "Container '$TS_CONTAINER_NAME' is not running"
  fi
}

backup_serves() {
  log "==> Backing up Tailscale Serve configuration"
  if ts serve status --json > "${SERVE_JSON}.tmp" 2>/dev/null; then
    if grep -q '"TCP"' "${SERVE_JSON}.tmp" && ! grep -q '"TCP": {}' "${SERVE_JSON}.tmp"; then
      mv "${SERVE_JSON}.tmp" "${SERVE_JSON}"
      local port_count
      port_count=$(grep -oP '"[0-9]+":' "${SERVE_JSON}" | wc -l)
      log "Backed up $port_count ports to ${SERVE_JSON}"
      # Keep timestamped backups
      cp "${SERVE_JSON}" "${SERVE_JSON}.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
      # Clean old backups (keep last 10)
      find "$STATE_DIR" -name "tailscale-serve.json.*" -type f 2>/dev/null | sort -r | tail -n +11 | xargs -r rm -f
    else
      warn "No active Tailscale Serve ports found"
      rm -f "${SERVE_JSON}.tmp"
    fi
  else
    warn "Could not backup serve config"
    rm -f "${SERVE_JSON}.tmp"
  fi
}

restore_serves() {
  if [[ ! -f "${SERVE_JSON}" ]]; then
    warn "No JSON backup found - skipping restore"
    return 0
  fi
  if [[ ! -s "${SERVE_JSON}" ]]; then
    warn "JSON backup is empty - skipping restore"
    return 0
  fi
  
  local ports
  ports=$(grep -oP '"([0-9]+)":\s*\{' "${SERVE_JSON}" | grep -oP '[0-9]+' | sort -n | uniq)
  if [[ -z "$ports" ]]; then
    warn "No ports found in backup - skipping restore"
    return 0
  fi
  
  local port_count
  port_count=$(echo "$ports" | wc -l)
  log "==> Restoring Tailscale Serve configuration for $port_count ports"
  
  local success_count=0
  local fail_count=0
  for port in $ports; do
    if docker exec "$TS_CONTAINER_NAME" tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >> "$LOG_FILE" 2>&1; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
      warn "Failed to configure port $port"
    fi
  done
  
  log "Configured $success_count of $port_count ports ($fail_count failed)"
}

# ============================================================================
# Update Functions
# ============================================================================

update_truenas_apps() {
  log "==> Checking for TrueNAS app updates..."
  
  if ! command -v midclt &> /dev/null; then
    warn "midclt not found - skipping TrueNAS app updates"
    return 0
  fi
  
  # Fix init containers first
  fix_init_container_restart_policies
  
  # Handle stuck apps
  handle_stuck_deploying_apps
  
  # Get apps with updates
  local apps_to_update
  apps_to_update=$(midclt_call app.query | jq -r '.[] | select(.upgrade_available == true) | .name' 2>/dev/null || true)
  
  if [[ -z "$apps_to_update" ]]; then
    log "No TrueNAS app updates available"
    return 0
  fi
  
  local app_count
  app_count=$(echo "$apps_to_update" | wc -l)
  log "Found $app_count app(s) with updates: $(echo $apps_to_update | tr '\n' ' ')"
  
  # Update apps sequentially
  local success_count=0
  local fail_count=0
  local current=0
  
  for app in $apps_to_update; do
    current=$((current + 1))
    log "==> Updating app $current/$app_count: $app"
    
    if midclt_call app.upgrade "$app" '{"app_version": "latest"}' >> "$LOG_FILE" 2>&1; then
      log "  Upgrade started for: $app"
      sleep 5
      
      # Fix init containers for this app
      local app_init_containers
      app_init_containers=$(docker ps -a --format '{{.Names}}' | grep -E "^ix-${app}-.*(permissions|upgrade|init)" || true)
      for container in $app_init_containers; do
        docker update --restart=no "$container" >/dev/null 2>&1 || true
      done
      
      if wait_for_app_state "$app" "RUNNING" "$APP_DEPLOY_TIMEOUT"; then
        log "  Successfully upgraded: $app"
        success_count=$((success_count + 1))
      else
        warn "Upgrade may have failed for: $app"
        restart_stuck_app "$app" && success_count=$((success_count + 1)) || fail_count=$((fail_count + 1))
      fi
    else
      warn "Failed to start upgrade for: $app"
      fail_count=$((fail_count + 1))
    fi
    
    sleep 5
  done
  
  log "==> TrueNAS app upgrades complete: $success_count succeeded, $fail_count failed"
}

run_watchtower() {
  if [[ "$ENABLE_WATCHTOWER" != "true" ]]; then
    log "==> Watchtower disabled, skipping"
    return 0
  fi
  
  log "==> Running Watchtower (run-once)"
  
  local wt_env=()
  wt_env+=("-e" "TZ=${WATCHTOWER_TZ}")
  wt_env+=("-e" "WATCHTOWER_CLEANUP=${WATCHTOWER_CLEANUP}")
  wt_env+=("-e" "WATCHTOWER_INCLUDE_STOPPED=${WATCHTOWER_INCLUDE_STOPPED}")
  
  if ! docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "${wt_env[@]}" \
    "$WATCHTOWER_IMAGE" --run-once 2>&1 | tee -a "$LOG_FILE"; then
    warn "Watchtower encountered errors"
  fi
  
  # Fix init containers after Watchtower
  fix_init_container_restart_policies
}

# ============================================================================
# Main
# ============================================================================

log "=========================================="
log "==> TrueNAS Apps Update Script"
log "=========================================="

# Initialize Tailscale if enabled
if [[ "$ENABLE_TAILSCALE_SERVE" == "true" ]]; then
  log "Auto-detecting Tailscale container..."
  TS_CONTAINER_NAME=$(detect_tailscale_container) || error "Could not find Tailscale container"
  log "Detected Tailscale container: $TS_CONTAINER_NAME"
  
  check_tailscale_container
  
  if ! ts version >/dev/null 2>&1; then
    error "Cannot communicate with Tailscale"
  fi
  
  backup_serves
  
  log "==> Stopping Tailscale Serve listeners"
  ts serve reset || warn "Failed to reset serve"
fi

# Fix init containers at start
fix_init_container_restart_policies

# Update TrueNAS apps
update_truenas_apps

# Run Watchtower
run_watchtower

log "==> Waiting ${STABILIZATION_WAIT}s for containers to stabilize..."
sleep "$STABILIZATION_WAIT"

# Final init container fix
fix_init_container_restart_policies

# Restore Tailscale Serve
if [[ "$ENABLE_TAILSCALE_SERVE" == "true" ]]; then
  log "==> Re-detecting Tailscale container..."
  NEW_CONTAINER=$(detect_tailscale_container) || error "Could not find Tailscale container after update"
  
  if [[ "$NEW_CONTAINER" != "$TS_CONTAINER_NAME" ]]; then
    log "Container name changed: $TS_CONTAINER_NAME -> $NEW_CONTAINER"
    TS_CONTAINER_NAME="$NEW_CONTAINER"
  fi
  
  check_tailscale_container
  wait_for_tailscale "$TAILSCALE_READY_TIMEOUT"
  restore_serves
  
  sleep 2
  log "==> Checking Tailscale Serve status"
  if ts serve status >/dev/null 2>&1; then
    log "Tailscale Serve is active"
  else
    warn "No Tailscale Serve configuration active"
  fi
fi

log "==> Script completed successfully"
exit 0
