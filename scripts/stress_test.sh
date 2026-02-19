#!/usr/bin/env bash
# vos-fastpath: Stress and correctness test — hammer XDP under load and verify behavior.
# For service-provider reliability: volume, blocklist, allowlist, malformed packets.
# Usage: sudo ./scripts/stress_test.sh [optional: rounds for hammer phase]
# Exit: 0 = all phases passed, non-zero = failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
NS_NAME="sip-sim"
HOST_IP="10.99.0.1"
SIM_IP="10.99.0.2"
PORT="5060"
HAMMER_ROUNDS="${1:-2}"   # rounds of volume hammer (each round = 30 OPTIONS + 30 REGISTER)
BATCH_OPTS=30
BATCH_REG=30

FAILED=0
log() { echo "[stress] $*"; }
fail() { log "FAIL: $*"; FAILED=1; }
ok()   { log "OK: $*"; }

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo."
	exit 1
fi

if [ ! -f "$BUILD_DIR/sip_logic.bpf.o" ]; then
	echo "Build first: make"
	exit 1
fi

get_stat() {
	local name="$1"
	local v
	v=$("$SCRIPT_DIR/read_xdp_stats.sh" 2>/dev/null | awk -v n="$name" '$0 ~ n {print $(NF); exit}')
	echo "${v:-0}"
}

get_dropped()   { get_stat "OPTIONS dropped"; }
get_blocked()   { get_stat "Blocked"; }
get_redirected(){ get_stat "Redirected"; }
get_passed()    { get_stat "Passed to stack"; }

send_batch() {
	local opts=$1 reg=$2
	local i
	for ((i=0; i<opts; i++)); do
		printf 'OPTIONS sip:test SIP/2.0\r\n' | ip netns exec "$NS_NAME" timeout 1 nc -u -w1 "$HOST_IP" "$PORT" 2>/dev/null || true
	done
	for ((i=0; i<reg; i++)); do
		printf 'REGISTER sip:test SIP/2.0\r\n' | ip netns exec "$NS_NAME" timeout 1 nc -u -w1 "$HOST_IP" "$PORT" 2>/dev/null || true
	done
}

# --- Clean and setup ---
log "Teardown any existing sim..."
"$SCRIPT_DIR/sip_sim_teardown.sh" 2>/dev/null || true
sleep 1
log "Setup sim + XDP..."
"$SCRIPT_DIR/sip_sim_setup.sh" 2>/dev/null || true
sleep 1

D0=$(get_dropped); B0=$(get_blocked); R0=$(get_redirected); P0=$(get_passed)
log "Baseline: dropped=$D0 blocked=$B0 redirected=$R0 passed=$P0"

# --- Phase 1: Volume and counter consistency ---
log "Phase 1: Volume (${HAMMER_ROUNDS} rounds x $BATCH_OPTS OPTIONS + $BATCH_REG REGISTER)..."
for ((r=0; r<HAMMER_ROUNDS; r++)); do
	send_batch $BATCH_OPTS $BATCH_REG
done
sleep 1
D1=$(get_dropped); B1=$(get_blocked); P1=$(get_passed)
log "After volume: dropped=$D1 blocked=$B1 passed=$P1"
delta_drop=$((D1 - D0)); delta_pass=$((P1 - P0))
expected_drop=$((HAMMER_ROUNDS * BATCH_OPTS)); expected_pass=$((HAMMER_ROUNDS * BATCH_REG))
tol=10
if [ "$delta_drop" -lt $((expected_drop - tol)) ] || [ "$delta_drop" -gt $((expected_drop + tol)) ]; then
	fail "Phase 1: OPTIONS dropped delta $delta_drop expected ~$expected_drop"
else
	ok "Phase 1: OPTIONS dropped delta $delta_drop"
fi
if [ "$delta_pass" -lt $((expected_pass - tol)) ] || [ "$delta_pass" -gt $((expected_pass + tol)) ]; then
	fail "Phase 1: Passed delta $delta_pass expected ~$expected_pass"
else
	ok "Phase 1: Passed delta $delta_pass"
fi

# --- Phase 2: Blocklist ---
log "Phase 2: Blocklist (block $SIM_IP, send 80, then unblock, send 40)..."
bash "$SCRIPT_DIR/block_ip.sh" "$SIM_IP" 2>/dev/null || { fail "block_ip.sh"; true; }
sleep 1
Bbefore=$(get_blocked)
send_batch 25 25
sleep 1
Bafter=$(get_blocked)
delta_block=$((Bafter - Bbefore))
if [ "$delta_block" -lt 35 ] || [ "$delta_block" -gt 55 ]; then
	fail "Phase 2: Blocked delta $delta_block expected ~50"
else
	ok "Phase 2: Blocked $delta_block packets"
fi
bash "$SCRIPT_DIR/unblock_ip.sh" "$SIM_IP" 2>/dev/null || true
sleep 1
send_batch 10 10
sleep 1
Bfinal=$(get_blocked)
if [ "$Bfinal" -ne "$Bafter" ]; then
	fail "Phase 2: Blocked count changed after unblock (expected no new blocks)"
else
	ok "Phase 2: Unblock stopped new blocks"
fi

# --- Phase 3: Allow list (OPTIONS from sim should pass after allow) ---
log "Phase 3: Allow list (allow $SIM_IP for OPTIONS, send OPTIONS, expect pass not drop)..."
bash "$SCRIPT_DIR/allow_ip.sh" "$SIM_IP" 2>/dev/null || { fail "allow_ip.sh"; true; }
sleep 1
Dbefore=$(get_dropped); Pbefore=$(get_passed)
send_batch 25 5    # 25 OPTIONS, 5 REGISTER
sleep 1
Dafter=$(get_dropped); Pafter=$(get_passed)
drop_delta=$((Dafter - Dbefore)); pass_delta=$((Pafter - Pbefore))
if [ "$drop_delta" -gt 5 ]; then
	fail "Phase 3: OPTIONS still dropped after allow (delta $drop_delta)"
else
	ok "Phase 3: OPTIONS not dropped after allow (drop_delta=$drop_delta)"
fi
if [ "$pass_delta" -lt 20 ]; then
	fail "Phase 3: Passed delta $pass_delta expected >= 20"
else
	ok "Phase 3: Passed delta $pass_delta"
fi

# --- Phase 4: Hammer — sustained load and stats stability ---
log "Phase 4: Hammer (sustained load + repeated stats read)..."
for ((r=0; r<3; r++)); do
	send_batch 15 15
	"$SCRIPT_DIR/read_xdp_stats.sh" >/dev/null 2>&1 || fail "Phase 4: read_xdp_stats failed"
done
ok "Phase 4: No crash under sustained load"

# --- Phase 5: Teardown and final check ---
log "Phase 5: Teardown..."
"$SCRIPT_DIR/sip_sim_teardown.sh" 2>/dev/null || true
if ip netns list 2>/dev/null | grep -q "^${NS_NAME} "; then
	fail "Phase 5: Namespace $NS_NAME still present after teardown"
else
	ok "Phase 5: Teardown clean"
fi

if [ "$FAILED" -eq 1 ]; then
	log "One or more phases failed."
	exit 1
fi
log "All phases passed. Reliability test OK."
exit 0
