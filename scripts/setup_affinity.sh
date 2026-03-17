#!/bin/bash
# vos-fastpath: Hardware Affinity & IRQ Pinning Setup
INTERFACE=$1
NUM_CORES=$(nproc)

if [ -z "$INTERFACE" ]; then
    echo "Usage: sudo ./setup_affinity.sh <interface>"
    exit 1
fi

echo "--- Optimizing $INTERFACE for Zero-Contention Datapath ---"

# 1. Stop irqbalance to prevent the OS from moving our pins
sudo systemctl stop irqbalance
sudo systemctl disable irqbalance

# 2. Set NIC queues to match CPU core count
sudo ethtool -L "$INTERFACE" combined "$NUM_CORES"

# 3. Get IRQs for the interface (Assumes common drivers like i40e, mlx5, igb)
IRQS=$(grep "$INTERFACE" /proc/interrupts | awk '{print $1}' | sed 's/://')

CORE=0
for IRQ in $IRQS; do
    if [ $CORE -lt "$NUM_CORES" ]; then
        echo "Pinning IRQ $IRQ to CPU Core $CORE"
        echo "$CORE" > "/proc/irq/$IRQ/smp_affinity_list"
        ((CORE++))
    fi
done

# 4. Enable Busy Polling for sub-microsecond latency
echo 2 | sudo tee "/sys/class/net/$INTERFACE/napi_defer_hard_irqs"
echo 200000 | sudo tee "/sys/class/net/$INTERFACE/gro_flush_timeout"

echo "--- Setup Complete: 1:1 Queue-to-Core mapping active ---"
