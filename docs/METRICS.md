# Metrics and Performance — What to Measure and How

This document describes the metrics you can use to see the **increases** from vos-fastpath (XDP + stealth + optional AF_XDP): what to collect, how to read them, and how to compare before/after.

---

## 1. XDP counters (built into the BPF program)

The SIP XDP program exposes **per-CPU counters** in the map `xdp_counters`:

| Key | Name              | Meaning |
|-----|-------------------|--------|
| 0   | OPTIONS_DROPPED   | SIP OPTIONS packets dropped by the stealth module (non-allowed IPs) |
| 1   | REDIRECTED        | UDP 5060 packets redirected to an AF_XDP socket (zero-copy path) |
| 2   | PASSED            | UDP 5060 packets passed to the kernel stack (no XSK in map, or allowed OPTIONS) |
| 3   | BLOCKED           | UDP 5060 packets dropped by the DoS blocklist (`blocked_ips` map) |
| 4   | MALFORMED         | Dropped: payload &lt; 20 bytes, or no "SIP/2.0" in first 64 bytes (garbage / malformed SIP) |

**How to read (sum across CPUs):**

- Use the provided script (recommended):
  ```bash
  sudo ./scripts/read_xdp_stats.sh
  ```
- Or manually with bpftool:
  ```bash
  # List maps and find id for "xdp_counters"
  bpftool map list | grep xdp_counters
  # Dump map (replace ID with the id from above)
  bpftool map dump id <ID>
  ```
  For each key, the value is per-CPU; sum the numbers for the total.

**What “increases” you get:**

- **OPTIONS_DROPPED** — High value means the stealth module is hiding you from scanners (those requests never hit OpenSIPS or the rest of the stack).
- **BLOCKED** — DoS blocklist drops; traffic from those IPs never reaches the stack.
- **MALFORMED** — REGISTER (and similar) that are too short or lack "SIP/2.0" in the first line are dropped so they never reach OpenSIPS or sngrep.
- **REDIRECTED** — When using AF_XDP listeners, this is the fast-path volume; compare to **rcv_requests** in OpenSIPS to see share of traffic on the bypass.
- **PASSED** — Traffic that still went through the kernel; with no AF_XDP socket, most SIP will be PASSED.

---

## 2. Interface and kernel stack metrics

Use these to see packet and drop behaviour at the NIC and IP stack.

| Source | What to look at |
|--------|------------------|
| **ethtool -S \<iface\>** | `rx_packets`, `rx_dropped`, `rx_missed_errors` — see if NIC drops change with XDP. |
| **ip -s link show \<iface\>** | RX/TX packets and drops. |
| **nstat -az** (or **netstat -s**) | UDP and IP layer stats: `UdpInDatagrams`, `UdpNoPorts`, `IpInReceives`, etc. |

**Before/after:**

- With XDP in place, some UDP 5060 traffic may be **redirected** (not seen as normal UDP in the stack) or **dropped** (OPTIONS). So stack-side “UDP in” can be lower than line rate; that’s expected and shows the fast path and stealth are active.

---

## 3. OpenSIPS statistics (application layer)

OpenSIPS exposes counters via the **Management Interface (MI)**. These are the main “business” metrics.

| Metric | Meaning |
|--------|---------|
| **rcv_requests** | SIP requests received by OpenSIPS (total). |
| **rcv_replies** | SIP replies received. |
| **fwd_requests** / **fwd_replies** | Forwarded traffic. |
| **drop_requests** / **drop_replies** | Dropped by OpenSIPS. |
| **err_requests** | Errored (e.g. parse/validation). |

**How to read:**

- MI command (e.g. over FIFO or HTTP, depending on your config):
  ```text
  get_statistics rcv_requests rcv_replies
  ```
- Or list all:
  ```text
  list_statistics
  ```
- If you use the **Prometheus** module, the same counters are exposed as HTTP metrics for scraping.

**What “increases” you get:**

- With **stealth**: OPTIONS from scanners never reach OpenSIPS, so **rcv_requests** does not include those; you get **fewer** useless requests and lower load.
- With **AF_XDP**: Same **rcv_requests** (or more if you handle more load), but with **lower CPU per packet** and often **higher requests/sec** and **lower latency** because of kernel bypass.

---

## 4. CPU and throughput

| What | How |
|------|-----|
| **CPU per core** | `top`, `htop`, or `pidstat -p <opensips_pid>`. Pin OpenSIPS to cores 4–7 and watch those. |
| **Requests per second** | Derive from OpenSIPS **rcv_requests** over time (e.g. MI `get_statistics` every second and diff). |
| **Latency** | SIP round-trip or one-way with a test tool (e.g. sipp, custom script) comparing with and without XDP/AF_XDP. |

**What “increases” you get:**

