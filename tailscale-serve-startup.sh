#!/usr/bin/env bash
#
# tailscale-serve-startup.sh
#
# Startup script to restore Tailscale Serve configuration after reboot.
# - Waits for Tailscale container to be ready
# - Fixes init container restart policies to prevent loops
# - Verifies port bindings and restarts apps with missing bindings
# - Restarts any crashed containers
# - Applies Tailscale Serve configuration from backup
#

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

STATE_DIR="/mnt/zfs_tank/scripts/state"
SERVE_JSON="${STATE_DIR}/tailscale-serve.json"
LOG_FILE="${STATE_DIR}/tailscale-serve-startup.log"

TAILSCALE_CONTAINER_TIMEOUT=180
CHECK_INTERVAL=5
CONTAINER_STARTUP_WAIT=180

mkdir -p "$STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

detect_tailscale_container() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -i tailscale | head -n1
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
# Get the actual TrueNAS app name for a container
# Queries the app list and matches against container prefix
# This correctly handles hyphenated app names like "speedtest-tracker"
# ============================================================================
get_app_name_for_container() {
  local container="$1"
  local apps
  apps=$(cli -c "app list" 2>/dev/null | awk 'NR>3 && NF {print $1}' | grep -v '^-' || true)
  
  for app in $apps; do
    if [[ "$container" == "ix-${app}-"* ]]; then
      echo "$app"
      return 0
    fi
  done
  return 1
}

