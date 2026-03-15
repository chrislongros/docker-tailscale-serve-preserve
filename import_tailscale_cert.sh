#!/bin/bash
set -euo pipefail

# =========================
# USER CONFIG (REQUIRED)
# Fill these in with YOUR values.
# =========================

# 1) Docker container name that runs tailscaled
CONTAINER_NAME="__TAILSCALE_CONTAINER_NAME__"

# 2) The Tailscale HTTPS hostname you want a cert for (your device's *.ts.net name)
TS_HOSTNAME="__TAILSCALE_DNS_NAME__"

# 3) Host directory (on TrueNAS) that is bind-mounted into the container at /certs
#    The container must have:  <HOST_CERT_DIR>  ->  /certs
HOST_CERT_DIR="__HOST_CERT_DIR__"

# 4) Where to write logs (should be writable by root)
LOG_FILE="__LOG_FILE__"

# =========================
# END USER CONFIG
# =========================

CRT="${HOST_CERT_DIR}/ts.crt"
KEY="${HOST_CERT_DIR}/ts.key"

# Cron-safe PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Log from inside the script (cron output may be discarded)
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec >>"$LOG_FILE" 2>&1
echo "----- $(date -Is) starting tailscale cert import -----"

# Basic dependency checks
command -v docker >/dev/null || { echo "ERROR: docker not found (PATH=$PATH)"; exit 2; }
command -v jq >/dev/null || { echo "ERROR: jq not found (PATH=$PATH)"; exit 2; }
command -v midclt >/dev/null || { echo "ERROR: midclt not found (PATH=$PATH)"; exit 2; }

# Ensure container is running
if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "ERROR: container '$CONTAINER_NAME' is not running"
  docker ps --format 'table {{.Names}}\t{{.Status}}'
  exit 2
fi

# Ensure /certs exists in container (mount check)
docker exec "$CONTAINER_NAME" sh -lc 'test -d /certs' || {
  echo "ERROR: /certs missing inside container. Bind-mount HOST_CERT_DIR -> /certs in the container."
  exit 2
}

# Issue/renew cert into /certs (host bind mount)
echo "Requesting/renewing certificate..."
docker exec "$CONTAINER_NAME" sh -lc \
  "tailscale cert --cert-file /certs/ts.crt --key-file /certs/ts.key \"$TS_HOSTNAME\""

# Verify files exist on host
if [[ ! -s "$CRT" || ! -s "$KEY" ]]; then
  echo "ERROR: cert files missing/empty on host directory"
  ls -l "$HOST_CERT_DIR" || true
  exit 2
fi

# Import into TrueNAS cert store with date-based name
CERT_NAME="tailscale-ui-$(date +%F)"
echo "Importing certificate as: $CERT_NAME"

midclt call certificate.create "$(jq -n \
  --arg n "$CERT_NAME" \
  --rawfile c "$CRT" \
  --rawfile k "$KEY" \
  '{name:$n, create_type:"CERTIFICATE_CREATE_IMPORTED", certificate:$c, privatekey:$k}')" >/dev/null || true

CERT_ID="$(midclt call certificate.query | jq -r --arg n "$CERT_NAME" \
  '.[] | select(.name==$n) | .id' | tail -n 1)"

if [[ -z "${CERT_ID:-}" || "$CERT_ID" == "null" ]]; then
  echo "ERROR: could not find imported certificate by name: $CERT_NAME"
  exit 2
fi

# Apply to Web UI and restart UI
echo "Applying certificate to Web UI (CERT_ID=$CERT_ID)..."
midclt call system.general.update "$(jq -n --argjson id "$CERT_ID" '{ui_certificate:$id, ui_restart_delay: 1}')"
midclt call system.general.ui_restart

# ---- CLEANUP: remove old tailscale-ui-* certificates ----
OLD_CERTS="$(midclt call certificate.query | jq -r --argjson keep "$CERT_ID" \
  '[.[] | select(.name | startswith("tailscale-ui-")) | select(.id != $keep) | .id] | .[]')"

if [[ -n "$OLD_CERTS" ]]; then
  for old_id in $OLD_CERTS; do
    echo "Deleting old certificate ID: $old_id"
    midclt call certificate.delete "$old_id" || echo "WARN: failed to delete cert $old_id"
  done
else
  echo "No old tailscale-ui certificates to clean up"
fi

echo "SUCCESS: applied new UI cert (name=$CERT_NAME id=$CERT_ID)"
