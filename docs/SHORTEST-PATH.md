# Shortest Path to Service Delivery

The best part? **Your valid SIP gets to OpenSIPS in the fewest possible steps**, and junk never gets there at all. Service delivery here means: **a SIP request reaches OpenSIPS and gets a proper response** (e.g. REGISTER → 200 OK, INVITE → routing). The goal is to make that path as short as possible and to avoid doing any work for traffic that will never become “service.”

---

## What “shortest path” means

| Traffic type | Shortest path | What vos-fastpath does |
|--------------|----------------|-------------------------|
| **Bad (OPTIONS scan, blocklist, malformed)** | **No path** — never touch the stack or OpenSIPS. | Drop at the NIC (XDP). Zero kernel stack, zero socket, zero OpenSIPS. Fastest possible “no.” |
| **Good (valid SIP you want to serve)** | **NIC → app with minimum hops and copies.** | Stealth + blocklist keep junk off the path. Optional **AF_XDP** = NIC → XDP → user space (OpenSIPS); kernel stack and extra copies are skipped. |

So: **shortest path to service delivery** = drop bad traffic at the NIC, and for good traffic use the shortest path from NIC to OpenSIPS (ideally AF_XDP).

---

## Path comparison (good traffic only)

| Step | Without XDP | With XDP (pass to stack) | With XDP + AF_XDP |
|------|-------------|---------------------------|--------------------|
| 1 | NIC → driver | NIC → driver | NIC → driver |
| 2 | Kernel skb, full IP/UDP stack | XDP (filter only) → stack | XDP → **redirect** |
| 3 | UDP demux, socket | UDP demux, socket | **AF_XDP ring (zero-copy)** |
| 4 | Copy to user space | Copy to user space | **No copy** — app reads ring |
| 5 | OpenSIPS | OpenSIPS | OpenSIPS |

**Shortest path for good traffic:** steps 1 → 2 (XDP redirect) → 3 (AF_XDP) → 5. Stack and socket copy are skipped; fewer hops, fewer cycles, lower latency.

---

## How to get the shortest path in practice

1. **Load XDP on every SIP-receiving interface**  
   `sudo ./scripts/deploy.sh <iface>` (and on every node in a cluster).

2. **Keep bad traffic off the path**  
   Use stealth (OPTIONS drop) and blocklist so junk never reaches the stack or OpenSIPS. That keeps queues short and latency low for valid requests.

3. **Use AF_XDP when your driver supports it**  
   Configure OpenSIPS to listen on AF_XDP (zero-copy) for UDP 5060 so good traffic takes the shortest path from NIC to app. See [NIC compatibility](NIC-COMPATIBILITY.md) and your OpenSIPS docs.

4. **Sync policy across the cluster**  
   Same blocklist (and allowlist) on every node so the “shortest path” story is consistent everywhere. See [Cluster offload](CLUSTER-OFFLOAD.md).

---

## One-line summary

**Shortest path to service delivery:** drop bad traffic at the NIC (no path); for good traffic, use XDP + AF_XDP so the path is NIC → XDP → OpenSIPS with no kernel stack and no extra copy.
