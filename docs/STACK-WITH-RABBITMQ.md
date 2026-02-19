# How vos-fastpath Fits in the Stack with RabbitMQ

This document describes how vos-fastpath works in a stack that includes **RabbitMQ**: from SIP traffic at the NIC, through OpenSIPS (as SBC), to RabbitMQ for events, and back to the NIC via the blocklist so bad traffic is stopped as early as possible.

---

## 1. Role of Each Component

| Component | Role |
|-----------|------|
| **NIC** | Receives all SIP (UDP 5060) traffic. |
| **XDP (vos-fastpath)** | First code path in the kernel: applies blocklist, OPTIONS stealth, malformed REGISTER drop. Drops or passes/redirects before the rest of the stack. |
| **Kernel stack** | Sees only traffic that XDP passed (no XSK redirect). Delivers to OpenSIPS socket. |
| **OpenSIPS (as SBC)** | SIP logic, routing, dialogs; can act as honeypot/sensor and detect bad or abusive sources. Publishes events or messages to RabbitMQ. |
| **RabbitMQ** | Message broker: carries “block this IP” (or threat-intel) messages from OpenSIPS (or other producers) to a blocklist-updater consumer. |
| **Blocklist updater** | Consumer that reads from RabbitMQ and updates the XDP blocklist (e.g. via `block_ip.sh` or `block_ips_from_file.sh`). |

---

## 2. Data Flow in the Stack

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                      Host (e.g. SBC)                     │
  SIP (UDP 5060)    │                                                         │
  ───────────────►  │   NIC ──► XDP (vos-fastpath)                             │
                    │            │                                             │
                    │            ├─ blocklist hit? ──► XDP_DROP (at NIC)       │
                    │            ├─ OPTIONS + not allowed? ──► XDP_DROP        │
                    │            ├─ malformed REGISTER? ──► XDP_DROP           │
                    │            └─ else ──► XDP_PASS or redirect to AF_XDP    │
                    │                     │                                    │
                    │                     ▼                                    │
                    │            Kernel stack ──► OpenSIPS (SBC)                │
                    │                                │                         │
                    │                                │ (bad IP / event)        │
                    │                                ▼                         │
                    │                         RabbitMQ ◄── publish              │
                    │                                │                         │
                    │                                │ (consume)                │
                    │                                ▼                         │
                    │                    Blocklist updater (consumer)          │
                    │                                │                         │
                    │                                │ block_ip / file          │
                    │                                ▼                         │
                    │            XDP blocklist (blocked_ips map) ◄──────────────┘
                    └─────────────────────────────────────────────────────────┘
