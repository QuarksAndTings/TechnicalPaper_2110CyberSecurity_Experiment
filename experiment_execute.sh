#!/usr/bin/env bash
set -euo pipefail

# USER CONFIG

#FILTER='udp port 5004'

DUR=60
GROUPIP=239.10.10.10
PASSWORD='admin123'

HOSTS=(
  admin@10.10.10.11   # pi1
  admin@10.10.10.12   # pi2
  admin@10.10.10.13   # pi3
  admin@10.10.20.21   # pi4
  admin@10.10.30.31   # pi5
  admin123@10.10.10.1 # RTRVM
)

PI1_HOST="admin@10.10.10.11"

RECEIVER_HOST="admin@10.10.10.12"
RECEIVER_SCRIPT="/usr/local/bin/receiver.sh"

NMOS_HOST="admin@10.10.20.21"

PI1_HEARTBEAT_HOST="admin@10.10.10.11"
PI2_HEARTBEAT_HOST="admin@10.10.10.12"

ROUTER_HOST="admin123@10.10.10.1"
SYSLOG_HOST="admin@10.10.30.31"

PI3_HOST="admin@10.10.10.13"

LOG_SERVICES=(
  tx-sender.service
  nmos-registry.service
  pi5-rtp-monitor.service
)

LOG_HOSTS=(
  "$PI1_HOST"       # Pi1
  "$RECEIVER_HOST"  # Pi2
  "$PI3_HOST"       # Pi3
  "$NMOS_HOST"      # Pi4
  "$ROUTER_HOST"    # RTRVM
  "$SYSLOG_HOST"    # Pi5
)
# PREP
RUN="logrun_$(date -u +%Y%m%dT%H%M%SZ)"
TARGET=$(( ( $(date -u +%s)/60 + 1 ) * 60 ))   # next UTC minute
END=$(( TARGET + DUR ))

NOW=$(date -u +%s)
CAP_OFFSET=$(( TARGET - NOW ))           # when pcaps + logs start
TX_OFFSET=$(( TARGET + 5 - NOW ))        # when tx-sender restarts

[ "$CAP_OFFSET" -lt 0 ] && CAP_OFFSET=0
[ "$TX_OFFSET"  -lt 0 ] && TX_OFFSET=0

CAPDIR="$HOME/captures"
mkdir -p "$CAPDIR"
CONFIG="$CAPDIR/${RUN}.conf"

{
  echo "run_id=$RUN"
  echo "target_utc_epoch=$TARGET"
  echo "duration_s=$DUR"
  echo "filter="
  echo "groupip=$GROUPIP"
  echo "hosts=${HOSTS[*]}"
} > "$CONFIG"

