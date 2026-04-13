#ifndef IP_H
#define IP_H
#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include "net_helpers.h"
#include "common/config.h"

#if EXPORT_SPANS == 1
#define MAX_STREAMS_IN_IP_OPTION 5
#else
#define MAX_STREAMS_IN_IP_OPTION 6
#endif
struct ip_hdr_opt_tracing {
    // see RFC 791 for ip option
    // option-type
    __u8 option_type;
    // __u8 copied_flag:1;
    // __u8 option_class:2;
    // __u8 option_number:5;
    __u8 option_len;
    __u16 magic;
    __u32 traceid;
    __u32 tcp_seq;
    // __u32 spanid;
    // base stream id
    // offset
} __attribute__((packed));

struct ip_hdr_opt_tracing_with_span {
    // see RFC 791 for ip option
    // option-type
    __u8 option_type;
    // __u8 copied_flag:1;
    // __u8 option_class:2;
    // __u8 option_number:5;
    __u8 option_len;
    __u16 magic;
    __u32 traceid;
    __u32 tcp_seq;
    __u32 spanid;
    // base stream id
    // offset
} __attribute__((packed));

struct ip_hdr_opt_tracing_additional_info {
    __u32 stream_count; //u8
    __u32 streamids[MAX_STREAMS_IN_IP_OPTION]; // requestid, streamid 
} __attribute__((packed));

#endif