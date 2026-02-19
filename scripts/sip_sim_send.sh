#!/usr/bin/env bash
# vos-fastpath: Send simulated SIP traffic from the "other host" (sip-sim namespace) to the XDP interface.
# Run after sip_sim_setup.sh. Usage: sudo ./scripts/sip_sim_send.sh [count]
# Sends OPTIONS (will be dropped by stealth) and REGISTER (will be passed). Default count=10 of each.

set -e

NS_NAME="sip-sim"
HOST_IP="10.99.0.1"
PORT="5060"
COUNT="${1:-10}"

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo."
	exit 1
fi

if ! ip netns list 2>/dev/null | grep -q "^${NS_NAME} "; then
	echo "Namespace $NS_NAME not found. Run sudo ./scripts/sip_sim_setup.sh first."
	exit 1
fi

echo "Sending $COUNT OPTIONS + $COUNT REGISTER from sim host to ${HOST_IP}:${PORT}..."

send_udp() {
	local msg="$1"
	local i
	for ((i=0; i<COUNT; i++)); do
		printf '%s\r\n' "$msg" | ip netns exec "$NS_NAME" timeout 1 nc -u -w1 "$HOST_IP" "$PORT" 2>/dev/null || true
	done
}

# SIP OPTIONS (stealth will drop: source IP not in allowed_ips)
send_udp "OPTIONS sip:test SIP/2.0"$'\r\n'
# SIP REGISTER (no OPTIONS prefix → passed to stack)
send_udp "REGISTER sip:test SIP/2.0"$'\r\n'

echo "Done. Run: sudo ./scripts/read_xdp_stats.sh"
echo "  (Expect OPTIONS dropped ≈ $COUNT, Passed to stack ≈ $COUNT)"
