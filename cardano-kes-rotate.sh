#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

VERSION="1.0.0"
SCRIPT_NAME="$(basename "$0")"
NETWORK_ARGS=()

die() { printf '\nERROR: %s\n\n' "$*" >&2; exit 1; }
log() { printf '\n============================================================\n%s\n============================================================\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
require_file() { [[ -f "$1" ]] || die "File not found: $1"; }
require_dir() { [[ -d "$1" ]] || die "Directory not found: $1"; }
canonical() { realpath "$1" 2>/dev/null || readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"; }
quote() { printf '%q' "$1"; }

ask() {
  local var="$1" prompt="$2" default="${3:-}" answer=""
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer
    answer="${answer:-$default}"
  else
    while [[ -z "$answer" ]]; do read -r -p "$prompt: " answer; done
  fi
  printf -v "$var" '%s' "$answer"
}

yes() {
  local answer=""
  read -r -p "$1 [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

confirm() {
  printf '\n%s\n' "$1"; shift
  printf '  %s\n' "$@"
  yes "Continue?" || die "Cancelled."
}

choose_candidate() {
  # choose_candidate VARIABLE DESCRIPTION candidate...
  local var="$1" description="$2"; shift 2
  local -a candidates=() unique=()
  local item seen choice
  for item in "$@"; do
    [[ -n "$item" && -e "$item" ]] || continue
    item="$(canonical "$item")"; seen=0
    for choice in "${unique[@]:-}"; do [[ "$choice" == "$item" ]] && seen=1; done
    (( seen == 0 )) && unique+=("$item")
  done
  if (( ${#unique[@]} == 1 )); then
    printf -v "$var" '%s' "${unique[0]}"
    printf 'Detected %-24s %s\n' "$description:" "${unique[0]}"
    return
  fi
  if (( ${#unique[@]} > 1 )); then
    printf '\nFound multiple candidates for %s:\n' "$description"
    local i=1
    for item in "${unique[@]}"; do printf '  %d) %s\n' "$i" "$item"; ((i++)); done
    printf '  m) enter manually\n'
    read -r -p "Choose: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#unique[@]} )); then
      printf -v "$var" '%s' "${unique[choice-1]}"; return
    fi
  fi
  ask "$var" "Path to $description"
}

find_files() {
  local name="$1"; shift
  find "$@" -xdev -type f -name "$name" -print 2>/dev/null || true
}

node_command_line() {
  pgrep -x cardano-node >/dev/null 2>&1 || return 0
  ps -ww -p "$(pgrep -o -x cardano-node)" -o args= 2>/dev/null || true
}

arg_value() {
  local args="$1" flag="$2"
  # Cardano paths cannot safely contain whitespace in a process command line parsed this way.
  sed -nE "s#.*${flag}[= ]([^ ]+).*#\\1#p" <<<"$args" | head -n1
}

detect_service() {
  local unit
  unit="$(systemctl list-units --type=service --all --no-legend 2>/dev/null |
    awk '$1 ~ /cardano.*node|node.*cardano/ {print $1; exit}')"
  printf '%s\n' "${unit%.service}"
}

detect_transfer_root() {
  local -a mounts=()
  mapfile -t mounts < <(lsblk -J -o MOUNTPOINTS,RM 2>/dev/null | jq -r '.. | objects | select(.rm == true) | .mountpoints[]? // empty' 2>/dev/null || true)
  (( ${#mounts[@]} )) || mapfile -t mounts < <(findmnt -rn -o TARGET 2>/dev/null | awk '$0 ~ "^/media/|^/mnt/|^/run/media/"')
  choose_candidate TRANSFER_ROOT "mounted transfer/USB directory" "${mounts[@]}"
  require_dir "$TRANSFER_ROOT"
}

detect_bp_environment() {
  need jq; need sha256sum; need cardano-cli
  CARDANO_CLI="$(command -v cardano-cli)"
  local args socket config kes vkey cert service user group
  args="$(node_command_line)"
  socket="${CARDANO_NODE_SOCKET_PATH:-$(arg_value "$args" '--socket-path')}"
  config="$(arg_value "$args" '--config')"
  kes="$(arg_value "$args" '--shelley-kes-key')"
  cert="$(arg_value "$args" '--shelley-operational-certificate')"
  service="$(detect_service)"

  choose_candidate NODE_SOCKET "node socket" "$socket" /run/cardano-node/node.socket /run/cardano/node.socket /opt/cardano/cnode/sockets/node0.socket
  [[ -S "$NODE_SOCKET" ]] || die "Not a Unix socket: $NODE_SOCKET"

  local -a genesis=()
  [[ -n "$config" && -f "$config" ]] && {
    local rel
    rel="$(jq -r '.ShelleyGenesisFile // .ShelleyGenesis // empty' "$config" 2>/dev/null || true)"
    [[ -n "$rel" ]] && genesis+=("$(dirname "$config")/$rel")
  }
  mapfile -t genesis < <(printf '%s\n' "${genesis[@]:-}"; find_files '*shelley*genesis*.json' /opt/cardano /etc/cardano /srv/cardano /home 2>/dev/null)
  local -a valid_genesis=() f
  for f in "${genesis[@]}"; do [[ -f "$f" ]] && jq -e '.slotsPerKESPeriod | numbers' "$f" >/dev/null 2>&1 && valid_genesis+=("$f"); done
  choose_candidate SHELLEY_GENESIS "Shelley genesis JSON" "${valid_genesis[@]}"

  local key_dir="${kes:+$(dirname "$kes")}" candidates=()
  [[ -n "$kes" ]] && candidates+=("$kes")
  mapfile -t candidates < <(printf '%s\n' "${candidates[@]:-}"; find_files 'kes.skey' "${key_dir:-/nonexistent}" /opt/cardano /etc/cardano /srv/cardano /home 2>/dev/null)
  choose_candidate ACTIVE_KES_SKEY "active KES signing key" "${candidates[@]}"
  key_dir="$(dirname "$ACTIVE_KES_SKEY")"
  vkey="${ACTIVE_KES_SKEY%.skey}.vkey"
  choose_candidate ACTIVE_KES_VKEY "active KES verification key" "$vkey" "$key_dir/kes.vkey"

  local -a certs=()
  [[ -n "$cert" ]] && certs+=("$cert")
  mapfile -t certs < <(printf '%s\n' "${certs[@]:-}"; find_files 'node.cert' "$key_dir" /opt/cardano /etc/cardano /srv/cardano /home 2>/dev/null)
  choose_candidate ACTIVE_NODE_CERT "active operational certificate" "${certs[@]}"

  ask SERVICE "systemd cardano-node service" "${service:-cardano-node}"
  user="$(systemctl show "$SERVICE" -p User --value 2>/dev/null || true)"; user="${user:-cardano}"
  group="$(systemctl show "$SERVICE" -p Group --value 2>/dev/null || true)"; group="${group:-$user}"
  ask NODE_USER "cardano-node user" "$user"; ask NODE_GROUP "cardano-node group" "$group"
  WORK_ROOT="${KES_ROTATION_HOME:-$HOME/kes-rotation}"
  detect_transfer_root

  local magic
  magic="$(jq -r '.networkMagic // empty' "$SHELLEY_GENESIS")"
  if grep -qi 'mainnet' <<<"$args $config" || [[ "$magic" == "764824073" ]]; then
    NETWORK_NAME=mainnet; NETWORK_ARGS=(--mainnet)
  else
    if [[ "$magic" =~ ^[0-9]+$ ]]; then NETWORK_NAME="testnet-magic-$magic"; NETWORK_ARGS=(--testnet-magic "$magic")
    else
      yes "Use mainnet?" && { NETWORK_NAME=mainnet; NETWORK_ARGS=(--mainnet); } || { ask magic "Testnet magic"; NETWORK_NAME="testnet-magic-$magic"; NETWORK_ARGS=(--testnet-magic "$magic"); }
    fi
  fi
}

prepare() {
  detect_bp_environment
  require_file "$ACTIVE_KES_SKEY"; require_file "$ACTIVE_KES_VKEY"; require_file "$ACTIVE_NODE_CERT"
  confirm "DETECTED BLOCK PRODUCER SETTINGS" \
    "Network: $NETWORK_NAME" "Socket: $NODE_SOCKET" "Genesis: $SHELLEY_GENESIS" \
    "Active KES key: $ACTIVE_KES_SKEY" "Active certificate: $ACTIVE_NODE_CERT" \
    "Service/user: $SERVICE ($NODE_USER:$NODE_GROUP)" "Transfer media: $TRANSFER_ROOT"

  log "QUERYING NODE AND CALCULATING KES PERIOD"
  local tip slot slots period rotation transfer pending
  tip="$("$CARDANO_CLI" query tip "${NETWORK_ARGS[@]}" --socket-path "$NODE_SOCKET")"
  jq . <<<"$tip"
  slot="$(jq -r '.slot // empty' <<<"$tip")"; [[ "$slot" =~ ^[0-9]+$ ]] || die "Could not read current slot."
  slots="$(jq -r '.slotsPerKESPeriod // empty' "$SHELLEY_GENESIS")"; [[ "$slots" =~ ^[0-9]+$ ]] || die "Invalid slotsPerKESPeriod."
  period=$((slot / slots)); printf '\nCurrent KES period: %s\n' "$period"
  "$CARDANO_CLI" query kes-period-info "${NETWORK_ARGS[@]}" --socket-path "$NODE_SOCKET" --op-cert-file "$ACTIVE_NODE_CERT" ||
    yes "KES status query failed. Continue anyway?" || die "Cancelled."

  pending="$WORK_ROOT/pending"; [[ ! -e "$pending" ]] || die "Pending rotation already exists: $pending"
  mkdir -p "$pending"
  rotation="$(date -u +'%Y%m%dT%H%M%SZ')"; transfer="$TRANSFER_ROOT/kes-rotation-$rotation"
  mkdir "$transfer"
  "$CARDANO_CLI" node key-gen-KES --verification-key-file "$pending/kes.vkey" --signing-key-file "$pending/kes.skey"
  chmod 400 "$pending/kes.skey"; chmod 444 "$pending/kes.vkey"
  cp "$pending/kes.vkey" "$transfer/kes.vkey"
  cp "$(canonical "$0")" "$transfer/$SCRIPT_NAME"
  chmod 500 "$transfer/$SCRIPT_NAME"
  printf '%s\n' "$period" >"$transfer/kes-period.txt"
  printf '%s\n' "$rotation" >"$transfer/rotation-id.txt"
  printf '%s\n' "$NETWORK_NAME" >"$transfer/network.txt"
  (cd "$transfer" && sha256sum kes.vkey >kes.vkey.sha256)
  printf '%s\n' "$rotation" >"$pending/rotation-id.txt"
  printf '%s\n' "$period" >"$pending/kes-period.txt"
  cat >"$pending/install.conf" <<EOF
CARDANO_CLI=$(quote "$CARDANO_CLI")
NODE_SOCKET=$(quote "$NODE_SOCKET")
ACTIVE_KES_SKEY=$(quote "$ACTIVE_KES_SKEY")
ACTIVE_KES_VKEY=$(quote "$ACTIVE_KES_VKEY")
ACTIVE_NODE_CERT=$(quote "$ACTIVE_NODE_CERT")
SERVICE=$(quote "$SERVICE")
NODE_USER=$(quote "$NODE_USER")
NODE_GROUP=$(quote "$NODE_GROUP")
NETWORK_NAME=$(quote "$NETWORK_NAME")
NETWORK_KIND=$( [[ "$NETWORK_NAME" == mainnet ]] && printf mainnet || printf testnet )
TESTNET_MAGIC=$( [[ ${NETWORK_ARGS[0]} == --testnet-magic ]] && quote "${NETWORK_ARGS[1]}" || printf "''" )
TRANSFER_NAME=$(quote "$(basename "$transfer")")
EOF
  sync
  printf '\nTransfer directory prepared: %s\n' "$transfer"
  printf 'The KES signing key remains only at: %s/kes.skey\n' "$pending"
}

cold() {
  need sha256sum; need cardano-cli
  local transfer="${2:-}" cold_skey="" cold_counter="" backup period stamp
  [[ -n "$transfer" ]] || choose_candidate transfer "kes-rotation transfer directory" "$PWD"/kes-rotation-* "$PWD"
  require_dir "$transfer"; require_file "$transfer/kes.vkey"; require_file "$transfer/kes-period.txt"; require_file "$transfer/kes.vkey.sha256"
  local -a skeys=() counters=()
  mapfile -t skeys < <(find_files 'cold.skey' /opt/cardano /etc/cardano /srv/cardano /home "$PWD" 2>/dev/null)
  mapfile -t counters < <(find_files 'cold.counter' /opt/cardano /etc/cardano /srv/cardano /home "$PWD" 2>/dev/null)
  choose_candidate cold_skey "cold signing key" "${skeys[@]}"
  choose_candidate cold_counter "latest cold counter" "${counters[@]}"
  require_file "$cold_skey"; require_file "$cold_counter"
  backup="$(dirname "$cold_counter")/counter-backups"
  period="$(tr -d '[:space:]' <"$transfer/kes-period.txt")"; [[ "$period" =~ ^[0-9]+$ ]] || die "Invalid KES period."
  (cd "$transfer" && sha256sum -c kes.vkey.sha256)
  confirm "COLD NODE SETTINGS" "Transfer: $(canonical "$transfer")" "KES period: $period" "Cold key: $(canonical "$cold_skey")" "LATEST counter: $(canonical "$cold_counter")" "Counter backups: $backup"
  yes "I confirm this is the latest cold.counter" || die "Cancelled."
  mkdir -p "$backup"; stamp="$(date -u +'%Y%m%dT%H%M%SZ')"
  cp -a "$cold_counter" "$backup/cold.counter.$stamp.before"
  cardano-cli node issue-op-cert --kes-verification-key-file "$transfer/kes.vkey" --cold-signing-key-file "$cold_skey" --operational-certificate-issue-counter "$cold_counter" --kes-period "$period" --out-file "$transfer/node.cert"
  cp -a "$cold_counter" "$backup/cold.counter.$stamp.after"
  (cd "$transfer" && sha256sum node.cert >node.cert.sha256)
  sync
  log "COLD STEP COMPLETE"
  printf 'Move this whole directory back to the block producer:\n  %s\n' "$(canonical "$transfer")"
  printf 'The cold key and counter remain on this machine.\n'
}

find_returned_transfer() {
  local name="$1" expected="$2" candidate
  for candidate in "$expected/$name" /media/*/*/"$name" /run/media/*/*/"$name" /mnt/*/"$name"; do
    [[ -f "$candidate/node.cert" ]] && { printf '%s\n' "$candidate"; return; }
  done
  return 1
}

install_phase() {
  need sha256sum
  local pending="$WORK_ROOT/pending" transfer backup rotation completed local_hash returned_hash
  require_dir "$pending"; require_file "$pending/install.conf"; require_file "$pending/kes.skey"; require_file "$pending/kes.vkey"
  # Created locally by this script with shell-escaped values.
  # shellcheck disable=SC1090
  source "$pending/install.conf"
  transfer="$(find_returned_transfer "$TRANSFER_NAME" "$TRANSFER_ROOT" || true)"
  [[ -n "$transfer" ]] || choose_candidate transfer "returned $TRANSFER_NAME directory" "$TRANSFER_ROOT/$TRANSFER_NAME" /media/*/*/"$TRANSFER_NAME" /run/media/*/*/"$TRANSFER_NAME" /mnt/*/"$TRANSFER_NAME"
  require_file "$transfer/node.cert"; require_file "$transfer/node.cert.sha256"; require_file "$transfer/kes.vkey"
  (cd "$transfer" && sha256sum -c node.cert.sha256)
  local_hash="$(sha256sum "$pending/kes.vkey" | awk '{print $1}')"; returned_hash="$(sha256sum "$transfer/kes.vkey" | awk '{print $1}')"
  [[ "$local_hash" == "$returned_hash" ]] || die "Returned KES vkey does not match the pending signing key."
  confirm "READY TO INSTALL" "KES signing key: $pending/kes.skey" "Certificate: $transfer/node.cert" "Service: $SERVICE" "Existing credentials will be backed up first."
  backup="$WORK_ROOT/backups/$(date -u +'%Y%m%dT%H%M%SZ')"; mkdir -p "$backup"
  cp -a "$ACTIVE_KES_SKEY" "$backup/kes.skey"; cp -a "$ACTIVE_KES_VKEY" "$backup/kes.vkey"; cp -a "$ACTIVE_NODE_CERT" "$backup/node.cert"
  sudo install -o "$NODE_USER" -g "$NODE_GROUP" -m 0400 "$pending/kes.skey" "$ACTIVE_KES_SKEY"
  sudo install -o "$NODE_USER" -g "$NODE_GROUP" -m 0444 "$pending/kes.vkey" "$ACTIVE_KES_VKEY"
  sudo install -o "$NODE_USER" -g "$NODE_GROUP" -m 0444 "$transfer/node.cert" "$ACTIVE_NODE_CERT"
  sudo systemctl restart "$SERVICE"; sleep 5
  sudo systemctl is-active --quiet "$SERVICE" || { sudo systemctl --no-pager --full status "$SERVICE" || true; die "Node restart failed. Restore from $backup"; }
  if [[ "$NETWORK_KIND" == mainnet ]]; then NETWORK_ARGS=(--mainnet); else NETWORK_ARGS=(--testnet-magic "$TESTNET_MAGIC"); fi
  "$CARDANO_CLI" query tip "${NETWORK_ARGS[@]}" --socket-path "$NODE_SOCKET"
  "$CARDANO_CLI" query kes-period-info "${NETWORK_ARGS[@]}" --socket-path "$NODE_SOCKET" --op-cert-file "$ACTIVE_NODE_CERT"
  rotation="$(<"$pending/rotation-id.txt")"; completed="$WORK_ROOT/completed"; mkdir -p "$completed"; mv "$pending" "$completed/$rotation"
  log "KES ROTATION COMPLETE"
  printf 'Backup: %s\nCompleted data: %s/%s\n' "$backup" "$completed" "$rotation"
}

rotate() {
  prepare
  log "ACTION REQUIRED ON THE COLD NODE"
  printf '%s\n' \
    "1. Safely unmount and move the transfer media to the offline cold node." \
    "2. On the cold node run: sudo ./$(basename "$0") cold /path/to/kes-rotation-*" \
    "3. Safely move the media back and mount it on this block producer."
  read -r -p "When the signed directory is back and mounted, press Enter to continue... "
  detect_transfer_root
  install_phase
}

usage() {
  cat <<EOF
Cardano KES Rotation Helper v$VERSION
Usage:
  sudo ./$SCRIPT_NAME              Complete guided flow on the block producer
  sudo ./$SCRIPT_NAME rotate       Same as above
  sudo ./$SCRIPT_NAME cold [DIR]   Sign on the offline/cold node
  sudo ./$SCRIPT_NAME install      Resume an interrupted install on block producer
  ./$SCRIPT_NAME --help
EOF
}

main() {
  case "${1:-rotate}" in
    rotate) rotate ;;
    cold) cold "$@" ;;
    install) WORK_ROOT="${KES_ROTATION_HOME:-$HOME/kes-rotation}"; TRANSFER_ROOT=/mnt; install_phase ;;
    -h|--help|help) usage ;;
    *) usage; die "Unknown command: $1" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
