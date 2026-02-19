# Kernel Requirements — What You Need for vos-fastpath to Work

There is **no separate kernel module to load**. XDP and BPF support are built into the kernel. Your kernel must be compiled with the right options and you need root (or the right capabilities) to attach the program.

---

## 1. What the kernel must have (compile-time)

| Config | Purpose |
|--------|---------|
| **CONFIG_DEBUG_INFO_BTF=y** | BTF (BPF Type Format) so we can build CO-RE and load the program. Without it, `vmlinux.h` generation and/or program load can fail. |
| **CONFIG_BPF_SYSCALL=y** | BPF system call — required to load programs and manage maps. |
| **CONFIG_BPF_JIT=y** | JIT for BPF (normal on modern distro kernels). |

XDP (including generic/`xdpgeneric`) is part of the core networking and BPF; it does not have its own loadable module. If your kernel is a standard Debian/Ubuntu/RHEL distro kernel from the last few years, these are usually enabled.

---

## 2. How to enable it in the kernel

You have two options: use a kernel that already has it, or build a kernel with the options enabled.

### Option A: Use a distro kernel that already has BTF (easiest)

Many current distros ship kernels with BTF and BPF enabled:

- **Debian 12+** — Default kernel packages usually have `CONFIG_DEBUG_INFO_BTF=y`.
- **Ubuntu 22.04+** — Same.
- **RHEL 9+ / Rocky / Alma** — Same.

**Steps:**

1. Upgrade to a recent kernel from your distro, or install the standard kernel meta-package if you’re on a custom one:
   - Debian: `sudo apt install linux-image-amd64` (or your arch).
   - Ubuntu: `sudo apt install linux-generic` or use the default kernel.
2. Reboot into the new kernel.
3. Check: `ls /sys/kernel/btf/vmlinux`. If the file exists, you’re done; no config changes needed.

### Option B: Build your own kernel with the options enabled

If you compile the kernel yourself, enable these (e.g. `make menuconfig` or edit `.config`):

**Required:**

```
CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
```

**BTF build dependency:** BTF is generated from DWARF debug info. You need **pahole** (from the `dwarves` package) in your PATH when building the kernel — usually **pahole 1.16+** (1.21+ if using DWARF 5). Install with:

```bash
# Debian/Ubuntu
sudo apt install dwarves

# Then build the kernel as usual; BTF is emitted at link time.
```

In `menuconfig`:

- **Kernel hacking** → **Compile-time checks and compiler options** → **Debug information** = “Debug information” (CONFIG_DEBUG_INFO), then **BTF type information** (CONFIG_DEBUG_INFO_BTF).
- **General setup** → **BPF subsystem** → **Enable bpf() system call** (CONFIG_BPF_SYSCALL), **JIT compiler support** (CONFIG_BPF_JIT).

Then build and install the kernel as you normally do. After booting into it, check again: `ls /sys/kernel/btf/vmlinux`.

**Note:** Some configs conflict with BTF (e.g. CONFIG_DEBUG_INFO_REDUCED, CONFIG_DEBUG_INFO_SPLIT). If BTF doesn’t appear in menuconfig, ensure DEBUG_INFO is set and you have pahole installed; the BTF option may be under “Compile-time checks and compiler options”.

---

## 3. How to check (run these)

**BTF (required for build and load):**
```bash
ls -la /sys/kernel/btf/vmlinux
```
- If the file **exists**, BTF is present and the build can use it.
- If **No such file or directory**, your kernel was not built with `CONFIG_DEBUG_INFO_BTF=y`. Use a distro kernel that has BTF (e.g. Debian 12+, Ubuntu 22.04+, RHEL 9+) or build your own kernel with BTF enabled.

**BPF / tools:**
```bash
bpftool prog list
```
- If this runs (even if the list is empty), BPF is available.
- If **command not found**, install `bpftool`:  
  `sudo apt install linux-tools-$(uname -r)` or `linux-tools-generic` (Debian/Ubuntu).

**Can we load XDP at all? (use veth — works without special NIC):**
```bash
cd /path/to/vos-fastpath
make
sudo ./scripts/sip_sim_setup.sh
```
- If the sim **sets up and loads XDP on veth-sip**, your kernel supports XDP (at least generic). Then run:
  ```bash
  sudo ./scripts/sip_sim_send.sh 5
  sudo ./scripts/read_xdp_stats.sh
  sudo ./scripts/sip_sim_teardown.sh
  ```
- If **sip_sim_setup.sh fails** (e.g. “Failed to load XDP”), the script now prints the kernel error — that usually points to missing BTF, missing BPF, or a verifier issue.

**Your real interface (e.g. eth0):**
```bash
sudo ./scripts/deploy.sh eth0
```
- If that **fails**, the script prints the error. Common cases:
  - **“Operation not supported”** — The driver for that NIC doesn’t support XDP (native or generic) on your kernel. Try the **sim** (veth) to confirm the rest works; use generic XDP on another interface (e.g. virtio in a VM) if available.
  - **Permission / capability** — Run with `sudo` (or ensure `CAP_NET_ADMIN` and `CAP_BPF` if using a non-root user).

---

## 4. No module to load

You do **not** need to run `modprobe` for XDP or BPF. There is no `xdp.ko` or `bpf.ko` to load. If your kernel has the config above, it’s already there. If loading still fails, it’s usually:

1. **No BTF** → use a kernel with `CONFIG_DEBUG_INFO_BTF=y` (or the sim won’t work either).
2. **NIC driver doesn’t support XDP** → use the **sim** (veth) to verify behavior, or a different NIC/driver that supports native or generic XDP.
3. **Missing tools** → install `bpftool` and (for build) `clang`, `libbpf-dev`.

---

## 5. Quick “does it work?” test

From the repo root:

```bash
make
sudo ./scripts/sip_sim_setup.sh
sudo ./scripts/sip_sim_send.sh 10
sudo ./scripts/read_xdp_stats.sh
sudo ./scripts/sip_sim_teardown.sh
```

If you see counters (e.g. OPTIONS dropped, Passed to stack), the stack works. If **sip_sim_setup.sh** fails, check BTF and the printed kernel error; there is no extra kernel module to install.
