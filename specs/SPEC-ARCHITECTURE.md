# Specification — System Architecture

This document specifies the **system architecture** of vos-fastpath: components, data flow, and packet path from NIC to OpenSIPS or kernel stack.

---

## 1. High-level architecture

vos-fastpath is a **SIP kernel-bypass edge**: XDP runs on the receive path of a network interface and either drops unwanted traffic, redirects UDP 5060 to an AF_XDP socket (zero-copy to OpenSIPS), or passes it to the kernel stack.

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                     Host / Node                          │
  SIP (UDP 5060)    │                                                          │
  ───────────────►  │   NIC  ──►  XDP (sip_xdp_prog)  ──┬──►  AF_XDP socket   │
                    │              │                     │         │           │
                    │              │                     │         ▼           │
                    │              │                     │    OpenSIPS         │
                    │              │                     │    (UDP or afxdp)    │
                    │              │                     │                      │
                    │              │                     └──►  Kernel stack     │
                    │              │                              │             │
                    │              │                              ▼             │
                    │              │                         UDP 5060           │
                    │              │                              │             │
                    │              │                              ▼             │
                    │              │                         OpenSIPS           │
                    │              │                                              │
                    │              ▼                                              │
                    │         DROP (OPTIONS stealth, blocklist, malformed)        │
                    └─────────────────────────────────────────────────────────┘
```

---

## 2. Components

| Component | Type | Role |
|-----------|------|------|
| **NIC** | Hardware / driver | Receives frames; invokes XDP program (native or generic). |
| **XDP program** (`sip_logic.bpf.c`) | eBPF | Runs on each RX packet: filter port 5060, blocklist, stealth OPTIONS, malformed drop, redirect or pass. |
| **BPF maps** | Kernel | `xsks_map`, `allowed_ips`, `blocked_ips`, `xdp_counters` — see [SPEC-MAPS.md](SPEC-MAPS.md). |
| **User space** | Scripts / bpftool | Load XDP, populate/update maps (allow/block IPs), read counters. |
| **AF_XDP socket** | Kernel + app | When present: XDP redirects to it (zero-copy path). OpenSIPS uses it when built with AF_XDP listener. |
| **Kernel stack** | Linux | Receives packets that XDP returns with `XDP_PASS`. |
| **OpenSIPS** | Application | SIP proxy; listens on UDP 5060 (and optionally AF_XDP). |

---

## 3. Data flow (packet path)

### 3.1 Entry

- Packet is received on the interface that has the XDP program attached.
- The kernel invokes the program with `struct xdp_md *ctx` (data, data_end, rx_queue_index).

### 3.2 Processing order (specification)

The program **must** evaluate in this order (see [SPEC-BPF.md](SPEC-BPF.md) for code-level detail):

1. **Protocol filter**
   - L2: Ethernet type must be IPv4 (`ETH_P_IP`). Else → `XDP_PASS`.
   - L3: IP version 4, header length ≥ 5. Else → `XDP_PASS`.
   - L4: UDP, destination port 5060. Else → `XDP_PASS`.
   - UDP length must be ≥ UDP header size. Else → `XDP_PASS`.

2. **Blocklist**
   - Lookup source IPv4 in `blocked_ips`. If present → increment BLOCKED counter, return `XDP_DROP`.

3. **Stealth (OPTIONS)**
   - If payload starts with `"OPTIONS "` (8 bytes): lookup source IP in `allowed_ips`. If not present → increment OPTIONS_DROPPED, return `XDP_DROP`.

4. **Malformed SIP**
   - REGISTER: if payload starts with `"REGISTER "` and (length < 20 bytes **or** no `"SIP/2.0"` in first 64 bytes) → increment MALFORMED, return `XDP_DROP`.
   - Any UDP 5060 payload with length ≥ 20 bytes: must contain `"SIP/2.0"` in first 64 bytes; else → increment MALFORMED, return `XDP_DROP`.

5. **Redirect or pass**
   - Lookup `rx_queue_index` in `xsks_map`. If an XSK is present → increment REDIRECTED, return `bpf_redirect_map(&xsks_map, queue_id, 0)`.
   - Else → increment PASSED, return `XDP_PASS`.

### 3.3 Outcomes

| Outcome | Counter | Meaning |
|--------|---------|--------|
| `XDP_DROP` (blocklist) | BLOCKED | All UDP 5060 from this IP dropped. |
| `XDP_DROP` (OPTIONS) | OPTIONS_DROPPED | OPTIONS from non-allowed IP dropped (stealth). |
| `XDP_DROP` (malformed) | MALFORMED | Packet dropped as invalid SIP. |
| `bpf_redirect_map` | REDIRECTED | Packet sent to AF_XDP socket for this queue. |
| `XDP_PASS` | PASSED | Packet handed to kernel stack; OpenSIPS receives via normal UDP. |

---

## 4. Deployment topology

### 4.1 Single node

- One interface (e.g. `eth0`) has the XDP program attached via `deploy.sh`.
- OpenSIPS runs on the same host (e.g. Docker with `network_mode: host`).
- Either:
  - **UDP only:** No XSK in `xsks_map` → all valid SIP passes to stack → OpenSIPS on UDP 5060.
  - **AF_XDP:** User-space (e.g. OpenSIPS with afxdp listener) creates AF_XDP sockets and attaches to `xsks_map` by queue_id → redirected traffic goes zero-copy to OpenSIPS.

### 4.2 Cluster

- Same XDP program and maps on every node.
- Blocklist/allowlist are synced (e.g. `cluster_sync_blocklist.sh` or central controller) so policy is consistent.
- Each node’s NIC runs XDP independently; no shared BPF state between nodes.

---

## 5. Interfaces and boundaries

| Boundary | Description |
|----------|--------------|
| **NIC ↔ XDP** | Driver (or generic path) invokes BPF program per packet; program reads only packet data and maps. |
| **XDP ↔ User space** | Maps are shared: user space updates `allowed_ips`, `blocked_ips`; user space can attach XSKs to `xsks_map`. Counters are read-only from user space (via bpftool map dump). |
| **XDP ↔ Kernel stack** | `XDP_PASS` delivers the packet to the normal IP/UDP stack. |
| **XDP ↔ AF_XDP** | `bpf_redirect_map` sends the frame to the AF_XDP socket for that queue; no copy to kernel stack. |
| **OpenSIPS ↔ network** | Either UDP socket (stack) or AF_XDP socket (bypass). |

---

## 6. Failure and fallback

- **XDP load failure:** `deploy.sh` tries native XDP first, then generic (SKB). If both fail, script exits non-zero; no XDP is attached.
- **No AF_XDP socket:** If `xsks_map` has no entry for a queue, traffic for that queue is passed to the stack (PASSED). OpenSIPS can still receive via UDP.
- **Map full:** Adding an IP to `allowed_ips` or `blocked_ips` can fail if the map is full (max_entries). Scripts report failure; operator must remove entries or resize map (requires program reload).

---

## 7. Security and isolation

- XDP runs in kernel context; it can only read packet data and map data, and return a verdict.
- Map updates (allow/block) require root (or CAP_BPF/CAP_NET_ADMIN as appropriate); scripts use `sudo`.
- No user-space packet data is injected into the kernel by the BPF program; redirect sends the same frame to the XSK.

---

## 8. References

- [SPEC-BPF.md](SPEC-BPF.md) — Program logic and constants.
- [SPEC-MAPS.md](SPEC-MAPS.md) — Map layout and bpftool.
- [SPEC-RUNTIME.md](SPEC-RUNTIME.md) — Docker and OpenSIPS runtime.
