#ifndef SOCKET_H
#define SOCKET_H

#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include "net_helpers.h"
#include "event.h"


enum socket_type {
    SOCKET_INNER = 0,
    SOCKET_SRC_OUTSIDE = 1,
    SOCKET_DEST_OUTSIDE = 2,
    SOCKET_OTHERS = 3,
};

struct {
    __uint(type,BPF_MAP_TYPE_HASH);
    __uint(max_entries,1<<10);
    __type(key, u32);
    __type(value, u32);
} service_ip_map SEC(".maps");

static __maybe_inline
enum socket_type socket_filter(struct sock* sk) {
    if(sk == NULL) return SOCKET_OTHERS;
    struct tcp_sock* tp = (struct tcp_sock*) sk;
    // filter by port and ip
    u16 family = sk->__sk_common.skc_family;
    u16 sport, dport;
   u32 saddr, daddr; // big endian
    if(family == AF_INET){
        saddr = sk->__sk_common.skc_rcv_saddr;
        daddr = sk->__sk_common.skc_daddr;
    }else{
        saddr = sk->__sk_common.skc_v6_rcv_saddr.in6_u.u6_addr32[3];
        daddr = sk->__sk_common.skc_v6_daddr.in6_u.u6_addr32[3];
    }
    u8 src_in_service = 0;
    u8 dest_in_service = 0;
    u32* src_active_port_ptr = (u32*)bpf_map_lookup_elem(&service_ip_map, &saddr);
    if(src_active_port_ptr!=NULL){
        if(*src_active_port_ptr == 0){
            src_in_service = 1;
        }else{
            sport = sk->__sk_common.skc_num;
            if(*src_active_port_ptr == sport){
                src_in_service = 1;
            }
        }
    }
    u32* dest_active_port_ptr = (u32*)bpf_map_lookup_elem(&service_ip_map, &daddr);
    if(dest_active_port_ptr!=NULL){
        if(*dest_active_port_ptr == 0){
            dest_in_service = 1;
        }else{
            dport = sk->__sk_common.skc_dport;
            dport = __bpf_ntohs(dport); // big endian
            if(*dest_active_port_ptr == dport){
                dest_in_service = 1;
            }
        }
    }

    u8 res = src_in_service + dest_in_service;
    if(res == 0){
        return SOCKET_OTHERS;
    }

    if(src_in_service == 0) return SOCKET_SRC_OUTSIDE;

    if(dest_in_service == 0) return SOCKET_DEST_OUTSIDE;
    return SOCKET_INNER;
}

#endif