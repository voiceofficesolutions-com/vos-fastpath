#!/usr/bin/env bash
# vos-fastpath: Add an IPv4 address to the allowed_ips map so OPTIONS from that IP are not dropped.
# Usage: sudo ./scripts/allow_ip.sh <ipv4_address>
# Example: sudo ./scripts/allow_ip.sh 10.99.0.2   # allow sim host so OPTIONS pass

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo."
	exit 1
fi

if [ -z "$1" ]; then
	echo "Usage: $0 <ipv4_address>"
	echo "Example: $0 10.99.0.2"
	exit 1
fi

IP="$1"
MAP_NAME="allowed_ips"

# Parse a.b.c.d into hex key (network byte order: first octet = MSB)
key_hex=$(echo "$IP" | awk -F. '{
	if (NF != 4) exit 1;
	printf "%02x %02x %02x %02x", $1, $2, $3, $4
}')
if [ -z "$key_hex" ]; then
	echo "Invalid IPv4: $IP"
	exit 1
fi

# Value: 1 byte = 1 (allowed)
value_hex="01"

MAP_ID=$(bpftool map list 2>/dev/null | while read -r line; do
	if echo "$line" | grep -q "$MAP_NAME"; then
		echo "$line" | grep -oE '^[0-9]+' || echo "$line" | grep -oE 'id [0-9]+' | grep -oE '[0-9]+'
		break
	fi
done | head -1)
[ -z "$MAP_ID" ] && MAP_ID=$(bpftool map list 2>/dev/null | grep -B20 "$MAP_NAME" | grep -oE '^[0-9]+' | tail -1)

if [ -z "$MAP_ID" ]; then
	echo "Map '$MAP_NAME' not found. Load the XDP program first (e.g. sip_sim_setup.sh or deploy.sh)."
	exit 1
fi

bpftool map update id "$MAP_ID" key hex $key_hex value hex $value_hex 2>/dev/null || {
	echo "Update failed. Is the program loaded?"
	exit 1
}
echo "Allowed OPTIONS from $IP (added to allowed_ips)."
