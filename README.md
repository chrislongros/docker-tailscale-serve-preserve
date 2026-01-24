# docker-tailscale-serve-preserve

Scripts to preserve Tailscale Serve configuration when using Watchtower for automatic Docker container updates, and restore configuration after system reboots.

## Screenshots

<img width="2109" height="1025" alt="Screenshot 2026-01-12 at 21-32-26 TrueNAS - truenas-scale kangaroo-newton ts net" src="https://github.com/user-attachments/assets/cb41cd05-96c8-46bf-bc4c-79ab05ead8c4" />

### TrueNAS Scale Cron Job Setup
![Cron Job Setup](screenshots/truenas-cron-job.png)

### TrueNAS Scale Post-Init Script Setup
![Post-Init Script Setup](screenshots/truenas-post-init.png)

### Tailscale Serve Status
![Tailscale Serve Status](screenshots/tailscale-serve-status.png)

### Script Logs
![Script Logs](screenshots/script-logs.png)

</details>

## Problem

When running Tailscale in a Docker container and using [Watchtower](https://containrrr.dev/watchtower/) for automatic updates:

1. Watchtower recreates the Tailscale container, wiping all `tailscale serve` rules
2. On system reboot, Tailscale Serve rules aren't automatically restored
3. Port conflicts can occur when both Tailscale Serve and Docker containers try to bind to the same port
4. **TrueNAS Scale specific:** After reboot, containers may start with port binding configurations but the actual host port mappings fail to apply due to a race condition in Docker/TrueNAS orchestration
5. **TrueNAS Scale specific:** Some containers may get stuck in restart loops, preventing services from becoming accessible

## Solution

These scripts:

- **Backup** your Tailscale Serve configuration before Watchtower runs
- **Restore** the configuration after container updates
- **Wait** for containers to be healthy before applying serve rules on boot
- **Avoid port conflicts** by proxying to `127.0.0.1` instead of binding directly
- **Detect and fix missing port bindings** by restarting affected TrueNAS apps via CLI
- **Fix restart loops** by detecting containers stuck in "Restarting" state and properly restarting their parent apps
- **Validate ports before configuring** Tailscale Serve to avoid errors on ports with no listeners

## Scripts

### `watchtower-with-tailscale-serve.sh`

Run via cron (e.g., daily at 3 AM) to update containers while preserving Tailscale Serve.

**What it does:**
1. Backs up current Tailscale Serve configuration to JSON
2. Resets Tailscale Serve listeners
3. Runs Watchtower to update all containers
4. Waits for containers to stabilize
5. Restores Tailscale Serve configuration

### `tailscale-serve-startup.sh`

Run as a post-init/startup script after system boot.

**What it does:**
1. Waits for Docker and Tailscale to be ready
2. Fixes init container restart policies (prevents restart loops)
3. Restarts any crashed containers
4. **Detects and fixes containers stuck in restart loops**
5. **Verifies port bindings and restarts apps with missing bindings**
6. Reads ports from the backup JSON file
7. **Validates that ports are actually listening before configuring Tailscale Serve**
8. Applies Tailscale Serve rules

## TrueNAS Scale Port Binding Issue

### The Problem

After a TrueNAS Scale reboot, there's a race condition where:

1. Docker daemon starts
2. TrueNAS app containers are created with port binding *configurations*
3. Containers start, but the actual host port mappings may not be applied
4. Result: Container is "running" but inaccessible because no port is bound to the host

You can identify this issue by running:
```bash
# Shows port binding is configured...
docker inspect <container> --format '{{json .HostConfig.PortBindings}}'
# Output: {"31015/tcp":[{"HostIp":"","HostPort":"31015"}]}

# ...but no actual port is bound
docker port <container>
# Output: (empty)
```

### The Fix

The updated startup script now:

1. **Detects missing port bindings** by comparing configured vs actual port mappings
2. **Extracts the app name** from the container name (e.g., `ix-portainer-portainer-1` → `portainer`)
3. **Restarts the app** using TrueNAS CLI: `cli -c "app stop <app>"` / `cli -c "app start <app>"`
4. **Waits for stabilization** before proceeding

This properly recreates the containers through TrueNAS's orchestration layer, which correctly applies port bindings.

### Containers in Restart Loops

The script also detects containers stuck in "Restarting" state (often caused by DNS resolution failures between containers in the same app stack) and restarts their parent apps to fix the issue.

## Installation

### 1. Download the scripts

```bash
# Create scripts directory
mkdir -p /path/to/scripts/state

# Download scripts
curl -o /path/to/scripts/watchtower-with-tailscale-serve.sh \
  https://raw.githubusercontent.com/chrislongros/docker-tailscale-serve-preserve/main/watchtower-with-tailscale-serve.sh

curl -o /path/to/scripts/tailscale-serve-startup.sh \
  https://raw.githubusercontent.com/chrislongros/docker-tailscale-serve-preserve/main/tailscale-serve-startup.sh

# Make executable
chmod +x /path/to/scripts/*.sh
```

### 2. Configure

Edit the configuration section at the top of each script, or set environment variables:

```bash
# REQUIRED: Set STATE_DIR to your preferred location
STATE_DIR="/your/path/here"

# Optional: Set Tailscale container name (auto-detected if not set)
TS_CONTAINER_NAME=""

# Optional: Customize timeouts
CONTAINER_TIMEOUT=300
TAILSCALE_READY_TIMEOUT=60
CONTAINER_STARTUP_WAIT=180
```

### 3. Set up scheduled tasks

#### For TrueNAS Scale

**Cron Job (for Watchtower updates):**
- Go to **System Settings → Advanced → Cron Jobs**
- Add new job:
  - Command: `/path/to/scripts/watchtower-with-tailscale-serve.sh`
  - Schedule: Daily at 3:00 AM (or your preference)
  - Run As User: `root`

**Post-Init Script (for boot-time restore):**
- Go to **System Settings → Advanced → Init/Shutdown Scripts**
- Add new script:
  - Type: Script
  - Script: `/path/to/scripts/tailscale-serve-startup.sh`
  - When: Post Init
  - Timeout: 300

#### For standard Linux

**Cron Job:**
```bash
# Edit crontab
sudo crontab -e

# Add line for daily 3 AM run
0 3 * * * /path/to/scripts/watchtower-with-tailscale-serve.sh >> /path/to/scripts/state/cron.log 2>&1
```

**Systemd Service (for boot):**

Create `/etc/systemd/system/tailscale-serve-restore.service`:

```ini
[Unit]
Description=Restore Tailscale Serve Configuration
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/path/to/scripts/tailscale-serve-startup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

Enable it:
```bash
sudo systemctl daemon-reload
sudo systemctl enable tailscale-serve-restore.service
```

## Configuration Options

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `STATE_DIR` | **(required)** | Directory for state files and logs |
| `SERVE_JSON` | `${STATE_DIR}/tailscale-serve.json` | Backup file location |
| `LOG_FILE` | `${STATE_DIR}/*.log` | Log file location |
| `TS_CONTAINER_NAME` | (auto-detect) | Tailscale container name (see below) |
| `CONTAINER_TIMEOUT` | `300` | Seconds to wait for containers |
| `CONTAINER_STARTUP_WAIT` | `180` | Seconds to wait for all containers to start on boot |
| `TAILSCALE_READY_TIMEOUT` | `60` | Seconds to wait for Tailscale |
| `TZ` | `UTC` | Timezone (watchtower script) |
| `WT_IMAGE` | `containrrr/watchtower` | Watchtower image |
| `WT_HOSTNAME` | `Docker-Host` | Watchtower notification hostname |

### Tailscale Container Auto-Detection

The scripts automatically find your Tailscale container by:
1. Looking for image name containing `tailscale/tailscale`
2. Looking for container name containing `tailscale`
3. Checking containers for the `tailscale` binary

You only need to set `TS_CONTAINER_NAME` if auto-detection fails.

### Example with environment variables

```bash
STATE_DIR="/opt/tailscale-serve-preserve" \
TZ="America/New_York" \
WT_HOSTNAME="my-server" \
/opt/scripts/watchtower-with-tailscale-serve.sh
```

## How It Works

### Port Conflict Prevention

The scripts configure Tailscale Serve to proxy to `127.0.0.1:PORT` instead of binding directly:

```bash
# This can cause conflicts:
tailscale serve --https=30070 30070

# This avoids conflicts (what the scripts use):
tailscale serve --https=30070 http://127.0.0.1:30070
```

This way:
- Docker container binds to `0.0.0.0:30070`
- Tailscale Serve listens on the Tailnet IP and proxies to `127.0.0.1:30070`
- No conflict!

### Port Binding Verification (TrueNAS Scale)

Before applying Tailscale Serve rules, the startup script:

1. **Scans all `ix-*` containers** (TrueNAS managed apps)
2. **Compares configured vs actual port bindings** using `docker inspect` and `docker port`
3. **Identifies apps with missing bindings** and restarts them via TrueNAS CLI
4. **Checks if ports are actually listening** using `ss -tlnp` before configuring Tailscale Serve

This ensures that Tailscale Serve only configures ports that have active listeners, and automatically fixes the common TrueNAS port binding race condition.

### Restart Loop Detection

The script detects containers stuck in "Restarting" state, which commonly happens when:
- DNS resolution fails between containers in the same app stack
- Database containers aren't ready when the main app starts
- Network initialization race conditions occur

When detected, the script restarts the parent app through TrueNAS CLI, which properly recreates the entire app stack with correct networking.

### Backup Format

The scripts backup the output of `tailscale serve status --json` and parse the port numbers from the TCP section. Timestamped backups are kept (last 10).

## Logs

Check the log files for troubleshooting:

```bash
# Watchtower script log
cat /path/to/scripts/state/watchtower-tailscale.log

# Startup script log
cat /path/to/scripts/state/tailscale-serve-startup.log
```

### Example Log Output

```
[2026-01-24 18:50:38] ==> Verifying port bindings for all apps...
[2026-01-24 18:50:38]   MISSING PORT BINDING: ix-portainer-portainer-1 (app: portainer)
[2026-01-24 18:50:38]   MISSING PORT BINDING: ix-heimdall-heimdall-1 (app: heimdall)
[2026-01-24 18:50:38] Found 2 app(s) with missing port bindings
[2026-01-24 18:50:38]   Restarting app: portainer
[2026-01-24 18:50:45]   Successfully restarted: portainer
[2026-01-24 18:50:45]   Restarting app: heimdall
[2026-01-24 18:50:52]   Successfully restarted: heimdall
[2026-01-24 18:51:22] All port bindings verified OK
```

## Requirements

- Docker
- Tailscale running in a Docker container
- Bash 4.0+
- Standard Unix tools: `grep`, `cut`, `sort`, `uniq`, `ss`
- **TrueNAS Scale:** CLI access (`cli` command) for app restart functionality

## Troubleshooting

### Container accessible locally but not via Tailscale

1. Check if Tailscale Serve is configured: `docker exec <tailscale-container> tailscale serve status`
2. Check if port is listening: `ss -tlnp | grep <port>`
3. Check startup script log for errors

### Apps not accessible after reboot (TrueNAS Scale)

1. Check for missing port bindings: `docker port <container-name>`
2. If empty, restart the app: `sudo cli -c "app stop <app>" && sudo cli -c "app start <app>"`
3. Check startup script log: `cat /path/to/scripts/state/tailscale-serve-startup.log`

### Containers stuck in restart loop

1. Check container logs: `docker logs <container-name>`
2. Common causes: DNS resolution failure, database not ready
3. Restart the parent app via TrueNAS CLI or UI

## License

BSD 3-Clause License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! Please open an issue or PR.

## Changelog

### v1.1.0 (2026-01-24)

- **New:** Port binding verification for TrueNAS Scale apps
- **New:** Automatic app restart for containers with missing port bindings
- **New:** Restart loop detection and automatic fix
- **New:** Pre-flight port listening check before configuring Tailscale Serve
- **New:** Configurable `CONTAINER_STARTUP_WAIT` variable
- **Improved:** Better logging with failed port details
- **Improved:** Documentation for TrueNAS Scale specific issues
