# vos-fastpath — Full Specification Index

This directory contains **full technical specifications** for the vos-fastpath SIP kernel-bypass engine. Use this index to find detailed specs for every component.

---

## Specification Documents

| Document | Scope |
|----------|--------|
| **[SPEC-ARCHITECTURE.md](SPEC-ARCHITECTURE.md)** | System architecture, data flow, component diagram, packet path (NIC → XDP → stack/AF_XDP). |
| **[SPEC-BPF.md](SPEC-BPF.md)** | BPF/XDP program: entry point, map definitions, packet processing order, constants, CO-RE build. |
| **[SPEC-MAPS.md](SPEC-MAPS.md)** | BPF maps: layout, key/value encoding, max entries, bpftool commands for operators. |
| **[SPEC-SCRIPTS.md](SPEC-SCRIPTS.md)** | Every script: synopsis, usage, arguments, exit codes, dependencies, examples. |
| **[SPEC-BUILD-DEPLOY.md](SPEC-BUILD-DEPLOY.md)** | Build system (Makefile), deploy flow, environment (kernel BTF, clang, bpftool). |
| **[SPEC-RUNTIME.md](SPEC-RUNTIME.md)** | Runtime: Docker, OpenSIPS config, network mode, tuning (busy poll, CPU pinning). |

---

## Quick Reference

### Packet flow (summary)

1. **L2/L3/L4** — Only IPv4 UDP destination port **5060** is processed; else `XDP_PASS`.
2. **Blocklist** — If source IP is in `blocked_ips` → `XDP_DROP` (counted as BLOCKED).
3. **Stealth** — If SIP method is OPTIONS and source IP not in `allowed_ips` → `XDP_DROP` (OPTIONS_DROPPED).
4. **Malformed** — REGISTER/request too short or missing "SIP/2.0" in first 64 bytes → `XDP_DROP` (MALFORMED). Any UDP 5060 payload ≥20 bytes without "SIP/2.0" in first 64 bytes → `XDP_DROP` (MALFORMED).
5. **Redirect** — If `xsks_map` has an XSK for this `rx_queue_index` → `bpf_redirect_map` (REDIRECTED).
6. **Pass** — Else → `XDP_PASS` to kernel stack (PASSED).

### Key file locations

| Role | Path |
|------|------|
| XDP program source | `bpf/sip_logic.bpf.c` |
| BPF object (built) | `build/sip_logic.bpf.o` |
| vmlinux.h (generated) | `build/vmlinux.h` |
| Deploy script | `scripts/deploy.sh` |
| Counter readout | `scripts/read_xdp_stats.sh` |
| OpenSIPS config | `opensips.cfg` |
| Docker Compose | `docker-compose.yml` |

### Map names (for bpftool)

| Map | Purpose |
|-----|---------|
| `xsks_map` | AF_XDP socket FDs by queue_id (populated by user space). |
| `allowed_ips` | IPv4 → allow OPTIONS (stealth allowlist). |
| `blocked_ips` | IPv4 → drop all UDP 5060 (blocklist). |
| `xdp_counters` | Per-CPU counters (keys 0–4). |

---

## Related Documentation (concepts and operations)

These docs live in `docs/` and describe *why* and *how to operate*; the SPEC-* docs in `specs/` are *what it is* (technical reference).

- **[SHORTEST-PATH.md](../docs/SHORTEST-PATH.md)** — Shortest path to service delivery.
- **[BENEFITS.md](../docs/BENEFITS.md)** — Benefits in depth (performance, stealth, DoS).
- **[METRICS.md](../docs/METRICS.md)** — What to measure, before/after comparison.
- **[RELIABILITY.md](../docs/RELIABILITY.md)** — Guarantees, stress test, failure modes.
- **[NIC-COMPATIBILITY.md](../docs/NIC-COMPATIBILITY.md)** — Native vs generic XDP by driver.
- **[existing-opensips-integration.md](../docs/existing-opensips-integration.md)** — Adding fastpath to existing OpenSIPS.
- **[CLUSTER-OFFLOAD.md](../docs/CLUSTER-OFFLOAD.md)**, **[CENTRALIZED-CONTROL.md](../docs/CENTRALIZED-CONTROL.md)**, **[STACK-WITH-RABBITMQ.md](../docs/STACK-WITH-RABBITMQ.md)** — Cluster and control plane.

---

## Version and environment

- **Project:** vos-fastpath (Voice Office Solutions).
- **Target:** SIP on UDP 5060; XDP + optional AF_XDP for OpenSIPS.
- **Build:** CO-RE (vmlinux.h from kernel BTF); clang `-target bpf`, `-mcpu=v3`.
- **Tested:** HP EliteBook 845 G7 (AMD Ryzen 7 4750U), Debian 12 (Proxmox), OpenSIPS 3.4+ in privileged Docker.
