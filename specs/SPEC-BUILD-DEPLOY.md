# Specification — Build and Deploy

This document specifies the **build system** (Makefile), **build products**, **deploy flow**, and **environment requirements** for vos-fastpath.

---

## 1. Build system (Makefile)

### 1.1 Variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `BPF_DIR` | `bpf` | Directory containing BPF source. |
| `OUT_DIR` | `build` | Output directory for generated and compiled files. |
| `VMLINUX_H` | `build/vmlinux.h` | Generated vmlinux BTF dump (C header). |
| `SIP_PROG` | `build/sip_logic.bpf.o` | Compiled XDP object. |
| `KERNEL_BTF` | `/sys/kernel/btf/vmlinux` | Kernel BTF file for CO-RE. |
| `CLANG` | `clang` | C/BPF compiler. |
| `LLVM_STRIP` | `llvm-strip` | Strip binary (not used in current Makefile; object kept with BTF). |
| `BPFTOOL` | `command -v bpftool` or `/usr/sbin/bpftool` | Tool to dump BTF and list/dump maps. |

### 1.2 Targets

| Target | Dependencies | Action |
|--------|--------------|--------|
| `all` (default) | `$(VMLINUX_H)` `$(SIP_PROG)` | Build vmlinux.h and sip_logic.bpf.o. |
| `$(OUT_DIR)` | — | Create `build/` directory. |
| `$(VMLINUX_H)` | `$(OUT_DIR)` | Run `bpftool btf dump file $(KERNEL_BTF) format c > $@`. Fails if BTF or bpftool missing. |
| `$(SIP_PROG)` | `bpf/sip_logic.bpf.c` `$(VMLINUX_H)` | Compile BPF with clang (see below). |
| `test` | `$(SIP_PROG)` | Run `sudo bash scripts/stress_test.sh 1`. |
| `clean` | — | Remove `$(OUT_DIR)` (all build artifacts). |

### 1.3 vmlinux.h generation

- **Prerequisite:** Kernel must expose BTF at `/sys/kernel/btf/vmlinux` (i.e. `CONFIG_DEBUG_INFO_BTF=y`; typical on Debian 12).
- **Command:** `bpftool btf dump file /sys/kernel/btf/vmlinux format c > build/vmlinux.h`
- **If BTF missing:** Makefile prints error and exits 1.
- **If bpftool missing:** Makefile prints install hint (e.g. `linux-tools-$(uname -r)` or `linux-tools-generic`).

### 1.4 BPF compile (sip_logic.bpf.o)

**Command (logical):**
```text
clang -target bpf -O2 -mcpu=v3 \
  -I build -I bpf -I /usr/include \
  -D__TARGET_ARCH_<arch> \
  -Wall -Wno-unused -Wno-pointer-sign \
  -g -c bpf/sip_logic.bpf.c -o build/sip_logic.bpf.o
```

**Arch macro:** `uname -m` is normalized: `x86_64` → `x86`, `aarch64` → `arm64`; then `-D__TARGET_ARCH_<arch>` is set.

**Flags summary:**

| Flag | Purpose |
|------|---------|
| `-target bpf` | Generate BPF bytecode. |
| `-O2` | Optimize. |
| `-mcpu=v3` | BPF instruction set. |
| `-I build` | vmlinux.h. |
| `-I bpf` | bpf_types.h (and any local headers). |
| `-I /usr/include` | libbpf headers (bpf_helpers.h, bpf_endian.h). |
| `-D__TARGET_ARCH_*` | CO-RE / kernel type compatibility. |
| `-g` | Debug info (BTF) for map and program introspection. |
| `-c` | Compile only; output object file. |

---

## 2. Build products

| Path | Type | Description |
|------|------|--------------|
| `build/` | Directory | Created by Makefile. |
| `build/vmlinux.h` | C header | Kernel BTF in C form; do not edit. |
| `build/sip_logic.bpf.o` | ELF object | BPF program + BTF; loadable by ip(8) or libbpf. |

---

## 3. Environment requirements

### 3.1 Build host

| Requirement | Notes |
|-------------|--------|
| **Kernel** | Linux with BTF: `CONFIG_DEBUG_INFO_BTF=y`. Check: `ls /sys/kernel/btf/vmlinux`. |
| **clang** | Used with `-target bpf`. Version that supports BPF target and BTF. |
| **libbpf headers** | Typically from `libbpf-dev`; provides `bpf_helpers.h`, `bpf_endian.h` under `/usr/include/bpf`. |
| **bpftool** | For BTF dump and (at runtime) map list/dump/update. Install: `linux-tools-$(uname -r)` or `linux-tools-generic`. |

### 3.2 Deploy / runtime host

