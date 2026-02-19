# Build Prerequisites — vos-fastpath

Complete, step-by-step guide to installing build tools and successfully compiling
`sip_logic.bpf.o` on a fresh Debian/Ubuntu system.

---

## 1. System requirements at a glance

| Requirement | Minimum | How to check |
|-------------|---------|--------------|
| Kernel BTF | Linux ≥ 5.8, `CONFIG_DEBUG_INFO_BTF=y` | `ls /sys/kernel/btf/vmlinux` |
| clang | ≥ 11 (19 confirmed working) | `clang --version` |
| libbpf headers | any current | `apt list --installed \| grep libbpf-dev` |
| bpftool | any current | `/usr/sbin/bpftool version` |
| GNU make | any | `make --version` |

**Tested reference environment:** Debian 13, kernel 6.12.69+deb13, clang 19.1.7,
bpftool 7.5.0 (`linux (6.12.73-1)` package).

---

## 2. Install build tools

```bash
# Refresh package index
sudo apt update

# Core build tools
sudo apt install -y clang llvm libbpf-dev make

# bpftool — provides vmlinux.h generation and map inspection.
# The standalone 'bpftool' package (Debian 11+) is the preferred route.
sudo apt install -y bpftool

# If 'bpftool' package is not available on your release, fall back to:
# sudo apt install -y linux-tools-$(uname -r) || sudo apt install -y linux-tools-generic
```

> **Note:** On Debian 13 / Ubuntu 24.04+, `bpftool` is a standalone package at
> `/usr/sbin/bpftool`. The Makefile auto-detects this path via
> `command -v bpftool || /usr/sbin/bpftool`. If you install via `linux-tools-*`,
> the binary lands at `/usr/lib/linux-tools-$(uname -r)/bpftool` and may not be
> in a non-root PATH — the Makefile still finds it because it uses the full path
> fallback.

---

## 3. Verify kernel BTF is present

```bash
ls -lh /sys/kernel/btf/vmlinux
```

Expected output — file exists, any size:
```
-r--r--r-- 1 root root 8.9M Feb 19 09:00 /sys/kernel/btf/vmlinux
```

If `No such file or directory`: your kernel was not built with `CONFIG_DEBUG_INFO_BTF=y`.
Install a standard Debian/Ubuntu/RHEL kernel (all ship with BTF since ~2021) or
see [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md).

---

## 4. Build

Run from the repo root:

```bash
make
```

What happens:
1. `bpftool btf dump file /sys/kernel/btf/vmlinux format c > build/vmlinux.h`  
   Generates the CO-RE kernel header (~2.5 MB on kernel 6.12).
2. `clang -target bpf -O2 -mcpu=v3 … -c bpf/sip_logic.bpf.c -o build/sip_logic.bpf.o`  
   Compiles the XDP program to BPF bytecode.

Expected output:
```
Generated build/vmlinux.h
Built build/sip_logic.bpf.o
```

---

## 5. Verify the object is correct

Check the ELF sections (no sudo needed):

```bash
readelf -S build/sip_logic.bpf.o | grep -E 'xdp|maps|license|btf'
```

Expected — all four sections present:
```
  [ 3] xdp               PROGBITS …
  [ 4] .relxdp           REL      …
  [ 5] .maps             PROGBITS …
  [ 6] license           PROGBITS …
```

Optionally disassemble (confirms verifier-friendly bounded loops):
```bash
llvm-objdump -d build/sip_logic.bpf.o | head -30
```

Dry-run load into the kernel (requires sudo / CAP_BPF):
```bash
sudo /usr/sbin/bpftool prog load build/sip_logic.bpf.o /sys/fs/bpf/sip_xdp_test type xdp \
  && echo "KERNEL VERIFIER ACCEPTED" \
  && sudo /usr/sbin/bpftool prog show pinned /sys/fs/bpf/sip_xdp_test \
  && sudo rm /sys/fs/bpf/sip_xdp_test
```

---

## 6. Known pitfalls

### 6.1 `bpftool: command not found` during `make`

`bpftool` is installed at `/usr/sbin/bpftool` but `/usr/sbin` is often not in a
normal user's PATH (only in root's PATH via `/etc/environment` or PAM).

The Makefile handles this automatically — it falls back to `/usr/sbin/bpftool`.
If you call `bpftool` manually, use the full path:

```bash
/usr/sbin/bpftool version
```

Or add `/usr/sbin` to your PATH for the session:

```bash
export PATH="$PATH:/usr/sbin"
```

### 6.2 `error: unable to open output file 'build/sip_logic.bpf.o': 'Operation not permitted'`

**Cause:** A previous `sudo make` run left `build/sip_logic.bpf.o` owned by `root`.
Subsequent non-root `make` runs can't overwrite it.

**Fix:**
```bash
rm build/sip_logic.bpf.o
make
```

The `build/` directory itself is owned by your user so `rm` works without sudo.

**Permanent mitigation:** Always run `make` as your regular user, not as root.
If you need a privilege for something in the build, use `sudo make <specific-target>`.
The Makefile does not require root for the compile step.

### 6.3 `libbpf: Failed to bump RLIMIT_MEMLOCK` during `bpftool prog load`

Non-root processes have a low `RLIMIT_MEMLOCK` that prevents pinning BPF programs.
This is expected when running `bpftool prog load` without sudo. The compile itself
is unaffected.

**Fix:** Use `sudo` for `bpftool prog load` and all runtime scripts:
```bash
sudo /usr/sbin/bpftool prog load build/sip_logic.bpf.o /sys/fs/bpf/... type xdp
```

On kernels ≥ 5.11 with `CONFIG_BPF_UNPRIV_DEFAULT_OFF=n`, you can grant
`CAP_BPF + CAP_NET_ADMIN` instead of running as root.

### 6.4 `ERROR: Kernel BTF not found at /sys/kernel/btf/vmlinux`

Your kernel lacks `CONFIG_DEBUG_INFO_BTF=y`. Install a distro kernel:

```bash
# Debian
sudo apt install linux-image-amd64 && sudo reboot
```

After reboot: `ls /sys/kernel/btf/vmlinux` should show the file.

### 6.5 `fatal error: 'bpf/bpf_helpers.h' file not found`

`libbpf-dev` is not installed:
```bash
sudo apt install libbpf-dev
```

---

## 7. Clean rebuild

```bash
make clean   # removes build/ entirely
make         # fresh rebuild of vmlinux.h and sip_logic.bpf.o
```

---

## 8. Next steps after a successful build

1. **Load onto real NIC:**
   ```bash
   sudo ./scripts/deploy.sh eth0   # replace eth0 with your interface
   ```

2. **Smoke-test with simulation (no physical SIP needed):**
   ```bash
   sudo ./scripts/sip_sim_setup.sh
   sudo ./scripts/sip_sim_send.sh 10
   sudo ./scripts/read_xdp_stats.sh
   sudo ./scripts/sip_sim_teardown.sh
   ```

3. **Allow a trusted SIP client IP:**
   ```bash
   sudo ./scripts/allow_ip.sh <client_ip>
   ```

4. **Start OpenSIPS:**
   ```bash
   docker-compose up -d
   ```

See [SPEC-BUILD-DEPLOY.md](../specs/SPEC-BUILD-DEPLOY.md) for the full deploy sequence
and [KERNEL-REQUIREMENTS.md](KERNEL-REQUIREMENTS.md) for kernel config details.
