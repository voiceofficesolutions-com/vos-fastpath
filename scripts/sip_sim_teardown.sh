#!/usr/bin/env bash
# vos-fastpath: Remove the SIP simulation (namespace + veth + XDP). Safe to run even if not set up.

set -e

NS_NAME="sip-sim"
VETH_HOST="veth-sip"

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo."
	exit 1
fi

echo "Tearing down SIP simulation..."

# Unload XDP from veth (required before deleting the link)
if ip link show "$VETH_HOST" &>/dev/null; then
	ip link set dev "$VETH_HOST" xdpgeneric off 2>/dev/null || true
	ip link set dev "$VETH_HOST" xdp off 2>/dev/null || true
	ip link del "$VETH_HOST" 2>/dev/null && echo "  Deleted $VETH_HOST (veth pair)." || true
fi

if ip netns list 2>/dev/null | grep -q "^${NS_NAME} "; then
	ip netns del "$NS_NAME" 2>/dev/null && echo "  Deleted namespace $NS_NAME." || true
fi

echo "Simulation removed."
