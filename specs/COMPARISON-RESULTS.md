# vos-fastpath — Comparison Run Results

**Date:** 2025-02-19  
**Interface:** enp1s0  
**Host:** Debian (kernel 6.12.x), AMD x86_64  

---

## 1. Build

- **vmlinux.h:** Generated from `/sys/kernel/btf/vmlinux` (CO-RE).
- **BPF object:** `build/sip_logic.bpf.o` built with clang `-target bpf -O2 -mcpu=v3 -g` (BTF kept for load).
- **Result:** Build succeeded.

---

## 2. Baseline (no XDP)

| Metric | Value |
|--------|--------|
| Interface | enp1s0 (UP, LOWER_UP) |
| RX packets (cumulative) | 15,540,835 |
| RX bytes | 21,145,438,929 |
| RX dropped | 0 |
| XDP | none |

---

## 3. With XDP loaded (SKB / generic mode)

- **Native XDP:** Not supported by driver (attempted first).
- **Fallback:** Loaded in **xdpgeneric** (SKB) mode.
- **Attach:** `ip link set dev enp1s0 xdpgeneric obj build/sip_logic.bpf.o sec xdp`

| Metric | Value |
|--------|--------|
| Interface | enp1s0, `xdpgeneric` attached |
| XDP prog id | 68,093 |
| xdp_counters map id | 13,610 |
| RX packets (cumulative) | 15,572,235 |
| RX dropped | 0 |

**XDP counters (read via `read_xdp_stats.sh`):**

| Counter | Value | Meaning |
|---------|--------|--------|
| OPTIONS dropped (stealth) | 0 | No OPTIONS from non-allowed IPs seen on this interface |
| Redirected (AF_XDP) | 0 | No AF_XDP socket in map (expected without OpenSIPS AF_XDP) |
| Passed to stack | 0 | No UDP 5060 traffic ingressing on enp1s0 during test |

*Note: UDP 5060 was sent from this host to its own IP; that traffic did not ingress on enp1s0 (local delivery), so the XDP program did not see it. Counters will increment when SIP traffic from the network actually arrives on enp1s0.*

---

## 4. After unloading XDP

- **Command:** `ip link set dev enp1s0 xdpgeneric off`
- **Result:** Interface back to normal (no `xdp`/`xdpgeneric` in `ip link` output).

---

## 5. Summary

| Phase | XDP state | Interface RX (packets) | XDP counters (drop / redirect / pass) |
|-------|-----------|-------------------------|----------------------------------------|
| Baseline | Off | 15,540,835 | N/A |
| With XDP | xdpgeneric | 15,572,235 | 0 / 0 / 0 |
| After unload | Off | — | N/A |

- **Build:** OK.  
- **Load:** OK (SKB mode; native not supported by driver).  
- **Stats script:** OK (map found, counters read).  
- **Counters:** 0/0/0 because no UDP 5060 traffic from the network hit enp1s0 during the test.

To see **increases in metrics** (non-zero OPTIONS dropped, passed, or redirected):

1. Have real SIP traffic (e.g. OPTIONS scans or a SIP load generator) **from another host** aimed at this host’s IP on port 5060 so it **ingresses on enp1s0**.
2. Optionally add an AF_XDP listener (e.g. OpenSIPS with afxdp) and fill the XSKMAP so **Redirected** increases.
3. Run `sudo ./scripts/read_xdp_stats.sh` and compare before/after and over time.
