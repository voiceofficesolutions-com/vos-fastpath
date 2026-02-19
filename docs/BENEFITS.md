# Why vos-fastpath Matters — Benefits in Depth

Here’s the good news: running SIP through vos-fastpath gives you **better performance**, **stronger security**, and **simpler operations** without replacing OpenSIPS. You get a shorter path to service delivery, you drop bad traffic at the NIC (so it never bothers your stack or your app), and you keep one clear policy everywhere you deploy. This document spells out **why** that’s a win: latency and throughput, stealth and DoS mitigation, and how it all fits together.

**Effectiveness in one sentence:** Unwanted SIP is dropped at the NIC — before the kernel stack or OpenSIPS — so scanners get no reply, blocklisted IPs never touch your app, and valid traffic gets more headroom and often 10–25% lower median RTT under load.

---

## 1. The Problem: Where SIP Packets Go Today

In a typical deployment without XDP, every SIP packet (UDP 5060) that hits your server follows the **full kernel path**:

1. **NIC** → driver RX ring → kernel allocates an skb (socket buffer).
2. **Network stack** — IP layer (routing, optionally iptables/nftables) → UDP → demux to socket.
3. **Socket** — copy from kernel to user space into OpenSIPS’s receive buffer.
4. **OpenSIPS** — parse SIP, run routing logic, possibly forward or respond.

Each step costs **CPU**, **memory bandwidth**, and **latency**. Under load, the kernel can become the bottleneck: softirq, context switches, and lock contention add up. Worse, **every** packet is treated the same — including OPTIONS scans from the internet and traffic from IPs you already know are abusive. You pay the full cost for traffic you would rather never process at all.

vos-fastpath changes the game by handling traffic **as early as possible**: in the driver or in generic XDP, before the rest of the stack (and, when using AF_XDP, before the normal socket path). The payoff is real: less work for junk traffic, a faster path for good traffic, and one place to enforce policy across every node.

---

## 2. Performance Benefits: Latency, Throughput, and CPU

### 2.1 First Line of Defense Is Also the Fastest

You get the best of both worlds: say “no” to bad traffic **before** it costs you anything. XDP runs at the **earliest point** where the kernel sees the packet — either in the driver (native XDP) or right after the generic receive path (SKB/generic XDP). That means:

- **Minimum work per packet** — No full IP/UDP stack traversal for packets you drop (stealth OPTIONS, blocklist). No socket allocation, no copy to user space. The packet is discarded before it consumes meaningful resources.
- **Predictable cost** — A single, small BPF program with a few map lookups and a byte comparison is orders of magnitude cheaper than going through the stack and into OpenSIPS. Under attack or heavy scan traffic, the **cost of saying “no”** is almost negligible.

So the first benefit is a big one: **reducing load**. By dropping unwanted traffic at XDP, you free CPU and memory for the traffic you actually care about — your real calls and registrations get the headroom they deserve.

### 2.2 AF_XDP Zero-Copy: Bypassing the Stack for Good Traffic

When you use AF_XDP with zero-copy:

- Packets that **pass** the filter (and, when configured, are **redirected**) go **directly from the NIC’s ring into a user-space buffer** that OpenSIPS (or another process) can read.
- The **kernel network stack is skipped** for that data path: no skb allocation, no UDP demux, no socket copy. That means:
  - **Lower latency** — Fewer hops and fewer copies between hardware and application.
  - **Higher throughput** — The same CPU can process more SIP messages per second because the per-packet overhead is much smaller.
  - **Better CPU efficiency** — Cycles that would go into the kernel and into copying are instead available for OpenSIPS logic and for handling more calls.

So the second performance benefit is just as good: **for the traffic you keep**, you get a faster, more efficient path when the stack supports it (right driver + AF_XDP listener). Lower latency and higher throughput with the same hardware — that’s the win.

### 2.3 Putting Numbers in Perspective

Exact gains depend on hardware, driver (native vs generic XDP), and workload. Conceptually:

- **Dropped traffic (stealth + blocklist)** — Cost is a few dozen to low hundreds of CPU cycles per packet at XDP, versus full stack + (if it reached OpenSIPS) SIP parsing and routing. Under a heavy OPTIONS scan or DoS, that difference can mean the difference between a responsive server and one that is overloaded.
- **Good traffic (AF_XDP path)** — Zero-copy redirect avoids one or more full copy operations and stack processing per packet. That typically translates to higher max throughput and lower latency under load, so you can **handle more concurrent calls or more requests per second** on the same hardware, or use smaller/cheaper instances for the same workload.

