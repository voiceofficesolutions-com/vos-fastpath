# Integrating vos-fastpath into Existing OpenSIPS Installations

This guide explains how to add the XDP/AF_XDP fast path and stealth module to an **existing** OpenSIPS deployment without replacing your current config or workflow.

## What You Get

- **Stealth:** SIP OPTIONS from IPs not in the allowed map are dropped in the kernel (no reply to scanners).
- **Same UDP 5060:** Until you use AF_XDP listeners, traffic that passes the filter continues to the kernel stack; your existing `listen = udp:...` keeps receiving it.
- **Optional zero-copy:** When your OpenSIPS build and NIC support it, you can add an AF_XDP listener for maximum performance.

## Prerequisites

- **Kernel:** BTF enabled (`/sys/kernel/btf/vmlinux` present). Default on Debian 12.
- **Build:** `clang`, `llvm`, `libbpf-dev`, `bpftool` (see [README](../README.md)).
- **OpenSIPS:** 3.4+ (existing install, any deployment: bare metal, Docker, or VM).
- **Interface:** The NIC that receives SIP (UDP 5060). Check with `ip addr` / `ss -ulnp`.

## Step 1: Build on a Build Host or the OpenSIPS Server

Clone or copy the vos-fastpath tree to the machine where you will build (same host as OpenSIPS or a build server with same arch):

```bash
cd /path/to/vos-fastpath
make
```

This produces `build/sip_logic.bpf.o` and `build/vmlinux.h`. You only need to deploy the `.bpf.o` (and load it) on the host where OpenSIPS runs.

## Step 2: Identify the SIP Interface

On the OpenSIPS host, find the interface that receives SIP traffic (often the default route or the one bound by OpenSIPS):

```bash
ip route get 1.1.1.1
ss -ulnp | grep 5060
```

Example: if OpenSIPS listens on `0.0.0.0:5060`, the “ingress” interface is the one through which packets arrive (e.g. `eth0`, `enp1s0`). Use that name in the next step.

## Step 3: Load XDP on the SIP Interface

Run the deploy script **before** or **while** OpenSIPS is running. XDP attaches to the NIC; it does not replace the UDP socket.

```bash
sudo ./scripts/deploy.sh <interface>
# e.g. sudo ./scripts/deploy.sh eth0
```

- If the driver supports **native XDP**, the program runs in driver context (best performance).
- Otherwise it falls back to **generic (SKB)** mode; stealth and redirect logic still apply.

Your existing OpenSIPS keeps listening on UDP. Packets that hit XDP and are not redirected (no AF_XDP socket in the map) are passed to the kernel and delivered to OpenSIPS as before. The only change: OPTIONS from non-allowed IPs are dropped before they reach the stack.

## Step 4: Keep Your Existing opensips.cfg

You do **not** need to replace your config. Keep your current `listen` and routing logic.

- **Minimal change:** None. XDP runs in front of the stack; UDP 5060 still reaches OpenSIPS except for dropped OPTIONS.
- **Optional:** If you later add an AF_XDP listener (when supported by your OpenSIPS build), add a line like `listen = afxdp:eth0:5060` in addition to or instead of UDP, per OpenSIPS docs. Until then, UDP alone is enough.

## Step 5: (Optional) Allow Specific IPs for OPTIONS

By default the **allowed_ips** map is empty, so **all** SIP OPTIONS are dropped. To allow certain IPs (e.g. a known scanner or monitoring host), you need a small user-space tool that:

1. Opens the BPF object (or pinned map under `/sys/fs/bpf`).
2. Calls `bpf_map_update_elem()` on the `allowed_ips` map with the IPv4 address (key) and a non-zero value.

We do not ship that tool in this repo yet; you can add it or use `bpftool map update` if the map is pinned. Once an IP is in **allowed_ips**, OPTIONS from that IP are no longer dropped and will reach OpenSIPS.

## Step 6: Startup Order and Persistence

- **Order:** Load XDP (Step 3) before or after starting OpenSIPS; both work. For a clean bootstrap, load XDP first, then start OpenSIPS.
- **Persistence:** After reboot, XDP is gone. To make it persistent:
  - Add a small systemd service (or cron @boot) that runs `./scripts/deploy.sh <interface>` after the interface is up.
  - Ensure the script and `build/sip_logic.bpf.o` are installed in a fixed path (e.g. `/opt/vos-fastpath`).

Example systemd unit (adjust paths):

```ini
[Unit]
Description=Load vos-fastpath XDP on SIP interface
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/vos-fastpath/scripts/deploy.sh eth0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

## Existing Install Types

| Deployment        | Notes |
|------------------|--------|
| **Bare metal**   | Build and run `deploy.sh` on the same host. Use the interface that receives SIP. |
| **Docker**       | Run the container with `--privileged` and `--network=host`. Load XDP on the **host** (e.g. `eth0`), not inside the container. Mount `/sys/fs/bpf` if you later pin maps for a loader. |
| **VM (Proxmox)** | Load XDP inside the VM on the VM’s NIC (e.g. `ens18`). Native XDP depends on the virtual driver (e.g. virtio_net supports it); otherwise generic XDP is used. |

## Verifying

- **XDP loaded:** `ip link show <interface>` should show `xdp` or `xdpgeneric`.
- **OpenSIPS:** Same as today: traffic on UDP 5060 (except dropped OPTIONS) still arrives. No config change required for stealth-only use.
- **Stealth:** Send an OPTIONS from a non-allowed IP; you should get no SIP response (packet dropped in kernel).

## Summary

- Build once with `make`, deploy with `sudo ./scripts/deploy.sh <interface>`.
- No need to replace your existing OpenSIPS config; keep your current `listen` and routing.
- Stealth (OPTIONS drop) works immediately; zero-copy AF_XDP is an optional next step when your stack and NIC support it.
