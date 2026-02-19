# Specification — BPF Maps Reference

This document specifies all BPF maps used by the vos-fastpath XDP program: layout, key/value encoding, max entries, and **bpftool** usage for operators.

---

## 1. Overview

| Map name | Type | Key | Value | Max entries | Writable from user space |
|----------|------|-----|--------|-------------|---------------------------|
| `xsks_map` | XSKMAP | queue_id (u32) | XSK FD (u32) | 64 | Yes (AF_XDP app) |
| `allowed_ips` | HASH | IPv4 (u32) | 1 (u8) | 256 | Yes (scripts / bpftool) |
| `blocked_ips` | HASH | IPv4 (u32) | 1 (u8) | 1024 | Yes (scripts / bpftool) |
| `xdp_counters` | PERCPU_ARRAY | index (u32) 0–4 | u64 | 5 | No (read-only dump) |

---

## 2. xsks_map

- **Purpose:** Redirect target for AF_XDP. Key = RX queue index; value = AF_XDP socket FD. Populated by the application (e.g. OpenSIPS with afxdp listener), not by the provided scripts.
- **Key:** 4 bytes, `__u32`, queue index (e.g. `ctx->rx_queue_index`).
- **Value:** 4 bytes, `__u32`, file descriptor of the AF_XDP socket.
- **Update/delete:** Typically done by the program that creates the XSK (libbpf or custom loader). bpftool can update if you have the FD and map id.

**bpftool (reference):**

```bash
# List maps and get map id
bpftool map list | grep xsks_map

# Dump (shows queue_id -> value; value is FD number)
bpftool map dump id <MAP_ID>
```

---

## 3. allowed_ips

- **Purpose:** Stealth allowlist. Source IPv4 in this map → OPTIONS from that IP are **not** dropped.
- **Key:** 4 bytes, IPv4 address in **network byte order** (big-endian). Example: 10.99.0.2 → `0a 63 00 02`.
- **Value:** 1 byte, `0x01` (allowed). Any non-zero is treated as “allowed” by the program.
- **Max entries:** 256. When full, `bpftool map update` fails; remove an entry or reload program with larger max_entries.

**IPv4 to key hex (script convention):**  
`a.b.c.d` → key hex `printf "%02x %02x %02x %02x", a, b, c, d` (same as network byte order for display).

**bpftool:**

```bash
# Find map id
bpftool map list | grep allowed_ips

# Add 10.99.0.2
bpftool map update id <MAP_ID> key hex 0a 63 00 02 value hex 01

# Delete 10.99.0.2
bpftool map delete id <MAP_ID> key hex 0a 63 00 02

# Dump all entries
bpftool map dump id <MAP_ID>
```

**Script:** `scripts/allow_ip.sh <ipv4>` — adds one IP (uses same key hex and value).

---

## 4. blocked_ips

- **Purpose:** Blocklist. Source IPv4 in this map → **all** UDP 5060 from that IP is dropped (XDP_DROP, counted as BLOCKED).
- **Key:** 4 bytes, IPv4 in network byte order (same as allowed_ips).
- **Value:** 1 byte, `0x01` (blocked).
- **Max entries:** 1024.

**bpftool:**

```bash
# Find map id
bpftool map list | grep blocked_ips

# Add 192.168.1.100
bpftool map update id <MAP_ID> key hex c0 a8 01 64 value hex 01

# Delete
bpftool map delete id <MAP_ID> key hex c0 a8 01 64

# Dump
bpftool map dump id <MAP_ID>
```

**Scripts:**  
- `scripts/block_ip.sh <ip>` — add one IP.  
- `scripts/unblock_ip.sh <ip>` — delete one IP.  
- `scripts/block_ips_from_file.sh <file>` — bulk add from file (one IPv4 per line).

---

## 5. xdp_counters

- **Purpose:** Per-CPU counters for metrics. Keys 0–4 correspond to the enum in [SPEC-BPF.md](SPEC-BPF.md). User space **sums** per-CPU values for each key to get totals.
- **Key:** 4 bytes, `__u32`, counter index 0–4.
- **Value:** 8 bytes, `__u64`, per-CPU count. Stored per CPU; dump shows one entry per key with multiple values (per CPU).
- **Max entries:** 5. Not updated by user space; only the BPF program updates.

**Counter keys:**

| Key (decimal) | Name | Meaning |
|---------------|------|---------|
| 0 | XDP_OPTIONS_DROPPED | OPTIONS dropped (stealth) |
| 1 | XDP_REDIRECTED | Redirected to AF_XDP |
| 2 | XDP_PASSED | Passed to kernel stack |
| 3 | XDP_BLOCKED | Dropped by blocklist |
| 4 | XDP_MALFORMED | Dropped as malformed SIP |

**bpftool:**

```bash
# Find map id
bpftool map list | grep xdp_counters

# Dump (JSON or hex); sum value across CPUs for each key
bpftool map dump id <MAP_ID>
```

**Script:** `scripts/read_xdp_stats.sh` — finds map by name, dumps, sums per key, prints human-readable lines. Requires `bpftool`; optional `jq` for robust JSON parsing.

---

## 6. Finding map IDs (all maps)

Map IDs are assigned at load time and can differ between runs. To resolve by name:

```bash
bpftool map list
```

Match by name (e.g. `allowed_ips`, `blocked_ips`, `xdp_counters`, `xsks_map`). Some bpftool versions print `id N` on the same line as the name; scripts parse the first numeric id from the matching block.

---

## 7. Map lifecycle

- Maps are created when the XDP program is **loaded** (e.g. `ip link set dev eth0 xdp obj sip_logic.bpf.o sec xdp`). They persist as long as the program is attached and no process holds the object file closed.
- **Unloading XDP** (e.g. `ip link set dev eth0 xdp off`) removes the program and its maps; all entries are lost. Reloading creates fresh maps.
- Updates to `allowed_ips` and `blocked_ips` take effect **immediately** for new packets; no program reload needed.
- Counters are cumulative until the program is unloaded (or system restarts if XDP is not reattached at boot).

---

## 8. References

- [SPEC-BPF.md](SPEC-BPF.md) — Program and enum definition.
- [SPEC-SCRIPTS.md](SPEC-SCRIPTS.md) — Scripts that update or read these maps.
- [METRICS.md](METRICS.md) — How to interpret counter values for performance and behavior.
