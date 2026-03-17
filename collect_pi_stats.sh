!/usr/bin/env bash
set -euo pipefail

PHASE="${1:-snapshot}"
RUN_ID="${2:-$(date -u +%Y%m%dT%H%M%SZ)}"

### USER TUNABLE VARS
RECEIVER_SERVICE="${RECEIVER_SERVICE:-}"

SERVICES="${SERVICES:-tx-sender.service pi5-rtp-monitor.service nmos-registry.service chronyd.service}"

NMOS_BASE_URL="${NMOS_BASE_URL:-}"

OUTDIR="${OUTDIR:-$HOME/2110_stats}"
### PREP
HOST="$(hostname)"
mkdir -p "$OUTDIR"

OUTFILE="${OUTDIR}/${HOST}_${RUN_ID}_${PHASE}.txt"
: > "$OUTFILE"   # truncate if exists

log() {
  local msg="[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
  echo "$msg" | tee -a "$OUTFILE"
}

header() {
  local title="$1"
  printf "\n========== %s ==========\n" "$title" | tee -a "$OUTFILE"
}

log "===== 2110 LAB SNAPSHOT ====="
log "Host     : $HOST"
log "Phase    : $PHASE"
log "Run ID   : $RUN_ID"
log "User     : $USER"
log "Outfile  : $OUTFILE"
### RECEIVER APP LOG
header "RECEIVER APP LOG (journalctl)"

if [[ -n "$RECEIVER_SERVICE" ]]; then
  log "Receiver service: $RECEIVER_SERVICE (last 400 lines)"
  if sudo systemctl status "$RECEIVER_SERVICE" >/dev/null 2>&1; then
    sudo journalctl -u "$RECEIVER_SERVICE" -n 400 --no-pager >>"$OUTFILE" 2>&1 \
      || log "WARN: journalctl for $RECEIVER_SERVICE failed"
  else
    log "WARN: systemd unit $RECEIVER_SERVICE not found on this host"
  fi
else
  log "NOTE: RECEIVER_SERVICE not set; skipping dedicated receiver log."
  log "      You can export RECEIVER_SERVICE=your.service before running."
fi
### INTERFACE STATS
header "INTERFACE STATS (ip -s link / ethtool -S)"

log "--- ip -4 addr show ---"
if command -v ip >/dev/null 2>&1; then
  ip -4 addr show >>"$OUTFILE" 2>&1 || log "WARN: ip -4 addr show failed"
else
  log "WARN: ip command not found"
fi

log "--- ip -s link ---"
if command -v ip >/dev/null 2>&1; then
  ip -s link >>"$OUTFILE" 2>&1 || log "WARN: ip -s link failed"
fi

primary_iface=""
if command -v ip >/dev/null 2>&1 && ip -4 route show default >/dev/null 2>&1; then
  primary_iface="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
fi

if [[ -n "$primary_iface" ]]; then
  log "--- ethtool -S $primary_iface ---"
  if command -v ethtool >/dev/null 2>&1; then
    sudo ethtool -S "$primary_iface" >>"$OUTFILE" 2>&1 \
      || log "WARN: ethtool -S failed on $primary_iface"
  else
    log "WARN: ethtool not installed on this host"
  fi
else
  log "WARN: Could not determine primary interface from default route"
fi
### SYSTEM LOGS
header "SYSTEM LOGS (dmesg tail + selected services)"

log "--- dmesg | tail -n 200 ---"
dmesg | tail -n 200 >>"$OUTFILE" 2>&1 || log "WARN: dmesg failed"

if [[ -n "$SERVICES" ]]; then
  for svc in $SERVICES; do
    log "--- journalctl -u $svc (tail -n 200) ---"
    if sudo systemctl status "$svc" >/dev/null 2>&1; then
      sudo journalctl -u "$svc" -n 200 --no-pager >>"$OUTFILE" 2>&1 \
        || log "WARN: journalctl for $svc failed"
    else
      log "INFO: Service $svc not present on this host (skipping)"
    fi
  done
else
  log "NOTE: SERVICES list is empty; no extra service logs collected."
fi
### NMOS / HTTP DUMP
header "NMOS / HTTP DUMP"

if [[ -n "$NMOS_BASE_URL" ]]; then
  log "NMOS_BASE_URL: $NMOS_BASE_URL"

  log "--- GET $NMOS_BASE_URL/x-nmos/node/v1.3/self ---"
  curl -sS "$NMOS_BASE_URL/x-nmos/node/v1.3/self" >>"$OUTFILE" 2>&1 \
    || log "WARN: curl for node self failed"

  printf "\n" >>"$OUTFILE"

  log "--- GET $NMOS_BASE_URL/x-nmos/registration/v1.3/resources ---"
  curl -sS "$NMOS_BASE_URL/x-nmos/registration/v1.3/resources" >>"$OUTFILE" 2>&1 \
    || log "WARN: curl for registration resources failed"

else
  log "NOTE: NMOS_BASE_URL not set; skipping NMOS/HTTP dump."
  log "      Example: export NMOS_BASE_URL='http://10.10.20.21:3000'"
fi

log "===== SNAPSHOT COMPLETE ====="
log "Saved to: $OUTFILE"
EOF

chmod +x ~/collect_pi_stats.sh
echo "Updated ~/collect_pi_stats.sh on VM"
