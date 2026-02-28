#!/usr/bin/env bash
# bench.sh — OpenSIPS ingress benchmark runner (with and without XDP fastpath)
#
# Requires: sipp (apt install sipp  OR  build from source for TLS/SRTP support)
# Root required for XDP attach/detach (sudo)
#
# Usage:
#   ./bench/bench.sh [subcommand] [options]
#
# Subcommands:
#   compare         Run WITHOUT XDP (baseline) then WITH XDP and print diff table.
#                   Alias for --compare flag.
#
# Options:
#   -t <target>     OpenSIPS IP:port               (default: 127.0.0.1:5060)
#   -i <iface>      NIC interface for XDP attach    (default: eth0)
#   -s <scenario>   options | register | invite | all  (default: options)
#   -r <cps>        call attempts per second        (default: 500)
#   -l <limit>      max concurrent calls            (default: 1000)
#   -m <total>      total requests to send          (default: 50000)
#   -d <hold_ms>    call hold duration ms           (default: 100)
#   --compare       run WITHOUT XDP, then WITH XDP, then print diff table
#   --xdp-on        attach XDP fastpath then exit
#   --xdp-off       detach XDP fastpath then exit
#   --install       install sipp via apt and exit
#   --gen-users N   generate N users in data/users.csv and exit
#
# Examples:
#   sudo bash bench/bench.sh compare -i eth0 -s options -r 1000 -m 20000
#   sudo bash bench/bench.sh compare -i eth0 -s all
#   bash bench/bench.sh -s options -r 2000          # one-shot, no XDP toggle
#   bash bench/bench.sh --xdp-on  -i eth0
#   bash bench/bench.sh --xdp-off -i eth0

# Guard: re-exec under bash if invoked via sh/dash (shebang is ignored when
# the caller explicitly runs: sh bench.sh  or  sudo sh bench.sh)
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCEN_DIR="$SCRIPT_DIR/scenarios"
DATA_DIR="$SCRIPT_DIR/data"
RESULTS_DIR="$SCRIPT_DIR/results"
mkdir -p "$RESULTS_DIR"

# ── Defaults ─────────────────────────────────────────────────────────────────
# Use the first real NIC IP (same as LOCAL_IP) so sipp targets the interface
# where OpenSIPS actually listens. Override with -t if needed.
LOCAL_IP="$(hostname -I | awk '{print $1}')"
TARGET="${LOCAL_IP}:5060"
IFACE="eth0"
SCENARIO="options"
# -r is a rate CAP, not a target. Set it ABOVE what OpenSIPS can handle so the
# system saturates — achieved rate drops below target and failures appear.
# 500 is too low to stress anything. 3000-10000 gives real numbers.
CPS=3000
CONCURRENCY=2000
TOTAL=30000
HOLD_MS=100
COMPARE=0
XDP_ON_ONLY=0
XDP_OFF_ONLY=0
TS="$(date +%Y%m%d-%H%M%S)"

# ── Positional subcommand (must come before any flags) ───────────────────────
# Strip a bare '--' separator if present (e.g. sudo bench.sh -- compare ...)
if [[ $# -gt 0 && "$1" == "--" ]]; then
  shift
fi
# Accept 'compare' as a positional first argument (alias for --compare)
if [[ $# -gt 0 && "$1" == "compare" ]]; then
  COMPARE=1
  shift
fi

# ── Arg parsing ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) TARGET="$2"; shift 2 ;;
    -i) IFACE="$2"; shift 2 ;;
    -s) SCENARIO="$2"; shift 2 ;;
    -r) CPS="$2"; shift 2 ;;
    -l) CONCURRENCY="$2"; shift 2 ;;
    -m) TOTAL="$2"; shift 2 ;;
    -d) HOLD_MS="$2"; shift 2 ;;
    --compare) COMPARE=1; shift ;;
    --xdp-on)  XDP_ON_ONLY=1; shift ;;
    --xdp-off) XDP_OFF_ONLY=1; shift ;;
    --install)
      echo "Installing sipp (sip-tester)..."
      sudo apt-get update -q && sudo apt-get install -y sip-tester
      echo "Done: $(sipp -v | head -1)"
      exit 0 ;;
    --gen-users)
      N="${2:-10000}"; shift 2
      echo "SEQUENTIAL" > "$DATA_DIR/users.csv"
      for i in $(seq -f "%07g" 1 "$N"); do echo "user$i"; done >> "$DATA_DIR/users.csv"
      echo "Generated $N users → $DATA_DIR/users.csv"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

