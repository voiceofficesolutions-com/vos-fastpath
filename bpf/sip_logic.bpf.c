// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define SIP_PORT 5060
#define SIP_VERSION_LEN 7
#define MAX_SIP_LOOKUP 64
#define MIN_SIP_PAYLOAD 20

/* Maps */
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __type(key, __u32);
    __type(value, __u32);
    __uint(max_entries, 64);
} xsks_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH); 
    __type(key, __u32);
    __type(value, __u8);
    __uint(max_entries, 1024);
} blocked_ips SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HASH);
    __type(key, __u32);
    __type(value, __u8);
    __uint(max_entries, 256);
} allowed_ips SEC(".maps");

enum xdp_counter {
    XDP_OPTIONS_DROPPED = 0,
    XDP_REDIRECTED,
    XDP_PASSED,
    XDP_BLOCKED,
    XDP_MALFORMED,
    XDP_COUNT_MAX
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __type(key, __u32);
    __type(value, __u64);
    __uint(max_entries, XDP_COUNT_MAX);
} xdp_counters SEC(".maps");

static __always_inline void increment_counter(__u32 counter_id) {
    __u64 *val = bpf_map_lookup_elem(&xdp_counters, &counter_id);
    if (val) *val += 1;
}

SEC("xdp")
int sip_xdp_prog(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    __u32 queue_id = ctx->rx_queue_index;

    struct ethhdr *eth = data;
    if ((void*)(eth + 1) > data_end) return XDP_PASS;
    if (eth->h_proto != bpf_htons(0x0800)) return XDP_PASS;

    struct iphdr *ip = (void*)(eth + 1);
    if ((void*)(ip + 1) > data_end) return XDP_PASS;
    if (ip->protocol != IPPROTO_UDP) return XDP_PASS;

    __u32 src_ip = ip->saddr;
    struct udphdr *udp = (void*)((__u32*)ip + ip->ihl);
    if ((void*)(udp + 1) > data_end) return XDP_PASS;
    if (udp->dest != bpf_htons(SIP_PORT)) return XDP_PASS;

    /* 1. Blocklist Check (Zero-Contention) */
    if (bpf_map_lookup_elem(&blocked_ips, &src_ip)) {
        increment_counter(XDP_BLOCKED);
        return XDP_DROP;
    }

    unsigned char *payload = (unsigned char *)(udp + 1);
    if ((void *)(payload + MIN_SIP_PAYLOAD) > data_end) return XDP_PASS;

    /* 2. Stealth OPTIONS Check */
    if (payload[0] == 'O' && payload[1] == 'P' && payload[2] == 'T') {
        if (!bpf_map_lookup_elem(&allowed_ips, &src_ip)) {
            increment_counter(XDP_OPTIONS_DROPPED);
            return XDP_DROP;
        }
    }

    /* 3. Universal SIP Sieve: Search for "SIP/2.0" in any valid method (INVITE, etc) */
    int found = 0;
    #pragma unroll
    for (__u32 i = 0; i < MAX_SIP_LOOKUP - SIP_VERSION_LEN; i++) {
        if ((void *)(payload + i + SIP_VERSION_LEN) > data_end) break;
        if (payload[i] == 'S' && payload[i+1] == 'I' && payload[i+2] == 'P' && 
            payload[i+3] == '/' && payload[i+4] == '2' && payload[i+5] == '.' && 
            payload[i+6] == '0') {
            found = 1;
            break;
        }
    }

    if (!found) {
        increment_counter(XDP_MALFORMED);
        return XDP_DROP;
    }

    /* 4. Redirect via AF_XDP */
    if (bpf_map_lookup_elem(&xsks_map, &queue_id)) {
        increment_counter(XDP_REDIRECTED);
        return bpf_redirect_map(&xsks_map, queue_id, 0);
    }

    increment_counter(XDP_PASSED);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
