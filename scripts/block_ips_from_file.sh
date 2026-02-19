#!/usr/bin/env bash
# vos-fastpath: Bulk-load IPv4 blocklist from a file (e.g. SBC honeypot export).
# Geared to honeypot on an SBC: SBC observes bad/suspicious SIP sources, exports
# IPs; this script loads them so traffic from those IPs is dropped at the NIC
# before the kernel stack or OpenSIPS.
# Usage: sudo ./scripts/block_ips_from_file.sh <file>
# File: one IPv4 address per line; # and empty lines ignored.

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo."
	exit 1
fi

if [ -z "$1" ] || [ ! -f "$1" ]; then
	echo "Usage: $0 <ip_list_file>"
	echo "  File: one IPv4 per line (e.g. export from SBC honeypot or threat intel)."
	exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDED=0
SKIP=0
FAIL=0

while IFS= read -r line || [ -n "$line" ]; do
	line="${line%%#*}"
	line=$(echo "$line" | tr -d ' \t\r\n')
	[ -z "$line" ] && continue
	if [[ "$line" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		if bash "$SCRIPT_DIR/block_ip.sh" "$line" 2>/dev/null; then
			ADDED=$((ADDED + 1))
		else
			FAIL=$((FAIL + 1))
		fi
	else
		SKIP=$((SKIP + 1))
	fi
done < "$1"

echo "Done: $ADDED blocked, $SKIP skipped (invalid), $FAIL failed (map full or not loaded)."