# ── Validate ──────────────────────────────────────────────────────────────────
# sipp may live outside sudo's trimmed PATH; check common locations explicitly
SIPP_BIN="$(command -v sipp 2>/dev/null || true)"
for _p in /usr/bin/sipp /usr/local/bin/sipp /usr/sbin/sipp; do
  [[ -z "$SIPP_BIN" && -x "$_p" ]] && SIPP_BIN="$_p"
done
if [[ -z "$SIPP_BIN" ]]; then
  echo "❌  sipp not found. Run:  $0 --install"
  exit 1
fi
# Wrapper so the rest of the script calls the resolved path
sipp() { "$SIPP_BIN" "$@"; }


# ── XDP helpers ───────────────────────────────────────────────────────────────
xdp_is_active() {
  ip link show "$IFACE" 2>/dev/null | grep -q "xdp"
}

xdp_attach() {
  echo "▶ Attaching XDP fastpath on $IFACE..."
  sudo "$REPO_ROOT/scripts/deploy.sh" "$IFACE"
  # Verify it actually attached
  if xdp_is_active; then
    echo "  ✓ XDP confirmed ACTIVE on $IFACE ($(ip link show "$IFACE" | grep -oE 'xdp[a-z]*' | head -1))"
  else
    echo "  ✗ ERROR: XDP does not appear active on $IFACE after attach — aborting."
    echo "    Check: ip link show $IFACE"
    exit 1
  fi
}

xdp_detach() {
  echo "▶ Detaching XDP from $IFACE..."
  sudo ip link set dev "$IFACE" xdp off 2>/dev/null || \
  sudo ip link set dev "$IFACE" xdpgeneric off 2>/dev/null || true
  # Verify it actually detached
  if xdp_is_active; then
    echo "  ✗ ERROR: XDP still appears active on $IFACE after detach — aborting."
    echo "    Try manually: sudo ip link set dev $IFACE xdp off"
    exit 1
  else
    echo "  ✓ XDP confirmed OFF on $IFACE"
  fi
}

xdp_stats() {
  # Returns XDP counter snapshot — works even when XDP is detached (reads pinned map)
  if command -v bpftool &>/dev/null; then
    sudo "$REPO_ROOT/scripts/read_xdp_stats.sh" 2>/dev/null || echo "(no XDP stats — program not loaded)"
  else
    echo "(bpftool not installed)"
  fi
}

handle_xdp_only_flags() {
  if [[ $XDP_ON_ONLY -eq 1 ]]; then
    xdp_attach
    echo "XDP fastpath active on $IFACE"
    exit 0
  fi
  if [[ $XDP_OFF_ONLY -eq 1 ]]; then
    xdp_detach
    echo "XDP fastpath removed from $IFACE"
    exit 0
  fi
}
handle_xdp_only_flags

# ── SIPp scenario runners ─────────────────────────────────────────────────────

_ensure_users_csv() {
  if [[ ! -f "$DATA_DIR/users.csv" ]] || [[ $(wc -l < "$DATA_DIR/users.csv") -lt 100 ]]; then
    echo "Generating users CSV (10000 users)..."
    echo "SEQUENTIAL" > "$DATA_DIR/users.csv"
    for i in $(seq -f "%07g" 1 10000); do echo "user$i"; done >> "$DATA_DIR/users.csv"
  fi
}

