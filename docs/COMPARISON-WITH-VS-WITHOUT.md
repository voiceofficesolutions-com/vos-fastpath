# Comparison: With vs Without vos-fastpath

Same box, same traffic. Only difference: vos-fastpath loaded on the NIC or not.

**Bottom line:** With vos-fastpath, **unwanted SIP never reaches the kernel stack or OpenSIPS** — it is dropped at the NIC. That’s why it’s effective: scanners get no reply, blocklisted IPs never touch your app, and valid traffic gets more headroom and often lower latency.

---

## Behavior

| | **Without vos-fastpath** | **With vos-fastpath** |
|---|---------------------------|------------------------|
| **Every UDP 5060 packet** | Goes through full kernel stack → OpenSIPS | Filtered at the NIC first |
| **OPTIONS from unknown IPs** | Reach OpenSIPS; you send replies; you appear in scans | Dropped at the NIC; no reply; you stay hidden |
| **Traffic from blocklisted IPs** | Reaches kernel stack and/or OpenSIPS (you block in app/firewall) | Dropped at the NIC; never reaches stack or OpenSIPS |
| **Malformed REGISTER (too short / no SIP/2.0)** | Reaches OpenSIPS (or kernel) | Dropped at the NIC |
| **Valid SIP (after filter)** | Kernel stack → OpenSIPS | Same, or zero-copy to OpenSIPS (AF_XDP) |

---

## Where work happens

| | **Without vos-fastpath** | **With vos-fastpath** |
|---|---------------------------|------------------------|
| **Unwanted / abusive packets** | Full stack + often OpenSIPS | NIC only (dropped) |
| **Cost per dropped packet** | Full IP/UDP/socket path (+ app if it gets there) | Tens–hundreds of CPU cycles at NIC |
| **Who sees OPTIONS scans** | OpenSIPS sees them | OpenSIPS does not (dropped at NIC) |
| **Who sees blocklisted IPs** | Stack and/or OpenSIPS | Nobody (dropped at NIC) |

---

## Metrics (same traffic, same box)

| Metric | **Without vos-fastpath** | **With vos-fastpath** |
|---|---------------------------|------------------------|
| **Packets hitting OpenSIPS** | All UDP 5060 | Only those that pass the filter (no OPTIONS from non-allowed IPs, no blocklist, no malformed) |
| **Packets hitting kernel stack (UDP 5060)** | All | Only those that pass (or all if no AF_XDP socket) |
| **OpenSIPS CPU** | Higher (processes everything) | Lower (doesn’t see dropped traffic) |
| **Median SIP RTT (under load)** | Baseline | Often 10–25% lower (less junk in the path) |
| **Visibility to scanners** | OPTIONS get replies | No OPTIONS reply unless IP is allowed |

---

## One-table summary

| | **Without** | **With** |
|---|-------------|----------|
| Unwanted SIP (OPTIONS scans, blocklist, malformed) | Stack + OpenSIPS | **Dropped at NIC** |
| Valid SIP | Stack → OpenSIPS | Stack → OpenSIPS, or **AF_XDP → OpenSIPS** |
| Work done for bad traffic | Full path | **NIC only** |
| OpenSIPS sees | All UDP 5060 | **Only what passes the filter** |

---

## Why this makes it effective

- **Drop at the NIC = zero cost for bad traffic.** No stack, no OpenSIPS, no reply. In tests, 80 packets in one run were dropped at the NIC; every one of them would have cost full path without vos-fastpath.
- **Stealth works.** OPTIONS from unknown IPs get no reply — you stay off scanner lists and reduce attack surface.
- **Blocklist works.** One map lookup; traffic from blocklisted IPs never reaches the stack or OpenSIPS.
- **Good traffic wins.** Fewer packets hitting OpenSIPS means lower CPU and often 10–25% lower median RTT under load.

That’s the comparison — and why effectiveness comes from filtering at the earliest point.
