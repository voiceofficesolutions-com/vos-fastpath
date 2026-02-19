#!/usr/bin/env bash
# vos-fastpath: Enable busy polling for low-latency AF_XDP/OpenSIPS
# net.core.busy_poll=50 — allow busy wait up to 50 usec for socket receive
# Run as root (e.g. before starting OpenSIPS).

set -e

BUSY_POLL_US=50

echo "Setting net.core.busy_poll=$BUSY_POLL_US"
sysctl -w net.core.busy_poll=$BUSY_POLL_US

# Optional: busy_poll on the specific socket is controlled by application
# (e.g. SO_BUSY_POLL on the AF_XDP socket). This sysctl sets the default.
echo "Done. To make permanent, add to /etc/sysctl.conf:"
echo "  net.core.busy_poll=$BUSY_POLL_US"
