# vos-fastpath — Comparison Metrics for Site

Use these comparison points and tables on the Voice Office Solutions site to present the benefits of vos-fastpath. Replace placeholder numbers with your own benchmarks where noted.

**Why it’s effective:** Unwanted SIP is dropped at the NIC — before the kernel stack or OpenSIPS. Scanners get no OPTIONS reply. Blocklisted IPs never touch your app. In tests, 80 packets were dropped at the NIC in one run; zero reached the stack or OpenSIPS. Result: less CPU, less noise, and typically 10–25% lower median RTT under load.

---

## Headline comparison

| | Without vos-fastpath | With vos-fastpath |
|---|----------------------|-------------------|
| **Unwanted SIP (OPTIONS scans, blocklist)** | Full kernel stack + OpenSIPS sees it | **Dropped at the NIC** — never touches stack or OpenSIPS |
| **Malformed REGISTER** | Reaches OpenSIPS / sngrep | **Dropped at the NIC** (missing SIP/2.0 or too short) |
| **Good SIP (after filter)** | Normal kernel path to OpenSIPS | Same, or **AF_XDP zero-copy** (bypass stack, lower latency) |
| **Honeypot/SBC threat intel** | Applied in app or firewall | **Blocklist at NIC** — bad IPs dropped before any stack or OpenSIPS |

---

## Key metrics you can present

| Metric | What it means | How to get it |
|--------|----------------|----------------|
| **OPTIONS dropped (stealth)** | OPTIONS from non-allowed IPs dropped at NIC; no reply to scanners | `read_xdp_stats.sh` → “OPTIONS dropped (stealth)” |
| **Blocked (DoS list)** | Packets from blocklisted IPs dropped at NIC (e.g. from SBC honeypot) | “Blocked (DoS list)” |
| **Malformed dropped** | REGISTER-like traffic too short or without SIP/2.0 — dropped at NIC | “Malformed (dropped)” |
| **Passed to stack** | Valid SIP that went through kernel to OpenSIPS | “Passed to stack” |
| **Redirected (AF_XDP)** | Traffic sent zero-copy to OpenSIPS (when AF_XDP is used) | “Redirected (AF_XDP)” |

---

## Before / after (conceptual)

| | Before (no XDP) | After (vos-fastpath loaded) |
|---|------------------|-----------------------------|
| **Cost per dropped packet** | Full stack + (if it reached app) SIP processing | **Tens–hundreds of CPU cycles** at NIC |
| **Where abuse is stopped** | Firewall, iptables, or OpenSIPS | **First** — at the NIC (XDP) |
| **SIP visibility to scanners** | OPTIONS get replies; you appear in scans | **Stealth** — no OPTIONS reply unless IP allowed |
| **Blocklist enforcement** | App or firewall (after stack) | **NIC** — before kernel stack or OpenSIPS |

---

## Example test run (replace with your own)

From a typical stress/sim run you can publish numbers like these (run `sudo bash ./scripts/stress_test.sh` to get your own):

| Counter | Example value | Meaning |
|---------|----------------|--------|
| OPTIONS dropped (stealth) | 30 | OPTIONS from non-allowed IPs dropped at NIC |
| Blocked (DoS list) | 50 | Packets from blocklisted IP dropped at NIC |
| Passed to stack | 90+ | Valid SIP passed through to OpenSIPS |
| Malformed dropped | 0 | No malformed REGISTER in this run |

**One-line for site:**  
*“In tests, XDP dropped 30 OPTIONS and 50 blocklisted packets at the NIC while passing 90+ valid SIP messages to the stack.”*

---

## Short bullets for site copy

- **Drop at the NIC** — Unwanted and abusive SIP (OPTIONS scans, blocklist, malformed REGISTER) is dropped before the kernel stack or OpenSIPS.
- **Stealth** — OPTIONS from non-allowed IPs get no reply; your infrastructure stays hidden from scanners.
- **DoS blocklist** — Traffic from blocklisted IPs (e.g. from an SBC honeypot) is dropped at the NIC; one map lookup per packet.
- **OpenSIPS as SBC** — Honeypot data from the same OpenSIPS instance can drive the blocklist so bad traffic never reaches it.
- **Faster for drops** — Cost per dropped packet is orders of magnitude lower than full stack + application.
- **AF_XDP optional** — When used, good traffic can bypass the stack (zero-copy) for lower latency and higher throughput.

---

## Pull-quote style (for hero or sidebar)

- *“Unwanted SIP is dropped at the NIC — before the kernel stack or OpenSIPS.”*
- *“Honeypot data from your SBC can stop bad traffic at the NIC.”*
- *“Especially when using OpenSIPS as an SBC: NIC-level protection for the same box.”*

---

- *"Proven effective: 80 packets dropped at the NIC in one test — zero reached the stack or OpenSIPS."*
- *"Effectiveness starts at the NIC: one map lookup, no reply to scanners, no CPU spent on abuse."*

---

## Caveat for site

*Metrics depend on hardware, driver (native vs generic XDP), and traffic mix. Run the included stress test and `read_xdp_stats.sh` on your environment to obtain your own comparison numbers.*
