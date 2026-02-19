# Centralized Control and Call Recovery

You need **centralized control** so one place (or a small, HA control plane) drives policy and topology across all nodes. And you want the same kind of resilience you had before: **lose a node (e.g. FreeSWITCH), recover the call on another node**. This doc describes how that fits with vos-fastpath and OpenSIPS.

---

## 1. What centralized control gives you

| Concern | Role of centralized control |
|--------|-----------------------------|
| **Policy (blocklist / allowlist)** | One source of truth. A central controller (or RabbitMQ consumer) pushes blocklist and allowlist to **all** nodes so every node drops and allows the same traffic. No node is a weak link. |
| **Topology** | Central view of which nodes exist, which are healthy, and where traffic should go. Drives load balancers, DNS, or OpenSIPS routing so traffic fails over when a node is lost. |
| **Call / session recovery** | Call recovery (e.g. “lose a FreeSWITCH node, recover the call on another”) is implemented in the **application layer** — OpenSIPS dialog state, FreeSWITCH/rtpengine, shared state (Redis/DB), and health-aware routing. Centralized control keeps **policy** in sync so whichever node picks up the call has the same XDP behavior. |

So: **centralized control** = one place that pushes policy to all nodes and can drive topology/failover; **call recovery** = application-layer HA (state, health, re-invite to another media node); **vos-fastpath** = same NIC-level policy on every node so when traffic fails over, the new node is already correct.

---

## 2. Centralized control in practice

### 2.1 Policy: one place, all nodes

- **RabbitMQ as backbone**  
  OpenSIPS (on any node) publishes “block this IP” to RabbitMQ. A **single** blocklist-updater service (your “controller”) consumes the queue and pushes to **all** nodes: e.g. SSH + `block_ip.sh`, or a small API on each node that updates the local BPF map. Result: one logical source of truth; all nodes get the same blocklist and allowlist. See [Stack with RabbitMQ](STACK-WITH-RABBITMQ.md) and [Cluster offload](CLUSTER-OFFLOAD.md) Option B (central updater).

- **Blocklist file + central push**  
  Maintain one blocklist file (e.g. from SBC honeypot or threat intel). A central job runs `cluster_sync_blocklist.sh` (or Ansible) to apply that file on every node. Same idea for allowlist if you use it.

- **Why it matters for failover**  
  When a node is lost and traffic (or the call) moves to another node, that node must drop and allow the **same** IPs. Centralized policy push ensures every node is in sync, so there’s no “recover to a node that has different policy.”

### 2.2 Topology and health

- **Central view of nodes**  
  Your control plane can maintain a list of SIP/OpenSIPS/FreeSWITCH nodes (or use service discovery). It can run health checks (e.g. SIP OPTIONS or HTTP to OpenSIPS MI) and mark nodes up/down.

- **Driving failover**  
  Use that view to:
  - Update a load balancer or DNS so SIP traffic goes only to healthy nodes.
  - Or drive OpenSIPS routing / dispatcher so dialogs and media are sent to live backends.

When a node is lost, the controller (or LB) stops sending new traffic to it and sends it to another node; existing calls are recovered by application-layer mechanisms (see below).

---

## 3. Losing a node and recovering the call on another

You used to have a setup where **losing a FreeSWITCH node** didn’t kill the call — it was **recovered on another node**. That behavior is achieved in the **SIP/application layer**, not in XDP:

| Layer | What handles “lose node, recover call” |
|-------|----------------------------------------|
| **Load balancing / routing** | LB or OpenSIPS dispatcher sends traffic to healthy nodes. When a node fails, health checks fail and traffic (new and, if supported, retried) goes to another node. |
| **Dialog / call state** | So that a **call** can be recovered (not just “next call goes elsewhere”), state must be shared or replicated: e.g. OpenSIPS dialog state in Redis/DB, or B2BUA/rtpengine that can re-anchor media to another FreeSWITCH/rtpengine node. |
| **Media (FreeSWITCH / rtpengine)** | Media path must fail over: e.g. re-INVITE to another FreeSWITCH or rtpengine instance so the media is re-established on a different node. That’s typically done by OpenSIPS (or your B2BUA) using shared state and dispatcher/list of media nodes. |

So: **call recovery** = shared or replicated dialog state + health-aware routing + re-INVITE (or equivalent) to another media node. vos-fastpath does not implement that; it ensures that **whatever node receives the traffic** applies the same NIC-level policy (blocklist, stealth, malformed drop).

### 3.2 How vos-fastpath fits

- **Same policy everywhere**  
  Centralized control pushes blocklist/allowlist to all nodes. So when a call fails over to node B (because node A was lost), node B’s XDP already blocks and allows the same IPs as node A. No policy gap.

- **Shortest path on every node**  
  Every node runs XDP (and optionally AF_XDP). So the node that recovers the call still gives you the shortest path to service delivery on that node.

- **Containers everywhere**  
  Same OpenSIPS (and optional FreeSWITCH/rtpengine) containers everywhere; central control keeps policy and topology consistent so you can “distribute containers everywhere” and still have one place in control and recover calls on another node when one is lost.

---

## 4. Summary

- **Centralized control** — One (or HA) control plane that pushes blocklist/allowlist to all nodes and can drive topology/health so traffic goes to healthy nodes and fails over when a node is lost.
- **Call recovery** — Implemented in the application layer (OpenSIPS, FreeSWITCH, rtpengine, shared state, re-INVITE). Centralized control keeps policy in sync so the node that recovers the call behaves the same as the one that was lost.
- **vos-fastpath** — Same XDP policy on every node; when you lose a node and recover the call on another, that other node already has the right NIC-level policy and shortest path.

For concrete patterns: policy push via RabbitMQ + central consumer (or `cluster_sync_blocklist.sh`) is in [Stack with RabbitMQ](STACK-WITH-RABBITMQ.md) and [Cluster offload](CLUSTER-OFFLOAD.md). Call/session recovery is in your OpenSIPS/FreeSWITCH/rtpengine design; centralized control is what keeps policy and topology consistent across all nodes.
