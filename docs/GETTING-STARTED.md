# Getting Started — Full Process (Zero to Working)

This document is the **single end-to-end process**: from a machine without vos-fastpath to a working XDP + OpenSIPS setup. Follow the steps in order; each section links to detailed docs where needed.

---

## Process overview

| Step | What you do | Doc for details |
|------|-------------|------------------|
| **1. Kernel** | Confirm BTF/BPF; enable in kernel if missing. | [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md) |
| **2. Build tools** | Install clang, libbpf-dev, bpftool, make. | [BUILD-PREREQS.md](BUILD-PREREQS.md) |
| **3. Build** | Run `make` in the repo. | [BUILD-PREREQS.md](BUILD-PREREQS.md) |
| **4. Verify (sim)** | Load XDP on veth, send traffic, read counters. | This doc, [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md) |
| **5. Deploy (real NIC)** | Load XDP on your interface, start OpenSIPS. | [README](../README.md), [NIC-COMPATIBILITY.md](NIC-COMPATIBILITY.md) |
| **6. Allow client & test** | Allow a SIP client IP, register, check stats. | [README](../README.md) |

---

## Step 1: Kernel support (no module to load)

XDP and BPF are built into the kernel. You only need a kernel compiled with the right options.

**1.1 Check if you already have it**

```bash
ls /sys/kernel/btf/vmlinux
```

- **File exists** → BTF is present. Go to [Step 2](#step-2-build-tools).
- **No such file or directory** → Enable BTF in the kernel (see below).

**1.2 Enable it in the kernel (only if 1.1 failed)**

You have two options:

- **Option A — Use a distro kernel that has BTF (easiest)**  
  Install the standard kernel and reboot.  
  - Debian: `sudo apt install linux-image-amd64` then reboot.  
  - Ubuntu: `sudo apt install linux-generic` then reboot.  
  After reboot, run `ls /sys/kernel/btf/vmlinux` again.

- **Option B — Build your own kernel**  
  Enable in `.config` or `make menuconfig`:  
  `CONFIG_DEBUG_INFO=y`, `CONFIG_DEBUG_INFO_BTF=y`, `CONFIG_BPF_SYSCALL=y`, `CONFIG_BPF_JIT=y`.  
  Install `dwarves` (for `pahole`) before building. Build, install, reboot.

**Full details (menuconfig paths, pahole, verifying config):** [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md).

---

## Step 2: Build tools

Install compilers and BPF tooling. From the repo root is not required for this step.

```bash
sudo apt update
sudo apt install -y clang llvm libbpf-dev make bpftool
```

If `bpftool` is not available as a package:  
`sudo apt install -y linux-tools-$(uname -r)` or `linux-tools-generic`.

**Full list, PATH caveats, pitfalls:** [BUILD-PREREQS.md](BUILD-PREREQS.md).

---

## Step 3: Build

From the **repo root** (`vos-fastpath/`):

```bash
make
```

You should see: `Generated build/vmlinux.h` and `Built build/sip_logic.bpf.o`.  
If you get "Kernel BTF not found", go back to [Step 1](#step-1-kernel-support-no-module-to-load).

**Troubleshooting build:** [BUILD-PREREQS.md](BUILD-PREREQS.md#6-known-pitfalls).

---

## Step 4: Verify with the sim (no real NIC needed)

This proves the kernel and BPF program work. Uses a veth pair and a network namespace; no physical SIP traffic.

From the repo root:

```bash
sudo ./scripts/sip_sim_setup.sh
sudo ./scripts/sip_sim_send.sh 10
sudo ./scripts/read_xdp_stats.sh
sudo ./scripts/sip_sim_teardown.sh
```

**Expected:** Counters show OPTIONS dropped (stealth) and Passed to stack. No errors from the scripts.

**If sip_sim_setup.sh fails:** The script prints the kernel error. Usually: missing BTF (back to [Step 1](KERNEL-REQUIREMENTS.md)), or missing bpftool (back to [Step 2](BUILD-PREREQS.md)). See [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md#3-how-to-check-run-these).

---

## Step 5: Deploy on your real interface

Replace `eth0` with your SIP-facing interface (e.g. `enp1s0`).

```bash
sudo ./scripts/deploy.sh eth0
```

- **Success** → Script says "Native XDP loaded" or "SKB (generic) XDP loaded". Proceed to Step 6.
- **Failure** → Script prints the error. Common: "Operation not supported" = driver doesn’t support XDP on that NIC. You can still use the **sim** for testing; for production use another NIC or a VM with virtio. See [NIC-COMPATIBILITY.md](NIC-COMPATIBILITY.md).

Then start OpenSIPS:

```bash
docker-compose up -d
# or: docker compose up -d
```

---

## Step 6: Allow a client and test registration

1. **Allow your client’s IP** (so OPTIONS and REGISTER aren’t dropped):
   ```bash
   sudo ./scripts/allow_ip.sh <client_ip>
   ```
2. **Point your SIP client** at this host’s IP, port 5060; register (any username/domain).
3. **Check counters:**
   ```bash
   sudo ./scripts/read_xdp_stats.sh
   ```

You should see Passed to stack for your client’s traffic and, if you had scanner traffic, OPTIONS dropped.

---

## Summary checklist

- [ ] `ls /sys/kernel/btf/vmlinux` exists (or you enabled kernel and rebooted).
- [ ] `clang`, `libbpf-dev`, `bpftool`, `make` installed.
- [ ] `make` succeeds in repo root.
- [ ] `sudo ./scripts/sip_sim_setup.sh` … `sip_sim_teardown.sh` run without error and counters look correct.
- [ ] `sudo ./scripts/deploy.sh <interface>` succeeds (or you accept using sim/virtio only).
- [ ] `docker-compose up -d` (or `docker compose up -d`) and OpenSIPS is running.
- [ ] `sudo ./scripts/allow_ip.sh <client_ip>` and client can register.

**Detailed references:** [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md) (kernel and enable steps), [BUILD-PREREQS.md](BUILD-PREREQS.md) (tools and build), [NIC-COMPATIBILITY.md](NIC-COMPATIBILITY.md) (which NICs support XDP).
