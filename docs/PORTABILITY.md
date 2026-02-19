# Portability — Running on Other Systems

vos-fastpath is designed to run on **other systems** without recompiling per machine: same BPF binary, same scripts, different NICs and kernels.

---

## What makes it portable

| Aspect | How it works |
|--------|----------------|
| **CO-RE (Compile Once – Run Everywhere)** | The BPF program is built with BTF and uses kernel types from the **running** kernel’s BTF. You generate `vmlinux.h` from the machine (or a matching kernel) and build once; the resulting `sip_logic.bpf.o` loads on any system with a compatible kernel (BTF). |
| **Native vs generic XDP** | Not every NIC has native XDP. The deploy script tries **native** first, then **generic (SKB)**. So the same object runs on Intel, Mellanox, Realtek, virtio, veth — best mode per driver. |
| **No host-specific paths in BPF** | The program only depends on L2/L3/L4 layout and BPF helpers; no hardcoded NIC or path. |
| **Scripts** | Bash + `bpftool` + `ip`; standard on Linux. Optional `jq` for stats; script falls back to awk. |

---

## What you need on each system

- **Kernel:** Linux with BTF (`CONFIG_DEBUG_INFO_BTF=y`). Check: `ls /sys/kernel/btf/vmlinux`.
- **Build (once per kernel ABI):** `clang`, `libbpf-dev`, `bpftool`. Generate `vmlinux.h` from that system’s (or matching) BTF, then `make`.
- **Run:** `bpftool`, `ip` (iproute2), root (or CAP_NET_ADMIN/CAP_BPF). Same scripts, same deploy flow.

---

## Different NICs

- **Native XDP:** Best performance; see [NIC compatibility](NIC-COMPATIBILITY.md) for supported drivers.
- **Generic XDP:** Works on any interface. Deploy script uses it automatically if native fails. Stealth and blocklist behave the same; only the attach point (and often CPU cost) differs.

---

## Different distros / clouds

- Build on a system that has BTF (e.g. Debian 12, recent Ubuntu, RHEL 9+) or use a container with the same kernel ABI.
- Run `make`; run `deploy.sh <your_interface>`. Same image and BPF can be used across datacenters and edge; sync blocklist/allowlist for consistent policy. See [Distribute everywhere](DISTRIBUTE-EVERYWHERE.md).

---

## Summary

**Portable = one BPF build (per kernel ABI) + same scripts everywhere.** Native vs generic is chosen at load time per NIC; no code change required.