# Run one SIPp scenario; output CSV to $1, label for display as $2
_run_sipp() {
  local csv_out="$1" label="$2"
  # Dynamic timeout: expected duration + 30s buffer so sipp isn't cut short
  # at low rates. e.g. -r 1000 -m 20000 → expected 20s + 30s = 50s timeout.
  local SIPP_TIMEOUT
  SIPP_TIMEOUT=$(awk -v m="$TOTAL" -v r="$CPS" 'BEGIN { t=int(m/r)+30; print (t<45?45:t) }')
  case "$SCENARIO" in
    options)
      sipp "$TARGET" \
        -sf "$SCEN_DIR/options-flood.xml" \
        -i "$LOCAL_IP" -t u1 \
        -r "$CPS" -l "$CONCURRENCY" -m "$TOTAL" \
        -timeout "$SIPP_TIMEOUT" \
        -trace_stat -stf "$csv_out" \
        -trace_err -error_file "${csv_out%.csv}.err" \
        >/dev/null 2>/dev/null || true
      ;;
    register)
      _ensure_users_csv
      sipp "$TARGET" \
        -sf "$SCEN_DIR/register-flood.xml" \
        -inf "$DATA_DIR/users.csv" \
        -i "$LOCAL_IP" -t u1 \
        -r "$CPS" -l "$CONCURRENCY" -m "$TOTAL" \
        -timeout "$SIPP_TIMEOUT" \
        -trace_stat -stf "$csv_out" \
        -trace_err -error_file "${csv_out%.csv}.err" \
        >/dev/null 2>/dev/null || true
      ;;
    invite)
      sipp "$LOCAL_IP:5070" \
        -sf "$SCEN_DIR/invite-uas.xml" \
        -i "$LOCAL_IP" -p 5070 -t u1 -bg \
        -trace_err -error_file "${csv_out%.csv}-uas.err" \
        >/dev/null 2>/dev/null || true
      sleep 1
      sipp "$TARGET" \
        -sf "$SCEN_DIR/invite-uac.xml" \
        -i "$LOCAL_IP" -p 5080 -t u1 \
        -r "$CPS" -l "$CONCURRENCY" -m "$TOTAL" -d "$HOLD_MS" \
        -timeout "$SIPP_TIMEOUT" \
        -trace_stat -stf "$csv_out" \
        -trace_err -error_file "${csv_out%.csv}.err" \
        >/dev/null 2>/dev/null || true
      pkill -f "sipp.*5070" 2>/dev/null || true
      ;;
  esac
}


# Parse SIPp final-summary CSV: return achieved_cps failed_calls successful_calls
# sipp CSV columns (1-indexed, semicolon-delimited, last summary row):
#   $6  = TargetRate       (what -r was set to — NOT the actual rate)
#   $8  = CallRate(C)      (actual cumulative achieved CPS)
#   $16 = SuccessfulCall(C)
#   $18 = FailedCall(C)
_parse_csv() {
  local csv="$1"
  [[ -f "$csv" ]] || { echo "0 0 0"; return; }
  tail -1 "$csv" | awk -F';' '{ print $8+0, $18+0, $16+0 }'
}

# ── One-shot mode (no XDP toggle) ─────────────────────────────────────────────
if [[ $COMPARE -eq 0 ]]; then
  header() {
    echo "
┌──────────────────────────────────────────────────────────┐
│       OpenSIPS Ingress Benchmark  —  $(date '+%Y-%m-%d %H:%M:%S')
├──────────────────────────────────────────────────────────┤
│  Target     : $TARGET
│  Interface  : $IFACE  $(xdp_is_active && echo '[XDP ACTIVE]' || echo '[no XDP]')
│  Scenario   : $SCENARIO
│  Rate (CPS) : $CPS  │  Concurrent: $CONCURRENCY  │  Total: $TOTAL
│  Results    : $RESULTS_DIR/
└──────────────────────────────────────────────────────────┘
"
  }
  header

  if [[ "$SCENARIO" == "all" ]]; then
    for sc in options register invite; do
      SCENARIO=$sc _run_sipp "$RESULTS_DIR/${sc}-${TS}.csv" "$sc"
      echo "✅  $sc done"
    done
  else
    _run_sipp "$RESULTS_DIR/${SCENARIO}-${TS}.csv" "$SCENARIO"
    echo "✅  $SCENARIO done → $RESULTS_DIR/${SCENARIO}-${TS}.csv"
  fi
  exit 0
