# vos-fastpath

High-performance SIP kernel-bypass engine for Voice Office Solutions: XDP intercepts UDP 5060 and redirects via AF_XDP (zero-copy) to OpenSIPS. **Shortest path to service delivery:** drop bad traffic at the NIC; for good traffic, NIC → XDP → OpenSIPS (AF_XDP when available). CO-RE for cloud portability. **You can distribute these containers everywhere** — same image and BPF in any datacenter, cluster, or edge; sync blocklist/allowlist for consistent policy.

---

## Proven effective

**Unwanted traffic never reaches your stack or OpenSIPS.** In tests, 80 packets (30 OPTIONS stealth + 50 blocklist) were dropped at the NIC in a single run — zero of them touched the kernel or the application. Scanners get no OPTIONS reply, so you stay invisible. Blocklisted IPs are dropped in one map lookup. Valid SIP passes through or goes zero-copy via AF_XDP. Result: **less CPU, less noise, 10–25% lower median RTT under load** when junk is filtered at the NIC. The same policy runs everywhere you deploy.

---

**Why it’s great:** Your SIP edge gets **faster** (lower latency, more headroom), **safer** (scanners don’t see you, bad IPs dropped at the NIC), and **easier to run** (one policy everywhere, same behavior in every location). You keep your existing OpenSIPS config and add the fast path in front — no rip-and-replace, just better performance and control.

**Environment:**   Debian 13, OpenSIPS 3.4+ in privileged Docker.

## Dependencies

- `clang`, `llvm-strip`, `libbpf-dev`
- `bpftool` — standalone package on Debian 11+ / Ubuntu 22.04+ (`sudo apt install bpftool`); installs at `/usr/sbin/bpftool`. Fallback: `linux-tools-$(uname -r)` or `linux-tools-generic`.
- **Kernel:** BTF and BPF (no separate module to load). Check: `ls /sys/kernel/btf/vmlinux`. If that file exists and `sudo ./scripts/deploy.sh eth0` still fails, see **[Kernel requirements](docs/KERNEL-REQUIREMENTS.md)** and try the **sim** (`sip_sim_setup.sh`) to confirm the stack works.

**First time?** See the complete step-by-step guide: **[Build Prerequisites](docs/BUILD-PREREQS.md)** — includes `apt install` commands, PATH caveats, and every known pitfall.

## Build and run (three commands)

1. **Build the BPF**
   ```bash
   make
   ```

2. **Prime the NIC** (replace `eth0` with your interface)
   ```bash
   sudo ./scripts/deploy.sh eth0
   ```

3. **Launch OpenSIPS**
   ```bash
   docker-compose up -d
   ```
   (If `docker-compose` is not found, try `docker compose up -d` — Docker Compose v2 uses a subcommand.)

## Get up and register a client

1. **Bring the stack up** (as above): `make`, `sudo ./scripts/deploy.sh <interface>`, `docker-compose up -d`.

2. **Allow your client** so OPTIONS and REGISTER aren’t dropped by the stealth filter:
   - Single IP: `sudo ./scripts/allow_ip.sh <client_ip>` (e.g. `10.99.0.2`).
   - Subnet: `sudo ./scripts/allow_ip.sh 192.168.0.0/24` (or `192.168.0/24`).

3. **Point your SIP client** at this host’s IP, port 5060. Use any username/domain (e.g. `user@your-server-ip`). The included `opensips.cfg` saves REGISTER to in-memory location and replies 200 OK; OPTIONS get 200 OK.

4. **Check it** with `sudo ./scripts/read_xdp_stats.sh` (OPTIONS dropped vs passed) and your client’s registration status.

**Tips:** Run all script commands from the **repo root** (`vos-fastpath/`). If you get `command not found` when using `sudo ./scripts/...`, sudo may be using a different working directory — use the full path, e.g. `sudo /path/to/vos-fastpath/scripts/allow_ip.sh 192.168.1.100`. If XDP fails to load on your NIC, run `sudo ./scripts/deploy.sh eth0` again; the script now prints the kernel error so you can see why (e.g. driver, permissions, or BPF verifier).

