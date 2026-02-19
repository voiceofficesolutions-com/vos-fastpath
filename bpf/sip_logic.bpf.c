// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
// vos-fastpath: XDP SIP sieve + AF_XDP redirect + Stealth OPTIONS filter
// CO-RE; use vmlinux.h from bpftool btf dump.

#include "bpf_types.h"
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#ifndef ETH_P_IP
#define ETH_P_IP 0x0800
#endif

#define SIP_PORT 5060
#define OPTIONS_LEN 8   /* "OPTIONS " */
#define REGISTER_LEN 9  /* "REGISTER " */
#define MIN_REGISTER_LEN 20
#define SIP_VERSION "SIP/2.0"
#define SIP_VERSION_LEN 7
#define MAX_FIRST_LINE 64
#define MIN_SIP_PAYLOAD 20   /* drop garbage shorter than this */
#define MAX_SIP_LOOKUP 64    /* require SIP/2.0 in first N bytes or drop (same as first line) */

/* AF_XDP socket map: queue_id -> XSK FD (populated from user space) */
struct {
	__uint(type, BPF_MAP_TYPE_XSKMAP);
	__type(key, __u32);
	__type(value, __u32);
	__uint(max_entries, 64);
} xsks_map SEC(".maps");

/* Stealth: allowed source IPs for SIP OPTIONS (single IP per entry) */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, __u32);   /* IPv4 addr */
	__type(value, __u8);  /* 1 = allowed */
	__uint(max_entries, 256);
} allowed_ips SEC(".maps");

/* DoS: blocklist — drop all UDP 5060 from these IPs before stack/OpenSIPS */
struct {
	__uint(type, BPF_MAP_TYPE_HASH);
	__type(key, __u32);   /* IPv4 addr */
	__type(value, __u8);  /* 1 = blocked */
	__uint(max_entries, 1024);
} blocked_ips SEC(".maps");

/* Per-CPU counters for metrics (sum in user space) */
enum xdp_counter {
	XDP_OPTIONS_DROPPED = 0,
	XDP_REDIRECTED,
	XDP_PASSED,
	XDP_BLOCKED,       /* DoS: dropped by blocklist */
	XDP_MALFORMED,     /* REGISTER/request missing SIP/2.0 or too short */
	XDP_COUNT_MAX
};
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__type(key, __u32);
	__type(value, __u64);
	__uint(max_entries, XDP_COUNT_MAX);
} xdp_counters SEC(".maps");

