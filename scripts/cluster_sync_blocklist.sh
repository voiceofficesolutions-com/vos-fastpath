#!/usr/bin/env bash
# vos-fastpath: Apply the same blocklist file on multiple cluster nodes via SSH.
# Ensures every node's XDP blocklist is in sync so offload is consistent across the cluster.
# Usage:
#   sudo ./scripts/cluster_sync_blocklist.sh <blocklist_file> <host1> [host2 ...]
#   export VOS_FASTPATH_CLUSTER_HOSTS="node1 node2 node3"
#   sudo ./scripts/cluster_sync_blocklist.sh <blocklist_file>
# Requires: SSH access (as root or user with passwordless sudo) to each host;
#           vos-fastpath scripts and BPF map on each remote host.

set -e

if [ "$(id -u)" -ne 0 ]; then
	echo "Run with sudo (needed for local block_ips_from_file if used)."
	exit 1
fi

if [ -z "$1" ] || [ ! -f "$1" ]; then
	echo "Usage: $0 <blocklist_file> [host1 host2 ...]"
	echo "  Or set VOS_FASTPATH_CLUSTER_HOSTS='host1 host2 ...' and run with just <blocklist_file>."
	echo "  File: one IPv4 per line (same format as block_ips_from_file.sh)."
	exit 1
fi

BLOCKLIST_FILE="$1"
shift
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "$*" ]; then
	HOSTS=("$@")
else
	# shellcheck disable=SC2086
	read -ra HOSTS <<< "${VOS_FASTPATH_CLUSTER_HOSTS:-}"
fi

if [ ${#HOSTS[@]} -eq 0 ]; then
	echo "No hosts given. Pass host names as arguments or set VOS_FASTPATH_CLUSTER_HOSTS."
	exit 1
fi

# On each remote host: path to repo (so script and BPF are there). Set if different from local.
REMOTE_REPO="${VOS_FASTPATH_CLUSTER_REMOTE_PATH:-$REPO_ROOT}"
REMOTE_SCRIPT="$REMOTE_REPO/scripts/block_ips_from_file.sh"
# Temp file on remote (under /tmp so we don't require repo path for the file)
REMOTE_FILE="/tmp/vos_fastpath_blocklist_$$.txt"

ok=0
fail=0
for h in "${HOSTS[@]}"; do
	[ -z "$h" ] && continue
	if scp -q -o ConnectTimeout=5 "$BLOCKLIST_FILE" "$h:$REMOTE_FILE" 2>/dev/null; then
		if ssh -o ConnectTimeout=5 "$h" "sudo bash $REMOTE_SCRIPT $REMOTE_FILE 2>/dev/null; rm -f $REMOTE_FILE"; then
			echo "OK $h"
			((ok++)) || true
		else
			echo "FAIL $h (script or map update failed)"
			((fail++)) || true
		fi
	else
		echo "FAIL $h (copy or connect failed)"
		((fail++)) || true
	fi
done

echo "Done: $ok succeeded, $fail failed."
[ "$fail" -gt 0 ] && exit 1
exit 0