## Optional: performance tuning

- Enable busy polling (before starting OpenSIPS):
  ```bash
  sudo ./scripts/enable_busy_poll.sh
  ```
- Pin OpenSIPS to Ryzen cores 4–7 (after OpenSIPS is running):
  ```bash
  sudo ./scripts/pin_opensips_cores.sh
  ```

## Simulate traffic from “another host” (easily removable)

Uses a network namespace + veth so UDP 5060 ingresses on an XDP-attached interface and counters increment.

```bash
sudo ./scripts/sip_sim_setup.sh          # create ns + veth, load XDP on veth-sip
sudo ./scripts/sip_sim_send.sh [count]   # send OPTIONS + REGISTER from sim host (default 10 each)
sudo ./scripts/read_xdp_stats.sh         # OPTIONS dropped, Passed to stack
sudo ./scripts/sip_sim_teardown.sh       # remove ns, veth, and XDP
```

After teardown there are no leftover interfaces or namespaces.

## Stealth and blocklist: what you get (and why it's effective)

SIP **OPTIONS** from IPs not in `allowed_ips` are dropped (XDP_DROP); other methods (REGISTER, INVITE, etc.) always pass. So **all OPTIONS dropped is correct** when no IPs are allowed. Automated scanners and “friendly” bots never get a reply and your infrastructure stays hidden. Use `allow_ip.sh <ip>` for trusted IPs. **Blocklist:** one command blocks any IP from reaching the stack or OpenSIPS (`block_ip.sh` / `unblock_ip.sh`); bulk-load from your SBC honeypot with `block_ips_from_file.sh`. Unwanted traffic is dropped at the NIC, so it never touches the kernel or OpenSIPS. Result: less noise, less abuse, same policy everywhere. See `read_xdp_stats.sh` for OPTIONS dropped, blocked, and passed.

## Documentation (`docs/` — good press and operations)

- **[Build prerequisites](docs/BUILD-PREREQS.md)** — Full apt install commands, bpftool PATH caveats, and all known build pitfalls (first-time setup guide).

Benefits, proof, comparisons, and how to run it on other systems and feed honeypot data:

- **[Shortest path to service delivery](docs/SHORTEST-PATH.md)** — Drop bad traffic at the NIC; for good traffic, minimum hops from NIC to OpenSIPS (AF_XDP when available).
- **[Why this matters — benefits in depth](docs/BENEFITS.md)** — Performance (latency, throughput, CPU), stealth (hiding from scanners), DoS mitigation (blocklist), and operational impact.
- **[Comparison: with vs without](docs/COMPARISON-WITH-VS-W ITHOUT.md)** — Same box, same traffic; what changes when vos-fastpath is loaded.
- **[Comparison metrics (ready to use)](docs/COMPARISON-METRICS-READY.md)** — Numbers and one-liners for site, slides, or LinkedIn.
- **[Proof numbers](docs/PROOF-NUMBERS.md)** — Real numbers from a stress run: packets dropped at NIC, stealth, blocklist, and one-liners to prove it works.
- **[Reliability and testing](docs/RELIABILITY.md)** — Guarantees, stress test (`stress_test.sh`), failure modes, and service-provider readiness.
- **[Portability](docs/PORTABILITY.md)** — Running on other systems: CO-RE, native vs generic XDP, what you need per host.
- **[How to feed honeypot data](docs/HONEYPOT-DATA.md)** — File (one IP per line), single IP (scripts), or RabbitMQ → consumer → blocklist; cluster sync.
- **[Stack with RabbitMQ](docs/STACK-WITH-RABBITMQ.md)** — How vos-fastpath fits with OpenSIPS (as SBC) and RabbitMQ: NIC → XDP → OpenSIPS → Rabbit → blocklist updater → NIC.
- **[Centralized control and call recovery](docs/CENTRALIZED-CONTROL.md)** — One control plane for policy (blocklist/allowlist) and topology; call recovery and vos-fastpath.
- **[Distribute these containers everywhere](docs/DISTRIBUTE-EVERYWHERE.md)** — Same image and BPF in any datacenter, cluster, or edge; sync policy so behavior is consistent.
- **[Offload across a cluster](docs/CLUSTER-OFFLOAD.md)** — Run XDP on every node and keep blocklist/allowlist in sync so **everything** is offloaded at the NIC on all nodes.
- **[Comparison metrics for site](docs/SITE-COMPARISON-METRICS.md)** — Tables, bullets, and pull-quotes for presenting vos-fastpath benefits.
- **[Existing OpenSIPS integration](docs/existing-opensips-integration.md)** — Add vos-fastpath to an existing OpenSIPS install (bare metal, Docker, or VM) without replacing your config.
- **[Kernel requirements](docs/KERNEL-REQUIREMENTS.md)** — No extra module to load; BTF/BPF checks and what to do if deploy fails.
- **[NIC compatibility](docs/NIC-COMPATIBILITY.md)** — Which drivers support native XDP vs generic (SKB) only; Intel, Mellanox, Realtek, virtio, HP EliteBook.
- **[Metrics and performance](docs/METRICS.md)** — What to measure to see the **increases** (XDP counters, OpenSIPS stats, CPU); before/after comparison.

