/* Minimal L2/L3/L4 headers for XDP; avoids relying on vmlinux.h UAPI. */

#ifndef __PKT_HEADERS_H
#define __PKT_HEADERS_H

#define ETH_P_IP 0x0800

struct ethhdr {
	unsigned char h_dest[6];
	unsigned char h_source[6];
	unsigned short h_proto;
} __attribute__((packed));

struct iphdr {
	unsigned char ihl:4, version:4;
	unsigned char tos;
	unsigned short tot_len;
	unsigned short id;
	unsigned short frag_off;
	unsigned char ttl;
	unsigned char protocol;
	unsigned short check;
	unsigned int saddr;
	unsigned int daddr;
} __attribute__((packed));

struct udphdr {
	unsigned short source;
	unsigned short dest;
	unsigned short len;
	unsigned short check;
} __attribute__((packed));

#endif /* __PKT_HEADERS_H */
