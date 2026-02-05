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
# Compatible with TrueNAS Scale 24.x, 25.x, and 26.x
#

set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

STATE_DIR="/mnt/zfs_tank/scripts/state"
SERVE_JSON="${STATE_DIR}/tailscale-serve.json"
LOG_FILE="${STATE_DIR}/tailscale-serve-startup.log"

TAILSCALE_CONTAINER_TIMEOUT=180
CHECK_INTERVAL=5
CONTAINER_STARTUP_WAIT=300

# Will be set by detect_cli_method
CLI_METHOD=""

mkdir -p "$STATE_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ============================================================================
# Detect which CLI method works on this TrueNAS version
# Sets CLI_METHOD to "cli" or "midclt"
# ============================================================================
detect_cli_method() {
  log "Detecting TrueNAS CLI method..."
  
  local cli_output
  local midclt_output
  
  # Try cli first (works on older versions)
  # Must check actual output - cli may return 0 even when it fails
  cli_output=$(cli -c "app list" 2>&1 || true)
  if [[ -n "$cli_output" ]] && ! echo "$cli_output" | grep -qi "not found\|error\|namespace"; then
    CLI_METHOD="cli"
    log "  Using 'cli' commands (TrueNAS 24.x/25.x style)"
    return 0
  fi
  
  # Try midclt (works on newer versions and is more reliable)
  midclt_output=$(midclt call app.query 2>/dev/null | jq -r '.[0].name' 2>/dev/null || true)
  if [[ -n "$midclt_output" ]]; then
    CLI_METHOD="midclt"
    log "  Using 'midclt' commands (TrueNAS 25.x/26.x style)"
    return 0
  fi
  
  log "ERROR: Could not detect working CLI method"
  return 1
}

# ============================================================================
# Get list of all app names (version-agnostic)
# ============================================================================
get_app_names() {
  case "$CLI_METHOD" in
    cli)
      cli -c "app list" 2>/dev/null | awk 'NR>3 && NF {print $1}' | grep -v '^-' || true
      ;;
    midclt)
      midclt call app.query 2>/dev/null | jq -r '.[].name' || true
      ;;
  esac
}

# ============================================================================
# Stop an app (version-agnostic)
# ============================================================================
app_stop() {
  local app="$1"
  case "$CLI_METHOD" in
    cli)
      cli -c "app stop $app" >> "$LOG_FILE" 2>&1
      ;;
    midclt)
      midclt call app.stop "$app" >> "$LOG_FILE" 2>&1
      ;;
  esac
}

# ============================================================================
# Start an app (version-agnostic)
# ============================================================================
app_start() {
  local app="$1"
  case "$CLI_METHOD" in
    cli)
      cli -c "app start $app" >> "$LOG_FILE" 2>&1
      ;;
    midclt)
      midclt call app.start "$app" >> "$LOG_FILE" 2>&1
      ;;
  esac
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
# Wait for all apps to finish deploying (smarter than fixed timeout)
# Returns when no apps are in DEPLOYING state or timeout reached
# Also detects stuck apps and tries to fix them
# ============================================================================
wait_for_apps_ready() {
  local max_wait=$1
  local elapsed=0
  local check_interval=15
  local stuck_threshold=120  # Consider stuck after 2 minutes of no change
  local last_deploying=""
  local stuck_time=0
  
  log "Waiting for all apps to finish deploying (max ${max_wait}s)..."
  
  while [[ $elapsed -lt $max_wait ]]; do
    local deploying
    deploying=$(midclt call app.query 2>/dev/null | jq -r '[.[] | select(.state == "DEPLOYING")] | length' || echo "0")
    
    if [[ "$deploying" == "0" ]]; then
      log "All apps finished deploying after ${elapsed}s"
      return 0
    fi
    
    local deploying_names
    deploying_names=$(midclt call app.query 2>/dev/null | jq -r '.[] | select(.state == "DEPLOYING") | .name' | sort | tr '\n' ' ' || true)
    
    # Check if same apps are stuck deploying
    if [[ "$deploying_names" == "$last_deploying" ]]; then
      stuck_time=$((stuck_time + check_interval))
      
      if [[ $stuck_time -ge $stuck_threshold ]]; then
        log "  WARN: Apps appear stuck in DEPLOYING for ${stuck_time}s, attempting fix..."
        
        # Try to start any containers stuck in Created state
        local created
        created=$(docker ps -a --filter "status=created" --format '{{.Names}}' | grep -E '^ix-' | grep -Ev 'permissions|upgrade|init|config' || true)
        if [[ -n "$created" ]]; then
          log "  Found containers in 'Created' state, starting them..."
          for container in $created; do
            log "    Starting: $container"
            docker start "$container" >> "$LOG_FILE" 2>&1 || true
          done
          stuck_time=0  # Reset stuck timer after fix attempt
        fi
      fi
    else
      stuck_time=0  # Reset if deploying list changed
    fi
    last_deploying="$deploying_names"
    
    log "  Still deploying ($deploying apps): $deploying_names- waiting..."
    
    sleep $check_interval
    elapsed=$((elapsed + check_interval))
  done
  
  log "WARN: Timeout waiting for apps to deploy, continuing anyway..."
  return 1
}

