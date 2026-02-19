#!/usr/bin/env bash
# vos-fastpath: Simulate SIP traffic from "another host" using a network namespace + veth.
# Traffic from the sim namespace ingresses on veth-sip in the main namespace, so XDP sees it.
# Requires: sudo. Run teardown when done: sudo ./scripts/sip_sim_teardown.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
XDP_OBJ="${BUILD_DIR}/sip_logic.bpf.o"

NS_NAME="sip-sim"
VETH_HOST="veth-sip"
VETH_SIM="veth-sim"
HOST_IP="10.99.0.1"
SIM_IP="10.99.0.2"
MASK="/24"
PORT="5060"

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo."
	exit 1
fi

if [ ! -f "$XDP_OBJ" ]; then
	echo "ERROR: $XDP_OBJ not found. Run 'make' first."
	exit 1
fi

# Idempotent: remove stale sim if present
if ip netns list 2>/dev/null | grep -q "^${NS_NAME} "; then
	echo "Removing existing namespace $NS_NAME..."
	ip link set dev "$VETH_HOST" xdpgeneric off 2>/dev/null || true
	ip link del "$VETH_HOST" 2>/dev/null || true
	ip netns del "$NS_NAME" 2>/dev/null || true
	sleep 1
fi

echo "Creating namespace $NS_NAME and veth pair..."
ip netns add "$NS_NAME"
ip link add "$VETH_HOST" type veth peer name "$VETH_SIM"
ip link set "$VETH_SIM" netns "$NS_NAME"

ip addr add "${HOST_IP}${MASK}" dev "$VETH_HOST"
ip link set "$VETH_HOST" up

ip netns exec "$NS_NAME" ip addr add "${SIM_IP}${MASK}" dev "$VETH_SIM"
ip netns exec "$NS_NAME" ip link set "$VETH_SIM" up
ip netns exec "$NS_NAME" ip link set lo up

echo "Loading XDP on $VETH_HOST (simulated ingress)..."
if ip link set dev "$VETH_HOST" xdp obj "$XDP_OBJ" sec xdp 2>/dev/null; then
	echo "  Native XDP loaded."
elif ip link set dev "$VETH_HOST" xdpgeneric obj "$XDP_OBJ" sec xdp 2>/dev/null; then
	echo "  SKB (generic) XDP loaded."
else
	ip link del "$VETH_HOST" 2>/dev/null || true
	ip netns del "$NS_NAME" 2>/dev/null || true
	echo "ERROR: Failed to load XDP on $VETH_HOST."
	exit 1
fi

echo ""
echo "Simulation is up. Traffic from $SIM_IP → ${HOST_IP}:${PORT} will hit XDP on $VETH_HOST."
echo ""
echo "  Send traffic:  sudo $SCRIPT_DIR/sip_sim_send.sh [count]"
echo "  Read counters: sudo $SCRIPT_DIR/read_xdp_stats.sh"
echo "  Remove everything: sudo $SCRIPT_DIR/sip_sim_teardown.sh"
echo ""
