# Specification — BPF/XDP Program

This document is the **full specification** of the vos-fastpath XDP program: source file, maps, constants, and packet processing logic.

---

## 1. Source and build

| Item | Value |
|------|--------|
| Source file | `bpf/sip_logic.bpf.c` |
| License | GPL-2.0 OR BSD-3-Clause |
| Section | `SEC("xdp")` → section name `xdp` |
| Output object | `build/sip_logic.bpf.o` (CO-RE; BTF embedded) |

### 1.1 Includes and types

- `bpf_types.h` — defines `__u8`, `__u16`, `__u32`, `__u64` if not provided by vmlinux.
- `vmlinux.h` — generated from kernel BTF; provides kernel types (e.g. `struct xdp_md`).
- `bpf/bpf_helpers.h`, `bpf/bpf_endian.h` — libbpf helpers and byte-order macros.
- `ETH_P_IP` is defined as `0x0800` if not already defined.

---

## 2. Constants

| Symbol | Value | Meaning |
|--------|--------|---------|
| `SIP_PORT` | 5060 | UDP destination port for SIP. |
| `OPTIONS_LEN` | 8 | Length of `"OPTIONS "` for method check. |
| `REGISTER_LEN` | 9 | Length of `"REGISTER "` for method check. |
| `MIN_REGISTER_LEN` | 20 | Minimum payload length for REGISTER before malformed check. |
| `SIP_VERSION` | `"SIP/2.0"` | String required in first line. |
| `SIP_VERSION_LEN` | 7 | Length of `"SIP/2.0"`. |
| `MAX_FIRST_LINE` | 64 | Max bytes to search for `SIP/2.0` in first line. |
| `MIN_SIP_PAYLOAD` | 20 | Payloads shorter than this are not subject to "no SIP/2.0" drop. |
| `MAX_SIP_LOOKUP` | 64 | Max bytes to search for `SIP/2.0` for generic SIP validation. |

---

## 3. BPF maps

All maps are defined in `sip_logic.bpf.c`. Full layout and bpftool usage: [SPEC-MAPS.md](SPEC-MAPS.md).

### 3.1 xsks_map

- **Type:** `BPF_MAP_TYPE_XSKMAP`
- **Key:** `__u32` (queue_id = `ctx->rx_queue_index`)
- **Value:** `__u32` (AF_XDP socket FD)
- **Max entries:** 64
- **Purpose:** Redirect target; user space (e.g. OpenSIPS) pins XSK FDs per queue. Lookup: if present → `bpf_redirect_map(&xsks_map, queue_id, 0)`.

### 3.2 allowed_ips

- **Type:** `BPF_MAP_TYPE_HASH`
- **Key:** `__u32` (IPv4 address, network byte order)
- **Value:** `__u8` (1 = allowed)
- **Max entries:** 256
- **Purpose:** Stealth allowlist; OPTIONS from this IP are not dropped.

### 3.3 blocked_ips

- **Type:** `BPF_MAP_TYPE_HASH`
- **Key:** `__u32` (IPv4 address, network byte order)
- **Value:** `__u8` (1 = blocked)
- **Max entries:** 1024
- **Purpose:** Blocklist; all UDP 5060 from this IP is dropped.

### 3.4 xdp_counters

- **Type:** `BPF_MAP_TYPE_PERCPU_ARRAY`
- **Key:** `__u32` (counter index, see enum below)
- **Value:** `__u64`
- **Max entries:** `XDP_COUNT_MAX` (5)
- **Purpose:** Per-CPU counters; user space sums across CPUs.

**Counter enum:**

```c
enum xdp_counter {
    XDP_OPTIONS_DROPPED = 0,  // OPTIONS dropped by stealth
    XDP_REDIRECTED,           // Redirected to AF_XDP
    XDP_PASSED,               // Passed to stack
    XDP_BLOCKED,              // Dropped by blocklist
    XDP_MALFORMED,            // Dropped: malformed SIP
    XDP_COUNT_MAX
};
```

---

## 4. Entry point and context

- **Function:** `sip_xdp_prog(struct xdp_md *ctx)`
- **Section:** `SEC("xdp")`
- **Context:** `ctx->data`, `ctx->data_end`, `ctx->rx_queue_index` (used as queue_id for xsks_map).

All packet access must be bounded by `data` and `data_end` for the verifier.

---

## 5. Packet processing (step-by-step)

### 5.1 L2 (Ethernet)