SEC("xdp")
int sip_xdp_prog(struct xdp_md *ctx)
{
	void *data_end = (void *)(long)ctx->data_end;
	void *data     = (void *)(long)ctx->data;
	__u32 queue_id = ctx->rx_queue_index;

	struct ethhdr *eth;
	struct iphdr *ip;
	struct udphdr *udp;
	unsigned char *payload;
	__u32 src_ip;
	__u8 *allowed;
	__u8 *blocked;
	__u32 key;
	int off;

	/* L2 */
	off = sizeof(*eth);
	if (data + off > data_end)
		return XDP_PASS;
	eth = data;
	if (eth->h_proto != bpf_htons(ETH_P_IP))
		return XDP_PASS;

	/* L3 */
	data += off;
	off = sizeof(*ip);
	if (data + off > data_end)
		return XDP_PASS;
	ip = data;
	if (ip->ihl < 5 || ip->version != 4)
		return XDP_PASS;
	src_ip = ip->saddr;
	off = ip->ihl * 4;
	if (data + off > data_end)
		return XDP_PASS;

	/* L4 UDP */
	data += off;
	off = sizeof(*udp);
	if (data + off > data_end)
		return XDP_PASS;
	udp = data;
	if (udp->dest != bpf_htons(SIP_PORT))
		return XDP_PASS;
	/* Sanity: UDP length must be at least header size (no overflow) */
	if (udp->len < bpf_htons(sizeof(*udp)))
		return XDP_PASS;

	/* DoS: drop all UDP 5060 from blocklisted IPs (before stack/OpenSIPS) */
	key = src_ip;
	blocked = bpf_map_lookup_elem(&blocked_ips, &key);
	if (blocked) {
		__u32 k = XDP_BLOCKED;
		__u64 *v = bpf_map_lookup_elem(&xdp_counters, &k);
		if (v)
			*v += 1;
		return XDP_DROP;
	}

	payload = (unsigned char *)(data + off);
	/* Stealth: drop SIP OPTIONS from IPs not in allowed_ips */
	if ((void *)(payload + OPTIONS_LEN) <= data_end) {
		if (payload[0] == 'O' && payload[1] == 'P' && payload[2] == 'T' &&
		    payload[3] == 'I' && payload[4] == 'O' && payload[5] == 'N' &&
		    payload[6] == 'S' && payload[7] == ' ') {
			key = src_ip;
			allowed = bpf_map_lookup_elem(&allowed_ips, &key);
			if (!allowed) {
				__u32 k = XDP_OPTIONS_DROPPED;
				__u64 *v = bpf_map_lookup_elem(&xdp_counters, &k);
				if (v)
					*v += 1;
				return XDP_DROP;
			}
		}
	}

	/* Drop obviously malformed REGISTER: too short or missing SIP/2.0 in first line */
	if ((void *)(payload + REGISTER_LEN) <= data_end &&
	    payload[0] == 'R' && payload[1] == 'E' && payload[2] == 'G' &&
	    payload[3] == 'I' && payload[4] == 'S' && payload[5] == 'T' &&
	    payload[6] == 'E' && payload[7] == 'R' && payload[8] == ' ') {
		unsigned int payload_len = (void *)data_end - (void *)payload;
		if (payload_len < MIN_REGISTER_LEN) {
			key = XDP_MALFORMED;
			__u64 *v = bpf_map_lookup_elem(&xdp_counters, &key);
			if (v) *v += 1;
			return XDP_DROP;
		}
		/* Search for "SIP/2.0" in first MAX_FIRST_LINE bytes (bounded loop for verifier) */
		{
			int found = 0;
#pragma unroll
			for (__u32 i = 0; i < MAX_FIRST_LINE - SIP_VERSION_LEN; i++) {
				if ((void *)(payload + i + SIP_VERSION_LEN) > data_end)
					break;
				if (payload[i] == 'S' && payload[i + 1] == 'I' &&
				    payload[i + 2] == 'P' && payload[i + 3] == '/' &&
				    payload[i + 4] == '2' && payload[i + 5] == '.' &&
				    payload[i + 6] == '0') {
					found = 1;
					break;
				}
			}
			if (!found) {
				key = XDP_MALFORMED;
				__u64 *v = bpf_map_lookup_elem(&xdp_counters, &key);
				if (v) *v += 1;
				return XDP_DROP;
			}
		}
	}

	/* Drop any UDP 5060 that doesn't look like SIP: payload >= 20 bytes but no "SIP/2.0" in first 64 bytes */
	{
		unsigned int payload_len = (void *)data_end - (void *)payload;
		if (payload_len >= MIN_SIP_PAYLOAD) {
			int found = 0;
#pragma unroll
			for (__u32 i = 0; i < MAX_SIP_LOOKUP - SIP_VERSION_LEN; i++) {
				if ((void *)(payload + i + SIP_VERSION_LEN) > data_end)
					break;
				if (payload[i] == 'S' && payload[i + 1] == 'I' &&
				    payload[i + 2] == 'P' && payload[i + 3] == '/' &&
				    payload[i + 4] == '2' && payload[i + 5] == '.' &&
				    payload[i + 6] == '0') {
					found = 1;
					break;
				}
			}
			if (!found) {
				key = XDP_MALFORMED;
				__u64 *v = bpf_map_lookup_elem(&xdp_counters, &key);
				if (v) *v += 1;
				return XDP_DROP;
			}
		}
	}

	/* Redirect to AF_XDP socket for this queue; if no socket, pass to stack */
	if (bpf_map_lookup_elem(&xsks_map, &queue_id)) {
		__u32 k = XDP_REDIRECTED;
		__u64 *v = bpf_map_lookup_elem(&xdp_counters, &k);
		if (v)
			*v += 1;
		return bpf_redirect_map(&xsks_map, queue_id, 0);
	}
	{
		__u32 k = XDP_PASSED;
		__u64 *v = bpf_map_lookup_elem(&xdp_counters, &k);
		if (v)
			*v += 1;
	}
	return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
