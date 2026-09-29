#!/usr/bin/env bash
set -Eeuo pipefail

# Keep HOST_IP in sync with the upstream address in /etc/redsocks.conf.
HOST_IP="${HOST_IP:-172.19.96.1}"
CLASH_DNS_PORT="${CLASH_DNS_PORT:-1053}"
REDSOCKS_PORT="${REDSOCKS_PORT:-12345}"
BYPASS_IPS="${BYPASS_IPS:-38.207.133.215}" # Space-separated IPv4 addresses/CIDRs.
DNS_TCP="${DNS_TCP:-0}"

TCP_CHAIN=WSL_PROXY_TCP
DNS_CHAIN=WSL_PROXY_DNS
SNAT_CHAIN=WSL_PROXY_SNAT

usage() {
  printf 'Usage: %s {start|stop|restart|status}\n' "$0" >&2
  exit 2
}

ipt() {
  if (( EUID == 0 )); then
    iptables -w "$@"
  else
    sudo iptables -w "$@"
  fi
}

require_iptables() {
  command -v iptables >/dev/null || { echo 'iptables is required' >&2; exit 1; }
  if (( EUID != 0 )) && ! sudo -n true 2>/dev/null; then
    sudo -v || exit 1
  fi
}

remove_all() {
  local table="$1"
  shift
  while ipt -t "$table" -C "$@" 2>/dev/null; do
    ipt -t "$table" -D "$@"
  done
}

remove_chain() {
  local chain="$1"
  if ipt -t nat -S "$chain" >/dev/null 2>&1; then
    ipt -t nat -F "$chain"
    ipt -t nat -X "$chain"
  fi
}

remove_legacy_rules() {
  # One-time migration from the original script. Delete its chain only when
  # no other rule still references it.
  local ip port rules
  rules=$(ipt -t nat -S)
  if [[ "$rules" != *REDSOCKS* &&
        "$rules" != *":1053"* &&
        "$rules" != *":${CLASH_DNS_PORT}"* &&
        "$rules" != *"--dport 1053"* &&
        "$rules" != *"--dport ${CLASH_DNS_PORT}"* ]]; then
    return 0
  fi
  remove_all nat OUTPUT -p tcp -j REDSOCKS
  remove_all nat PREROUTING -p tcp -j REDSOCKS
  for ip in 172.19.96.1 "$HOST_IP"; do
    for port in 1053 "$CLASH_DNS_PORT"; do
      remove_all nat OUTPUT -p udp --dport 53 -j DNAT --to-destination "${ip}:${port}"
      remove_all nat OUTPUT -p tcp --dport 53 -j DNAT --to-destination "${ip}:${port}"
      remove_all nat POSTROUTING -p udp -d "$ip" --dport "$port" -j MASQUERADE
      remove_all nat POSTROUTING -p tcp -d "$ip" --dport "$port" -j MASQUERADE
    done
  done
  rules=$(ipt -t nat -S)
  if [[ "$rules" == *"-N REDSOCKS"* &&
        "$rules" != *" -j REDSOCKS"* &&
        "$rules" != *" -g REDSOCKS"* ]]; then
    remove_chain REDSOCKS
  fi
}

stop_rules() {
  remove_all nat OUTPUT -p tcp -j "$TCP_CHAIN"
  remove_all nat OUTPUT -p udp --dport 53 -j "$DNS_CHAIN"
  remove_all nat OUTPUT -p tcp --dport 53 -j "$DNS_CHAIN"
  remove_all nat POSTROUTING -p udp -j "$SNAT_CHAIN"
  remove_all nat POSTROUTING -p tcp -j "$SNAT_CHAIN"
  remove_chain "$TCP_CHAIN"
  remove_chain "$DNS_CHAIN"
  remove_chain "$SNAT_CHAIN"
  remove_legacy_rules
}

