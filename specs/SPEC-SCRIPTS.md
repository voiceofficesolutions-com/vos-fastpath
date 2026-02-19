# Specification — Scripts Reference

This document specifies **every script** in `scripts/`: synopsis, usage, arguments, exit codes, dependencies, and examples. All scripts are Bash; they use `set -e` unless noted.

---

## 1. deploy.sh — Load XDP on interface

**Path:** `scripts/deploy.sh`

**Synopsis:**  
Load the vos-fastpath XDP program on a network interface. Tries **native XDP** first; on failure, tries **generic (SKB) XDP**.

**Usage:**
```bash
sudo ./scripts/deploy.sh <interface> [xdp_object]
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `interface` | Yes | Network interface name (e.g. `eth0`). |
| `xdp_object` | No | Path to BPF object. Default: `build/sip_logic.bpf.o`. |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | XDP loaded (native or generic). |
| 1 | Missing interface argument, object file not found, or both native and generic load failed. |

**Dependencies:**  
- Root (or CAP_NET_ADMIN / CAP_BPF).  
- BPF object must exist (run `make` first).  
- `ip` (iproute2).  
- Optional: `ethtool` for logging driver name.

**Examples:**
```bash
make
sudo ./scripts/deploy.sh eth0
sudo ./scripts/deploy.sh eth0 /path/to/sip_logic.bpf.o
```

---

## 2. read_xdp_stats.sh — Print XDP counters

**Path:** `scripts/read_xdp_stats.sh`

**Synopsis:**  
Read the `xdp_counters` BPF map, sum per-CPU values for each key, and print human-readable lines.

**Usage:**
```bash
sudo ./scripts/read_xdp_stats.sh
```

**Arguments:** None.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success; counters printed. |
| 1 | `bpftool` not found, or map `xdp_counters` not found (XDP not loaded). |

**Dependencies:**  
- Root (to access BPF maps).  
- `bpftool`.  
- Optional: `jq` for JSON parsing (script falls back to awk if jq missing).

**Output (example):**
```
XDP counters (map id 12):
  OPTIONS dropped (stealth): 100
  Blocked (DoS list):        5
  Malformed (dropped):       2
  Redirected (AF_XDP):      0
  Passed to stack:          50
  Total UDP 5060 handled:   157
```

---

## 3. allow_ip.sh — Add IP to stealth allowlist

**Path:** `scripts/allow_ip.sh`

**Synopsis:**  
Add an IPv4 address to the `allowed_ips` map so that SIP OPTIONS from that IP are not dropped by the stealth logic.

**Usage:**
```bash
sudo ./scripts/allow_ip.sh <ipv4_address>
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `ipv4_address` | Yes | Dotted-decimal IPv4 (e.g. `10.99.0.2`). |

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | IP added successfully. |
| 1 | Not root, missing argument, invalid IPv4, map not found, or bpftool update failed. |

**Dependencies:**  
- Root.  
- `bpftool`.  
- XDP program loaded (so `allowed_ips` map exists).

**Example:**
```bash
sudo ./scripts/allow_ip.sh 10.99.0.2
```

---

## 4. block_ip.sh — Add IP to blocklist

**Path:** `scripts/block_ip.sh`

**Synopsis:**  
Add an IPv4 to the `blocked_ips` map. All UDP 5060 traffic from this IP is dropped at XDP (DoS mitigation).

**Usage:**
```bash
sudo ./scripts/block_ip.sh <ipv4_address>
```

**Arguments:** Same as `allow_ip.sh` (single IPv4).

**Exit codes:** Same pattern: 0 = success, 1 = usage/privilege/map/update failure.

**Dependencies:** Root, bpftool, XDP loaded.

**Example:**
```bash
sudo ./scripts/block_ip.sh 192.168.1.100
```

---

## 5. unblock_ip.sh — Remove IP from blocklist

**Path:** `scripts/unblock_ip.sh`

**Synopsis:**  
Remove an IPv4 from the `blocked_ips` map (delete key).

**Usage:**
```bash
sudo ./scripts/unblock_ip.sh <ipv4_address>
```

**Arguments:** One IPv4.

**Exit codes:**  
- 0: Unblocked (or key not in map but delete succeeded).  
- 1: Not root, missing argument, invalid IP, map not found, or delete failed.

**Example:**
```bash
sudo ./scripts/unblock_ip.sh 192.168.1.100
```

---

## 6. block_ips_from_file.sh — Bulk load blocklist

**Path:** `scripts/block_ips_from_file.sh`