fi

# ── COMPARE mode: baseline (no XDP) → then with XDP ─────────────────────────
scenarios_to_run=("$SCENARIO")
[[ "$SCENARIO" == "all" ]] && scenarios_to_run=(options register invite)

echo "
╔══════════════════════════════════════════════════════════════╗
║  COMPARE MODE: Kernel stack (baseline)  vs  XDP fastpath     ║
╠══════════════════════════════════════════════════════════════╣
║  Target     : $TARGET
║  Interface  : $IFACE
║  Scenarios  : ${scenarios_to_run[*]}
║  Rate (CPS) : $CPS  │  Concurrent: $CONCURRENCY  │  Total: $TOTAL
╚══════════════════════════════════════════════════════════════╝
"

# Helper: extract a single named counter from xdp_stats output
_xdp_val() {
  echo "$1" | awk -v key="$2" '$0 ~ key { print $NF; exit }'
}

# Helper: parse one cumulative XDP stats snapshot into variables
# Sets: _dropped _blocked _redirected _passed _total
_snap_xdp() {
  local raw="$1"
  _dropped=$(  _xdp_val "$raw" "OPTIONS dropped")
  _blocked=$(  _xdp_val "$raw" "Blocked")
  _redirected=$(_xdp_val "$raw" "Redirected")
  _passed=$(   _xdp_val "$raw" "Passed to stack")
  _total=$(    _xdp_val "$raw" "Total UDP")
  # default to 0 if map not loaded
  _dropped=${_dropped:-0}; _blocked=${_blocked:-0}
  _redirected=${_redirected:-0}; _passed=${_passed:-0}; _total=${_total:-0}
}

# ─── Phase 1: Baseline (XDP OFF) ──────────────────────────────────────────────
echo "════ Phase 1/2: Baseline — XDP OFF ══════════════════════════"
xdp_detach
sleep 1

declare -A BASE_CPS BASE_FAILED BASE_SUCC
declare -A BASE_XDP_DROP BASE_XDP_PASS BASE_XDP_BLOCK

for sc in "${scenarios_to_run[@]}"; do
  csv="$RESULTS_DIR/${sc}-baseline-${TS}.csv"
  pre_raw=$(xdp_stats 2>/dev/null || echo "")
  _snap_xdp "$pre_raw"; pre_d=$_dropped; pre_p=$_passed; pre_b=$_blocked

  echo "  ▶ $sc..."
  SCENARIO=$sc _run_sipp "$csv" "$sc"

  post_raw=$(xdp_stats 2>/dev/null || echo "")
  _snap_xdp "$post_raw"

  read -r s f r <<< "$(_parse_csv "$csv")"
  BASE_CPS[$sc]=$s; BASE_FAILED[$sc]=${f:-0}; BASE_SUCC[$sc]=${r:-0}
  BASE_XDP_DROP[$sc]=$(( ${_dropped:-0}  - ${pre_d:-0} ))
  BASE_XDP_PASS[$sc]=$(( ${_passed:-0}   - ${pre_p:-0} ))
  BASE_XDP_BLOCK[$sc]=$(( ${_blocked:-0} - ${pre_b:-0} ))
  echo "  ✓ sent≈${s} pps  success=${r:-0}  fail=${f:-0}  xdp_drop=0 (XDP off)"
done