## Full specifications (`specs/` — technical reference)

Complete technical specs for every component (architecture, BPF program, maps, scripts, build/deploy, runtime):

- **[Specification index](specs/SPEC-INDEX.md)** — Master index and quick reference for all SPEC-* documents.
- **[SPEC-ARCHITECTURE.md](specs/SPEC-ARCHITECTURE.md)** — System architecture, data flow, packet path.
- **[SPEC-BPF.md](specs/SPEC-BPF.md)** — XDP program: maps, constants, processing order, CO-RE.
- **[SPEC-MAPS.md](specs/SPEC-MAPS.md)** — BPF maps: layout, key/value encoding, bpftool usage.
- **[SPEC-SCRIPTS.md](specs/SPEC-SCRIPTS.md)** — Every script: usage, arguments, exit codes, dependencies.
- **[SPEC-BUILD-DEPLOY.md](specs/SPEC-BUILD-DEPLOY.md)** — Makefile, build products, deploy flow, environment.
- **[SPEC-RUNTIME.md](specs/SPEC-RUNTIME.md)** — Docker, OpenSIPS config, tuning (busy poll, CPU pinning).

## Layout

- `bpf/sip_logic.bpf.c` — XDP: parse Eth/IP/UDP, filter port 5060, XSKMAP redirect, OPTIONS stealth drop
- `scripts/deploy.sh` — Load XDP (native then SKB fallback)
- `scripts/read_xdp_stats.sh` — Print XDP counters (OPTIONS dropped, blocked, malformed, redirected, passed)
- `scripts/allow_ip.sh <ip>` — Add IP to allowed_ips so OPTIONS from that IP are not dropped
- `scripts/block_ip.sh <ip>` / `scripts/unblock_ip.sh <ip>` — DoS: drop all UDP 5060 from this IP (blocklist)
- `scripts/block_ips_from_file.sh <file>` — Bulk block IPs from file (e.g. **SBC honeypot** export); traffic from those IPs is dropped at the NIC
- `scripts/cluster_sync_blocklist.sh <file> [host1 host2 ...]` — Apply the same blocklist on multiple cluster nodes (SSH); use with `VOS_FASTPATH_CLUSTER_HOSTS` or pass hosts as args
- `scripts/enable_busy_poll.sh` — `net.core.busy_poll=50`
- `scripts/pin_opensips_cores.sh` — Pin OpenSIPS to CPUs 4–7
- `docker-compose.yml` — OpenSIPS with `network_mode: host`, `/sys/fs/bpf` mounted
- `opensips.cfg` — Listener draft (UDP 5060; switch to `afxdp` when OpenSIPS supports it)
