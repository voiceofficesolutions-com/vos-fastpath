# How to Feed Honeypot Data Into vos-fastpath

This doc describes **how you interact with vos-fastpath to provide honeypot (or threat-intel) data** so that bad IPs are dropped at the NIC.

---

## What the system expects

- **Blocklist:** A set of **IPv4 addresses**. Any UDP 5060 traffic from those IPs is dropped by XDP at the NIC (before the kernel stack or OpenSIPS).
- **Source of the list:** Your SBC honeypot, threat-intel feed, or any system that produces “these IPs are bad.”

---

## Three ways to provide the data

### 1. File (one IPv4 per line)

**Format:** Plain text file, one IPv4 per line. Empty lines and lines starting with `#` are ignored.

**Example file:**
```
192.168.1.100
10.0.0.50
# 203.0.113.1
```

**How to apply it:**

- **On this host (single node):**
  ```bash
  sudo ./scripts/block_ips_from_file.sh /path/to/your_blocklist.txt
  ```
  Each line is passed to `block_ip.sh`; each IP is added to the XDP `blocked_ips` map.

- **On every node (cluster):**
  ```bash
  export VOS_FASTPATH_CLUSTER_HOSTS="node1 node2 node3"
  sudo ./scripts/cluster_sync_blocklist.sh /path/to/your_blocklist.txt
  ```
  The file is copied to each host and `block_ips_from_file.sh` is run there so every node has the same blocklist.

**Typical flow:** Honeypot or threat-intel pipeline writes/export a file (e.g. daily or on event). Cron or a small job runs `block_ips_from_file.sh` (or `cluster_sync_blocklist.sh`) so the XDP blocklist is updated.

---

### 2. Single IP (script or API)

**Add one IP:**
```bash
sudo ./scripts/block_ip.sh 192.168.1.100
```

**Remove one IP:**
```bash
sudo ./scripts/unblock_ip.sh 192.168.1.100
```

Use this when you get a single “block this IP” signal (e.g. from an OpenSIPS event or a manual decision). For bulk, use the file method above.

---

### 3. Via RabbitMQ (OpenSIPS → consumer → blocklist)

When OpenSIPS (as SBC or honeypot) detects a bad source, it can publish “block this IP” to **RabbitMQ**. A **blocklist-updater consumer** on the host(s) running XDP consumes those messages and updates the blocklist.

**Flow:**
1. OpenSIPS sees bad/suspicious traffic → publishes to RabbitMQ (e.g. `{"ip":"1.2.3.4"}` or event_rabbitmq).
2. Consumer on the XDP host reads the queue and runs `block_ip.sh 1.2.3.4` (or updates the BPF map directly).
3. Next packet from that IP hits XDP → blocklist match → dropped at the NIC.

**Details:** See [Stack with RabbitMQ](STACK-WITH-RABBITMQ.md) for OpenSIPS → RabbitMQ → consumer and how to run the consumer on every cluster node so the blocklist stays in sync.

---

## Summary

| You have | How to feed it in |
|----------|--------------------|
| **File of IPs** (honeypot export, threat intel) | `block_ips_from_file.sh <file>` on each host, or `cluster_sync_blocklist.sh <file>` for the cluster. |
| **Single IP** (event or manual) | `block_ip.sh <ip>` on the XDP host. |
| **OpenSIPS (or SBC) detecting bad IPs** | Publish to RabbitMQ; consumer runs `block_ip.sh` or updates the map. Use same consumer (or sync) on every node for a cluster. |

The **interface** to vos-fastpath is: **IPs in a file** or **single IP** via scripts (or direct map update via bpftool/libbpf). Honeypot data is whatever produces that list or stream; you plug it in with one of the three methods above.