So the performance story is simple and positive: **pay almost nothing for bad traffic**, and **pay less per packet for good traffic** when using the fast path. More headroom, happier users.

---

## 3. Stealth Benefits: Hiding from Scanners and Reducing Noise

### 3.1 Why OPTIONS Matter

SIP **OPTIONS** is often used for:

- **Discovery and scanning** — Automated tools send OPTIONS to find SIP servers, versions, and capabilities. Once you respond, you appear on lists and become a target for attacks, spam, and further probing.
- **“Friendly” keepalives** — Some upstream or monitoring systems send OPTIONS. You may want to allow those from known IPs and drop the rest.

If you answer OPTIONS from **everyone**, you are effectively advertising: “Here is a SIP server.” That increases your attack surface and generates a lot of useless traffic (replies, retries, follow-up probes) that consumes CPU and bandwidth.

### 3.2 What Stealth Does for You

The stealth module in vos-fastpath drops **OPTIONS from any source IP that is not in the `allowed_ips` map**. So:

- **Scanners get no reply** — From their perspective, the host either doesn’t exist or doesn’t speak SIP. You never appear in their results. Your infrastructure is **invisible** to broad internet scans.
- **No CPU spent on them** — The packet is dropped at XDP. OpenSIPS never sees it. No parsing, no routing, no response. The “cost” of the request is the tiny XDP program execution.
- **You choose who can see you** — By adding trusted IPs (e.g. your SBC, monitoring, or partner) to `allowed_ips`, only those hosts get OPTIONS replies. Everyone else is ignored.

So the benefit is **security and peace of mind**: smaller footprint, less noise, and you decide who is allowed to discover or probe your SIP layer. Scanners move on; your real traffic gets the attention.

---

## 4. DoS Mitigation Benefits: Blocklist at the Earliest Point

### 4.1 Why “Filter by IP” Helps Against DoS

Many SIP DoS or abuse patterns come from a **limited set of source IPs** (or you quickly identify bad actors by IP). If you can **drop all traffic from those IPs** before it uses any significant resource, you:

- **Protect the kernel stack** — Packets never reach IP/UDP processing, socket allocation, or iptables rules for that flow. The attack is stopped at the NIC/driver boundary.
- **Protect OpenSIPS** — No sockets, no parsing, no routing logic for that traffic. Your proxy keeps CPU and memory for legitimate calls.
- **Scale the defense** — A single map lookup in BPF is extremely cheap. You can block hundreds or thousands of IPs without adding noticeable overhead. The **cost of the attack to the attacker** (sending packets) stays the same, but the **cost to you** (processing them) drops to almost zero.

### 4.2 How the Blocklist Fits In

The **blocklist** (`blocked_ips`) is checked **as soon as** the XDP program has identified a UDP packet to port 5060. If the source IP is in the map, the packet is **dropped immediately** (XDP_DROP). No OPTIONS logic, no redirect, no pass to the stack. So:

- **First line of defense** — Before iptables, before OpenSIPS, before any other software. The packet is discarded at the earliest possible point in the kernel.
- **Dynamic** — You can add or remove IPs at runtime with `block_ip.sh` / `unblock_ip.sh` (map update/delete). No reload of the XDP program, no restart of OpenSIPS. That lets you react quickly to new attackers or unblock IPs that were added by mistake.
- **Visible** — The **Blocked (DoS list)** counter in `read_xdp_stats.sh` tells you how many packets were dropped by the blocklist. That gives you a direct measure of how much attack or abuse traffic you are deflecting.

So the benefit is **effective, low-cost DoS mitigation**: bad IPs are neutralized before they can load the stack or the application, and you keep full control and visibility. One map update and that IP is gone from every node — no restarts, no drama.

---

## 5. Operational and Business Benefits

### 5.1 Fits Into Existing OpenSIPS Deployments

vos-fastpath is designed to sit **in front of** OpenSIPS, not replace it:

- You keep your existing **opensips.cfg**, routing logic, and integrations. No need to reimplement SIP semantics in the kernel.
- You can enable the fast path **gradually**: start with stealth and blocklist only (traffic still goes to OpenSIPS via the normal socket). When you’re ready, add an AF_XDP listener and get the zero-copy performance gain.
- The **same BPF program** can run on your real NIC (e.g. `deploy.sh eth0`) or on a veth in a simulation. So you get one consistent behavior in production and in test.

