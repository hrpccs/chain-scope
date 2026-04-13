#ifndef TRACE_INFO_H
#define TRACE_INFO_H

#include "event.h"
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "common/config.h"
#include "common/http.h"
#include "common/macros.h"

#if DEBUG_LEVEL > 0 && defined(DEBUG_TRACE_INFO)
#define traceinfo_debug(fmt, ...) bpf_printk(fmt, ##__VA_ARGS__)
#else
#define traceinfo_debug(fmt, ...)
#endif

u64 metric_rpc_drop_at_merge = 0;
u64 metric_rename_event_count = 0;
u64 metric_tcp_event_count = 0;

//BPF_MAP_TYPE_PERCPU_ARRAY
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct trace_info);
} percpu_tmp_traceinfo SEC(".maps");

#if GRPC_IP_TAGGING == 1
static __always_inline
bool has_multiplex_info(const struct trace_info *trace)
{
    return trace->stream_count > 0;
}


#define bpf_clamp_umax(VAR, UMAX)                                                                  \
    asm volatile("if %0 <= %[max] goto +1\n"                                                       \
                 "%0 = %[max]\n"                                                                   \
                 : "+r"(VAR)                                                                       \
                 : [max] "i"(UMAX))


/* 3. Merge multiplex_info from two trace_info entries */
static __maybe_inline
int merge_trace_infos(struct trace_info* target,struct trace_info *source)
{
    struct multiplex_info *target_info, *source_info;
    __u32 i, space_needed;
    int ret = -1;
    if(!target || !source){
        return -1;
    }

    u32 replaced_traceid = 0;
    u32 replaced_spanid = 0;
    u32 replaced_tcp_seq = 0;
    // set traceid first
    if(target->traceid != source->traceid || target->tcp_seq != source->tcp_seq){
        replaced_traceid = source->traceid;    
        replaced_spanid = source->tcp_seq;
        // need to produce an event to help chain reconstruction
        traceinfo_debug("\treplace source traceid %u with target traceid %u\n",source->traceid,target->traceid);
        traceinfo_debug("\treplace source tcp_seq %u with target tcp_seq %u\n",source->tcp_seq,target->tcp_seq);
    }

    /* Check if both have multiplex_info */
    if (!has_multiplex_info(target) && !has_multiplex_info(source))
        return 0; /* Nothing to merge */

    if (target->stream_count >= MAX_MULTIPLEX_STREAMS) {
        traceinfo_debug("\tmax multiplex streams reached, cannot merge more streams\n");
        __sync_fetch_and_add(&metric_rpc_drop_at_merge, source->stream_count);
        return 0; // prevent overflow
    }
    
    
    u32 source_stream_merged = 0;
    u32 target_stream_index = target->stream_count;
    for(i = 0; i < source->stream_count; i++) {
        if(target_stream_index >= MAX_MULTIPLEX_STREAMS || i >= MAX_MULTIPLEX_STREAMS){
            traceinfo_debug("\tmax multiplex streams reached, cannot merge more streams\n");
            break; // prevent overflow
        }
        bpf_clamp_umax(target_stream_index, MAX_MULTIPLEX_STREAMS - 1);
        bpf_clamp_umax(i, MAX_MULTIPLEX_STREAMS - 1);
        target->streamids[target_stream_index] = source->streamids[i];
        target->stream_count++;
        source_stream_merged++;
        target_stream_index++;
    }


    if(source_stream_merged != 0){
        //produce rename event
        struct skb_event* rename_event = (struct skb_event*)bpf_ringbuf_reserve(&event_ringbuf, sizeof(struct skb_event), 0);
        if(rename_event){
            rename_event->evtype = SKB_RENAME;
            rename_event->ts = bpf_ktime_get_ns();
            rename_event->old_traceid = source->traceid;
            rename_event->old_tcp_seq = source->tcp_seq;
            rename_event->new_traceid = target->traceid;
            rename_event->new_tcp_seq = target->tcp_seq;
            rename_event->stream_count = source_stream_merged;
            for(u32 j=0;j<source_stream_merged;j++){
                if(j >= MAX_MULTIPLEX_STREAMS){
                    break; // prevent overflow
                }
                rename_event->streamids[j] = source->streamids[j];
            }
            traceinfo_debug("\tproduced rename event for %u streams from source traceid %u to target traceid %u\n",
                            rename_event->stream_count, source->traceid, target->traceid);
            __sync_fetch_and_add(&metric_rename_event_count, 1);
            bpf_ringbuf_submit(rename_event, 0);
        }
    }

    if(source_stream_merged < source->stream_count){
        //produce drop event
        traceinfo_debug("\tproduced drop event for %u streams from source traceid %u\n",
                            source->stream_count - source_stream_merged, source->traceid);
        __sync_fetch_and_add(&metric_rpc_drop_at_merge, source->stream_count - source_stream_merged);
    }

    traceinfo_debug("\tmerged info traceid %u stream count %u\n",target->traceid, target->stream_count);
    return 0;
}
#endif
static __maybe_inline
void collect_tcp_event(enum event_type type,struct sock* sk,struct trace_info* ti,u32 skb_seq,u32 bytes,struct iov_iter* iter) {
#if GRPC_IP_TAGGING == 1
    if(has_multiplex_info(ti)){
        // // multiplex info is not supported in this event
        struct tcp_event_with_streamid* val = (struct tcp_event_with_streamid*)bpf_ringbuf_reserve(&event_ringbuf,sizeof(struct tcp_event_with_streamid),0);
        if(val){
            val->pid_tgid = bpf_get_current_pid_tgid();
            val->evtype = type;
            val->end_ts = bpf_ktime_get_ns();
            val->sk = (u64)sk;
            val->family = sk->__sk_common.skc_family;
            if(val->family == AF_INET) {
                val->saddr = sk->__sk_common.skc_rcv_saddr;
                val->daddr = sk->__sk_common.skc_daddr;
                val->sport = sk->__sk_common.skc_num;
                val->dport = sk->__sk_common.skc_dport;
            }
            else if (val->family == AF_INET6) {
                val->saddr = sk->__sk_common.skc_v6_rcv_saddr.in6_u.u6_addr32[3];
                val->daddr = sk->__sk_common.skc_v6_daddr.in6_u.u6_addr32[3];
                val->sport = sk->__sk_common.skc_num;
                val->dport = sk->__sk_common.skc_dport;
            }
            val->bytes = bytes;
            val->skb_seq = skb_seq;
            val->traceid = ti->traceid;
            val->stream_count = 0;
            val->new_trace_flag = type == TCP_RECVMSG_FROM_OUTSIDE ? 1 : 0; // only set new_traceid for TCP_RECVMSG_FROM_OUTSIDE event
            // copy streamids
            for(int i=0;i<MAX_MULTIPLEX_STREAMS;i++){
                if(i<ti->stream_count){
                    val->stream_count++;
                    val->streamids[i] = ti->streamids[i];
                }
            }
            bpf_ringbuf_submit(val, 0);
        }
    }else
#endif 
    {
        struct tcp_event* val = (struct tcp_event*)bpf_ringbuf_reserve(&event_ringbuf,sizeof(struct tcp_event),0);
        if(val){
            val->pid_tgid = bpf_get_current_pid_tgid();
            val->evtype = type;
            val->end_ts = bpf_ktime_get_ns();
            val->sk = (u64)sk;
            if(sk){
                val->family = sk->__sk_common.skc_family;
                if(val->family == AF_INET) {
                    val->saddr = sk->__sk_common.skc_rcv_saddr;
                    val->daddr = sk->__sk_common.skc_daddr;
                    val->sport = sk->__sk_common.skc_num;
                    val->dport = sk->__sk_common.skc_dport;
                }
                else if (val->family == AF_INET6) {
                    val->saddr = sk->__sk_common.skc_v6_rcv_saddr.in6_u.u6_addr32[3];
                    val->daddr = sk->__sk_common.skc_v6_daddr.in6_u.u6_addr32[3];
                    val->sport = sk->__sk_common.skc_num;
                    val->dport = sk->__sk_common.skc_dport;
                }
            }
            val->bytes = bytes;
            val->skb_seq = skb_seq;
            val->traceid = ti->traceid;
            val->new_trace_flag = type == TCP_RECVMSG_FROM_OUTSIDE ? 1 : 0; // only set new_traceid for TCP_RECVMSG_FROM_OUTSIDE event

#if GROUND_TRUTH == 1
            if (bytes > 0) {
                val->ground_truth = debug_pop_ground_truth(val->pid_tgid, type, sk);
            } else {
                val->ground_truth = 0;
            }
#endif
            try_collect_socket_data(ti, iter, bytes);
            __sync_fetch_and_add(&metric_tcp_event_count, 1);
            bpf_ringbuf_submit(val, 0);
        }
    }
}

#endif