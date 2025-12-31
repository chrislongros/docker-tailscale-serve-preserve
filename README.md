# docker-tailscale-serve-preserverve

Scripts to preserve Tailscale Serve configuration when using Watchtower for automatic Docker container updates, and restore configuration after system reboots.

## Screenshots

<details>
<summary>Click to expand screenshots</summary>

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

## Solution

These scripts:

- **Backup** your Tailscale Serve configuration before Watchtower runs
- **Restore** the configuration after container updates
- **Wait** for containers to be healthy before applying serve rules on boot
- **Avoid port conflicts** by proxying to `127.0.0.1` instead of binding directly

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
2. Reads ports from the backup JSON file
3. Waits for containers using those ports to be healthy
4. Applies Tailscale Serve rules

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
# Required: Update STATE_DIR to your preferred location
STATE_DIR="/path/to/scripts/state"

# Optional: Set Tailscale container name (auto-detected if not set)
TS_CONTAINER_NAME=""

# Optional: Customize timeouts
CONTAINER_TIMEOUT=300
TAILSCALE_READY_TIMEOUT=60
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
| `STATE_DIR` | `/mnt/zfs_tank/scripts/state` | Directory for state files and logs |
| `SERVE_JSON` | `${STATE_DIR}/tailscale-serve.json` | Backup file location |
| `LOG_FILE` | `${STATE_DIR}/*.log` | Log file location |
| `TS_CONTAINER_NAME` | (auto-detect) | Tailscale container name |
| `CONTAINER_TIMEOUT` | `300` | Seconds to wait for containers |
| `TAILSCALE_READY_TIMEOUT` | `60` | Seconds to wait for Tailscale |
| `TZ` | `UTC` | Timezone (watchtower script) |
| `WT_IMAGE` | `containrrr/watchtower` | Watchtower image |
| `WT_HOSTNAME` | `Docker-Host` | Watchtower notification hostname |

### Example with environment variables

```bash
STATE_DIR="/opt/docker/scripts/state" \
TZ="America/New_York" \
WT_HOSTNAME="my-server" \
/opt/docker/scripts/watchtower-with-tailscale-serve.sh
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

## Requirements

- Docker
- Tailscale running in a Docker container
- Bash 4.0+
- Standard Unix tools: `grep`, `cut`, `sort`, `uniq`

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! Please open an issue or PR.
