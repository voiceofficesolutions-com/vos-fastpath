# Distribute These Containers Everywhere

The same OpenSIPS + vos-fastpath pattern can run **everywhere** you need it: multiple datacenters, edge sites, Kubernetes clusters, or standalone hosts. One image and one BPF object type; deploy and sync policy so behavior is consistent across all locations.

---

## Why it works everywhere

| Aspect | What it means |
|--------|----------------|
| **Containers** | OpenSIPS runs in Docker (or your orchestrator) with `network_mode: host` and access to `/sys/fs/bpf`. The same image runs on any Linux host that meets the requirements. |
| **CO-RE BPF** | The XDP program is **Compile Once – Run Everywhere**. One BPF object (`sip_logic.bpf.o`) loads on any kernel with BTF (e.g. Debian 12, typical cloud kernels). No recompile per kernel or driver. |
| **XDP per host** | XDP is attached to the host’s NIC. Wherever you run the container, you load the same BPF on that host’s SIP interface. Same program, same behavior. |
| **Policy sync** | Blocklist and allowlist are in BPF maps on each host. Use your existing automation (RabbitMQ consumers, `cluster_sync_blocklist.sh`, or config management) to keep the same policy across all deployed nodes. |

So: **distribute the same containers (and BPF) everywhere**; keep policy in sync so every location drops the same bad traffic and allows the same good traffic.

---

## Where you can run them

- **Single host** — One server, one interface, one container. Easiest starting point.
- **Cluster** — Many nodes in one site; XDP on every node, same blocklist/allowlist. See [Cluster offload](CLUSTER-OFFLOAD.md).
- **Multi-datacenter / multi-region** — Same image and BPF in each DC; each site has its own XDP and maps; sync policy (e.g. from a central RabbitMQ or shared blocklist file) so all sites share the same blocklist/allowlist.
- **Edge** — Deploy the same container + XDP on edge nodes; minimal footprint, same shortest-path and stealth behavior.

---

## Practical checklist

1. **Same image** — Use the same OpenSIPS image (e.g. `opensips/opensips:3.4`) and the same `opensips.cfg` (or parameterize per site if needed).
2. **Same BPF** — Build once, copy `build/sip_logic.bpf.o` and `scripts/deploy.sh` to each host (or build from same source in CI and ship the artifact).
3. **Load XDP on each host** — On every node that receives SIP, run `sudo ./scripts/deploy.sh <sip_interface>` (at boot or via Ansible/similar).
4. **Start the container on each host** — `docker-compose up -d` (or your orchestrator) so OpenSIPS runs with host network and BPF access.
5. **Sync policy** — Keep blocklist (and allowlist) identical across all nodes: RabbitMQ consumer per node, or push updates with `cluster_sync_blocklist.sh` / your automation.

Result: **containers and XDP distributed everywhere**, with the same shortest path to service delivery and the same policy at every location.
