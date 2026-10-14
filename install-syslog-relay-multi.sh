#!/usr/bin/env bash
# Interactive rsyslog UDP/514 fan-out installer for Ubuntu.
# Written by Cyb3rBob (and Codex)
# Video walk-through for this script:  https://youtu.be/cZhyzyxrXVg
# To run this script
# chmod +x install-syslog-relay.sh
# sudo ./install-syslog-reloay.sh
# After Installation you can see if rsyslog is receiving and forwarding traffic
# sudo tcpdump -ni any 'udp port 514'
# sudo tail -f /var/log/rsyslog-relay-stats.log
set -Eeuo pipefail

RELAY_CONF=/etc/rsyslog.d/30-udp514-relay.conf
STATS_CONF=/etc/rsyslog.d/00-relay-impstats.conf
STATS_LOG=/var/log/rsyslog-relay-stats.log
BACKUP_DIR="/var/backups/rsyslog-relay/$(date +%Y%m%d-%H%M%S)-$$"
COMMITTED=0
MODIFIED=0
HAD_RELAY=0
HAD_STATS=0

log() { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
rollback() {
  if [[ "$COMMITTED" == 1 || "$MODIFIED" == 0 ]]; then return; fi
  warn 'Restoring pre-existing relay configuration after unsuccessful installation.'
  if [[ "$HAD_RELAY" == 1 ]]; then cp -p "$BACKUP_DIR/relay.conf" "$RELAY_CONF"; else rm -f "$RELAY_CONF"; fi
  if [[ "$HAD_STATS" == 1 ]]; then cp -p "$BACKUP_DIR/stats.conf" "$STATS_CONF"; else rm -f "$STATS_CONF"; fi
  if command -v rsyslogd >/dev/null 2>&1 && rsyslogd -N1 >/dev/null 2>&1; then
    systemctl restart rsyslog >/dev/null 2>&1 || true
  fi
}
on_exit() { local rc=$?; if (( rc != 0 )); then rollback; fi; }
trap on_exit EXIT

(( EUID == 0 )) || die 'Run this installer with sudo.'
[[ -f /etc/os-release ]] || die 'Cannot identify OS.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die 'This installer targets Ubuntu only.'

printf '=== rsyslog UDP/514 multi-destination relay installer ===\n'
printf 'Ubuntu version: %s\n' "${PRETTY_NAME:-unknown}"
[[ "${VERSION_ID:-}" == '26.04' ]] || warn 'Designed for Ubuntu 26.04; verify compatibility on this release.'

valid_ip() {
  local ip=$1 part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local IFS=.; read -r -a octets <<< "$ip"
  for part in "${octets[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( 10#$part <= 255 )) || return 1
  done
  [[ "$ip" != '0.0.0.0' && "$ip" != '255.255.255.255' ]]
}
read_ip() {
  local prompt=$1 reply
  while :; do
    read -r -p "$prompt" reply
    if valid_ip "$reply"; then printf '%s' "$reply"; return; fi
    warn 'Enter a valid IPv4 address.'
  done
}
while :; do
  read -r -p 'How many logging destinations? ' DEST_COUNT
  if [[ "$DEST_COUNT" =~ ^[1-9][0-9]*$ ]] && (( ${#DEST_COUNT} <= 4 )) && (( 10#$DEST_COUNT <= 100 )); then
    DEST_COUNT=$((10#$DEST_COUNT))
    break
  fi
  warn 'Enter a number from 1 to 100.'
done
DESTINATIONS=()
for (( i=1; i<=DEST_COUNT; i++ )); do
  while :; do
    address=$(read_ip "Destination logging server #$i IPv4 address: ")
    duplicate=0
    for prior in "${DESTINATIONS[@]}"; do
      if [[ "$address" == "$prior" ]]; then duplicate=1; break; fi
    done
    if (( duplicate == 0 )); then DESTINATIONS+=("$address"); break; fi
    warn 'Destination IP addresses must differ.'
  done
done

printf '\nConfiguration: UDP/514 -> %s destination(s) (UDP/514):\n' "$DEST_COUNT"
for (( i=0; i<DEST_COUNT; i++ )); do printf '  %s\n' "${DESTINATIONS[i]}"; done
read -r -p 'Continue with installation? [y/N]: ' CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { printf 'Cancelled.\n'; exit 0; }

log 'Installing rsyslog and diagnostics utilities.'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y rsyslog iproute2 tcpdump

# Fail safely rather than interfering with an unrelated UDP/514 listener.
if ss -H -lun '( sport = :514 )' 2>/dev/null | grep -q .; then
  # An already-running rsyslog relay is allowed on a rerun; otherwise stop.
  if [[ ! -f "$RELAY_CONF" ]]; then
    die 'UDP/514 is already bound, and this installer does not own that listener. Resolve the conflict manually.'
  fi
fi

# Avoid duplicate UDP input definitions in other config files.
if grep -REl '^[[:space:]]*(\$ModLoad[[:space:]]+imudp|module\([[:space:]]*load=["\x27]?imudp|\$UDPServerRun|input\([[:space:]]*type=["\x27]?imudp)' /etc/rsyslog.conf /etc/rsyslog.d --include='*.conf' 2>/dev/null | grep -vFx "$RELAY_CONF" | grep -q .; then
  die 'Found existing imudp configuration outside the managed file. Check it for duplicate module loading/listeners before rerunning.'
fi
if grep -REl '^[[:space:]]*module\([[:space:]]*load=["\x27]?impstats' /etc/rsyslog.conf /etc/rsyslog.d --include='*.conf' 2>/dev/null | grep -vFx "$STATS_CONF" | grep -q .; then
  die 'Found existing impstats module configuration outside the managed file. Reconcile it manually before rerunning.'
fi

install -d -m 0700 "$BACKUP_DIR"
if [[ -e "$RELAY_CONF" ]]; then cp -p "$RELAY_CONF" "$BACKUP_DIR/relay.conf"; HAD_RELAY=1; fi
if [[ -e "$STATS_CONF" ]]; then cp -p "$STATS_CONF" "$BACKUP_DIR/stats.conf"; HAD_STATS=1; fi

MODIFIED=1
log "Writing dedicated relay ruleset to $RELAY_CONF"
cat > "$RELAY_CONF" <<'RSYSLOG'
# Managed by install-syslog-relay.sh. Incoming UDP/514 only.
module(load="imudp" threads="1" batchSize="32")
ruleset(name="remote_udp514_relay") {
RSYSLOG
for (( i=0; i<DEST_COUNT; i++ )); do
  printf '    action(name="relay_to_server%d" type="omfwd" target="%s" port="514" protocol="udp")\n' \
    "$((i+1))" "${DESTINATIONS[i]}" >> "$RELAY_CONF"
done
cat >> "$RELAY_CONF" <<'RSYSLOG'
}
input(type="imudp" port="514" ruleset="remote_udp514_relay")
RSYSLOG
chmod 0644 "$RELAY_CONF"

cat > "$STATS_CONF" <<'RSYSLOG'
# Managed by install-syslog-relay.sh. Internal metrics are local only.
module(load="impstats" interval="60" format="json"
       log.syslog="off" log.file="/var/log/rsyslog-relay-stats.log")
RSYSLOG
chmod 0644 "$STATS_CONF"

log 'Validating rsyslog configuration.'
rsyslogd -N1 || die 'Configuration validation failed.'

log 'Enabling and restarting rsyslog.'
systemctl enable rsyslog
systemctl restart rsyslog
systemctl is-active --quiet rsyslog || die 'rsyslog did not become active.'
if ! ss -H -lun '( sport = :514 )' | grep -q .; then
  die 'rsyslog is active but UDP/514 does not appear to be listening.'
fi
COMMITTED=1

printf '\n=============================================\n'
printf 'SUCCESS: UDP syslog relay configured\n'
printf 'Incoming: UDP/514\n'
for (( i=0; i<DEST_COUNT; i++ )); do printf 'Destination %d: %s:514 (UDP)\n' "$((i+1))" "${DESTINATIONS[i]}"; done
printf 'Performance target: approximately 1,000 messages/second (to be measured)\n'
printf 'Stats log: %s\n' "$STATS_LOG"
printf 'Backup (previous managed files, if any): %s\n' "$BACKUP_DIR"
printf 'Configuration: %s\n' "$RELAY_CONF"
printf 'Check stats after 60 sec: sudo tail -f %s\n' "$STATS_LOG"
printf "Check UDP drops: nstat -az | grep -E 'UdpInErrors|UdpRcvbufErrors'\n"
printf 'Verify packets: sudo tcpdump -ni any "udp port 514"\n'
printf 'NOTE: UDP has no end-to-end delivery guarantee. Verify receipt on both collectors.\n'
printf '=============================================\n'