```

- **Inbound:** Traffic hits the NIC → XDP runs first (blocklist, stealth, malformed) → what’s left goes to the kernel and OpenSIPS.
- **Outbound to RabbitMQ:** OpenSIPS (as SBC or honeypot) decides “this source IP is bad” and publishes a message (e.g. “block 1.2.3.4”) to RabbitMQ.
- **Back to the NIC:** A consumer reads those messages and updates the XDP blocklist; the next packet from that IP is dropped at the NIC by XDP.

---

## 3. OpenSIPS → RabbitMQ

OpenSIPS can send “block this IP” (or threat events) to RabbitMQ in two main ways:

### 3.1 Event interface (event_rabbitmq)

Use the **event_rabbitmq** module so that when OpenSIPS raises an internal event (e.g. PIKE block, or a custom event), it is published to RabbitMQ.

- Configure a RabbitMQ socket and subscribe events to it (e.g. `E_PIKE_BLOCKED` or a custom event that includes the source IP).
- When the event fires, OpenSIPS publishes to RabbitMQ; a consumer can parse the message and add that IP to the blocklist.

### 3.2 Direct publish (rabbitmq module)

Use the **rabbitmq** module and call **`rabbitmq_publish()`** from the OpenSIPS script when you detect a bad source (e.g. after a failed auth, scan pattern, or honeypot trigger).

- Example: in `request_route` or a failure route, get `$si` (source IP), then `rabbitmq_publish(server_id, "blocklist", "{\"ip\":\"$si\"}")` (or a simple "IP" line).
- A consumer on the "blocklist" queue receives the message and updates the XDP blocklist.

Either way, RabbitMQ carries the “block this IP” (or “add these IPs”) signal from OpenSIPS to whatever service updates the blocklist.

---

## 4. RabbitMQ → Blocklist (consumer)

A **blocklist updater** process subscribes to the relevant queue(s) and, for each message:

1. Parse the message (e.g. extract IPv4 address or list of IPs).
2. Update the XDP blocklist:
   - **Single IP:** call `block_ip.sh <ip>` or equivalent (e.g. `bpf_map_update_elem` on `blocked_ips`).
   - **Bulk:** write IPs to a file (one per line) and run `block_ips_from_file.sh <file>`, or update the map in a loop.

The consumer can run on the **same host** as OpenSIPS and XDP (so it only needs to run `block_ip.sh` or update the map locally), or on another host that pushes the list to the host that has XDP loaded (e.g. via SSH + script, or a small API that the XDP host exposes). The important part is that the consumer’s action ends up updating the `blocked_ips` map (or the file that `block_ips_from_file.sh` reads) on the host where vos-fastpath is attached.

**Cluster:** To offload everywhere, run the blocklist updater on **every** cluster node (each updates its local BPF map from the same RabbitMQ queue or fan-out), so every node has the same blocklist. See [Cluster offload](CLUSTER-OFFLOAD.md).

---

## 5. End-to-End Loop (with Rabbit)

1. **First time:** Packet from IP `1.2.3.4` hits the NIC → XDP has no blocklist entry → passes to OpenSIPS. OpenSIPS (as SBC/honeypot) decides the source is bad and publishes to RabbitMQ (e.g. `{"action":"block","ip":"1.2.3.4"}`).
2. **Consumer:** Blocklist updater consumes the message and adds `1.2.3.4` to the XDP blocklist (e.g. `block_ip.sh 1.2.3.4`).
3. **Next time:** Packet from `1.2.3.4` hits the NIC → XDP finds it in the blocklist → **XDP_DROP** at the NIC. OpenSIPS and the kernel stack never see it.

So the stack **with RabbitMQ** gives you a closed loop: observe bad traffic in OpenSIPS (as SBC), publish to Rabbit, consumer updates the blocklist, and the NIC drops that traffic from then on.

---

## 6. Deployment Options

- **Single host:** OpenSIPS, RabbitMQ, and the blocklist-updater consumer all on the same box; XDP is loaded on the same box. Consumer runs `block_ip.sh` or updates the map directly.
- **Split:** OpenSIPS and RabbitMQ on one (or more) hosts; consumer on the host that has XDP loaded, consuming from RabbitMQ and updating the local blocklist. Or consumer on a separate “controller” host that pushes blocklist updates (e.g. file + `block_ips_from_file.sh` over SSH) to the XDP host.
- **Cluster:** Run XDP on every node and run the blocklist consumer on every node (same queue or fan-out). Each node updates its **local** `blocked_ips` map so the blocklist is identical everywhere. Alternatively, one consumer pushes updates to all nodes (e.g. `cluster_sync_blocklist.sh` or SSH). See [Offloading everything across a cluster](CLUSTER-OFFLOAD.md).

RabbitMQ’s role is to **decouple** “who observed the bad IP” (OpenSIPS) from “who updates the blocklist” (consumer on the XDP host), so you can scale or move components without changing the flow.

---

## 7. Summary

- **NIC → XDP → kernel → OpenSIPS:** vos-fastpath runs first and drops blocklisted, stealth, and malformed traffic at the NIC; the rest reaches OpenSIPS (as SBC).
- **OpenSIPS → RabbitMQ:** OpenSIPS publishes “block this IP” (or events) to RabbitMQ when it detects bad/suspicious sources.
- **RabbitMQ → blocklist:** A consumer updates the XDP blocklist (script or map), so subsequent packets from those IPs are dropped at the NIC.

That’s how it works in the stack with Rabbit: observation in OpenSIPS, messaging via RabbitMQ, and enforcement at the NIC by vos-fastpath.
