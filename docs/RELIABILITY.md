# Reliability — Service-Provider Readiness

vos-fastpath is designed to run in front of OpenSIPS in production. This document states what we guarantee, how we test it, and what failure modes to expect.

---

## 1. Design Guarantees

### 1.1 Safe packet handling

- **Bounds:** The BPF program never reads past `data_end`. Every pointer advance is checked before use. Malformed or truncated packets that pass the minimal L2/L3/L4 checks either **XDP_PASS** (handed to the kernel) or **XDP_DROP** (blocklist/OPTIONS); there is no out-of-bounds access.
- **UDP length:** The program checks `udp->len >= sizeof(udphdr)` before using the payload. Invalid lengths cause **XDP_PASS** so the kernel can handle or discard the packet.
- **Non-SIP / non-5060:** Traffic that is not IPv4 UDP to port 5060 is **XDP_PASS** immediately. No map lookups, no payload inspection. Other protocols and ports are unaffected.

### 1.2 Map lookups

- All `bpf_map_lookup_elem` results are checked before use. Null (missing key) is handled: we do not drop or redirect on lookup failure; we **XDP_PASS** when there is no XSK in the map, and we only drop OPTIONS when the IP is not in `allowed_ips` after a successful lookup.
- **blocked_ips** and **allowed_ips** are best-effort: full maps (1024 / 256 entries) cause new entries to fail at update time in user space; the BPF program continues to behave correctly with existing entries.

### 1.3 Counter consistency

- Per-CPU counters are incremented only on the path that actually returns DROP, REDIRECT, or PASS. Each packet is accounted exactly once. Under load, the sum of OPTIONS_DROPPED + BLOCKED + REDIRECTED + PASSED equals the number of UDP 5060 packets processed by the program.

---

## 2. Testing

### 2.1 Stress and correctness test

Run the full stress test (requires sim setup, blocklist, allowlist, volume, teardown). Use `bash` so helper scripts run correctly:

```bash
sudo bash ./scripts/stress_test.sh [rounds]
```

Typical duration: ~3 minutes for 1 round; increase `rounds` (e.g. `10`) for a heavier hammer.

- **Phase 1 — Volume:** Sends many OPTIONS and REGISTER from the sim host. Verifies OPTIONS are dropped (stealth) and REGISTER are passed; counter deltas match expected counts within tolerance.
- **Phase 2 — Blocklist:** Blocks the sim IP, sends traffic, verifies BLOCKED increases. Unblocks, sends again, verifies no new BLOCKED.
- **Phase 3 — Allow list:** Allows the sim IP for OPTIONS, sends OPTIONS, verifies they are no longer dropped and appear as PASSED.
- **Phase 4 — Hammer:** Sustained send + repeated `read_xdp_stats.sh` to ensure no crash or stats failure under load.
- **Phase 5 — Teardown:** Removes the sim namespace and veth; confirms clean removal.

Exit 0 only if all phases pass. Recommended before releases and after BPF or script changes.

### 2.2 Manual hammer (high volume)

For maximum load (e.g. 10 rounds × 150 OPTIONS + 150 REGISTER):

```bash
sudo ./scripts/sip_sim_setup.sh
sudo ./scripts/stress_test.sh 10
sudo ./scripts/sip_sim_teardown.sh
```

Use this to validate behavior under sustained load on your hardware.

### 2.3 Build and load

- **Build:** `make` must complete without error. The BPF object is built with `-g` (BTF) so the kernel can load it.
- **Load:** `deploy.sh <iface>` tries native XDP then SKB. On interfaces that support neither (or on error), the script exits non-zero and does not attach. No partial or broken attach.

---

## 3. Failure Modes and Recovery

| Situation | Behavior | Recovery |
|-----------|----------|----------|
| **NIC down / link down** | XDP is attached to the interface; when the link goes down, the program remains attached. When the link comes up again, traffic is processed again. No crash. | None required. |
| **XDP program unload** | `ip link set dev <if> xdpgeneric off` (or `xdp off`) removes the program. Traffic to port 5060 again follows the normal kernel path. OpenSIPS continues to receive UDP 5060 if it is listening. | Reload with `deploy.sh` when the interface is ready. |
| **Map full (blocked_ips / allowed_ips)** | New `block_ip.sh` / `allow_ip.sh` updates can fail (map update returns error). Existing entries still work. BPF program does not crash. | Unblock/unallow some IPs to free space, or restart with a new program (larger map) if you need more entries. |
| **bpftool / jq missing** | `read_xdp_stats.sh` may fail or show zeros if jq is missing and the awk fallback fails on your bpftool output. XDP and maps are unaffected. | Install `jq` or rely on `bpftool map dump id <id>` manually. |
| **Sim namespace left behind** | If `sip_sim_teardown.sh` is not run, the namespace and veth persist. No impact on production if you only use `deploy.sh` on the real NIC. | Run `sip_sim_teardown.sh` to remove. |
| **Kernel without BTF** | Program load fails (e.g. “BTF required”). | Use a kernel with `CONFIG_DEBUG_INFO_BTF=y` or provide a compatible vmlinux.h and rebuild. |

---

## 4. Conditions We Run Under

- **All conditions** here means: any valid IPv4 UDP packet to port 5060 (including malformed, short, or garbage payload), under load (many packets per second), with blocklist and allowlist updates during operation, and with repeated stats reads. The program is written to:
  - **Pass** non-5060 and non-IPv4 so the kernel handles them.
  - **Drop** only when the packet is UDP 5060 and (a) source is in **blocked_ips**, or (b) payload starts with `OPTIONS ` and source is not in **allowed_ips**.
  - **Redirect** only when UDP 5060 and an XSK exists for the queue; otherwise **pass**.
  - **Never** read out of bounds or dereference a null map value.

The stress test (`stress_test.sh`) and the hardening (bounds checks, UDP length check, null checks) are there so this holds under all conditions that a service provider can hit in production.
