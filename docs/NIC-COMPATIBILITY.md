# Network Card Compatibility — XDP and vos-fastpath

vos-fastpath works in two modes on the NIC:

1. **Native XDP (driver)** — Program runs in the driver; lowest latency and best for AF_XDP zero-copy when the driver supports it.
2. **Generic XDP (SKB)** — Program runs after the kernel’s generic receive path. Works on **any** interface; higher CPU cost than native.

The deploy script tries **native first**, then **generic**, so any NIC can run the filter and stealth; native is preferred when available.

---

## Quick reference

| Your NIC / environment | Native XDP | Generic XDP (fallback) | Notes |
|------------------------|------------|-------------------------|--------|
| **Intel** (see table below) | Many supported | Yes | Prefer ixgbe, i40e, ice, igc where available. |
| **Mellanox** mlx4/mlx5 | Yes | Yes | Common in servers. |
| **Realtek** (e.g. r8169) | No | Yes | Typical on many laptops/desktops; use generic. |
| **Virtio** (VMs) | Yes | Yes | Good for Proxmox/VMs. |
| **veth** (containers) | Yes | Yes | For host/container setups. |
| **Other / unknown** | Check below | Yes | Deploy script will use generic if native fails. |

---

## Drivers with native XDP support (upstream kernel)

These drivers support **native XDP** in mainline Linux. If your interface uses one of them, `./scripts/deploy.sh` will attach in native mode.

| Vendor / type | Driver | Typical NICs / use |
|---------------|--------|---------------------|
| **Intel** | ixgbe | 10G (e.g. X520). |
| **Intel** | ixgbevf | 10G VF. |
| **Intel** | i40e | XXV710, X710, etc. |
| **Intel** | ice | E810, E822/E823/E825 (800 series). |
| **Intel** | igc | I225-LM, I225-V (common on newer boards/laptops). |
| **Intel** | iavf | Ice VF. |
| **Mellanox** | mlx4 | ConnectX-3. |
| **Mellanox** | mlx5 | ConnectX-4/5. |
| **Netronome** | nfp | Agilio. |
| **Broadcom** | bnxt | Broadcom NetXtreme. |
| **Marvell/Cavium** | thunder | ThunderX NICs. |
| **NXP** | dpaa2 | DPAA2. |
| **QLogic** | qede | QLogic FastLinQ. |
| **Socionext** | netsec | NetSec. |
| **Virtual** | tun | TUN device. |
| **Virtual** | veth | Veth pair (containers). |
| **Virtual** | virtio_net | Virtio (KVM/Proxmox VMs). |

*Source: [xdp-project drivers](https://github.com/xdp-project/xdp-project/blob/main/areas/drivers/README.org), kernel docs, and driver-specific notes. Newer kernels may add more drivers.*

---

## Drivers that typically do NOT have native XDP (use generic)

- **Realtek:** r8169, r8168, r8125, etc. — very common on desktops and laptops (e.g. many HP EliteBook, consumer boards).
- **Other consumer/desktop chipsets** not listed in the native table above.

For these, the script automatically uses **generic XDP** (`xdpgeneric`). Stealth and redirect logic still apply; only the attachment point is different (after SKB allocation).

---

## HP EliteBook 845 G7 (AMD Ryzen 7 4750U)

- **Wired:** Often **Realtek** (e.g. r8169) — expect **generic XDP** only.
- **If your machine has an Intel I225/I219** (check with `ethtool -i <interface>`), the **igc** driver supports **native XDP** and AF_XDP zero-copy on supported kernels.

Run:

```bash
ethtool -i eth0   # or your SIP interface name
```

Use the driver name with the table above. Then run `./scripts/deploy.sh eth0`; the script will report “Native XDP” or “SKB (generic) XDP”.

---

## How to check what mode is active

After loading:

```bash
ip link show eth0
```

- `xdp` in the output → native XDP.
- `xdpgeneric` → generic XDP.

To see the driver:

```bash
ethtool -i eth0
```

---

## References

- [xdp-project: XDP driver support status](https://github.com/xdp-project/xdp-project/blob/main/areas/drivers/README.org)
- [Kernel: AF_XDP](https://docs.kernel.org/networking/af_xdp.html)
- [Kernel: BPF_MAP_TYPE_XSKMAP](https://docs.kernel.org/bpf/map_xskmap.html)
- [IOVisor: BPF features by kernel version (XDP section)](https://github.com/iovisor/bcc/blob/master/docs/kernel-versions.md#xdp)
