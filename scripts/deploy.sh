#!/usr/bin/env bash
# vos-fastpath: Smart XDP loader — Native first, fallback to SKB (generic)
# Usage: sudo ./scripts/deploy.sh <interface> [xdp_object]
# Example: sudo ./scripts/deploy.sh eth0

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
XDP_OBJ="${2:-${BUILD_DIR}/sip_logic.bpf.o}"
SEC="xdp"

if [ -z "$1" ]; then
	echo "Usage: $0 <interface> [xdp_object]"
	echo "Example: $0 eth0"
	exit 1
fi

IFACE="$1"

if [ ! -f "$XDP_OBJ" ]; then
	echo "ERROR: XDP object not found: $XDP_OBJ"
	echo "Run 'make' first."
	exit 1
fi

# Probe NIC driver (optional; for logging)
if command -v ethtool &>/dev/null; then
	DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver:/{print $2}' || true)
	[ -n "$DRIVER" ] && echo "Interface $IFACE driver: $DRIVER"
fi

# Try Native XDP first
echo "Attempting Native XDP attach on $IFACE..."
if ip link set dev "$IFACE" xdp obj "$XDP_OBJ" sec "$SEC" 2>&1; then
	echo "Native XDP loaded on $IFACE."
	exit 0
fi

# Fallback: SKB (generic) mode
echo "Native XDP not supported; loading in SKB (generic) mode..."
if ip link set dev "$IFACE" xdpgeneric obj "$XDP_OBJ" sec "$SEC" 2>&1; then
	echo "SKB (generic) XDP loaded on $IFACE."
	exit 0
fi

echo "ERROR: Failed to load XDP in both Native and SKB modes. See error above."
exit 1