echo "Config: $CONFIG"
echo "Scheduled capture start: $(date -u -d @$TARGET '+%Y-%m-%d %H:%M:%S UTC')"
echo "Pi1 tx-sender start:      $(date -u -d $((TARGET+5)) '+%Y-%m-%d %H:%M:%S UTC') (TARGET+5s)"
echo "Pi1 tx-sender stop:       $(date -u -d @$END '+%Y-%m-%d %H:%M:%S UTC') (TARGET+${DUR}s)"
echo
echo "Local time now:           $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Capture will start in     ${CAP_OFFSET}s"
echo "Tx-sender will start in   ${TX_OFFSET}s"
echo
# LOCAL START NOTIFICATION
(
  sleep "$CAP_OFFSET"

  MSG="Capture window STARTED at $(date -u '+%Y-%m-%d %H:%M:%S UTC') (duration ${DUR}s)"
  echo
  echo "$MSG"
  printf '\a'
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "logrun $RUN" "$MSG"
  fi
) &
# PI1 TX-SENDER START
(
  sleep "$TX_OFFSET"

  MSG="Starting tx-sender.service on Pi1 ($PI1_HOST) at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  echo "$MSG"
  printf '\a'

  if command -v notify-send >/dev/null 2>&1; then
    notify-send "logrun $RUN" "$MSG"
  fi

  ssh -n -T -o ConnectTimeout=5 "$PI1_HOST" \
    "printf '%s\n' '$PASSWORD' | sudo -S -p '' systemctl restart tx-sender.service" \
    || echo "Failed to start tx-sender.service on $PI1_HOST"
) &
# PI2 RECEIVER LOG START
(
  sleep "$CAP_OFFSET"

  MSG="Starting receiver log on $RECEIVER_HOST at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo
  echo "$MSG"
  printf '\a'
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "logrun $RUN" "$MSG"
  fi

  ssh -n -T -o ConnectTimeout=5 "$RECEIVER_HOST" "bash -lc '
    set -euo pipefail
    RUN_ID=\"$RUN\"
    DUR_SEC=$DUR
    RECEIVER_SCRIPT=\"$RECEIVER_SCRIPT\"

    LOGDIR=\$HOME/receiver_logs
    mkdir -p \"\$LOGDIR\"

    TS=\$(date -u +%Y%m%dT%H%M%SZ)
    LOGFILE=\"\$LOGDIR/\${RUN_ID}_receiver_\$TS.log\"

    echo \"=== RECEIVER START \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===\" >>\"\$LOGFILE\"

    timeout \$DUR_SEC \"\$RECEIVER_SCRIPT\" >>\"\$LOGFILE\" 2>&1 || true

    echo \"=== RECEIVER END   \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===\" >>\"\$LOGFILE\"
  '" || echo "  WARN: receiver logging failed on $RECEIVER_HOST"
) &
# START REMOTE PCAPS
for h in "${HOSTS[@]}"; do
  if [[ "$h" == "$ROUTER_HOST" ]]; then
    echo "Queueing capture on router $h (IFACE=any) ..."
    ssh -n -T -o ConnectTimeout=5 "$h" "
      # Sleep the same offset as the Dell before starting the capture
      sleep ${CAP_OFFSET}

      TS=\$(date -u +%Y%m%dT%H%M%SZ)
      OUT_FINAL=/tmp/${RUN}_\$(hostname)_\${TS}.pcapng
      OUT_TMP=/tmp/.${RUN}_\$(hostname)_\${TS}.pcapng.partial

      echo \"[\$(hostname)] starting capture on IFACE=any at \$(date -u '+%Y-%m-%d %H:%M:%S UTC')\" >&2

      # Capture EVERYTHING on all interfaces
      if command -v tshark >/dev/null 2>&1; then
        printf '%s\n' '$PASSWORD' | sudo -S -p '' tshark -i any -a duration:$DUR -w \"\$OUT_TMP\" >/tmp/multicap_last.log 2>&1 || true
      else
        printf '%s\n' '$PASSWORD' | sudo -S -p '' timeout $DUR tcpdump -i any -s0 -w \"\$OUT_TMP\" >/tmp/multicap_last.log 2>&1 || true
      fi

      if sudo test -s \"\$OUT_TMP\"; then
        sudo mv \"\$OUT_TMP\" \"\$OUT_FINAL\"
        sudo chmod a+r \"\$OUT_FINAL\"
        RUSER=\$(logname 2>/dev/null || whoami)
        sudo chown \"\$RUSER\":\"\$RUSER\" \"\$OUT_FINAL\"
        echo \"[\$(hostname)] capture complete (any): \$OUT_FINAL\" >&2
      else
        echo \"[\$(hostname)] ERROR: no capture written (any)\" >&2
      fi
    " &
  else
    echo "Queueing capture on $h ..."
    ssh -n -T -o ConnectTimeout=5 "$h" "
      GROUPIP=\"$GROUPIP\"

      # Pick interface that would reach GROUPIP; fallback to first non-lo
      IFACE=\$(ip -o route get \"$GROUPIP\" 2>/dev/null | awk '/ dev /{for(i=1;i<=NF;i++) if(\$i==\"dev\"){print \$(i+1); exit}}')
      if [ -z \"\$IFACE\" ]; then
        IFACE=\$(ip -o link show | awk -F': ' '\$2!=\"lo\"{print \$2; exit}')
      fi

      # Sleep the same offset as the Dell before starting the capture
      sleep ${CAP_OFFSET}

      TS=\$(date -u +%Y%m%dT%H%M%SZ)
      OUT_FINAL=/tmp/${RUN}_\$(hostname)_\${TS}.pcapng
      OUT_TMP=/tmp/.${RUN}_\$(hostname)_\${TS}.pcapng.partial

      echo \"[\$(hostname)] starting capture on IFACE=\$IFACE at \$(date -u '+%Y-%m-%d %H:%M:%S UTC')\" >&2

      if command -v tshark >/dev/null 2>&1; then
        printf '%s\n' '$PASSWORD' | sudo -S -p '' tshark -i \"\$IFACE\" -a duration:$DUR -w \"\$OUT_TMP\" >/tmp/multicap_last.log 2>&1 || true
      else
        printf '%s\n' '$PASSWORD' | sudo -S -p '' timeout $DUR tcpdump -i \"\$IFACE\" -s0 -w \"\$OUT_TMP\" >/tmp/multicap_last.log 2>&1 || true
      fi

      if sudo test -s \"\$OUT_TMP\"; then
        sudo mv \"\$OUT_TMP\" \"\$OUT_FINAL\"
        sudo chmod a+r \"\$OUT_FINAL\"
        RUSER=\$(logname 2>/dev/null || whoami)
        sudo chown \"\$RUSER\":\"\$RUSER\" \"\$OUT_FINAL\"
        echo \"[\$(hostname)] capture complete: \$OUT_FINAL\" >&2
      else
        echo \"[\$(hostname)] ERROR: no capture written (temp file \$OUT_TMP missing or empty)\" >&2
      fi
    " &
  fi
done

echo
echo "Waiting for remote captures to finish (~${DUR}s)..."

wait || true

echo
echo "All remote capture jobs finished (or timed out)."
echo "Capture window ended at: $(date -u -d @$END '+%Y-%m-%d %H:%M:%S UTC')"
# STOP TX-SENDER
MSG="Stopping tx-sender.service on Pi1 ($PI1_HOST) at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo
echo "$MSG"
printf '\a'
if command -v notify-send >/dev/null 2>&1; then
  notify-send "logcap $RUN" "$MSG"
fi

ssh -n -T -o ConnectTimeout=5 "$PI1_HOST" \
  "printf '%s\n' '$PASSWORD' | sudo -S -p '' systemctl stop tx-sender.service" \
  || echo "Failed to stop tx-sender.service on $PI1_HOST"
# NMOS HEARTBEAT (REGISTRY)
echo
echo "Collecting NMOS heartbeat log on $NMOS_HOST ..."
ssh -n -T -o ConnectTimeout=5 "$NMOS_HOST" "bash -lc '
  set -euo pipefail
  RUN_ID=\"$RUN\"
  TARGET_EPOCH=$TARGET
  END_EPOCH=$END
  PASSWORD=\"$PASSWORD\"

  LOGDIR=\$HOME/syslogs
  mkdir -p \"\$LOGDIR\"
  TS=\$(date -u +%Y%m%dT%H%M%SZ)
  LOGFILE=\"\$LOGDIR/\${RUN_ID}_\$(hostname)_\${TS}_nmos-heartbeat.log\"

  echo \"=== NMOS HEARTBEAT START \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===\" >\"\$LOGFILE\"

  printf \"%s\n\" \"\$PASSWORD\" | sudo -S -p \"\" \
    journalctl -u nmos-registry.service --since \"@\${TARGET_EPOCH}\" --until \"@\${END_EPOCH}\" \
    >>\"\$LOGFILE\" 2>&1 || echo \"(no journal entries or service missing)\" >>\"\$LOGFILE\"

  echo \"=== NMOS HEARTBEAT END   \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===\" >>\"\$LOGFILE\"
'" || echo "  WARN: failed to collect NMOS heartbeat log on $NMOS_HOST"
# PI1 / PI2 HEARTBEAT SEND LOGS
for HBHOST in "$PI1_HEARTBEAT_HOST" "$PI2_HEARTBEAT_HOST"; do
  echo
  echo "Collecting NMOS heartbeat SEND logs on $HBHOST ..."
  ssh -n -T -o ConnectTimeout=5 "$HBHOST" "bash -lc '
    set -euo pipefail
    RUN_ID=\"$RUN\"
    TARGET_EPOCH=$TARGET
    END_EPOCH=$END
    PASSWORD=\"$PASSWORD\"

    LOGDIR=\$HOME/syslogs
    mkdir -p \"\$LOGDIR\"
    TS=\$(date -u +%Y%m%dT%H%M%SZ)
    LOGFILE=\"\$LOGDIR/\${RUN_ID}_\$(hostname)_\${TS}_nmos-heartbeat-send.log\"

    echo \"=== NMOS HEARTBEAT SEND START \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===\" >\"\$LOGFILE\"

    printf \"%s\n\" \"\$PASSWORD\" | sudo -S -p \"\" \
      journalctl -u nmos-heartbeat.service --since \"@\${TARGET_EPOCH}\" --until \"@\${END_EPOCH}\" \
      >>\"\$LOGFILE\" 2>&1 || echo \"(no heartbeat-send logs found)\" >>\"\$LOGFILE\"

    echo \"=== NMOS HEARTBEAT SEND END   \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===\" >>\"\$LOGFILE\"
  '" || echo "  WARN: failed to collect heartbeat logs on $HBHOST"
done
# SYSTEM LOG SNAPSHOTS
for h in "${LOG_HOSTS[@]}"; do
  echo
  echo "Collecting system logs on $h ..."
  ssh -n -T -o ConnectTimeout=5 "$h" "bash -lc '
    set -euo pipefail
    RUN_ID=\"$RUN\"
    TARGET_EPOCH=$TARGET
    END_EPOCH=$END
    PASSWORD=\"$PASSWORD\"

    LOGDIR=\$HOME/syslogs
    mkdir -p \"\$LOGDIR\"
    TS=\$(date -u +%Y%m%dT%H%M%SZ)

    # dmesg snapshot (last 500 lines)
    if command -v dmesg >/dev/null 2>&1; then
      if printf \"%s\n\" \"\$PASSWORD\" | sudo -S -p \"\" dmesg --ctime >/tmp/.dmesg.\$\$ 2>/dev/null; then
        tail -n 500 /tmp/.dmesg.\$\$ >\"\$LOGDIR/\${RUN_ID}_\$(hostname)_\${TS}_dmesg.log\" 2>/dev/null || true
        rm -f /tmp/.dmesg.\$\$ || true
      fi
    fi

    # journalctl snapshots for interesting services
    SERVICES=(tx-sender.service nmos-registry.service pi5-rtp-monitor.service)
    for svc in \"\${SERVICES[@]}\"; do
      if systemctl list-units --type=service --all | grep -q \"\$svc\"; then
        printf \"%s\n\" \"\$PASSWORD\" | sudo -S -p \"\" \
          journalctl -u \"\$svc\" --since \"@\${TARGET_EPOCH}\" --until \"@\${END_EPOCH}\" \
          >\"\$LOGDIR/\${RUN_ID}_\$(hostname)_\${TS}_\${svc}.log\" 2>/dev/null || true
      fi
    done
  '" || echo "  WARN: failed to collect logs on $h"
done
# PULL RESULTS
DEST="$HOME/all_captures_${RUN}"
mkdir -p "$DEST"
echo
echo "Pulling finalized files to: $DEST"

pull_one() {
  local host="$1"
  local list
  list=$(ssh -n "$host" "ls -1 /tmp/${RUN}_*.pcap* 2>/dev/null" || true)
  if [[ -z "$list" ]]; then
    echo "  $host: no final pcap files"
    return
  fi
  while IFS= read -r REMOTE; do
    [[ -z "$REMOTE" ]] && continue
    echo "  $host -> $(basename "$REMOTE")"
    if ! scp "$host":"$REMOTE" "$DEST/"; then
      echo "    WARN: scp failed for $REMOTE, trying sudo cat fallback"
      ssh -n "$host" "sudo cat '$REMOTE'" > "$DEST/${host//@/_}__$(basename "$REMOTE")"
    fi
  done <<< "$list"
}

pull_receiver_logs() {
  local host="$1"
  echo
  echo "Pulling receiver logs from $host ..."

  # First see what actually exists
  local list
  list=$(ssh -n "$host" "ls -1 ~/receiver_logs/${RUN}_receiver_*.log 2>/dev/null" || true)

  if [[ -z "$list" ]]; then
    echo "  $host: no receiver logs found matching ~/receiver_logs/${RUN}_receiver_*.log"
    return
  fi

  echo "  $host: found receiver logs:"
  echo "$list" | sed 's/^/    - /'

  # Now SCP each file explicitly so you see any failures
  while IFS= read -r REMOTE; do
    [[ -z "$REMOTE" ]] && continue
    local base
    base=$(basename "$REMOTE")
    echo "  $host -> $base"
    if ! scp "$host:$REMOTE" "$DEST/"; then
      echo "    WARN: scp failed for $REMOTE"
    fi
  done <<< "$list"
}

pull_syslogs() {
  local host="$1"
  echo
  echo "Pulling system logs from $host ..."

  # Check what exists first
  local list
  list=$(ssh -n "$host" "ls -1 ~/syslogs/${RUN}_*.log 2>/dev/null" || true)

  if [[ -z "$list" ]]; then
    echo "  $host: no system logs found matching ~/syslogs/${RUN}_*.log"
    return
  fi

  echo "  $host: found syslog files:"
  echo "$list" | sed 's/^/    - /'

  # SCP each log individually so we see real errors
  while IFS= read -r REMOTE; do
    [[ -z "$REMOTE" ]] && continue
    local base
    base=$(basename "$REMOTE")
    echo "  $host -> $base"
    if ! scp "$host:$REMOTE" "$DEST/"; then
      echo "    WARN: scp failed for $REMOTE"
    fi
  done <<< "$list"
}


for h in "${HOSTS[@]}"; do
  pull_one "$h"
done

# Pull receiver logs from the main receiver host
pull_receiver_logs "$RECEIVER_HOST"

# Pull system + NMOS logs from log hosts
for h in "${LOG_HOSTS[@]}"; do
  pull_syslogs "$h"
done

echo
ls -lh "$DEST" || true
# MERGECAP
if command -v mergecap >/dev/null 2>&1; then
  MERGED="$DEST/${RUN}_merged.pcapng"
  echo
  echo "Merging to: $MERGED"
  mergecap -w "$MERGED" "$DEST"/*.pcap* 2>/dev/null || true
  ls -lh "$MERGED" || true
fi

echo
echo "Done. Run id: $RUN"
echo "   Config: $CONFIG"
echo "   Results: $DEST"
echo "exit"