# ============================================================================
# CRITICAL: Fix init container restart policies
# Init containers (permissions, upgrade, init) must have restart=no
# otherwise they loop forever and prevent main containers from starting
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
    log "All init containers already have correct restart policy"
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
# Verify port bindings and restart apps with missing bindings
# This fixes the race condition where containers start but ports don't bind
# ============================================================================
verify_and_fix_port_bindings() {
  log "==> Verifying port bindings for all apps..."
  local apps_to_restart=()
  
  # Get all running ix- containers that should have port bindings
  local containers
  containers=$(docker ps --format '{{.Names}}' | grep -E '^ix-' | grep -Ev 'permissions|upgrade|init|config|postgres|redis|valkey|elastic|gotenberg|tika|meilisearch' || true)
  
  for container in $containers; do
    # Check if container has port binding configuration
    local configured_ports
    configured_ports=$(docker inspect "$container" --format '{{json .HostConfig.PortBindings}}' 2>/dev/null)
    
    if [[ "$configured_ports" != "null" && "$configured_ports" != "{}" ]]; then
      # Container has port config - check if actually bound
      local actual_ports
      actual_ports=$(docker port "$container" 2>/dev/null)
      
      if [[ -z "$actual_ports" ]]; then
        # Port configured but not bound - get actual app name
        local app_name
        app_name=$(get_app_name_for_container "$container")
        
        if [[ -z "$app_name" ]]; then
          log "  WARN: Could not determine app name for $container"
          continue
        fi
        
        # Avoid duplicates
        if [[ ! " ${apps_to_restart[*]:-} " =~ " ${app_name} " ]]; then
          apps_to_restart+=("$app_name")
          log "  MISSING PORT BINDING: $container (app: $app_name)"
        fi
      fi
    fi
  done
  
  # Restart apps with missing port bindings
  if [[ ${#apps_to_restart[@]} -gt 0 ]]; then
    log "Found ${#apps_to_restart[@]} app(s) with missing port bindings"
    
    for app in "${apps_to_restart[@]}"; do
      log "  Restarting app: $app"
      if cli -c "app stop $app" >> "$LOG_FILE" 2>&1; then
        sleep 5
        if cli -c "app start $app" >> "$LOG_FILE" 2>&1; then
          log "  Successfully restarted: $app"
        else
          log "  WARN: Failed to start: $app"
        fi
      else
        log "  WARN: Failed to stop: $app"
      fi
    done
    
    # Wait for restarted apps to stabilize
    log "Waiting 30s for restarted apps to stabilize..."
    sleep 30
  else
    log "All port bindings verified OK"
  fi
}

# ============================================================================
# Check for containers stuck in restart loop
# ============================================================================
fix_restart_loops() {
  log "Checking for containers in restart loops..."
  local restarting
  restarting=$(docker ps -a --filter "status=restarting" --format '{{.Names}}' | grep -E '^ix-' | grep -Ev 'permissions|upgrade|init|config' || true)
  
  if [[ -n "$restarting" ]]; then
    log "Found containers in restart loop:"
    local apps_to_restart=()
    
    for container in $restarting; do
      local app_name
      app_name=$(get_app_name_for_container "$container")
      
      if [[ -z "$app_name" ]]; then
        log "  WARN: Could not determine app name for $container"
        continue
      fi
      
      log "  $container (app: $app_name)"
      
      if [[ ! " ${apps_to_restart[*]:-} " =~ " ${app_name} " ]]; then
        apps_to_restart+=("$app_name")
      fi
    done
    
    for app in "${apps_to_restart[@]}"; do
      log "  Restarting app to fix loop: $app"
      cli -c "app stop $app" >> "$LOG_FILE" 2>&1 || true
      sleep 5
      cli -c "app start $app" >> "$LOG_FILE" 2>&1 || true
    done
    
    log "Waiting 30s for apps to stabilize..."
    sleep 30
  else
    log "No containers in restart loops"
  fi
}

# Main
log "=========================================="
log "==> Tailscale Serve Startup Script"
log "=========================================="

# Wait for Tailscale container
if ! wait_for_tailscale_container "$TAILSCALE_CONTAINER_TIMEOUT"; then
  log "ERROR: Tailscale container not found after ${TAILSCALE_CONTAINER_TIMEOUT}s"
  exit 1
fi

# Wait for Tailscale to be ready
log "Waiting for Tailscale to be ready..."
for i in {1..30}; do
  if docker exec "$TS_CONTAINER" tailscale status >/dev/null 2>&1; then
    log "Tailscale is ready"
    break
  fi
  sleep 2
done

# Reset any existing serves to free ports
log "Resetting Tailscale Serve to free ports..."
docker exec "$TS_CONTAINER" tailscale serve reset >> "$LOG_FILE" 2>&1 || true

# Fix init container restart policies BEFORE waiting for containers
log "==> Fixing init container restart policies (prevents restart loops)..."
fix_init_container_restart_policies

# Wait for containers to start
log "Waiting ${CONTAINER_STARTUP_WAIT}s for all containers to start..."
sleep "$CONTAINER_STARTUP_WAIT"

# Fix again in case new init containers appeared
fix_init_container_restart_policies

# Restart crashed containers (after fixing init containers)
restart_crashed_containers
sleep 30

# Check and fix again
fix_init_container_restart_policies
restart_crashed_containers

# Fix containers stuck in restart loops
fix_restart_loops

# Verify and fix port bindings before applying Tailscale serves
verify_and_fix_port_bindings

# Now apply serves (after all containers are running with correct port bindings)
ports=$(get_ports_from_backup)
if [[ -z "$ports" ]]; then
  log "ERROR: No ports in backup file"
  exit 1
fi

log "Applying serves for ports: $(echo $ports | tr '\n' ' ')"

success=0
fail=0
failed_ports=""
for port in $ports; do
  # First check if something is actually listening on this port
  if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    log "WARN: Nothing listening on port $port - skipping"
    fail=$((fail + 1))
    failed_ports="$failed_ports $port"
    continue
  fi
  
  if docker exec "$TS_CONTAINER" tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >/dev/null 2>&1; then
    success=$((success + 1))
  else
    fail=$((fail + 1))
    failed_ports="$failed_ports $port"
    log "WARN: Failed to configure Tailscale serve for port $port"
  fi
done

log "Configured $success ports ($fail failed)"
if [[ -n "$failed_ports" ]]; then
  log "Failed ports:$failed_ports"
fi

log "==> Startup script completed successfully"
exit 0