# ─── Phase 2: XDP Fastpath (XDP ON) ───────────────────────────────────────────
echo ""
echo "════ Phase 2/2: XDP Fastpath — XDP ON ══════════════════════"
xdp_attach
sleep 2   # allow XDP to warm up

declare -A XDP_CPS XDP_FAILED XDP_SUCC
declare -A XDP_DROP XDP_PASS XDP_BLOCK

for sc in "${scenarios_to_run[@]}"; do
  csv="$RESULTS_DIR/${sc}-xdp-${TS}.csv"
  pre_raw=$(xdp_stats 2>/dev/null || echo "")
  _snap_xdp "$pre_raw"; pre_d=$_dropped; pre_p=$_passed; pre_b=$_blocked

  echo "  ▶ $sc..."
  SCENARIO=$sc _run_sipp "$csv" "$sc"

  post_raw=$(xdp_stats 2>/dev/null || echo "")
  _snap_xdp "$post_raw"

  read -r s f r <<< "$(_parse_csv "$csv")"
  XDP_CPS[$sc]=$s; XDP_FAILED[$sc]=${f:-0}; XDP_SUCC[$sc]=${r:-0}
  XDP_DROP[$sc]=$(( ${_dropped:-0}  - ${pre_d:-0} ))
  XDP_PASS[$sc]=$(( ${_passed:-0}   - ${pre_p:-0} ))
  XDP_BLOCK[$sc]=$(( ${_blocked:-0} - ${pre_b:-0} ))
  echo "  ✓ sent≈${s} pps  success=${r:-0}  fail=${f:-0}  xdp_drop=${XDP_DROP[$sc]}"
done

# ─── Side-by-side results table ───────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════════"
printf "  %-10s  %-44s  %-44s\n" "" "── Baseline (no XDP) ─────────────────────" "── XDP Fastpath ───────────────────────────"
printf "  %-10s  %-8s %-8s %-8s %-7s %-8s  %-8s %-8s %-8s %-7s %-8s\n" \
  "Scenario" "AchvPPS" "Success" "Fail" "Dropped" "Passed" \
              "AchvPPS" "Success" "Fail" "Dropped" "Passed"
echo "  ----------  -------  -------  ----  -------  -------   -------  -------  ----  -------  -------"

for sc in "${scenarios_to_run[@]}"; do
  printf "  %-10s  %-8s %-8s %-8s %-7s %-8s  %-8s %-8s %-8s %-7s %-8s\n" \
    "$sc" \
    "${BASE_CPS[$sc]:-0}" "${BASE_SUCC[$sc]:-0}" "${BASE_FAILED[$sc]:-0}" "${BASE_XDP_DROP[$sc]:-0}" "${BASE_XDP_PASS[$sc]:-0}" \
    "${XDP_CPS[$sc]:-0}"  "${XDP_SUCC[$sc]:-0}"  "${XDP_FAILED[$sc]:-0}"  "${XDP_DROP[$sc]:-0}"     "${XDP_PASS[$sc]:-0}"
done

echo "══════════════════════════════════════════════════════════════════════════"
echo ""
echo "  NOTE: 'Dropped' and 'Passed' are XDP kernel counters (bpftool)."
echo "        SentPPS is from sipp (sender view — counts UDP sends, not replies)."
for sc in "${scenarios_to_run[@]}"; do
  d=${XDP_DROP[$sc]:-0}; p=${XDP_PASS[$sc]:-0}; total=$(( d + p ))
  if (( total > 0 )); then
    pct=$(awk -v d="$d" -v t="$total" 'BEGIN { printf "%.1f", (d/t)*100 }')
    echo "  ${sc}: ${pct}% of packets dropped at NIC by XDP (${d}/${total})"
  fi
done
echo ""
echo "  Results: $RESULTS_DIR/"
echo ""

# Leave XDP on (it was the last state tested)
echo "  XDP is still attached on $IFACE."
echo "  To detach: sudo ip link set dev $IFACE xdp off"
echo ""



