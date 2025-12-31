#!/usr/bin/env bash
#
# tailscale-serve-startup.sh
#
# Restores Tailscale Serve configuration after system boot.
# Waits for Docker containers to be healthy before applying serve rules.
# Designed for TrueNAS Scale but works on any Docker + Tailscale setup.
#
# Usage:
#   1. Configure the variables below or set them as environment variables
#   2. Run as a post-init/startup script
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
STATE_DIR="${STATE_DIR:-}"

if [[ -z "$STATE_DIR" ]]; then
  echo "ERROR: STATE_DIR is not set. Please set it to your preferred directory." >&2
  echo "Example: STATE_DIR=/opt/tailscale-serve-preserve $0" >&2
  exit 1
fi

# Tailscale Serve backup file (created by watchtower-with-tailscale-serve.sh)
SERVE_JSON="${SERVE_JSON:-${STATE_DIR}/tailscale-serve.json}"

# Log file location
LOG_FILE="${LOG_FILE:-${STATE_DIR}/tailscale-serve-startup.log}"

# How long to wait for containers to be healthy (seconds)
CONTAINER_TIMEOUT="${CONTAINER_TIMEOUT:-300}"

# How long to wait for Tailscale to be ready (seconds)
TAILSCALE_READY_TIMEOUT="${TAILSCALE_READY_TIMEOUT:-60}"

# Check interval when waiting for containers (seconds)
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"

# Initial delay to let Docker fully start (seconds)
INITIAL_DELAY="${INITIAL_DELAY:-10}"

# Final stabilization delay before applying serves (seconds)
FINAL_DELAY="${FINAL_DELAY:-10}"

# Tailscale container name (leave empty for auto-detection)
TS_CONTAINER_NAME="${TS_CONTAINER_NAME:-}"

#######################################
# END CONFIGURATION
#######################################

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

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

get_ports_from_backup() {
  if [[ ! -f "${SERVE_JSON}" ]] || [[ ! -s "${SERVE_JSON}" ]]; then
    return 1
  fi
  grep -oP '"([0-9]+)":\s*\{' "${SERVE_JSON}" | grep -oP '[0-9]+' | sort -n | uniq
}

# Get container name for a port by checking which container has that port mapped
get_container_for_port() {
  local port=$1
  docker ps --format '{{.Names}}\t{{.Ports}}' | grep ":${port}->" | head -n1 | cut -f1
}

# Check if a container is healthy
is_container_healthy() {
  local container=$1
  local health
  health=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "none")
  
  if [[ "$health" == "healthy" ]]; then
    return 0
  elif [[ "$health" == "none" ]]; then
    # Container has no healthcheck, check if it's running
    local state
    state=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "unknown")
    [[ "$state" == "running" ]]
  else
    return 1
  fi
}

# Wait for all containers that have ports in our backup to be healthy
wait_for_containers() {
  local ports="$1"
  local timeout=$CONTAINER_TIMEOUT
  local elapsed=0
  
  log "Waiting for containers to be healthy (timeout: ${timeout}s)..."
  
  # Build list of containers we need to wait for
  local containers=()
  for port in $ports; do
    local container
    container=$(get_container_for_port "$port")
    if [[ -n "$container" ]] && [[ ! " ${containers[*]:-} " =~ " ${container} " ]]; then
      containers+=("$container")
    fi
  done
  
  if [[ ${#containers[@]} -eq 0 ]]; then
    log "No containers found for ports, waiting ${CHECK_INTERVAL}s and proceeding..."
    sleep "$CHECK_INTERVAL"
    return 0
  fi
  
  log "Found ${#containers[@]} containers to monitor: ${containers[*]}"
  
  while [[ $elapsed -lt $timeout ]]; do
    local all_healthy=true
    local status_line=""
    
    for container in "${containers[@]}"; do
      if is_container_healthy "$container"; then
        status_line+="$container:OK "
      else
        status_line+="$container:WAIT "
        all_healthy=false
      fi
    done
    
    if $all_healthy; then
      log "All containers healthy: $status_line"
      return 0
    fi
    
    log "Status: $status_line (${elapsed}s/${timeout}s)"
    sleep "$CHECK_INTERVAL"
    elapsed=$((elapsed + CHECK_INTERVAL))
  done
  
  log "WARN: Timeout waiting for containers, proceeding anyway..."
  return 0
}

apply_serves() {
  local ports="$1"
  local port_count
  port_count=$(echo "$ports" | wc -w)
  
  log "==> Applying Tailscale Serve configuration for $port_count ports"
  
  local success_count=0
  local fail_count=0
  
  for port in $ports; do
    # Use http://127.0.0.1:$port to proxy to localhost instead of binding to the port directly
    # This avoids conflicts with Docker containers that also bind to 0.0.0.0:$port
    if docker exec "$TS_CONTAINER_NAME" tailscale serve --bg --https="$port" "http://127.0.0.1:$port" >> "$LOG_FILE" 2>&1; then
      success_count=$((success_count + 1))
      log "Configured port $port"
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
log "=========================================="
log "==> Tailscale Serve Startup Script"
log "=========================================="

# Wait a bit for Docker to be fully ready
log "Waiting ${INITIAL_DELAY}s for Docker to be fully ready..."
sleep "$INITIAL_DELAY"

# Detect Tailscale container
if [[ -n "${TS_CONTAINER_NAME}" ]]; then
  log "Using manually specified container: $TS_CONTAINER_NAME"
else
  log "Auto-detecting Tailscale container..."
  TS_CONTAINER_NAME=$(detect_tailscale_container) || error "Could not auto-detect Tailscale container. Set TS_CONTAINER_NAME manually."
  log "Detected Tailscale container: $TS_CONTAINER_NAME"
fi

# Wait for Tailscale to be ready
wait_for_tailscale "$TAILSCALE_READY_TIMEOUT"

# Get ports from backup
ports=$(get_ports_from_backup) || error "No ports found in backup file: ${SERVE_JSON}"
log "Found ports in backup: $(echo $ports | tr '\n' ' ')"

# Wait for containers to be healthy
wait_for_containers "$ports"

# Small additional delay for stability
log "Waiting ${FINAL_DELAY}s for final stabilization..."
sleep "$FINAL_DELAY"

# Apply serves
apply_serves "$ports"

# Verify
sleep 2
log "==> Verifying Tailscale Serve status"
if ts serve status >/dev/null 2>&1; then
  active_count=$(ts serve status --json 2>/dev/null | grep -oP '"[0-9]+":' | wc -l || echo 0)
  log "Active serves: $active_count ports"
  ts serve status >> "$LOG_FILE" 2>&1
else
  log "WARN: Could not verify Tailscale Serve status"
fi

log "==> Startup script completed successfully"
exit 0