| Requirement | Notes |
|-------------|--------|
| **Root (or CAP_NET_ADMIN/CAP_BPF)** | Required to attach XDP and update maps. |
| **ip (iproute2)** | `ip link set dev <if> xdp obj ...` / `xdpgeneric`. |
| **bpftool** | For scripts that read/update maps (read_xdp_stats, allow_ip, block_ip, etc.). |
| **Interface** | Physical or virtual (e.g. veth) with driver supporting native or generic XDP. |

---

## 4. Deploy flow (sequence)

1. **Build**
   ```bash
   make
   ```
   Produces `build/vmlinux.h` and `build/sip_logic.bpf.o`.

2. **Load XDP on interface**
   ```bash
   sudo ./scripts/deploy.sh <interface>
   ```
   Tries native XDP, then generic. On success, every packet on that interface’s RX path is processed by `sip_xdp_prog`.

3. **Optional: tune**
   - Before starting OpenSIPS: `sudo ./scripts/enable_busy_poll.sh`
   - After starting OpenSIPS: `sudo ./scripts/pin_opensips_cores.sh`

4. **Start OpenSIPS**
   ```bash
   docker-compose up -d
   ```
   OpenSIPS listens on UDP 5060 (and optionally AF_XDP when supported). See [SPEC-RUNTIME.md](SPEC-RUNTIME.md).

5. **Policy (allowlist/blocklist)**
   - Allow OPTIONS from IP: `sudo ./scripts/allow_ip.sh <ip>`
   - Block IP: `sudo ./scripts/block_ip.sh <ip>`
   - Bulk block: `sudo ./scripts/block_ips_from_file.sh <file>`
   - Cluster sync: `sudo ./scripts/cluster_sync_blocklist.sh <file> [hosts...]`

6. **Observe**
   - Counters: `sudo ./scripts/read_xdp_stats.sh`

---

## 5. Unload / cleanup

- **Unload XDP from interface:**
  ```bash
  sudo ip link set dev <interface> xdp off
  # or, for generic:
  sudo ip link set dev <interface> xdpgeneric off
  ```
  Maps and program are then removed by the kernel.

- **Stop OpenSIPS:**
  ```bash
  docker-compose down
  ```

- **Build cleanup:**
  ```bash
  make clean
  ```
  Removes entire `build/` directory.

---

## 6. Test flow

- **Simulation (no physical SIP):**
  1. `make`
  2. `sudo ./scripts/sip_sim_setup.sh`
  3. `sudo ./scripts/sip_sim_send.sh [count]`
  4. `sudo ./scripts/read_xdp_stats.sh`
  5. `sudo ./scripts/sip_sim_teardown.sh`

- **Automated stress/correctness:**
  ```bash
  make test
  ```
  Runs `sudo ./scripts/stress_test.sh 1` (see [SPEC-SCRIPTS.md](SPEC-SCRIPTS.md)).

---

## 8. Known pitfalls

| Symptom | Cause | Fix |
|---------|-------|-----|
| `bpftool: command not found` during `make` | bpftool binary is at `/usr/sbin/bpftool`, which is not in user PATH | Makefile auto-detects `/usr/sbin/bpftool`; manually use full path or `export PATH="$PATH:/usr/sbin"` |
| `error: unable to open output file 'build/sip_logic.bpf.o': 'Operation not permitted'` | Prior `sudo make` left `build/sip_logic.bpf.o` owned by root | `rm build/sip_logic.bpf.o && make` — the directory is user-owned so rm succeeds |
| `libbpf: Failed to bump RLIMIT_MEMLOCK` on `bpftool prog load` | Non-root process can't pin BPF programs | Use `sudo /usr/sbin/bpftool prog load …`; compile step is unaffected |
| `fatal error: 'bpf/bpf_helpers.h' file not found` | `libbpf-dev` not installed | `sudo apt install libbpf-dev` |
| `ERROR: Kernel BTF not found` | Kernel built without `CONFIG_DEBUG_INFO_BTF=y` | Install a distro kernel; see [KERNEL-REQUIREMENTS.md](../docs/KERNEL-REQUIREMENTS.md) |

See [BUILD-PREREQS.md](../docs/BUILD-PREREQS.md) for the full prerequisite walkthrough.

---

## 7. References

- [BUILD-PREREQS.md](../docs/BUILD-PREREQS.md) — Complete install and first-build walkthrough with pitfalls.
- [SPEC-SCRIPTS.md](SPEC-SCRIPTS.md) — deploy.sh, allow/block, sim scripts.
- [SPEC-RUNTIME.md](SPEC-RUNTIME.md) — Docker and OpenSIPS runtime.
- [NIC-COMPATIBILITY.md](../docs/NIC-COMPATIBILITY.md) — Native vs generic XDP by driver.