That means **low adoption risk** and **incremental benefit**: you can start with “drop OPTIONS and block a few IPs” and only later turn on the full AF_XDP path.

### 5.2 One Place to Enforce Policy

With XDP you centralize **early policy** in one place:

- **Who is allowed to get OPTIONS replies?** → `allowed_ips`.
- **Who is never allowed to reach OpenSIPS on 5060?** → `blocked_ips`.
- **What goes to the fast path?** → Whatever passes the above and is redirected to the AF_XDP socket.

So you get **clear, auditable behavior**: one program, a few maps, and simple scripts to update them. That simplifies operations and makes it easier to reason about security and performance.

### 5.3 Capacity and Cost

Because you:

- **Drop** unwanted and abusive traffic at minimal cost, and  
- **Process** good traffic more efficiently when using AF_XDP,

you can often:

- **Handle more load** on the same hardware (more calls, more registrations, more messages per second), or  
- **Use smaller or fewer instances** for the same workload, reducing cloud or server cost.

So the benefit is also **economic**: better utilization and the option to scale down or delay scaling up.

### 5.4 Compliance and Risk

- **Smaller attack surface** — Invisible to generic SIP scanners; no OPTIONS replies to the internet at large. That can help with security reviews and compliance narratives (e.g. “we do not expose SIP to arbitrary probes”).
- **Resilience** — Under DoS or heavy scanning, the XDP layer absorbs most of the load. OpenSIPS and the rest of the system stay stable, which supports availability and SLA.

### 5.5 Honeypot on an SBC → block at the NIC

The integration is **geared to a honeypot on an SBC (Session Border Controller)**. The SBC (or a honeypot component on it) sees malicious or suspicious SIP traffic and records the source IPs. Export that list and feed it into the XDP blocklist; from then on, all UDP 5060 from those IPs is **dropped at the NIC** before the kernel stack or OpenSIPS.

- **Flow:** SBC honeypot observes bad/suspicious sources → export IPs to a file (or API) → on the host running XDP, run `block_ips_from_file.sh <file>` (or a daemon that updates the map). Those IPs are then blocked at the earliest point — the NIC.
- **Topology:** The SBC may be in front of OpenSIPS (e.g. SBC at the edge, OpenSIPS behind it). Push the blocklist from the SBC (or a central collector that aggregates SBC honeypot data) to the host(s) that run vos-fastpath — e.g. the same box as OpenSIPS or a dedicated edge node. Cron, CI, or a small sync service can keep the blocklist updated.
- **Result:** Threat intel from the **SBC honeypot** becomes **NIC-level drops** on real SIP traffic; bad actors never reach your SIP stack or OpenSIPS.

Use **`scripts/block_ips_from_file.sh`** to bulk-load IPs from a file (one per line), e.g. export from your SBC honeypot or threat-intel feed.

**Especially when using OpenSIPS as an SBC:** the same OpenSIPS instance that handles your edge traffic can participate in (or sit behind) a honeypot/sensor role. Bad IPs observed there are fed into the XDP blocklist so that traffic from those IPs is **dropped at the NIC** before it ever reaches OpenSIPS. You get NIC-level protection for the very box that is acting as your SBC — a major benefit when OpenSIPS is your session border.

---

## 6. How It All Fits Together

A useful way to see the benefits is to think in **layers**:

| Layer        | What happens there                         | Benefit                          |
|-------------|---------------------------------------------|----------------------------------|
| **XDP (earliest)** | Blocklist → Stealth OPTIONS → Redirect/Pass | DoS and scan traffic dropped here; good traffic can bypass the stack (AF_XDP). |
| **Kernel stack**   | IP, UDP, sockets (only for PASSED traffic)  | Sees less load; only traffic you didn’t drop or redirect. |
| **OpenSIPS**       | SIP logic, routing, dialogs                | Sees only traffic you chose to keep; optionally via fast path. |

So:

- **Security** — Stealth + blocklist at XDP = less exposure and less impact from abuse.
- **Performance** — Fewer packets in the stack and in OpenSIPS; when using AF_XDP, lower latency and higher throughput for the rest.
- **Operations** — One program, a few scripts, clear counters, and the ability to add or remove IPs at runtime without restarts.

Together, that’s why vos-fastpath is such a strong win: it makes your SIP edge **faster, safer, and easier to control**, without replacing the application you already trust. You keep what works and add a layer that pays off every day — better latency, less abuse, and one policy everywhere you run it.
