#!/usr/bin/env bash
# vos-fastpath: Remove an IPv4 from the blocklist.
# Usage: sudo ./scripts/unblock_ip.sh <ip>

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo."
	exit 1
fi

if [ -z "$1" ]; then
	echo "Usage: $0 <ipv4_address>"
	exit 1
fi

IP="$1"
MAP_NAME="blocked_ips"

key_hex=$(echo "$IP" | awk -F. '{
	if (NF != 4) exit 1;
	printf "%02x %02x %02x %02x", $1, $2, $3, $4
}')
if [ -z "$key_hex" ]; then
	echo "Invalid IPv4: $IP"
	exit 1
fi

MAP_ID=$(bpftool map list 2>/dev/null | while read -r line; do
	if echo "$line" | grep -q "$MAP_NAME"; then
		echo "$line" | grep -oE '^[0-9]+' || echo "$line" | grep -oE 'id [0-9]+' | grep -oE '[0-9]+'
		break
	fi
done | head -1)
[ -z "$MAP_ID" ] && MAP_ID=$(bpftool map list 2>/dev/null | grep -B20 "$MAP_NAME" | grep -oE '^[0-9]+' | tail -1)

if [ -z "$MAP_ID" ]; then
	echo "Map '$MAP_NAME' not found."
	exit 1
fi

bpftool map delete id "$MAP_ID" key hex $key_hex 2>/dev/null && echo "Unblocked $IP." || echo "Key not in map or delete failed."