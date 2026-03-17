#!/usr/bin/env bash
set -euo pipefail

### CONFIG

HOSTS=(
  admin@10.10.10.11  # Pi1
  admin@10.10.10.12  # Pi2
  admin@10.10.10.13  # Pi3
  admin@10.10.20.21  # Pi4
  admin123@10.10.10.1  # RTRVM
)

RUN_ID="${1:-$(date -u +%Y%m%dT%H%M%SZ)}"
PHASE="${2:-snapshot}"

VM_OUT_BASE="${HOME}/BASE_ETH_LOGS"
VM_OUT_DIR="${VM_OUT_BASE}/${RUN_ID}_${PHASE}"

mkdir -p "$VM_OUT_DIR"

echo "==== 2110 STATS COLLECTION ===="
echo "Run ID : $RUN_ID"
echo "Phase  : $PHASE"
echo "VM dir : $VM_OUT_DIR"
echo

### PER-HOST ENV OVERRIDES (OPTIONAL)

get_env_for_host() {
  local host="$1"
  
  local env="SERVICES='tx-sender.service pi5-rtp-monitor.service nmos-registry.service chronyd.service'"

  case "$host" in
    *10.10.10.12) 
      env="$env RECEIVER_SERVICE=rx-receiver.service"
      ;;
    *10.10.10.13) 
      env="$env NMOS_BASE_URL='http://10.10.20.21:3000'"
      ;;
    *10.10.20.21)  
      env="$env NMOS_BASE_URL='http://10.10.20.21:3000'"
      ;;
  esac

  echo "$env"
}

### MAIN LOOP

for HOST in "${HOSTS[@]}"; do
  echo "---- $HOST ----"
  
  if ! ssh -o ConnectTimeout=5 "$HOST" 'test -x ~/collect_pi_stats.sh'; then
    echo "  ERROR: ~/collect_pi_stats.sh not found or not executable on $HOST"
    echo "         Install it first, then re-run this script."
    continue
  fi
  EXTRA_ENV="$(get_env_for_host "$HOST")"

  echo "  Running collect_pi_stats.sh on remote host..."
  ssh -o ConnectTimeout=5 "$HOST" \
    "$EXTRA_ENV OUTDIR=\$HOME/2110_stats ~/collect_pi_stats.sh '$PHASE' '$RUN_ID'" || {
      echo "  WARN: remote stats collection failed on $HOST"
      continue
    }

  echo "  Copying TXT snapshot(s) back to VM..."

  scp -p "$HOST:~/2110_stats/*_${RUN_ID}_${PHASE}.txt" "$VM_OUT_DIR/" 2>/dev/null || {
    echo "  WARN: scp failed or no matching files on $HOST"
    continue
  }

  echo "  Done with $HOST."
  echo
done

echo "==== COMPLETE ===="
echo "All collected TXT files (that succeeded) are in:"
echo "  $VM_OUT_DIR"
