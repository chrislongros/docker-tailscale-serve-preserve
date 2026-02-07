#!/usr/bin/env bash
#
# tailscale-serve-startup.sh
#
# Startup script to restore Tailscale Serve configuration after reboot.
# - Waits for Tailscale container to be ready
# - Fixes init container restart policies to prevent loops
# - Restarts ALL crashed containers (TrueNAS apps + standalone)
# - Verifies port bindings and restarts containers with missing bindings
# - Applies Tailscale Serve configuration from backup
# - Saves updated config after applying
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

# Containers to never restart (port conflicts, internal-only, support containers)
EXCLUDE_PATTERN='permissions|upgrade|init|config|sist2'
# Additional exclusions for port binding checks (support containers without exposed ports)
PORT_EXCLUDE_PATTERN='permissions|upgrade|init|config|postgres|redis|valkey|elastic|gotenberg|tika|meilisearch|sist2|gluetun'

# Will be set by detect_cli_method
CLI_METHOD=""

mkdir -p "$STATE_DIR"

# ============================================================================
# Colors and formatting
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Status symbols
OK="${GREEN}✔${NC}"
FAIL="${RED}✘${NC}"
WARN="${YELLOW}⚠${NC}"
INFO="${BLUE}ℹ${NC}"
ARROW="${CYAN}➜${NC}"
STAR="${MAGENTA}★${NC}"

log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  # Log without colors to file
  echo "[$timestamp] $*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
  # Print with colors to terminal
  echo -e "${DIM}[$timestamp]${NC} $*"
}

header() {
  echo ""
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo -e "${BOLD}${WHITE}  $*${NC}"
  echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"
  echo ""
  log "==> $*"
}

subheader() {
  echo ""
  echo -e "  ${BOLD}${BLUE}── $* ──${NC}"
  log "--- $*"
}

success() {
  log " ${OK} $*"
}

warn() {
  log " ${WARN} $*"
}

fail() {
  log " ${FAIL} $*"
}

info() {
  log " ${INFO} $*"
}

# ============================================================================
# Detect which CLI method works on this TrueNAS version
# ============================================================================
detect_cli_method() {
  subheader "Detecting TrueNAS CLI method"

  local cli_output
  local midclt_output

  cli_output=$(cli -c "app list" 2>&1 || true)
  if [[ -n "$cli_output" ]] && ! echo "$cli_output" | grep -qi "not found\|error\|namespace"; then
    CLI_METHOD="cli"
    success "Using ${BOLD}cli${NC} commands (TrueNAS 24.x/25.x style)"
    return 0
  fi

  midclt_output=$(midclt call app.query 2>/dev/null | jq -r '.[0].name' 2>/dev/null || true)
  if [[ -n "$midclt_output" ]]; then
    CLI_METHOD="midclt"
    success "Using ${BOLD}midclt${NC} commands (TrueNAS 25.x/26.x style)"
    return 0
  fi

  fail "Could not detect working CLI method"
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

app_stop() {
  local app="$1"
  case "$CLI_METHOD" in
    cli)    cli -c "app stop $app" >> "$LOG_FILE" 2>&1 ;;
    midclt) midclt call app.stop "$app" >> "$LOG_FILE" 2>&1 ;;
  esac
}

app_start() {
  local app="$1"
  case "$CLI_METHOD" in
    cli)    cli -c "app start $app" >> "$LOG_FILE" 2>&1 ;;
    midclt) midclt call app.start "$app" >> "$LOG_FILE" 2>&1 ;;
  esac
}

detect_tailscale_container() {
  docker ps --format '{{.Names}}' 2>/dev/null | grep -i tailscale | head -n1
}

# ============================================================================
# Get the actual TrueNAS app name for a container
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
# Wait for Tailscale container
# ============================================================================
wait_for_tailscale_container() {
  local timeout=$1
  local elapsed=0
  subheader "Waiting for Tailscale container (timeout: ${timeout}s)"

  while [[ $elapsed -lt $timeout ]]; do
    if TS_CONTAINER=$(detect_tailscale_container) && [[ -n "$TS_CONTAINER" ]]; then
      success "Detected container: ${BOLD}$TS_CONTAINER${NC}"
      return 0
    fi
    sleep $CHECK_INTERVAL
    elapsed=$((elapsed + CHECK_INTERVAL))
    echo -ne "\r  ${DIM}Waiting... ${elapsed}s${NC}    "
  done
  echo ""
  fail "Tailscale container not found after ${timeout}s"
  return 1
}

