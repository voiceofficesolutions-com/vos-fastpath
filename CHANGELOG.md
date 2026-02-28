# Changelog — vos-fastpath

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [Unreleased]

### Added
- `bench/bench.sh` — positional `compare` subcommand (`bench.sh compare -i <iface>
  -s <method> -r <pps> -m <total>`) as an alias for `--compare`. Runs baseline
  (XDP off) then XDP fastpath phase back-to-back and prints a side-by-side diff
  table of success, failed, and retransmit counts using SIPp.
- `docs/BUILD-PREREQS.md` — comprehensive step-by-step guide for installing build
  dependencies and compiling `sip_logic.bpf.o` from scratch, including all known
  pitfalls discovered during first-build verification.
- `CHANGELOG.md` — this file.

### Fixed
- Build blocked by root-owned `build/sip_logic.bpf.o` (artifact from prior `sudo make`
  run). Fix: `rm build/sip_logic.bpf.o && make`. Documented in BUILD-PREREQS.md §6.2.

### Verified (2026-02-19)
- Full build confirmed on **Debian 13, kernel 6.12.69+deb13-amd64**, clang 19.1.7,
  bpftool 7.5.0.
- `build/vmlinux.h` generated from `/sys/kernel/btf/vmlinux` (CO-RE, ~2.5 MB).
- `build/sip_logic.bpf.o` compiles clean, zero warnings.
- ELF sections verified: `xdp`, `.relxdp`, `.maps`, `license`, BTF.
- Disassembly confirms `sip_xdp_prog` entry point and bounded loops accepted by
  BPF verifier.
- `bpftool` installed as standalone package at `/usr/sbin/bpftool` (not in default
  user PATH — Makefile fallback path handles this automatically).

---

## [0.1.0] — Initial implementation

### Added
- `bpf/sip_logic.bpf.c` — XDP SIP sieve:
  - L2/L3/L4 parse (Ethernet → IPv4 → UDP), port 5060 filter.
  - DoS blocklist (`blocked_ips` BPF_MAP_TYPE_HASH, 1024 entries) — drops all UDP
    5060 from blocklisted IPs before stack/OpenSIPS.
  - Stealth OPTIONS filter (`allowed_ips` hash, 256 entries) — drops SIP OPTIONS
    from IPs not in allowlist (scanners get no reply).
  - Malformed SIP filter — drops REGISTER without `SIP/2.0` in first 64 bytes.
  - AF_XDP redirect (`xsks_map` XSKMAP, 64 queues) — zero-copy path to OpenSIPS.
  - Per-CPU counters (`xdp_counters` PERCPU_ARRAY): OPTIONS_DROPPED, REDIRECTED,
    PASSED, BLOCKED, MALFORMED.
  - CO-RE build (vmlinux.h from bpftool); portable across kernels.
- `bpf/bpf_types.h`, `bpf/pkt_headers.h` — supporting headers.
- `Makefile` — builds vmlinux.h and sip_logic.bpf.o; auto-detects bpftool path.
- `scripts/deploy.sh` — load XDP (native then SKB fallback).
- `scripts/allow_ip.sh` / `scripts/block_ip.sh` / `scripts/unblock_ip.sh` — map management.
- `scripts/block_ips_from_file.sh` — bulk blocklist from file.
- `scripts/cluster_sync_blocklist.sh` — SSH sync of blocklist across cluster nodes.
- `scripts/read_xdp_stats.sh` — display per-CPU counters.
- `scripts/sip_sim_setup.sh` / `sip_sim_send.sh` / `sip_sim_teardown.sh` — veth
  network namespace simulation (no physical SIP required).
- `scripts/stress_test.sh` — automated correctness and stress test (`make test`).
- `scripts/enable_busy_poll.sh` — set `net.core.busy_poll=50` for reduced latency.
- `scripts/pin_opensips_cores.sh` — pin OpenSIPS to CPU cores 4–7.
- `docker-compose.yml` — OpenSIPS with `network_mode: host` and `/sys/fs/bpf` mount.
- `opensips.cfg` — UDP 5060 listener draft.
- `docs/` — 17 documentation files covering benefits, comparison metrics, kernel
  requirements, NIC compatibility, portability, RabbitMQ integration, and more.
- `specs/` — 7 technical specification files (architecture, BPF, maps, scripts,
  build/deploy, runtime, index).
