/* BPF type shim when vmlinux.h doesn't provide __u* (e.g. bpftool dump) */
#ifndef __VOS_BPF_TYPES_H
#define __VOS_BPF_TYPES_H
#ifndef __u8
typedef unsigned char __u8;
#endif
#ifndef __u16
typedef unsigned short __u16;
#endif
#ifndef __u32
typedef unsigned int __u32;
#endif
#ifndef __u64
typedef unsigned long long __u64;
#endif
#endif