# ============================================================================
# Wait for Tailscale to be ready
# ============================================================================
wait_for_tailscale_ready() {
  subheader "Waiting for Tailscale to be ready"
  for i in {1..30}; do
    if docker exec "$TS_CONTAINER" tailscale status >/dev/null 2>&1; then
      success "Tailscale is ready"
      return 0
    fi
    sleep 2
  done
  fail "Tailscale not ready after 60s"
  return 1
}

# ============================================================================
# Wait for all apps to finish deploying
# ============================================================================
wait_for_apps_ready() {
  local max_wait=$1
  local elapsed=0
  local check_interval=15
  local stuck_threshold=120
  local last_deploying=""
  local stuck_time=0

  subheader "Waiting for apps to finish deploying (max ${max_wait}s)"

  while [[ $elapsed -lt $max_wait ]]; do
    local deploying
    deploying=$(midclt call app.query 2>/dev/null | jq -r '[.[] | select(.state == "DEPLOYING")] | length' || echo "0")

    if [[ "$deploying" == "0" ]]; then
      success "All apps finished deploying after ${elapsed}s"
      return 0
    fi

    local deploying_names
    deploying_names=$(midclt call app.query 2>/dev/null | jq -r '.[] | select(.state == "DEPLOYING") | .name' | sort | tr '\n' ' ' || true)

    if [[ "$deploying_names" == "$last_deploying" ]]; then
      stuck_time=$((stuck_time + check_interval))
      if [[ $stuck_time -ge $stuck_threshold ]]; then
        warn "Apps stuck in DEPLOYING for ${stuck_time}s, attempting fix..."
        local created
        created=$(docker ps -a --filter "status=created" --format '{{.Names}}' | grep -Ev "$EXCLUDE_PATTERN" || true)
        if [[ -n "$created" ]]; then
          for container in $created; do
            info "Starting stuck container: ${BOLD}$container${NC}"
            docker start "$container" >> "$LOG_FILE" 2>&1 || true
          done
          stuck_time=0
        fi
      fi
    else
      stuck_time=0
    fi
    last_deploying="$deploying_names"

    info "Still deploying (${deploying} apps): ${YELLOW}${deploying_names}${NC}"
    sleep $check_interval
    elapsed=$((elapsed + check_interval))
  done

  warn "Timeout waiting for apps to deploy, continuing..."
  return 1
}

# ============================================================================
# Fix init container restart policies
# ============================================================================
fix_init_container_restart_policies() {
  subheader "Fixing init container restart policies"
  local fixed=0
  local containers
  containers=$(docker ps -a --format '{{.Names}}' | grep -E '(permissions|upgrade|init)' || true)

  if [[ -z "$containers" ]]; then
    info "No init containers found"
    return 0
  fi

  for container in $containers; do
    local current_policy
    current_policy=$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null || echo "unknown")

    if [[ "$current_policy" != "no" && "$current_policy" != "" ]]; then
      if docker update --restart=no "$container" >/dev/null 2>&1; then
        success "Fixed ${BOLD}$container${NC}: $current_policy → no"
        fixed=$((fixed + 1))
      else
        warn "Failed to fix $container"
      fi
    fi
  done

  if [[ $fixed -gt 0 ]]; then
    success "Fixed restart policy on ${BOLD}$fixed${NC} init container(s)"
  else
    success "All init containers already have correct restart policy"
  fi
}

# ============================================================================
# Restart crashed containers (ALL, not just ix-)
# ============================================================================
restart_crashed_containers() {
  subheader "Checking for crashed containers"
  local crashed
  crashed=$(docker ps -a --filter "status=exited" --format '{{.Names}}\t{{.Status}}' | grep -Ev "$EXCLUDE_PATTERN" || true)

  if [[ -z "$crashed" ]]; then
    success "No crashed containers found"
    return 0
  fi

  # Filter out containers that exited cleanly (exit 0) - these are one-shot tasks
  local needs_restart=""
  while IFS=$'\t' read -r name sts; do
    if echo "$sts" | grep -qP 'Exited \(0\)'; then
      info "Skipping ${DIM}$name${NC} (clean exit)"
    else
      needs_restart="$needs_restart $name"
      warn "Crashed: ${BOLD}$name${NC} (${RED}$sts${NC})"
    fi
  done <<< "$crashed"

  if [[ -z "$needs_restart" ]]; then
    success "No containers need restarting"
    return 0
  fi

  local count=0
  for container in $needs_restart; do
    if docker start "$container" >> "$LOG_FILE" 2>&1; then
      success "Restarted: ${BOLD}$container${NC}"
      count=$((count + 1))
    else
      fail "Failed to restart: ${BOLD}$container${NC}"
    fi
  done
  info "Restarted ${BOLD}$count${NC} container(s)"
}