- **Lower CPU** for the same SIP load when using AF_XDP (fewer kernel path and copies).
- **Higher max rcv_requests/sec** and **lower latency** under load when the fast path is used.

---

## 5. Before/after comparison (summary)

1. **Baseline (no XDP):** Note `rcv_requests` rate, CPU of OpenSIPS, and optionally `ethtool -S` / `ip -s link` for the SIP interface.
2. **Load XDP (stealth only):** Run `deploy.sh`, keep UDP listener. Check `read_xdp_stats.sh`: **OPTIONS_DROPPED** should increase for scanner traffic; **PASSED** should match the rest of SIP; **rcv_requests** should be lower (no OPTIONS from scanners).
3. **With AF_XDP (when available):** Add AF_XDP listener; **REDIRECTED** should increase and **PASSED** decrease for that interface. Compare **rcv_requests/sec** and CPU again — you should see **increases in useful metrics** (throughput, efficiency) and **decreases** in cost (CPU, noise from OPTIONS).

Use the **XDP counters** plus **OpenSIPS stats** and **CPU** to quantify these increases in your environment.

---

## 6. How to know it’s faster (proof for OpenSIPS and the rest)

You know it’s faster by comparing the **same workload** with and without XDP, and by using the counters to show that traffic is handled earlier (at the NIC) instead of by the stack and OpenSIPS.

### What “faster” means here

| Situation | How it’s faster |
|-----------|------------------|
| **Dropped traffic** (OPTIONS, blocklist, malformed) | Packets never reach the kernel stack or OpenSIPS. Cost is a few dozen–hundred CPU cycles at the NIC instead of full stack + OpenSIPS. So **OpenSIPS and the rest do less work** — that’s the speedup. |
| **Passed traffic** (valid SIP) | Same path as without XDP (kernel → OpenSIPS). You add a small XDP filter cost; the gain is that **all the bad traffic was already dropped**, so OpenSIPS sees only useful traffic and uses less CPU overall. |
| **Redirected traffic** (AF_XDP) | Packets bypass the normal kernel path and go zero-copy to OpenSIPS. **Lower latency and higher throughput** than the normal socket path for that traffic. |

### What to measure

1. **XDP counters** — `sudo ./scripts/read_xdp_stats.sh`  
   - **OPTIONS_DROPPED + BLOCKED + MALFORMED** = packets that **never** touched the stack or OpenSIPS. The higher these are (under the same line rate), the more work you’re not doing in the stack and in OpenSIPS.
2. **OpenSIPS** — MI `get_statistics rcv_requests` (or Prometheus) over time.  
   - With XDP dropping bad traffic, **rcv_requests** should be **lower** for the same incoming SIP rate (fewer useless requests), and OpenSIPS CPU can be **lower**.
3. **CPU** — `top` / `htop` or `pidstat -p <opensips_pid>`.  
   - Compare OpenSIPS CPU and system CPU **with XDP** vs **without XDP** under the same load.
4. **Latency (RTT)** — Use SIPp (e.g. `-trace_rtt` / `-trace_stat`) or another SIP tester to measure median and 95th percentile response time with and without XDP. With XDP dropping junk at the NIC, **RTT for good traffic typically decreases** (e.g. 10–25%) under load. See **Proof Numbers — Latency** in [PROOF-NUMBERS.md](PROOF-NUMBERS.md#latency-decreases-you-can-cite) for indicative numbers and how to get your own.

### Simple before/after test

1. **Baseline (no XDP):** Start OpenSIPS, send a fixed load (e.g. SIPp or your sim) for 60 seconds. Note: **rcv_requests** (total or per second), **OpenSIPS CPU %**, and optionally **system UDP/softirq**.
2. **Stop load.** Load XDP: `sudo ./scripts/deploy.sh <iface>`.
3. **With XDP:** Send the **same** load again for 60 seconds. Note: **rcv_requests**, **OpenSIPS CPU %**, and run **`read_xdp_stats.sh`** — note OPTIONS_DROPPED, BLOCKED, MALFORMED, PASSED.
4. **Compare:**  
   - If you had OPTIONS/blocklist/malformed in the load: **rcv_requests** with XDP should be **lower** (those never reached OpenSIPS), and OpenSIPS CPU should be **lower or similar** while handling only the traffic that passed.  
   - The **difference** in rcv_requests (or in CPU) is the “faster” — work that no longer hits OpenSIPS or the stack.

### One-line proof

**“XDP counters show N packets dropped at the NIC (OPTIONS + blocked + malformed). Those N packets never reached the kernel stack or OpenSIPS, so OpenSIPS and the rest of the stack did less work — that’s the speedup.”** When you use AF_XDP, **“Redirected”** is the traffic that took the faster path (bypass stack, zero-copy); compare throughput and CPU for that path vs the normal socket path to show it’s faster.