- Advance past `sizeof(struct ethhdr)`; validate `data + off <= data_end`.
- Check `eth->h_proto == bpf_htons(ETH_P_IP)`. If not → `return XDP_PASS`.

### 5.2 L3 (IPv4)

- Advance by `sizeof(struct iphdr)`; validate.
- Check `ip->ihl >= 5` and `ip->version == 4`. If not → `return XDP_PASS`.
- Read `src_ip = ip->saddr`.
- Advance by `ip->ihl * 4` (full IP header); validate.

### 5.3 L4 (UDP)

- Advance by `sizeof(struct udphdr)`; validate.
- Check `udp->dest == bpf_htons(SIP_PORT)`. If not → `return XDP_PASS`.
- Check `udp->len >= bpf_htons(sizeof(struct udphdr))`. If not → `return XDP_PASS`.
- Payload pointer: `payload = (unsigned char *)(data + off)`.

### 5.4 Blocklist

- `key = src_ip`; `blocked = bpf_map_lookup_elem(&blocked_ips, &key)`.
- If `blocked` non-NULL: increment `xdp_counters[XDP_BLOCKED]`, `return XDP_DROP`.

### 5.5 Stealth (OPTIONS)

- If `(payload + OPTIONS_LEN) <= data_end` and payload starts with `"OPTIONS "` (byte-by-byte):
  - `allowed = bpf_map_lookup_elem(&allowed_ips, &key)` with `key = src_ip`.
  - If `allowed` is NULL: increment `xdp_counters[XDP_OPTIONS_DROPPED]`, `return XDP_DROP`.

### 5.6 Malformed REGISTER

- If payload starts with `"REGISTER "` (9 bytes) and within bounds:
  - If `payload_len < MIN_REGISTER_LEN` (20): increment MALFORMED, `return XDP_DROP`.
  - Else: search for `"SIP/2.0"` in `payload[0..MAX_FIRST_LINE - SIP_VERSION_LEN]` (bounded loop, `#pragma unroll`). If not found: increment MALFORMED, `return XDP_DROP`.

### 5.7 Malformed generic (any SIP-like length)

- If `payload_len >= MIN_SIP_PAYLOAD` (20):
  - Search for `"SIP/2.0"` in first `MAX_SIP_LOOKUP - SIP_VERSION_LEN` bytes (bounded loop). If not found: increment MALFORMED, `return XDP_DROP`.

### 5.8 Redirect or pass

- `queue_id = ctx->rx_queue_index`.
- If `bpf_map_lookup_elem(&xsks_map, &queue_id)` non-NULL:
  - Increment `xdp_counters[XDP_REDIRECTED]`.
  - `return bpf_redirect_map(&xsks_map, queue_id, 0)`.
- Else:
  - Increment `xdp_counters[XDP_PASSED]`.
  - `return XDP_PASS`.

---

## 6. Header definitions

- **bpf_types.h:** `__u8`, `__u16`, `__u32`, `__u64` (shim when vmlinux.h doesn’t provide them).
- **pkt_headers.h:** Not included by sip_logic.bpf.c; sip_logic uses vmlinux/kernel types. The repo’s `pkt_headers.h` defines minimal `struct ethhdr`, `struct iphdr`, `struct udphdr` for reference; the program relies on the kernel/vmlinux definitions consistent with these layouts (Eth: 6+6+2, IP: standard IPv4, UDP: 2+2+2+2).

---

## 7. CO-RE and portability

- Program is compiled with BTF and no target-specific assumptions beyond standard L2/L3/L4 layout.
- `vmlinux.h` is generated from the **running** kernel’s BTF (`/sys/kernel/btf/vmlinux`) so types match the kernel.
- Build uses `-target bpf`, `-mcpu=v3`, and `-D__TARGET_ARCH_*` for the current arch (e.g. x86, arm64). See [SPEC-BUILD-DEPLOY.md](SPEC-BUILD-DEPLOY.md).

---

## 8. Verifier and safety

- All packet reads are guarded by `data + off <= data_end` (or equivalent).
- Loops over payload use fixed upper bound (`MAX_FIRST_LINE - SIP_VERSION_LEN`, `MAX_SIP_LOOKUP - SIP_VERSION_LEN`) with `#pragma unroll` so the verifier can bound iterations.
- Map lookups check for NULL before dereference; counter updates use `if (v) *v += 1`.

---

## 9. References

- [SPEC-MAPS.md](SPEC-MAPS.md) — Map key/value format and bpftool.
- [SPEC-ARCHITECTURE.md](SPEC-ARCHITECTURE.md) — Data flow and component roles.
