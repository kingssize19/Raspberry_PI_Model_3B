#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
USAGE:
  sudo ./set_ip.sh -i <iface> -a <ip[/prefix]> [-g <gateway>] [-d "dns1,dns2"] [-c <conn-name>] [-f]

Options:
  -i  Interface name (eth0, wlan0, etc.)                [REQUIRED]
  -a  IP/CIDR (e.g., 192.168.68.10/24). If missing, /24 [REQUIRED]
  -g  Gateway (optional)
  -d  DNS list (comma separated: "1.1.1.1,8.8.8.8")     (optional)
  -c  Connection/profile name                           (optional)
  -f  Force (skip IP conflict test)                     (optional)
EOF
}

err()  { echo -e "\e[31mError:\e[0m $*" >&2; }
info() { echo -e "\e[36m[INFO]\e[0m $*"; }
ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
warn() { echo -e "\e[33m[WARNING]\e[0m $*"; }

IFACE=""
ADDR_IN=""
GW="${GW:-}"
DNS="${DNS:-}"
CONN="${CONN:-}"
FORCE=0

while getopts ":i:a:g:d:c:f" opt; do
  case "$opt" in
    i) IFACE="$OPTARG";;
    a) ADDR_IN="$OPTARG";;
    g) GW="$OPTARG";;
    d) DNS="$OPTARG";;
    c) CONN="$OPTARG";;
    f) FORCE=1;;
    \?) err "Unknown option: -$OPTARG"; usage; exit 2;;
    :)  err "Option -$OPTARG requires an argument"; usage; exit 2;;
  esac
done

[[ -z "$IFACE" || -z "$ADDR_IN" ]] && { usage; exit 2; }

# Prerequisites
command -v nmcli >/dev/null 2>&1 || { err "nmcli not found. Install NetworkManager."; exit 1; }
[[ $EUID -eq 0 ]] || { err "Please run with sudo."; exit 1; }

# Interface present?
if ! nmcli -t -f DEVICE device status | cut -d: -f1 | grep -qx "$IFACE"; then
  err "$IFACE interface not found."
  exit 1
fi
IFTYPE="$(nmcli -t -f DEVICE,TYPE device status | awk -F: -v d="$IFACE" '$1==d{print $2}')"

# Parse IP/CIDR
if [[ "$ADDR_IN" == */* ]]; then
  ADDR="$ADDR_IN"
  IP="${ADDR_IN%/*}"
  PREFIX="${ADDR_IN#*/}"
else
  warn "CIDR not specified; /24 assumed."
  ADDR="${ADDR_IN}/24"
  IP="$ADDR_IN"
  PREFIX="24"
fi
# Basic checks
if ! [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then err "Invalid IP: $IP"; exit 1; fi
if ! [[ "$PREFIX" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]]; then err "Invalid PREFIX: $PREFIX (0-32)"; exit 1; fi

# Find/Create connection
if [[ -z "$CONN" ]]; then
  CONN="$(nmcli -t -f NAME,DEVICE,ACTIVE connection show \
          | awk -F: -v d="$IFACE" '$2==d && $3=="yes"{print $1}' | head -n1 || true)"
  [[ -z "$CONN" ]] && CONN="$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v d="$IFACE" '$2==d{print $1}' | head -n1 || true)"
fi

if [[ -z "$CONN" ]]; then
  if [[ "$IFTYPE" == "wifi" ]]; then
    err "No Wi-Fi profile found for $IFACE. Connect to the SSID first (create a profile)."
    exit 1
  fi
  CONN="${IFACE}-static"
  info "Profile does not exist, creating new profile for Ethernet: $CONN"
  nmcli con add type ethernet ifname "$IFACE" con-name "$CONN" autoconnect yes >/dev/null
fi

ok "Profile to use:  \"$CONN\" (Interface: $IFACE)"

# Backup current profile settings
SAFE_CONN="${CONN// /_}"
BACKUP="/root/nm-backup-${SAFE_CONN}-$(date -u +%Y%m%d-%H%M%S).txt"
nmcli con show "$CONN" > "$BACKUP" || true
info "Current profile settings have been backed up."

# IP conflict test
if (( FORCE == 0 )); then
  IN_USE=0
  info "IP conflict test: $IP"
  if command -v arping >/dev/null 2>&1; then
    if arping -D -I "$IFACE" -c 2 "$IP" >/dev/null 2>&1; then
      ok "arping: $IP looks free."
    else
      warn "arping: Got a reply for $IP; may be in use."
      IN_USE=1
    fi
  else
    warn "arping not installed; falling back to ping (not definitive)."
    if ping -c1 -W1 "$IP" >/dev/null 2>&1; then
      warn "ping: $IP responded; may be in use."
      IN_USE=1
    else
      ok "ping: no reply; continuing."
    fi
  fi
  if (( IN_USE == 1 )); then
    err "The $IP appears to be in use. You are giving up."
    exit 3
  fi
else
  warn "Force enabled: IP conflict test skipped."
fi

# DNS comma -> space
if [[ -n "${DNS:-}" ]]; then
  DNS="${DNS//,/ }"
fi

# Apply settings
info "Updating profile..."
nmcli con mod "$CONN" ipv4.method manual ipv4.addresses "$ADDR"
if [[ -n "${GW:-}" ]]; then nmcli con mod "$CONN" ipv4.gateway "$GW"; else nmcli con mod "$CONN" -ipv4.gateway; fi
if [[ -n "${DNS:-}" ]]; then nmcli con mod "$CONN" ipv4.dns "$DNS"; else nmcli con mod "$CONN" -ipv4.dns; fi
nmcli con mod "$CONN" connection.autoconnect yes
nmcli con mod "$CONN" ipv6.method ignore || true

info "Restarting connection..."
nmcli -w 5 con down "$CONN" >/dev/null 2>&1 || true
nmcli -w 15 con up "$CONN"

sleep 1
ok "New state:"
ip -4 addr show dev "$IFACE" | sed 's/^/  /'
ip route | sed 's/^/  /' | head -n 7

ok "STATIC IP ASSIGNMENT COMPLETED."

echo
echo "Revert to DHCP:"
echo "  nmcli con mod \"$CONN\" ipv4.method auto; nmcli con up \"$CONN\""
