#!/usr/bin/env bash
# vos-fastpath: Pin OpenSIPS threads to Ryzen cores 4–7 (second CCX on 4750U)
# Usage: run after OpenSIPS is up; pass OpenSIPS PID or use 'opensips' process name.
# Example: sudo ./scripts/pin_opensips_cores.sh
# Or:     sudo ./scripts/pin_opensips_cores.sh $(pgrep -f opensips)

set -e

# Ryzen 7 4750U: cores 0–3 (first CCX), 4–7 (second CCX). Use 4–7 for SIP worker.
CPUS="4,5,6,7"

if [ -n "$1" ]; then
	PIDS="$1"
else
	PIDS=$(pgrep -f opensips || true)
fi

if [ -z "$PIDS" ]; then
	echo "No OpenSIPS process found. Start OpenSIPS first or pass PID: $0 <pid>"
	exit 1
fi

for pid in $PIDS; do
	if [ -d "/proc/$pid" ]; then
		echo "Pinning PID $pid to CPUs $CPUS"
		taskset -a -cp $CPUS $pid
	fi
done
echo "Done."
