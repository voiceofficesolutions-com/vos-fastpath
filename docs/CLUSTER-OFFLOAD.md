# Offloading Everything Across a Cluster

To get **full offload across a cluster**, every node that receives SIP (UDP 5060) must run vos-fastpath (XDP) on its SIP-facing interface(s), and the **blocklist (and optionally allowlist) must be the same on every node**. Then every packet is filtered at the NIC on whichever node it hits—no node is a weak link.

---

## 1. Model: XDP is per-node

| Concept | What it means |
|--------|----------------|
| **XDP runs on the NIC** | Each server has its own NIC(s). XDP is attached **per interface, per host**. There is no single “cluster XDP”; each node runs its own XDP program. |
| **Offload “everywhere”** | Every cluster node that receives SIP must have XDP loaded on the interface where SIP arrives. Then **all** SIP traffic, on **all** nodes, is subject to blocklist, OPTIONS stealth, and malformed drop before the kernel stack or OpenSIPS. |
| **Maps are per-node** | The BPF maps (`blocked_ips`, `allowed_ips`) live in the kernel on each host. To have the same policy everywhere, you must **sync** blocklist (and allowlist) to every node. |

So “offload everything across the cluster” = **deploy XDP on every node** + **keep blocklist/allowlist identical on every node**.

---

## 2. Deploy XDP on every node

On **each** cluster node that receives SIP:

1. Build (or copy) the BPF object and deploy script, e.g.:
   - Build on each node: `make` then `sudo ./scripts/deploy.sh <sip_interface>`.
   - Or copy `build/sip_logic.bpf.o` and `scripts/deploy.sh` to each node and run `deploy.sh <sip_interface>` there.
2. Use the same interface name (e.g. `eth0`) or your automation’s interface list per node.

Repeat for every SIP-receiving interface if a node has more than one (e.g. bond members or multiple NICs). Optional: use Ansible, Salt, or a small init/systemd unit so XDP is loaded on boot on every node.

**Check:** On each node, run `sudo ./scripts/read_xdp_stats.sh` (and/or `ip link show <iface>` and look for `xdp`). If XDP is loaded, counters will show OPTIONS_DROPPED, BLOCKED, PASSED, etc.

---

## 3. Keep blocklist (and allowlist) in sync

If node A blocks IP `1.2.3.4` but node B does not, traffic to B from `1.2.3.4` still hits the stack and OpenSIPS on B. So **the same blocklist (and, if used, allowlist) must be applied on every node**.

### Option A: Blocklist updater on every node (recommended for RabbitMQ)

Run the **same blocklist-updater consumer on every cluster node**. Each consumer:

- Connects to the same RabbitMQ (same queue or a fan-out so every node gets a copy of each “block this IP” message).
- For each message, updates **only its local** BPF map (e.g. runs `block_ip.sh` or updates `blocked_ips` via bpftool on the same host).

Result: every node applies the same blocklist updates locally; no central “push” needed. See [Stack with RabbitMQ](STACK-WITH-RABBITMQ.md) for the OpenSIPS → RabbitMQ → consumer flow; in a cluster, run that consumer on **every** XDP node.

### Option B: Central updater pushes to all nodes

One process (or script) consumes RabbitMQ and, for each “block this IP” (or “load these IPs”):

- Updates a **shared blocklist file** (e.g. on NFS or object store), then triggers each node to apply it; or
- Pushes directly to each node: SSH to each host and run `block_ip.sh <ip>` (or `block_ips_from_file.sh <file>`), or call a small API on each node that updates the local map.

Result: one logical “source of truth,” but you must ensure every node is updated (retries, failure handling).

### Option C: Sync a blocklist file to all nodes

Maintain one blocklist file (e.g. from SBC honeypot export or threat intel). Periodically:

- Copy that file to every cluster node (e.g. rsync, Ansible, or config management).
- On each node, run `sudo ./scripts/block_ips_from_file.sh <file>` (and, if you use allowlist, your allowlist equivalent).

You can automate this with the provided **cluster sync script** (see below) or your own Ansible playbook.

---

## 4. Cluster blocklist sync script

The repo provides a script that applies the **same blocklist file** on multiple hosts via SSH, so every node’s XDP map gets the same set of blocked IPs.

- **Script:** `scripts/cluster_sync_blocklist.sh`
- **Usage:**  
  `sudo ./scripts/cluster_sync_blocklist.sh <blocklist_file> <host1> [host2 ...]`  
  Or set `VOS_FASTPATH_CLUSTER_HOSTS` (space-separated list) and pass only the file.
- **Remote path:** If the repo lives in a different path on the cluster nodes, set `VOS_FASTPATH_CLUSTER_REMOTE_PATH` (e.g. `/opt/vos-fastpath`) so the script runs the correct `block_ips_from_file.sh` on each host.

The script copies the file to each host and runs `block_ips_from_file.sh` there. Run it from a place that can SSH (and sudo) to all cluster nodes. Use it on a schedule (cron) or after updating the blocklist file so that **all nodes stay in sync**.

---

## 5. Allowlist (OPTIONS stealth)

If you use the OPTIONS stealth allowlist (`allowed_ips`), the same reasoning applies: for consistent behavior, **every node should have the same set of allowed IPs**. You can:

- Run the same “allowlist updater” on every node (e.g. consuming from a queue or reading a shared file), or
- Push allowlist updates to all nodes in the same way you push blocklist (e.g. `allow_ip.sh` via SSH or a small API).

Currently the repo provides `allow_ip.sh` per-node; extend your cluster automation to call it (or update `allowed_ips` map) on every node when the allowlist changes.

---

## 6. Summary checklist

| Requirement | Action |
|-------------|--------|
| XDP on every node | Run `deploy.sh <sip_interface>` on each cluster node (and on boot if desired). |
| Same blocklist everywhere | Use Option A (consumer on every node), B (central push), or C (sync file + `cluster_sync_blocklist.sh`). |
| Same allowlist everywhere (if used) | Propagate `allowed_ips` updates to all nodes in the same way you do blocklist. |
| Verify | On each node: `read_xdp_stats.sh`, and optionally send test traffic to each node and confirm blocked IPs are dropped on all of them. |

When all nodes run XDP and share the same blocklist (and allowlist), **everything is offloaded across the cluster**: every SIP packet is filtered at the NIC on the node that receives it, and no node accepts traffic that others would drop.

For **centralized control** (one place pushing policy to all nodes) and **call recovery** when a node is lost (e.g. FreeSWITCH failover), see [Centralized control and call recovery](CENTRALIZED-CONTROL.md). For the bigger picture — same containers and BPF in multiple datacenters, edge, or clusters — see [Distribute these containers everywhere](DISTRIBUTE-EVERYWHERE.md).