validate_config() {
  local port ip octet address prefix
  local -a octets
  for port in "$CLASH_DNS_PORT" "$REDSOCKS_PORT"; do
    [[ "$port" =~ ^[0-9]+$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || {
      echo "Invalid port: $port" >&2
      return 1
    }
  done
  [[ "$DNS_TCP" == 0 || "$DNS_TCP" == 1 ]] || {
    echo 'DNS_TCP must be 0 or 1' >&2
    return 1
  }
  [[ "$HOST_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "Invalid HOST_IP: $HOST_IP" >&2
    return 1
  }
  for ip in "$HOST_IP" $BYPASS_IPS; do
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || {
      echo "Invalid IP/CIDR: $ip" >&2
      return 1
    }
    address="${ip%%/*}"
    IFS=. read -r -a octets <<< "$address"
    for octet in "${octets[@]}"; do
      (( 10#$octet <= 255 )) || { echo "Invalid IP/CIDR: $ip" >&2; return 1; }
    done
    if [[ "$ip" == */* ]]; then
      prefix="${ip#*/}"
      (( 10#$prefix <= 32 )) || { echo "Invalid IP/CIDR: $ip" >&2; return 1; }
    fi
  done
}

start_rules() {
  local ip cidr
  validate_config
  stop_rules
  trap 'trap - ERR; stop_rules; echo "Failed to apply proxy rules; rolled back" >&2' ERR

  ipt -t nat -N "$TCP_CHAIN"
  ipt -t nat -N "$DNS_CHAIN"
  ipt -t nat -N "$SNAT_CHAIN"

  for cidr in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
              172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    ipt -t nat -A "$TCP_CHAIN" -d "$cidr" -j RETURN
  done
  ipt -t nat -A "$TCP_CHAIN" -d "$HOST_IP" -j RETURN
  for ip in $BYPASS_IPS; do
    ipt -t nat -A "$TCP_CHAIN" -d "$ip" -j RETURN
  done
  ipt -t nat -A "$TCP_CHAIN" -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"

  ipt -t nat -A "$DNS_CHAIN" -p udp -j DNAT --to-destination "${HOST_IP}:${CLASH_DNS_PORT}"
  ipt -t nat -A "$SNAT_CHAIN" -p udp -d "$HOST_IP" --dport "$CLASH_DNS_PORT" -j MASQUERADE
  if [[ "$DNS_TCP" == 1 ]]; then
    ipt -t nat -A "$DNS_CHAIN" -p tcp -j DNAT --to-destination "${HOST_IP}:${CLASH_DNS_PORT}"
    ipt -t nat -A "$SNAT_CHAIN" -p tcp -d "$HOST_IP" --dport "$CLASH_DNS_PORT" -j MASQUERADE
  fi

  ipt -t nat -A OUTPUT -p udp --dport 53 -j "$DNS_CHAIN"
  if [[ "$DNS_TCP" == 1 ]]; then
    ipt -t nat -A OUTPUT -p tcp --dport 53 -j "$DNS_CHAIN"
  fi
  ipt -t nat -A POSTROUTING -p udp -j "$SNAT_CHAIN"
  if [[ "$DNS_TCP" == 1 ]]; then
    ipt -t nat -A POSTROUTING -p tcp -j "$SNAT_CHAIN"
  fi
  ipt -t nat -A OUTPUT -p tcp -j "$TCP_CHAIN"

  trap - ERR
  echo "Proxy rules started (Clash DNS ${HOST_IP}:${CLASH_DNS_PORT}, redsocks :${REDSOCKS_PORT})"
}

status_rules() {
  local active=0
  local expected=3
  local result
  ipt -t nat -C OUTPUT -p tcp -j "$TCP_CHAIN" 2>/dev/null && ((active+=1)) || true
  ipt -t nat -C OUTPUT -p udp --dport 53 -j "$DNS_CHAIN" 2>/dev/null && ((active+=1)) || true
  ipt -t nat -C POSTROUTING -p udp -j "$SNAT_CHAIN" 2>/dev/null && ((active+=1)) || true
  if [[ "$DNS_TCP" == 1 ]]; then
    expected=5
    ipt -t nat -C OUTPUT -p tcp --dport 53 -j "$DNS_CHAIN" 2>/dev/null && ((active+=1)) || true
    ipt -t nat -C POSTROUTING -p tcp -j "$SNAT_CHAIN" 2>/dev/null && ((active+=1)) || true
  fi
  if (( active == expected )) &&
     ipt -t nat -C "$TCP_CHAIN" -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT" 2>/dev/null &&
     ipt -t nat -C "$DNS_CHAIN" -p udp -j DNAT --to-destination "${HOST_IP}:${CLASH_DNS_PORT}" 2>/dev/null &&
     { [[ "$DNS_TCP" == 0 ]] || ipt -t nat -C "$DNS_CHAIN" -p tcp -j DNAT --to-destination "${HOST_IP}:${CLASH_DNS_PORT}" 2>/dev/null; }; then
    echo 'active'
    result=0
  elif (( active == 0 )); then
    if ipt -t nat -C OUTPUT -p tcp -j REDSOCKS 2>/dev/null ||
       ipt -t nat -C OUTPUT -p udp --dport 53 -j DNAT --to-destination '172.19.96.1:1053' 2>/dev/null; then
      echo 'legacy rules active; run start or stop to migrate' >&2
      result=1
    else
      echo 'stopped'
      result=3
    fi
  else
    echo 'partial or configuration changed' >&2
    result=1
  fi
  echo 'Current IPv4 NAT rules:'
  ipt -t nat -S
  return "$result"
}

(( $# == 1 )) || usage
case "$1" in
  start) require_iptables; start_rules ;;
  stop) require_iptables; stop_rules; echo 'Proxy rules stopped' ;;
  restart) require_iptables; start_rules ;;
  status) require_iptables; status_rules ;;
  *) usage ;;
esac
