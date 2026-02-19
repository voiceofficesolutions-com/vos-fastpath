#!/usr/bin/env bash
# vos-fastpath: Read and print XDP per-CPU counters (options_dropped, redirected, passed)
# Requires: bpftool, loaded sip_logic XDP program with xdp_counters map
# Usage: sudo ./scripts/read_xdp_stats.sh

set -e

MAP_NAME="xdp_counters"
KEY_DROP=0
KEY_REDIR=1
KEY_PASS=2
KEY_BLOCKED=3
KEY_MALFORMED=4

if ! command -v bpftool &>/dev/null; then
	echo "bpftool not found. Install linux-tools or libbpf-tools."
	exit 1
fi

# Find map id by name
MAP_ID=$(bpftool map list 2>/dev/null | while read -r line; do
	if echo "$line" | grep -q "$MAP_NAME"; then
		echo "$line" | grep -oE '^[0-9]+' || echo "$line" | grep -oE 'id [0-9]+' | grep -oE '[0-9]+'
		break
	fi
done | head -1)
# Some bpftool: "id 12" on same line as name
[ -z "$MAP_ID" ] && MAP_ID=$(bpftool map list 2>/dev/null | grep -B20 "$MAP_NAME" | grep -oE '^[0-9]+' | tail -1)
if [ -z "$MAP_ID" ]; then
	echo "Map '$MAP_NAME' not found. Is the XDP program loaded? (sudo ./scripts/deploy.sh <iface>)"
	exit 1
fi

# Sum per-CPU values for one key (bpftool often dumps JSON)
sum_key() {
	local key_dec=$1
	local dump
	dump=$(bpftool map dump id "$MAP_ID" 2>/dev/null || true)
	if [ -z "$dump" ]; then
		echo "0"
		return
	fi
	# JSON: "key": N, "values": [ {"cpu": 0, "value": M }, ... ]
	if command -v jq &>/dev/null; then
		echo "$dump" | jq -r --argjson k "$key_dec" '.[] | select(.key == $k) | .values[].value' 2>/dev/null | awk '{s+=$1} END {print s+0}'
		return
	fi
	# No jq: parse JSON for this key's values (match "value": N but not "values")
	echo "$dump" | awk -v key="$key_dec" '
		/\"key\":/ { gsub(/,/,""); k=$2+0; in_key=(k==key) }
		in_key && /\"value\": [0-9]/ { gsub(/,/,""); for(i=1;i<=NF;i++) if($i=="\"value\":") { sum+=$(i+1)+0; break } }
		END { print sum+0 }
	'
}

DROPPED=$(sum_key $KEY_DROP)
REDIRECTED=$(sum_key $KEY_REDIR)
PASSED=$(sum_key $KEY_PASS)
BLOCKED=$(sum_key $KEY_BLOCKED)
MALFORMED=$(sum_key $KEY_MALFORMED)

echo "XDP counters (map id $MAP_ID):"
echo "  OPTIONS dropped (stealth): $DROPPED"
echo "  Blocked (DoS list):        $BLOCKED"
echo "  Malformed (dropped):       $MALFORMED"
echo "  Redirected (AF_XDP):      $REDIRECTED"
echo "  Passed to stack:          $PASSED"
echo "  Total UDP 5060 handled:   $(( DROPPED + BLOCKED + MALFORMED + REDIRECTED + PASSED ))"
