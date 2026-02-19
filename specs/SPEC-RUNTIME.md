# Specification — Runtime (Docker, OpenSIPS, Tuning)

This document specifies the **runtime** environment: Docker Compose, OpenSIPS configuration, network mode, mounts, and optional tuning (busy poll, CPU pinning).

---

## 1. Docker Compose

**Path:** `docker-compose.yml`

### 1.1 Service: opensips

| Attribute | Value | Meaning |
|-----------|--------|---------|
| **image** | `opensips/opensips:3.4` | Official OpenSIPS 3.4. |
| **container_name** | `vos-fastpath-opensips` | Fixed name for scripts/tools. |
| **privileged** | `true` | Required for BPF map access (e.g. if OpenSIPS or helpers need to touch `/sys/fs/bpf` or XDP). |
| **network_mode** | `host` | Container shares host network; no NAT; OpenSIPS listens on host’s UDP 5060 (and same netns as XDP). |
| **restart** | `unless-stopped` | Restart on failure or reboot unless manually stopped. |

### 1.2 Volumes

| Host path | Container path | Mode | Purpose |
|-----------|----------------|------|---------|
| `/sys/fs/bpf` | `/sys/fs/bpf` | rw | BPF filesystem; required if OpenSIPS (or a sidecar) attaches AF_XDP or accesses pinned maps. |
| `./opensips.cfg` | `/etc/opensips/opensips.cfg` | ro | Main OpenSIPS config. |

### 1.3 Environment

- `OPENSIPS_EXTRA_ARGS` — Empty by default; can pass extra CLI args to the OpenSIPS process.

### 1.4 Prerequisites (host)

- XDP program **loaded** on the SIP interface (e.g. `sudo ./scripts/deploy.sh eth0`). Otherwise traffic is not filtered by XDP; OpenSIPS still receives UDP 5060 from the stack.
- BPF filesystem mounted: `mount -t bpf bpf /sys/fs/bpf` (often already done by systemd or init). Docker mounts host’s `/sys/fs/bpf` into the container.

---

## 2. OpenSIPS configuration

**Path:** `opensips.cfg` (mounted at `/etc/opensips/opensips.cfg`)

### 2.1 Listen directive

- **Current (default):** `listen = udp:0.0.0.0:5060`  
  OpenSIPS listens on UDP 5060 on all interfaces. With `network_mode: host`, this is the host’s 0.0.0.0:5060. Traffic that XDP returns with `XDP_PASS` reaches this socket.

- **AF_XDP (draft/placeholder):**  
  When OpenSIPS is built with AF_XDP listener support, you can switch to zero-copy from XDP:
  ```text
  listen = afxdp:eth0:5060
  ```
  Then OpenSIPS would create AF_XDP sockets and attach them to the XDP program’s `xsks_map` (by queue_id). Redirected traffic would go to OpenSIPS without passing through the kernel stack.

### 2.2 Routing (placeholder)

- `request_route` calls `route(REQUESTS)`.
- `route[REQUESTS]`: if method is `INVITE|REGISTER|SUBSCRIBE|OPTIONS`, then `return;` (handle or relay as you extend). Otherwise `return;`.

This is a minimal stub; production config would add logic for registration, dialog, and media.

---

## 3. Network and packet path

- **Host and container share the same network namespace** (`network_mode: host`).
- **XDP** is attached to a **host** interface (e.g. `eth0`). It runs in the kernel before the stack.
- **UDP 5060** that XDP **passes** goes to the kernel stack; OpenSIPS (in the same netns) receives it on its UDP socket.
- **UDP 5060** that XDP **redirects** goes to an AF_XDP socket when one is present in `xsks_map`; that socket would be created by OpenSIPS if using `listen = afxdp:...`.
- **Dropped** traffic (OPTIONS stealth, blocklist, malformed) never reaches the stack or OpenSIPS.

---

## 4. Tuning scripts (runtime)

### 4.1 enable_busy_poll.sh

- **When:** Before starting OpenSIPS (or before heavy load).
- **Effect:** `sysctl -w net.core.busy_poll=50` — allows up to 50 µs busy wait on socket receive, reducing latency for AF_XDP / UDP.
- **Persistence:** Add `net.core.busy_poll=50` to `/etc/sysctl.conf` for reboot persistence.

### 4.2 pin_opensips_cores.sh

- **When:** After OpenSIPS is running.
- **Effect:** Pins OpenSIPS processes to CPUs 4–7 (intended for AMD Ryzen 7 4750U second CCX). Reduces cache bouncing and can improve throughput.
- **Override:** Edit the script to change `CPUS="4,5,6,7"` for your topology.

---

## 5. Running order (summary)

1. Build: `make`
2. Optional: `sudo ./scripts/enable_busy_poll.sh`
3. Load XDP: `sudo ./scripts/deploy.sh eth0` (or your interface)
4. Start OpenSIPS: `docker-compose up -d`
5. Optional: `sudo ./scripts/pin_opensips_cores.sh`
6. Policy: allow_ip / block_ip / block_ips_from_file as needed
7. Monitor: `sudo ./scripts/read_xdp_stats.sh`

---

## 6. Stopping and cleanup

- **OpenSIPS:** `docker-compose down`
- **XDP:** `sudo ip link set dev eth0 xdp off` (or `xdpgeneric off` if loaded in generic mode)
- **BPF maps** are destroyed when the XDP program is detached; no separate cleanup needed for maps.

---

## 7. References

- [SPEC-BUILD-DEPLOY.md](SPEC-BUILD-DEPLOY.md) — Build and deploy flow.
- [SPEC-SCRIPTS.md](SPEC-SCRIPTS.md) — enable_busy_poll.sh, pin_opensips_cores.sh.
- [existing-opensips-integration.md](existing-opensips-integration.md) — Adding fastpath to an existing OpenSIPS install.