# ============================================================================
# Get the actual TrueNAS app name for a container
# Queries the app list and matches against container prefix
# This correctly handles hyphenated app names like "speedtest-tracker"
# ============================================================================
get_app_name_for_container() {
  local container="$1"
  local apps
  apps=$(get_app_names)
  
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
# Start containers stuck in "Created" state (never started)
# ============================================================================
start_created_containers() {
  log "Checking for containers stuck in 'Created' state..."
  local created
  created=$(docker ps -a --filter "status=created" --format '{{.Names}}' | grep -E '^ix-' | grep -Ev 'permissions|upgrade|init|config' || true)
  if [[ -n "$created" ]]; then
    local count
    count=$(echo "$created" | wc -l)
    log "Found $count containers in 'Created' state, starting..."
    for container in $created; do
      log "  Starting: $container"
      if docker start "$container" >> "$LOG_FILE" 2>&1; then
        log "    Started successfully"
      else
        log "    WARN: Failed to start (check logs: docker logs $container)"
      fi
    done
  else
    log "No containers stuck in 'Created' state"
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
      if app_stop "$app"; then
        sleep 5
        if app_start "$app"; then
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
      app_stop "$app" || true
      sleep 5
      app_start "$app" || true
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

# Detect CLI method first
if ! detect_cli_method; then
  log "ERROR: Cannot proceed without working CLI"
  exit 1
fi

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

# Wait for containers to start (smart wait for DEPLOYING apps)
wait_for_apps_ready "$CONTAINER_STARTUP_WAIT"

# Fix again in case new init containers appeared
fix_init_container_restart_policies

# Restart crashed containers and start any stuck in Created state
restart_crashed_containers
start_created_containers
sleep 30

# Check and fix again
fix_init_container_restart_policies
restart_crashed_containers
start_created_containers

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

# ============================================================================
# Helper: verify a port is actually in tailscale serve status
# ============================================================================
verify_serve_active() {
  local port="$1"
  docker exec "$TS_CONTAINER" tailscale serve status 2>/dev/null | grep -q ":${port}" 
}

# ============================================================================
# Helper: apply serve for a single port with verification and retry
# ============================================================================
apply_serve_for_port() {
  local port="$1"
  local max_attempts=3
  
  for attempt in $(seq 1 $max_attempts); do
    docker exec "$TS_CONTAINER" tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >/dev/null 2>&1
    
    # Verify it actually took effect
    sleep 1
    if verify_serve_active "$port"; then
      return 0
    fi
    
    if [[ $attempt -lt $max_attempts ]]; then
      log "  Port $port: serve not active after attempt $attempt, retrying..."
      sleep 2
    fi
  done
  
  return 1
}

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
  
  if apply_serve_for_port "$port"; then
    success=$((success + 1))
  else
    fail=$((fail + 1))
    failed_ports="$failed_ports $port"
    log "WARN: Failed to configure Tailscale serve for port $port (not active after $max_attempts attempts)"
  fi
done

log "Configured $success ports ($fail failed)"
if [[ -n "$failed_ports" ]]; then
  log "Failed ports:$failed_ports"
fi

# ============================================================================
# Second pass: retry failed ports after additional wait
# ============================================================================
if [[ $fail -gt 0 && -n "$failed_ports" ]]; then
  log "==> Second pass: waiting 60s then retrying failed ports..."
  sleep 60
  
  # Check if any DEPLOYING apps remain
  still_deploying=$(midclt call app.query 2>/dev/null | jq -r '.[] | select(.state == "DEPLOYING") | .name' | tr '\n' ' ' || true)
  if [[ -n "$still_deploying" ]]; then
    log "  Apps still deploying: $still_deploying"
    log "  Waiting additional 60s..."
    sleep 60
  fi
  
  retry_success=0
  retry_fail=0
  still_failed=""
  
  for port in $failed_ports; do
    # Check if something is now listening on this port
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      log "  Port $port still has nothing listening - skipping"
      retry_fail=$((retry_fail + 1))
      still_failed="$still_failed $port"
      continue
    fi
    
    if apply_serve_for_port "$port"; then
      log "  Port $port: SUCCESS on retry"
      retry_success=$((retry_success + 1))
    else
      log "  Port $port: FAILED on retry"
      retry_fail=$((retry_fail + 1))
      still_failed="$still_failed $port"
    fi
  done
  
  log "Second pass: $retry_success recovered, $retry_fail still failed"
  if [[ -n "$still_failed" ]]; then
    log "Still failed ports:$still_failed"
  fi
  
  # Update totals
  success=$((success + retry_success))
  fail=$retry_fail
fi

# ============================================================================
# Final verification: check all ports are actually in tailscale serve status
# ============================================================================
log "==> Final verification of all Tailscale serves..."
missing_serves=""
missing_count=0
for port in $ports; do
  if ! verify_serve_active "$port"; then
    # Only flag as missing if something is listening (otherwise it was intentionally skipped)
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      missing_serves="$missing_serves $port"
      missing_count=$((missing_count + 1))
      
      # One last attempt to fix
      log "  Port $port: missing from serve status, attempting recovery..."
      if apply_serve_for_port "$port"; then
        log "  Port $port: recovered"
        missing_count=$((missing_count - 1))
        missing_serves=$(echo "$missing_serves" | sed "s/ $port//")
        success=$((success + 1))
      else
        log "  Port $port: FAILED recovery"
      fi
    fi
  fi
done

if [[ $missing_count -eq 0 ]]; then
  log "  All serves verified OK"
else
  log "  WARN: $missing_count port(s) still missing from serve status:$missing_serves"
fi

log "==> Final result: $success ports configured, $fail failed"

log "==> Startup script completed successfully"
exit 0