# ============================================================================
# Start containers stuck in "Created" state
# ============================================================================
start_created_containers() {
  subheader "Checking for containers stuck in 'Created' state"
  local created
  created=$(docker ps -a --filter "status=created" --format '{{.Names}}' | grep -Ev "$EXCLUDE_PATTERN" || true)

  if [[ -z "$created" ]]; then
    success "No containers stuck in Created state"
    return 0
  fi

  for container in $created; do
    if docker start "$container" >> "$LOG_FILE" 2>&1; then
      success "Started: ${BOLD}$container${NC}"
    else
      fail "Failed to start: ${BOLD}$container${NC}"
    fi
  done
}

# ============================================================================
# Fix containers stuck in restart loop
# ============================================================================
fix_restart_loops() {
  subheader "Checking for containers in restart loops"
  local restarting
  restarting=$(docker ps -a --filter "status=restarting" --format '{{.Names}}' | grep -Ev "$EXCLUDE_PATTERN" || true)

  if [[ -z "$restarting" ]]; then
    success "No containers in restart loops"
    return 0
  fi

  local apps_to_restart=()

  for container in $restarting; do
    local app_name
    app_name=$(get_app_name_for_container "$container" 2>/dev/null || true)

    if [[ -n "$app_name" ]]; then
      # TrueNAS app: restart via app manager
      if [[ ! " ${apps_to_restart[*]:-} " =~ " ${app_name} " ]]; then
        apps_to_restart+=("$app_name")
      fi
    else
      # Standalone container: restart directly
      warn "Restart loop: ${BOLD}$container${NC} (standalone)"
      docker restart "$container" >> "$LOG_FILE" 2>&1 || true
    fi
  done

  for app in "${apps_to_restart[@]}"; do
    warn "Restart loop in app: ${BOLD}$app${NC}"
    app_stop "$app" || true
    sleep 5
    app_start "$app" || true
  done

  if [[ ${#apps_to_restart[@]} -gt 0 ]]; then
    info "Waiting 30s for apps to stabilize..."
    sleep 30
  fi
}

# ============================================================================
# Verify port bindings and fix containers with missing bindings
# ============================================================================
verify_and_fix_port_bindings() {
  subheader "Verifying port bindings"
  local apps_to_restart=()
  local fixed_standalone=0

  local containers
  containers=$(docker ps --format '{{.Names}}' | grep -Ev "$PORT_EXCLUDE_PATTERN" || true)

  for container in $containers; do
    local configured_ports
    configured_ports=$(docker inspect "$container" --format '{{json .HostConfig.PortBindings}}' 2>/dev/null)

    if [[ "$configured_ports" != "null" && "$configured_ports" != "{}" ]]; then
      local actual_ports
      actual_ports=$(docker port "$container" 2>/dev/null)

      if [[ -z "$actual_ports" ]]; then
        # Check network mode - containers using another container's network won't have direct ports
        local net_mode
        net_mode=$(docker inspect "$container" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)
        if [[ "$net_mode" == container:* ]]; then
          # Using another container's network (e.g., qbittorrent via gluetun)
          continue
        fi

        local app_name
        app_name=$(get_app_name_for_container "$container" 2>/dev/null || true)

        if [[ -z "$app_name" ]]; then
          # Standalone container: restart directly
          warn "Missing port binding: ${BOLD}$container${NC} (standalone) — restarting"
          docker restart "$container" >> "$LOG_FILE" 2>&1 || true
          fixed_standalone=$((fixed_standalone + 1))
          continue
        fi

        if [[ ! " ${apps_to_restart[*]:-} " =~ " ${app_name} " ]]; then
          apps_to_restart+=("$app_name")
          warn "Missing port binding: ${BOLD}$container${NC} (app: ${CYAN}$app_name${NC})"
        fi
      fi
    fi
  done

  if [[ ${#apps_to_restart[@]} -gt 0 ]]; then
    info "Restarting ${BOLD}${#apps_to_restart[@]}${NC} app(s) with missing port bindings"
    for app in "${apps_to_restart[@]}"; do
      info "Restarting app: ${BOLD}$app${NC}"
      app_stop "$app" 2>/dev/null || true
      sleep 5
      app_start "$app" 2>/dev/null || true
    done
    info "Waiting 30s for restarted apps to stabilize..."
    sleep 30
  elif [[ $fixed_standalone -eq 0 ]]; then
    success "All port bindings verified OK"
  else
    info "Fixed ${BOLD}$fixed_standalone${NC} standalone container(s)"
  fi
}

# ============================================================================
# Bring up docker compose stacks
# ============================================================================
restore_compose_stacks() {
  subheader "Checking Docker Compose stacks"

  # Immich stack (Portainer-managed)
  local immich_compose="/mnt/.ix-apps/app_mounts/portainer/data/compose/1/docker-compose.yml"
  local immich_env="/mnt/.ix-apps/app_mounts/portainer/data/compose/1/stack.env"

  if [[ -f "$immich_compose" && -f "$immich_env" ]]; then
    info "Found Immich compose stack, ensuring all containers are up..."
    if docker compose -f "$immich_compose" --env-file "$immich_env" up -d >> "$LOG_FILE" 2>&1; then
      success "Immich stack is up"
    else
      warn "Immich stack had issues (check logs)"
    fi
  fi
}

# ============================================================================
# Apply Tailscale serves from backup
# ============================================================================
apply_tailscale_serves() {
  subheader "Applying Tailscale Serve configuration"

  local ports
  ports=$(get_ports_from_backup)
  if [[ -z "$ports" ]]; then
    fail "No ports in backup file: $SERVE_JSON"
    return 1
  fi

  local port_count
  port_count=$(echo "$ports" | wc -w)
  info "Found ${BOLD}$port_count${NC} ports in backup"

  local success_count=0
  local fail_count=0
  local skip_count=0
  local failed_ports=""

  for port in $ports; do
    if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      warn "Port ${YELLOW}$port${NC} — nothing listening, skipping"
      skip_count=$((skip_count + 1))
      failed_ports="$failed_ports $port"
      continue
    fi

    if apply_serve_for_port "$port"; then
      success "Port ${GREEN}$port${NC} ${OK}"
      success_count=$((success_count + 1))
    else
      fail "Port ${RED}$port${NC} ${FAIL}"
      fail_count=$((fail_count + 1))
      failed_ports="$failed_ports $port"
    fi
  done

  echo ""
  info "Results: ${GREEN}${success_count} configured${NC}, ${YELLOW}${skip_count} skipped${NC}, ${RED}${fail_count} failed${NC}"

  # Second pass for failed/skipped ports
  if [[ -n "$failed_ports" ]]; then
    subheader "Second pass: retrying failed ports (waiting 60s)"
    sleep 60

    local retry_success=0
    local still_failed=""

    for port in $failed_ports; do
      if ! ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        info "Port ${YELLOW}$port${NC} — still nothing listening"
        still_failed="$still_failed $port"
        continue
      fi

      if apply_serve_for_port "$port"; then
        success "Port ${GREEN}$port${NC} recovered ${OK}"
        retry_success=$((retry_success + 1))
      else
        fail "Port ${RED}$port${NC} still failing"
        still_failed="$still_failed $port"
      fi
    done

    if [[ $retry_success -gt 0 ]]; then
      info "Recovered ${GREEN}$retry_success${NC} port(s) on second pass"
    fi
    if [[ -n "$still_failed" ]]; then
      warn "Still failed:${RED}$still_failed${NC}"
    fi

    success_count=$((success_count + retry_success))
  fi

  return 0
}

get_ports_from_backup() {
  [[ -f "$SERVE_JSON" ]] && grep -oP '"([0-9]+)":\s*\{' "$SERVE_JSON" | grep -oP '[0-9]+' | sort -n | uniq
}

verify_serve_active() {
  local port="$1"
  docker exec "$TS_CONTAINER" tailscale serve status 2>/dev/null | grep -q ":${port}"
}

apply_serve_for_port() {
  local port="$1"
  local max_attempts=3

  for attempt in $(seq 1 $max_attempts); do
    docker exec "$TS_CONTAINER" tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >/dev/null 2>&1
    sleep 1
    if verify_serve_active "$port"; then
      return 0
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      sleep 2
    fi
  done
  return 1
}

# ============================================================================
# Final verification
# ============================================================================
final_verification() {
  subheader "Final verification"

  local ports
  ports=$(get_ports_from_backup)
  local total=0
  local active=0
  local missing=0

  for port in $ports; do
    total=$((total + 1))
    if verify_serve_active "$port"; then
      active=$((active + 1))
    elif ss -tlnp 2>/dev/null | grep -q ":${port} "; then
      # Something listening but serve not active — try one more time
      if apply_serve_for_port "$port"; then
        success "Recovered port ${GREEN}$port${NC}"
        active=$((active + 1))
      else
        fail "Port ${RED}$port${NC} — serve not active despite listener"
        missing=$((missing + 1))
      fi
    fi
  done

  echo ""
  if [[ $missing -eq 0 ]]; then
    success "All serves verified OK (${GREEN}${active}/${total}${NC})"
  else
    warn "${active}/${total} serves active, ${RED}${missing} missing${NC}"
  fi
}

# ============================================================================
# Save current serve config
# ============================================================================
save_serve_config() {
  subheader "Saving Tailscale Serve config"
  if docker exec "$TS_CONTAINER" tailscale serve status --json > "$SERVE_JSON" 2>/dev/null; then
    local count
    count=$(grep -c HTTPS "$SERVE_JSON" || echo "0")
    success "Saved config with ${BOLD}$count${NC} entries"
  else
    warn "Could not save serve config"
  fi
}

# ============================================================================
# Container status summary
# ============================================================================
print_container_summary() {
  subheader "Container Status Summary"

  local running healthy unhealthy restarting exited
  running=$(docker ps --format '{{.Names}}' | wc -l)
  healthy=$(docker ps --filter "health=healthy" --format '{{.Names}}' | wc -l)
  unhealthy=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' | wc -l)
  restarting=$(docker ps -a --filter "status=restarting" --format '{{.Names}}' | wc -l)
  exited=$(docker ps -a --filter "status=exited" --format '{{.Names}}' | grep -Ev 'permissions|upgrade|init|config' | grep -cP 'Exited \([1-9]' 2>/dev/null || echo "0")

  echo -e "  ${GREEN}●${NC} Running:     ${BOLD}$running${NC}"
  echo -e "  ${GREEN}●${NC} Healthy:     ${BOLD}$healthy${NC}"
  if [[ "$unhealthy" -gt 0 ]]; then
    echo -e "  ${RED}●${NC} Unhealthy:   ${BOLD}$unhealthy${NC}"
  fi
  if [[ "$restarting" -gt 0 ]]; then
    echo -e "  ${YELLOW}●${NC} Restarting:  ${BOLD}$restarting${NC}"
  fi

  # Count crashed (non-zero exit, excluding init containers)
  local crashed_containers
  crashed_containers=$(docker ps -a --filter "status=exited" --format '{{.Names}}\t{{.Status}}' | grep -Ev 'permissions|upgrade|init|config' | grep -v 'Exited (0)' || true)
  local crashed_count=0
  if [[ -n "$crashed_containers" ]]; then
    crashed_count=$(echo "$crashed_containers" | wc -l)
    echo -e "  ${RED}●${NC} Crashed:     ${BOLD}$crashed_count${NC}"
    while IFS=$'\t' read -r name sts; do
      echo -e "    ${RED}└─${NC} $name ${DIM}($sts)${NC}"
    done <<< "$crashed_containers"
  fi
  echo ""
}

# ============================================================================
# MAIN
# ============================================================================

header "Tailscale Serve Startup Script"

if ! detect_cli_method; then
  fail "Cannot proceed without working CLI"
  exit 1
fi

if ! wait_for_tailscale_container "$TAILSCALE_CONTAINER_TIMEOUT"; then
  fail "Tailscale container not found"
  exit 1
fi

wait_for_tailscale_ready

# Reset existing serves
info "Resetting Tailscale Serve to free ports..."
docker exec "$TS_CONTAINER" tailscale serve reset >> "$LOG_FILE" 2>&1 || true

# Phase 1: Fix init containers
header "Phase 1: Container Health"
fix_init_container_restart_policies

# Wait for apps
wait_for_apps_ready "$CONTAINER_STARTUP_WAIT"

# Fix init containers again (new ones may have appeared)
fix_init_container_restart_policies

# Phase 2: Restart crashed/stuck containers
header "Phase 2: Container Recovery"
restart_crashed_containers
start_created_containers
info "Waiting 30s for containers to stabilize..."
sleep 30

# Check again after stabilization
fix_init_container_restart_policies
restart_crashed_containers
start_created_containers
fix_restart_loops

# Phase 3: Restore compose stacks
header "Phase 3: Compose Stacks"
restore_compose_stacks

# Phase 4: Verify port bindings
header "Phase 4: Port Bindings"
verify_and_fix_port_bindings

# Phase 5: Apply Tailscale serves
header "Phase 5: Tailscale Serves"
apply_tailscale_serves

# Phase 6: Final verification
header "Phase 6: Verification"
final_verification
save_serve_config
print_container_summary

# Done
header "Startup Complete"
success "Script finished successfully"
echo ""