**Synopsis:**  
Read a file with one IPv4 per line and call `block_ip.sh` for each. Intended for SBC honeypot exports or threat-intel lists. Lines starting with `#` and empty lines are skipped.

**Usage:**
```bash
sudo ./scripts/block_ips_from_file.sh <file>
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `file` | Yes | Path to text file; one IPv4 per line. |

**Exit codes:**  
- 0: Script completed (see summary for added/skipped/failed counts).  
- 1: Not root, missing/invalid file.

**Dependencies:** Root, `block_ip.sh` in same directory, bpftool, XDP loaded.

**Output (example):**
```
Done: 100 blocked, 2 skipped (invalid), 0 failed (map full or not loaded).
```

**Example:**
```bash
sudo ./scripts/block_ips_from_file.sh /path/to/honeypot_ips.txt
```

---

## 7. cluster_sync_blocklist.sh — Sync blocklist to cluster nodes

**Path:** `scripts/cluster_sync_blocklist.sh`

**Synopsis:**  
Copy a blocklist file to one or more remote hosts and run `block_ips_from_file.sh` there so every node has the same blocklist. Hosts can be passed as arguments or via `VOS_FASTPATH_CLUSTER_HOSTS`.

**Usage:**
```bash
sudo ./scripts/cluster_sync_blocklist.sh <blocklist_file> [host1 host2 ...]
# Or:
export VOS_FASTPATH_CLUSTER_HOSTS="node1 node2 node3"
sudo ./scripts/cluster_sync_blocklist.sh <blocklist_file>
```

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `blocklist_file` | Yes | Local path; same format as for `block_ips_from_file.sh`. |
| `host1 host2 ...` | No | Remote hostnames or IPs. If omitted, uses `VOS_FASTPATH_CLUSTER_HOSTS`. |

**Environment:**

| Variable | Description |
|----------|-------------|
| `VOS_FASTPATH_CLUSTER_HOSTS` | Space-separated list of hosts (used if no positional hosts). |
| `VOS_FASTPATH_CLUSTER_REMOTE_PATH` | Path to repo on remote (default: same as local `REPO_ROOT`). |

**Exit codes:**  
- 0: All hosts updated successfully.  
- 1: Not root, missing file, no hosts, or at least one host failed (copy or remote script).

**Dependencies:** Root, `scp`, `ssh`, remote host has repo and sudo for `block_ips_from_file.sh`.

**Example:**
```bash
export VOS_FASTPATH_CLUSTER_HOSTS="sip-node-1 sip-node-2"
sudo ./scripts/cluster_sync_blocklist.sh /tmp/blocklist.txt
```

---

## 8. enable_busy_poll.sh — Set busy poll sysctl

**Path:** `scripts/enable_busy_poll.sh`

**Synopsis:**  
Set `net.core.busy_poll` to 50 (microseconds) to allow busy polling on sockets (e.g. AF_XDP / OpenSIPS) for lower latency. Run before starting OpenSIPS if desired.

**Usage:**
```bash
sudo ./scripts/enable_busy_poll.sh
```

**Arguments:** None.

**Exit codes:** 0 on success; non-zero if sysctl fails.

**Dependencies:** Root.

**Persistence:** Script reminds to add the line to `/etc/sysctl.conf` for reboot persistence.

---

## 9. pin_opensips_cores.sh — Pin OpenSIPS to CPUs

**Path:** `scripts/pin_opensips_cores.sh`

**Synopsis:**  
Pin OpenSIPS processes to CPUs 4–7 (tuned for AMD Ryzen 7 4750U second CCX). Run after OpenSIPS is up.

**Usage:**
```bash
sudo ./scripts/pin_opensips_cores.sh [pid_or_empty]
```
If no argument: finds processes matching `opensips` via `pgrep -f opensips`. If argument given: use that PID (or space-separated PIDs).

**Arguments:** Optional: one or more PIDs. Default: discover via `pgrep -f opensips`.

**Exit codes:**  
- 0: At least one process pinned.  
- 1: No OpenSIPS process found (or invalid PID).

**Dependencies:** Root, `taskset`, `pgrep`.

**Example:**
```bash
sudo ./scripts/pin_opensips_cores.sh
sudo ./scripts/pin_opensips_cores.sh $(pgrep -f opensips)
```

---

## 10. sip_sim_setup.sh — Create SIP simulation (namespace + veth + XDP)

**Path:** `scripts/sip_sim_setup.sh`

**Synopsis:**  
Create a network namespace `sip-sim`, a veth pair (`veth-sip` on host, `veth-sim` in namespace), assign IPs (host 10.99.0.1, sim 10.99.0.2), and load the XDP program on `veth-sip`. Used to generate UDP 5060 traffic that hits XDP without another physical host.

**Usage:**
```bash
sudo ./scripts/sip_sim_setup.sh
```

**Arguments:** None.

**Exit codes:**  
- 0: Namespace, veth, and XDP are up.  
- 1: Not root, or BPF object not found, or XDP load failed (script cleans up on failure).

**Dependencies:** Root, `build/sip_logic.bpf.o` (run `make` first), `ip` (iproute2).

**Idempotence:** If `sip-sim` namespace already exists, script removes it and the veth pair first, then recreates.

---

## 11. sip_sim_send.sh — Send simulated SIP traffic

**Path:** `scripts/sip_sim_send.sh`

**Synopsis:**  
From the `sip-sim` namespace, send UDP packets to 10.99.0.1:5060: `count` OPTIONS and `count` REGISTER (minimal SIP first lines). Used after `sip_sim_setup.sh` to drive XDP counters.

**Usage:**
```bash
sudo ./scripts/sip_sim_send.sh [count]
```

**Arguments:**  
- `count`: Optional; default 10. Number of OPTIONS and number of REGISTER to send.

**Exit codes:**  
- 0: Sent (or namespace missing; script exits 1 if namespace not found).  
- 1: Not root or namespace `sip-sim` not found.

**Dependencies:** Root, namespace `sip-sim` (run `sip_sim_setup.sh` first), `nc` (netcat) in the namespace.

---

## 12. sip_sim_teardown.sh — Remove SIP simulation

**Path:** `scripts/sip_sim_teardown.sh`

**Synopsis:**  
Unload XDP from `veth-sip`, delete the veth pair, and delete the `sip-sim` namespace. Safe to run even if setup was not run.

**Usage:**
```bash
sudo ./scripts/sip_sim_teardown.sh
```

**Arguments:** None.

**Exit codes:** 0.

**Dependencies:** Root, `ip`.

---

## 13. stress_test.sh — Stress and correctness test

**Path:** `scripts/stress_test.sh`

**Synopsis:**  
Multi-phase test: teardown any existing sim, setup sim + XDP, run volume, blocklist, allowlist, and hammer phases, then teardown. Verifies counter consistency and that block/allow behave as specified. Used for reliability validation.

**Usage:**
```bash
sudo ./scripts/stress_test.sh [hammer_rounds]
```

**Arguments:**  
- `hammer_rounds`: Optional; default 2. Rounds of volume phase (each round: 30 OPTIONS + 30 REGISTER).

**Exit codes:**  
- 0: All phases passed.  
- 1: Not root, BPF object missing, or any phase failed (assertions on counter deltas).

**Dependencies:** Root, `make` (build), `sip_sim_setup.sh`, `sip_sim_send.sh`, `sip_sim_teardown.sh`, `read_xdp_stats.sh`, `block_ip.sh`, `unblock_ip.sh`, `allow_ip.sh`, `nc`.

**Make target:** `make test` runs `stress_test.sh 1`.

---

## 14. Summary table

| Script | Purpose | Typical use |
|--------|---------|-------------|
| `deploy.sh` | Load XDP on interface | After build; production or test |
| `read_xdp_stats.sh` | Print XDP counters | Monitoring; after sim or live traffic |
| `allow_ip.sh` | Allow OPTIONS from IP | Stealth allowlist |
| `block_ip.sh` | Block all UDP 5060 from IP | DoS blocklist |
| `unblock_ip.sh` | Remove IP from blocklist | Unblock |
| `block_ips_from_file.sh` | Bulk block from file | Honeypot / threat intel |
| `cluster_sync_blocklist.sh` | Sync blocklist to cluster | Multi-node policy |
| `enable_busy_poll.sh` | Set busy_poll sysctl | Tuning before OpenSIPS |
| `pin_opensips_cores.sh` | Pin OpenSIPS to CPUs 4–7 | Tuning after OpenSIPS start |
| `sip_sim_setup.sh` | Create sim namespace + veth + XDP | Test environment |
| `sip_sim_send.sh` | Send OPTIONS + REGISTER from sim | Generate test traffic |
| `sip_sim_teardown.sh` | Remove sim | Cleanup after test |
| `stress_test.sh` | Full reliability test | CI or manual validation |

---

## 15. References

- [SPEC-MAPS.md](SPEC-MAPS.md) — Maps updated by allow/block scripts and read by read_xdp_stats.
- [SPEC-BUILD-DEPLOY.md](SPEC-BUILD-DEPLOY.md) — Build and deploy order (make → deploy.sh → OpenSIPS).
