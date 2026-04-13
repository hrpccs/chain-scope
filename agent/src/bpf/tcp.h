#ifndef TCP_H 
#define TCP_H 

#include "context.h"
#include "event.h"
#include "ip.h"
#include "sampling.h"
#include "socket.h"
#include "trace_info.h"
#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include "common/config.h"
#include "common/http.h"

u64 metric_tcp_recv_total_streams_count = 0;
u64 metric_tcp_send_total_streams_count = 0;
u64 metric_span_count = 0;

#define DEBUG_TCP
#if DEBUG_LEVEL > 0 && defined(DEBUG_TCP)
#define tcp_debug(fmt, ...) bpf_printk(fmt, ##__VA_ARGS__)
#else
#define tcp_debug(fmt, ...)
#endif

enum span_type {
    UNKNOWN_SPAN = 0,
    CLIENT_SPAN,
    SERVER_SPAN,
};
struct spaninfo_t { // request-response match 
    enum span_type span_type;
    u32 traceid;
    u32 spanid;
    u32 parent_spanid;
    u64 start_ts;
    u64 end_ts;
};
// header option for tcp tracing
struct tcp_hdr_opt_tracing {
    __u8 kind;
    __u8 len;
    __u16 magic;
    __u16 rid;
    __u16 seq;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1<<20);
    __type(key, u32);
    __type(value, struct trace_info);
} tcp_seq_traceinfo_map SEC(".maps"); // assume seq between sk will not overlap

struct {
        __uint(type, BPF_MAP_TYPE_SK_STORAGE);
        __uint(map_flags, BPF_F_NO_PREALLOC);
        __type(key, int);
        __type(value, struct trace_info);
} envoy_sk_storage SEC(".maps"); // short cut for envoy/nginx HTTP1\2 proxy traffic from downstream to upstream

struct {
        __uint(type, BPF_MAP_TYPE_SK_STORAGE);
        __uint(map_flags, BPF_F_NO_PREALLOC);
        __type(key, int);
        __type(value, u32);
} rtx_orig_seq SEC(".maps"); // keep track the original seq of skb before partial ack


struct request_t { // can unique identify a request
    u64 sk;
    u32 streamid;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1<<20);
    __type(key, struct request_t);
    __type(value, struct spaninfo_t);
}  tcp_sk_active_reuqest_map SEC(".maps");  // help decide whether recvmsg and sendmsg will propogate context and help build the span. 

static __maybe_inline
int update_current_context(struct trace_info* traceinfo, u32 tid){
    // update the current context for the tid
    #if GRPC_IP_TAGGING == 1
    if(traceinfo->stream_count == 0){
        struct context_t context = get_current_execution_context(get_context_type(bpf_get_current_pid_tgid()));
        bpf_map_update_elem(&execution_context_traceinfo_map, &context, traceinfo, BPF_ANY);
        tcp_debug("[update_current_context]: context %p type %u traceid %u spanid %u\n",
                  context.execution_context, context.type, traceinfo->traceid, traceinfo->spanid);
    }else{
        if(traceinfo->is_response == 1){
            return 0; // do not update the context for server side response, just propogate the traceinfo
        }
        struct context_t context = get_current_execution_context(get_context_type(bpf_get_current_pid_tgid()));
        for(int i = 0; i < traceinfo->stream_count; i++){
            if(i >= MAX_MULTIPLEX_STREAMS){
                tcp_debug("[update_current_context]: stream count exceeds max multiplex streams %u\n",MAX_MULTIPLEX_STREAMS);
                break; // avoid overflow
            }
            struct demultiplex_context_t demultiplex_context = {
                .streamid = traceinfo->streamids[i],
                .context = context,
            };
            bpf_map_update_elem(&demultiplex_execution_context_traceinfo_map, &demultiplex_context, traceinfo, BPF_ANY);
            tcp_debug("[update_current_context]: update context %p type %u for streamid %u traceid %u spanid %u\n",
                      context.execution_context, context.type, traceinfo->streamids[i], traceinfo->traceid, traceinfo->spanid);
        }
        __sync_fetch_and_add(&metric_tcp_recv_total_streams_count, traceinfo->stream_count);
    }
    #else 
        #if COROUTINE_EXTENSION_SUPPORT == 1
            struct context_t context = get_current_execution_context(get_context_type(bpf_get_current_pid_tgid()));
            bpf_map_update_elem(&execution_context_traceinfo_map, &context, traceinfo, BPF_ANY);
            tcp_debug("[update_current_context]: context %p type %u traceid %u spanid %u\n",
                    context.execution_context, context.type, traceinfo->traceid, traceinfo->spanid);
        #else
        struct context_t context = {
            .execution_context = bpf_get_current_pid_tgid(), // use the current pid_tgid as the context
            .pid = bpf_get_current_pid_tgid() >> 32,
            .type = CONTEXT_THREAD,
        };
        bpf_map_update_elem(&execution_context_traceinfo_map, &context, traceinfo, BPF_ANY);
        tcp_debug("[update_current_context]: context %p type %u traceid %u spanid %u\n",
                  context.execution_context, context.type, traceinfo->traceid, traceinfo->spanid);
        #endif
    #endif

    #if UPROBE_OPTIMIZE_SUPPORT == 1
    struct trace_info* thread_local_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&thread_local_address_map, &tid);
    if(thread_local_traceinfo){
        // update the current traceinfo
        bpf_probe_write_user(thread_local_traceinfo, traceinfo, sizeof(struct trace_info));
    }
    #endif
    return 0;
}

//TODO: record the get_current_execution_context function
static __maybe_inline
int lookup_and_delete_current_context(struct trace_info* traceinfo, u32 tid, struct sock* sk){
    int err = 0;
    #if UPROBE_OPTIMIZE_SUPPORT == 1
    struct trace_info* thread_local_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&thread_local_address_map, &tid);
    if(thread_local_traceinfo){
        err = bpf_probe_read(traceinfo, sizeof(struct trace_info), thread_local_traceinfo);
        if(err < 0){
            tcp_debug("[lookup_current_context]: bpf_probe_read err %d\n", err);
            return -1; // error
        }
        err = bpf_probe_write_user(thread_local_traceinfo, traceinfo, sizeof(struct trace_info));
        if(err < 0){
            tcp_debug("[lookup_current_context]: bpf_probe_read/write_user err %d\n", err);
            return -1; // error
        }
        return 0;
    }
    #endif

    #if GRPC_IP_TAGGING == 0
    struct trace_info* sk_traceinfo =  (struct trace_info*)bpf_sk_storage_get(&envoy_sk_storage, sk, 0, 0);
    if(sk_traceinfo && sk_traceinfo->traceid != 0){
        // update the current traceinfo
        __builtin_memcpy(traceinfo, sk_traceinfo, sizeof(struct trace_info));
        __builtin_memset(sk_traceinfo, 0, sizeof(struct trace_info)); // reset the sk traceinfo
        tcp_debug("[lookup_current_context]: found traceinfo for sk %p traceid %u\n", sk, traceinfo->traceid);
        return 0;
    }
    #endif

    #if COROUTINE_EXTENSION_SUPPORT == 1
        struct context_t context = get_current_execution_context(get_context_type(bpf_get_current_pid_tgid()));

        // lookup the current context for the tid
        struct trace_info* orig_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map, &context);
    #else 
        struct context_t context = {
            .execution_context = bpf_get_current_pid_tgid(), // use the current pid_tgid as the context
            .pid = bpf_get_current_pid_tgid() >> 32,
            .type = CONTEXT_THREAD,
        };
        struct trace_info* orig_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map, &context);
    #endif

    if(orig_traceinfo){ // traceinfo may contain multiple streamid
        // update the current traceinfo
    #if GRPC_IP_TAGGING == 1
        if(orig_traceinfo->is_response == 0){
            __sync_fetch_and_add(&metric_tcp_send_total_streams_count, traceinfo->stream_count);
        }
    #endif
        tcp_debug("[lookup_current_context]: found traceid %llu\n", orig_traceinfo->traceid);
        __builtin_memcpy(traceinfo, orig_traceinfo, sizeof(struct trace_info));
        bpf_map_delete_elem(&execution_context_traceinfo_map, &context);

        return 0;
    } 

    return -1;
}

static __maybe_inline
int delete_context(struct trace_info* traceinfo,u32 tid){
    #if UPROBE_OPTIMIZE_SUPPORT == 1
    struct trace_info* thread_local_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&thread_local_address_map, &tid);
    if(thread_local_traceinfo){
        // delete the current traceinfo
        traceinfo->traceid = 0; // mark as deleted
        traceinfo->spanid = 0;
        traceinfo->stream_count = 0;
        bpf_probe_write_user(thread_local_traceinfo, traceinfo, sizeof(struct trace_info));
    }
    #endif
    struct context_t context = get_current_execution_context(get_context_type(bpf_get_current_pid_tgid()));
    bpf_map_delete_elem(&execution_context_traceinfo_map, &context);
    return 0;
}


#if GRPC_IP_TAGGING == 1
// most of the time, user access frontend with http1.x
SEC("fexit/tcp_recvmsg")
int BPF_PROG(tcp_recvmsg_exit,struct sock *sk, struct msghdr *msg, size_t len, int flags, int *addr_len,int ret){
    if(ret <= 0) return 0; 
       // discard msg_peek
    if(flags & MSG_PEEK){
        // bpf_debug("<tcp recvmsg> exit  : \tmsg_peek");
        return 0;
    }
    
    // check the socket direction
    enum socket_type skt = socket_filter(sk);
    if(skt == SOCKET_DEST_OUTSIDE){
        // generator new traceid for each sk 
        u64 pid_tgid = bpf_get_current_pid_tgid();
        u32 tid = pid_tgid & 0xFFFFFFFF;

        struct request_t request = {
            .sk = (u64)sk,
            .streamid = 0,
        };

        struct spaninfo_t* spaninfo = (struct spaninfo_t*)bpf_map_lookup_elem(&tcp_sk_active_reuqest_map,&request);
        if(spaninfo){
            // sk already has traceid
            return 0;
        }

        u32 percpu_map_key = 0;
        struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&percpu_tmp_traceinfo, &percpu_map_key);
        if(!traceinfo){
            tcp_debug("[tcp_recvmsg]: can not get percpu_tmp_traceinfo\n");
            return 0; // no traceinfo to propogate
        }
   
        traceinfo->traceid = get_new_traceid();
        traceinfo->spanid = 0; // no spanid for recvmsg
        traceinfo->stream_count = 0; // no streamid for recvmsg
        traceinfo->from_grpc_operate_header = 0; // mark as from network thread
        traceinfo->propogate = 0; // mark as not propogate, only for network thread
        traceinfo->tcp_seq = 0;

        if(traceinfo->traceid == 0){
            // no traceid available, do not propogate
            return 0;
        }

        tcp_debug( "[tcp_recvmsg]: create new traceinfo for sk %p with traceid %u\n", sk, traceinfo->traceid);
        update_current_context(traceinfo, tid);

#if GROUND_TRUTH == 1
        debug_push_ground_truth(msg, MSGHDR, TCP_RECVMSG_FROM_OUTSIDE, 25);
#endif

        // #if EXPORT_SPANS == 1
    // help identify the user sk response
    struct spaninfo_t new_spaninfo = {
        .span_type = UNKNOWN_SPAN,
        .traceid = traceinfo->traceid,
        .spanid = traceinfo->spanid,
        .parent_spanid = 0,
        .start_ts = bpf_ktime_get_ns(),
        .end_ts = 0,
    };
    bpf_map_update_elem(&tcp_sk_active_reuqest_map,&request,&new_spaninfo,BPF_ANY);
        // #endif

    collect_tcp_event(TCP_RECVMSG_FROM_OUTSIDE, sk, traceinfo, 0, ret,&msg->msg_iter);
    }

    return 0;
}


// //which sk_buff will the first bytes goto? wrtie queue tail or the first newly allocated sk_buff whose seq is the same as the write_seq; 
SEC("fentry/tcp_sendmsg_locked")
int BPF_PROG(tcp_sendmsg_locked_enter, struct sock *sk, struct msghdr *msg, size_t size){
    // lookup traceinfo in the execution context
    u32 skb_seq = 0;
    u32 write_queue_len = sk->sk_write_queue.qlen;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 tid = pid_tgid & 0xFFFFFFFF;
    u32 percpu_map_key = 0;
    struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&percpu_tmp_traceinfo, &percpu_map_key);
    if(!traceinfo){
        tcp_debug("[tcp_sendmsg_locked]: can not get percpu_tmp_traceinfo\n");
        return 0; // no traceinfo to propogate
    }
    if(lookup_and_delete_current_context(traceinfo,tid,sk) == 0){
        goto found_ok_traceinfo;
    }

not_found_ok_traceinfo:
    return 0;

found_ok_traceinfo:
    struct request_t request = {
        .sk = (u64)sk,
        .streamid = 0,
    };
    tcp_debug("[tcp_sendmsg_locked]: check whether is user sk %p traceid %u spanid %u\n",
              sk, traceinfo->traceid, traceinfo->spanid);
    struct spaninfo_t* spaninfo = (struct spaninfo_t*)bpf_map_lookup_elem(&tcp_sk_active_reuqest_map, &request);
    if(spaninfo){
        // the response sendmsg, do not propogate traceinfo
        tcp_debug("[lookup_current_context]: do not propogate traceinfo to user sk %p traceid %u spanid %u\n",
                  sk, traceinfo->traceid, traceinfo->spanid);
        // end the span
        bpf_map_delete_elem(&tcp_sk_active_reuqest_map, &request);
        // skip the traceinfo propogation
        goto export_event;
    }
    do_actual_ip_tagging:
    // do the actual traceinfo propogation from sendmsg to skb
    if(write_queue_len > 0){
        // continous sendmsg may merge into one skb
        struct sk_buff* skb = sk->sk_write_queue.prev;
        struct tcp_skb_cb* skb_cb = (struct tcp_skb_cb*)skb->cb;
        skb_seq = skb_cb->seq;
        struct trace_info* to_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&tcp_seq_traceinfo_map,&skb_seq);
        if(to_traceinfo != NULL){
            merge_trace_infos(to_traceinfo,traceinfo);
        }else{
            traceinfo->tcp_seq = skb_seq; // update the traceinfo with the skb_seq
            bpf_map_update_elem(&tcp_seq_traceinfo_map,&skb_seq,traceinfo,BPF_ANY);
        }
    }else{
        // http1.x next skb
        struct tcp_sock* tcp_sk = (struct tcp_sock*)sk;
        tcp_sk = bpf_core_cast(tcp_sk, struct tcp_sock);
        skb_seq = tcp_sk->write_seq;
        traceinfo->tcp_seq = skb_seq; // update the traceinfo with the skb_seq
        bpf_map_update_elem(&tcp_seq_traceinfo_map,&skb_seq,traceinfo,BPF_ANY);
    }
    tcp_debug("[tcp_sendmsg_locked]:sendmsg to sk %p traceid %u skb_seq %u size %u\n",(u64)sk,traceinfo->traceid,skb_seq,size);

export_event:
#if GROUND_TRUTH == 1
    debug_push_ground_truth(msg, MSGHDR, TCP_SENDMSG, 25);
#endif
    collect_tcp_event(TCP_SENDMSG,  sk, traceinfo, skb_seq, size, &msg->msg_iter);
end:
    return 0;
}

//int skb_copy_datagram_iter(const struct sk_buff *skb, int offset,
			   //struct iov_iter *to, int len)
SEC("fentry/skb_copy_datagram_iter")
int BPF_PROG(skb_copy_datagram_iter_enter,struct sk_buff* skb,int offset,struct iov_iter* iter,int size)
{
    u8 is_tcp_skb = skb->sk->sk_protocol == IPPROTO_TCP; 
    if(!is_tcp_skb){
        // not tcp skb, do not trace
        return 0;
    }

    u32 tcp_seq = 0;
    struct tcp_skb_cb* skb_cb = (struct tcp_skb_cb*)skb->cb;
    tcp_seq = skb_cb->seq;

    struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&tcp_seq_traceinfo_map,&tcp_seq);
    if(traceinfo == NULL){
        // not found traceinfo, do not trace
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 tid = pid_tgid & 0xFFFFFFFF;

#if GROUND_TRUTH == 1
    debug_push_ground_truth(skb, SK_BUFF, TCP_RECV_FROM_SKB, 25);
#endif

    tcp_debug("[skb_copy_datagram_iter] skb %p tcp seq %u size %u\n",skb,tcp_seq,size);
    // need to propogate traceinfo
    traceinfo->from_grpc_operate_header = 1;
    traceinfo->propogate = 0;
    update_current_context(traceinfo, tid);
    collect_tcp_event(TCP_RECV_FROM_SKB, skb->sk, traceinfo, tcp_seq, size, iter);

end:
    tcp_debug("[skb_copy_datagram_iter]: delete skb %p traceinfo tcp seq %u\n",skb,tcp_seq);
    bpf_map_delete_elem(&tcp_seq_traceinfo_map,&tcp_seq);
    return 0;
}

// rx path coalesce 
// tcp_try_coalesce
//bool skb_try_coalesce(struct sk_buff *to, struct sk_buff *from,
		      //bool *fragstolen, int *delta_truesize)
SEC("fexit/tcp_try_coalesce")
int BPF_PROG(tcp_try_coalesce_enter,struct sock* sk,struct sk_buff* to,struct sk_buff* from,bool* fragstolen,int ret)
{
    if(ret == 0) return 0;
    struct tcp_skb_cb* from_cb = (struct tcp_skb_cb*)(from->cb);
    u32 seq_from = from_cb->seq;
    struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&tcp_seq_traceinfo_map,&seq_from);
    if(traceinfo != NULL){
        struct tcp_skb_cb* to_cb = (struct tcp_skb_cb*)(to->cb);
        u32 seq_to = to_cb->seq;
        struct trace_info* traceinfo_to = (struct trace_info*)bpf_map_lookup_elem(&tcp_seq_traceinfo_map,&seq_to);
        tcp_debug("[tcp_try_coalesce]:merge traceinfo from seq %u to seq %u\n",seq_from,seq_to);
        if(traceinfo_to != NULL){
            merge_trace_infos(traceinfo_to,traceinfo);
        }else{
            traceinfo->tcp_seq = seq_to; // update the traceinfo with the skb_seq
            bpf_map_update_elem(&tcp_seq_traceinfo_map,&seq_to,traceinfo,BPF_ANY);
        }
        bpf_map_delete_elem(&tcp_seq_traceinfo_map,&seq_from); 
    }
    return 0;
}
#else
//  especially for golang net/http server side
static __maybe_inline
int lookup_pending_sk_request(struct sock *sk,struct trace_info* traceinfo) {
    struct request_t request = {
        .sk = (u64)sk,
        .streamid = 0,
    };
    u32 traceid_to_write = 0;
    u32 spanid_to_write = 0;

    struct spaninfo_t* spaninfo = (struct spaninfo_t*)bpf_map_lookup_elem(&tcp_sk_active_reuqest_map, &request);
    if (spaninfo) {
        tcp_debug("[lookup_pending_sk_request]: found pending request for sk %p traceid %u spanid %u\n", sk, spaninfo->traceid, spaninfo->spanid);
        // pending server side send
        // server side send 
        // end the span
        spaninfo->span_type =  SERVER_SPAN;
        if(spaninfo->parent_spanid == 0){
            // no parent spanid, do not propogate traceid and spanid
            traceid_to_write = 0;
            spanid_to_write = 0;
        } else {
            // propogate the parent spanid to the client
            traceid_to_write = spaninfo->traceid;
            spanid_to_write = spaninfo->parent_spanid; 
        }
        spaninfo->end_ts = bpf_ktime_get_ns();
    #if EXPORT_SPANS == 1
        __sync_fetch_and_add(&metric_span_count, 1);
        bpf_ringbuf_output(&event_ringbuf, spaninfo, sizeof(struct spaninfo_t), 0);
    #endif
        bpf_map_delete_elem(&tcp_sk_active_reuqest_map, &request);
    }

    if (traceid_to_write == 0) {
        // no traceid to propogate, do not propogate traceinfo
        return -1;
    }

    traceinfo->traceid = traceid_to_write;
    traceinfo->spanid = spanid_to_write;
    return 0;
}



// help decide the traceinfo to propogate, and track request-response to produce span.
static __maybe_inline
void update_sk_active_request(struct trace_info *traceinfo,
                                           struct sock *sk, enum event_type event_type) {
    u32 traceid_to_write = traceinfo->traceid;
    u32 spanid_to_write = traceinfo->spanid;
    struct spaninfo_t new_spaninfo = {
        .span_type = UNKNOWN_SPAN,
        .traceid = traceinfo->traceid,
        .spanid = bpf_get_prandom_u32(),
        .parent_spanid = traceinfo->spanid,
        .start_ts = bpf_ktime_get_ns(),
        .end_ts = 0,
    };
    struct request_t request = {
        .sk = (u64)sk,
        .streamid = 0,
    };
    struct spaninfo_t* spaninfo = (struct spaninfo_t*)bpf_map_lookup_elem(&tcp_sk_active_reuqest_map, &request);
     if (spaninfo) {
            // server side send or client side recv
            // end the span
            if(event_type == TCP_SENDMSG){
                // server side send
                // send back the parent spanid to the client
                if(spaninfo->parent_spanid != 0){
                    traceid_to_write = spaninfo->traceid;
                    spanid_to_write = spaninfo->parent_spanid; 
                    tcp_debug("[tcp_sendmsg_locked]: no multiplex: send back parent spanid %u traceid %u\n", spaninfo->parent_spanid, spaninfo->traceid);
                }else{
                    traceid_to_write = 0; // do not propogate to user sk
                    spanid_to_write = 0;
                    tcp_debug("[tcp_sendmsg_locked]: no multiplex: do not propogate traceinfo to user\n");
                }
                spaninfo->span_type =  SERVER_SPAN;
            }else{
                // client side recv
                // no need to propogate the traceinfo
                tcp_debug("[tcp_recvmsg_locked]: no multiplex: stop propogate traceinfo\n");
                traceid_to_write = 0;
                spanid_to_write = 0;
                spaninfo->span_type =  CLIENT_SPAN;
            }
            spaninfo->end_ts = bpf_ktime_get_ns();
            tcp_debug("\t no multiplex: end span for streamid %u traceid %u spanid %u parent_spanid %u\n",
                    request.streamid, spaninfo->traceid, spaninfo->spanid, spaninfo->parent_spanid);
            __sync_fetch_and_add(&metric_span_count, 1);
            bpf_ringbuf_output(&event_ringbuf, spaninfo, sizeof(struct spaninfo_t), 0);
            bpf_map_delete_elem(&tcp_sk_active_reuqest_map, &request);
        } else {
            // client side send or server side recv
            // generate a new span for each streamid
            // start the span
            if(event_type == TCP_SENDMSG){
                // client send 
                // generate new spanid set the parent spanid
                // and send out
                tcp_debug("[tcp_sendmsg_locked]: no multiplex: traceid %u new spanid %u parent_spanid %u\n", traceinfo->traceid, new_spaninfo.spanid, new_spaninfo.parent_spanid);
                traceid_to_write = new_spaninfo.traceid;
                spanid_to_write = new_spaninfo.spanid;
            }else{
                // server side recv
                // generate new spanid set the parent spanid
                tcp_debug("[tcp_recvmsg_locked]: no multiplex: traceid %u new spanid %u parent_spanid %u\n", traceinfo->traceid, new_spaninfo.spanid, new_spaninfo.parent_spanid);
                traceid_to_write = new_spaninfo.traceid;
                spanid_to_write = new_spaninfo.spanid;
            }
            tcp_debug("\t no multiplex: start new span for streamid %u traceid %u spanid %u parent_spanid %u\n",
                    request.streamid, new_spaninfo.traceid, new_spaninfo.spanid, new_spaninfo.parent_spanid);
            bpf_map_update_elem(&tcp_sk_active_reuqest_map, &request, &new_spaninfo, BPF_ANY);
        }

        if(traceid_to_write == 0){
            // no traceid to propogate, do not propogate traceinfo
            tcp_debug("[tcp_sendmsg_locked]: no traceid to propogate, do not propogate traceinfo\n");
            return;
        }

        traceinfo->traceid = traceid_to_write;  
        traceinfo->spanid = spanid_to_write;
}

// //which sk_buff will the first bytes goto? wrtie queue tail or the first newly allocated sk_buff whose seq is the same as the write_seq; 
SEC("fentry/tcp_sendmsg_locked")
int BPF_PROG(tcp_sendmsg_locked_enter, struct sock *sk, struct msghdr *msg, size_t size){
    struct request_t request = {
        .sk = (u64)sk,
        .streamid = 0,
    };
    u64 start_filtering_ts,start_action_ts, start_export_ts,end_ts;
    // lookup traceinfo in the execution context
    u32 skb_seq = 0;
    u32 write_queue_len = sk->sk_write_queue.qlen;
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 tid = pid_tgid & 0xFFFFFFFF;
    struct trace_info traceinfo = {};
    if(lookup_and_delete_current_context(&traceinfo,tid,sk) == 0){
        goto found_ok_traceinfo;
    }

not_found_ok_traceinfo:
    #if EXPORT_SPANS == 1
    if(lookup_pending_sk_request(sk, &traceinfo) == 0){
        // found pending request, use the traceid and spanid from the pending request
        tcp_debug("[tcp_sendmsg_locked]:found pending request for sk %p traceid %u spanid %u\n", sk, traceinfo.traceid, traceinfo.spanid);
        goto do_actual_ip_tagging;
    }
    #endif
    return 0;
found_ok_traceinfo:
    #if EXPORT_SPANS == 1
    // adjust the traceinfo to send, try build produce span info, and decide what traceinfo to propogate
    update_sk_active_request(&traceinfo,sk,TCP_SENDMSG);
    if(traceinfo.traceid == 0){
        goto end;
    }
    #else
    tcp_debug("[tcp_sendmsg_locked]: check whether is user sk %p traceid %u spanid %u\n",
              sk, traceinfo.traceid, traceinfo.spanid);
    struct spaninfo_t* spaninfo = (struct spaninfo_t*)bpf_map_lookup_elem(&tcp_sk_active_reuqest_map, &request);
    if(spaninfo){
        // the response sendmsg, do not propogate traceinfo
        tcp_debug("[lookup_current_context]: do not propogate traceinfo to user sk %p traceid %u spanid %u\n",
                  sk, traceinfo.traceid, traceinfo.spanid);
        // end the span
        bpf_map_delete_elem(&tcp_sk_active_reuqest_map, &request);
        // skip the traceinfo propogation
        goto export_event;
    }
    #endif


    do_actual_ip_tagging:
    start_action_ts = bpf_ktime_get_ns();
    // do the actual traceinfo propogation from sendmsg to skb
    if(write_queue_len > 0){
        // continous sendmsg may merge into one skb
        struct sk_buff* skb = sk->sk_write_queue.prev;
        struct tcp_skb_cb* skb_cb = (struct tcp_skb_cb*)skb->cb;
        skb_seq = skb_cb->seq;
        bpf_map_update_elem(&tcp_seq_traceinfo_map,&skb_seq,&traceinfo,BPF_ANY);
    }else{
        // http1.x next skb
        struct tcp_sock* tcp_sk = (struct tcp_sock*)sk;
        tcp_sk = bpf_core_cast(tcp_sk, struct tcp_sock);
        skb_seq = tcp_sk->write_seq;
        bpf_map_update_elem(&tcp_seq_traceinfo_map,&skb_seq,&traceinfo,BPF_ANY);
    }
    tcp_debug("[tcp_sendmsg_locked]:sendmsg to sk %p traceid %u skb_seq %u size %u\n",(u64)sk,traceinfo.traceid,skb_seq,size);

export_event:
    #if GROUND_TRUTH == 1
    debug_push_ground_truth(msg, MSGHDR, TCP_SENDMSG, 25);
    #endif
    #if EXPORT_EVENTS_AT_TCP == 1
    collect_tcp_event(TCP_SENDMSG,  sk, &traceinfo, skb_seq, size,&msg->msg_iter);
    #endif

end:
    return 0;
}
//int skb_copy_datagram_iter(const struct sk_buff *skb, int offset,
			   //struct iov_iter *to, int len)
SEC("fentry/skb_copy_datagram_iter")
int BPF_PROG(skb_copy_datagram_iter_enter,struct sk_buff* skb,int offset,struct iov_iter* iter,int size)
{
    u8 is_tcp_skb = skb->sk->sk_protocol == IPPROTO_TCP; 
    if(!is_tcp_skb){
        // not tcp skb, do not trace
        return 0;
    }

    u32 tcp_seq = 0;
    struct tcp_skb_cb* skb_cb = (struct tcp_skb_cb*)skb->cb;
    tcp_seq = skb_cb->seq;

    struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&tcp_seq_traceinfo_map,&tcp_seq);
    if(traceinfo == NULL){
        // not found traceinfo, do not trace
        return 0;
    }

    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 tid = pid_tgid & 0xFFFFFFFF;

    #if GROUND_TRUTH == 1
    debug_push_ground_truth(skb, SK_BUFF, TCP_RECV_FROM_SKB, 25);
    #endif

    tcp_debug("[skb_copy_datagram_iter] skb %p tcp seq %u size %u\n",skb,tcp_seq,size);
    #if EXPORT_SPANS == 1
    update_sk_active_request(traceinfo,skb->sk,TCP_RECV_FROM_SKB);
    if(traceinfo->traceid == 0){
        goto end;
    }
    #endif
    // need to propogate traceinfo
    update_current_context(traceinfo, tid);
    #if EXPORT_EVENTS_AT_TCP == 1
    collect_tcp_event(TCP_RECV_FROM_SKB, skb->sk, traceinfo, tcp_seq, size, iter);
    #endif

end:
    tcp_debug("[skb_copy_datagram_iter]: delete skb %p traceinfo tcp seq %u\n",skb,tcp_seq);
    bpf_map_delete_elem(&tcp_seq_traceinfo_map,&tcp_seq);
    return 0;
}

SEC("fexit/tcp_recvmsg")
int BPF_PROG(tcp_recvmsg_exit,struct sock *sk, struct msghdr *msg, size_t len, int flags, int *addr_len,int ret){
    if(ret <= 0) return 0; 
       // discard msg_peek
    if(flags & MSG_PEEK){
        // bpf_debug("<tcp recvmsg> exit  : \tmsg_peek");
        return 0;
    }
    
    // check the socket direction
    enum socket_type skt = socket_filter(sk);
    if(skt == SOCKET_DEST_OUTSIDE){
        // generator new traceid for each sk 
        u64 pid_tgid = bpf_get_current_pid_tgid();
        u32 tid = pid_tgid & 0xFFFFFFFF;

        struct request_t request = {
            .sk = (u64)sk,
            .streamid = 0,
        };

        struct spaninfo_t* spaninfo = (struct spaninfo_t*)bpf_map_lookup_elem(&tcp_sk_active_reuqest_map,&request);
        if(spaninfo){
            // sk already has traceid
            return 0;
        }

        struct trace_info traceinfo = {
            .traceid = get_new_traceid(),
            #if EXPORT_SPANS == 1
            .spanid = bpf_get_prandom_u32(),
            #else
            .spanid = 0, // no spanid for recvmsg
            #endif
        };

        if(traceinfo.traceid == 0){
            // no traceid available, do not propogate
            tcp_debug("[tcp_recvmsg]: no traceid available for sk %p\n",sk);
            return 0;
        }

        tcp_debug( "[tcp_recvmsg]: create new traceinfo for sk %p with traceid %u\n", sk, traceinfo.traceid);
        update_current_context(&traceinfo, tid);

    #if GROUND_TRUTH == 1
        debug_push_ground_truth(msg, MSGHDR, TCP_RECVMSG_FROM_OUTSIDE, 25);
    #endif

        // #if EXPORT_SPANS == 1
    // root span start !
    struct spaninfo_t new_spaninfo = {
        .span_type = UNKNOWN_SPAN,
        .traceid = traceinfo.traceid,
        .spanid = traceinfo.spanid,
        .parent_spanid = 0,
        .start_ts = bpf_ktime_get_ns(),
        .end_ts = 0,
    };
    bpf_map_update_elem(&tcp_sk_active_reuqest_map,&request,&new_spaninfo,BPF_ANY);
        // #endif

    #if EXPORT_EVENTS_AT_TCP == 1
        collect_tcp_event(TCP_RECVMSG_FROM_OUTSIDE, sk, &traceinfo, 0, ret, &msg->msg_iter);
    #endif
    }
    return 0;
}

// static int ep_insert(struct eventpoll *ep, const struct epoll_event *event,
//     struct file *tfile, int fd, int full_check)
SEC("fentry/ep_insert")
int BPF_PROG(ep_insert_enter, struct eventpoll *ep, const struct epoll_event *event,
    struct file *tfile, int fd, int full_check){
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 tid = pid_tgid & 0xFFFFFFFF;

    enum context_type context_type = get_context_type(pid_tgid);
    if( context_type != CONTEXT_ISTIO && context_type != CONTEXT_TRAEFIK) {
        return 0;
    }
    if(tfile == NULL){
        return 0;
    }
    struct socket* socket = bpf_sock_from_file(tfile);
    if(socket == NULL){
        tcp_debug("[ep_insert]: \tsocket is NULL");
        return 0;
    }
    struct trace_info traceinfo = {};
    if(lookup_and_delete_current_context(&traceinfo, tid, socket->sk) != 0){
        tcp_debug("[ep_insert]: \tno traceinfo found for tid %u\n", tid);
        // no traceinfo found, do not propogate
        return 0;
    }

    tcp_debug("[ep_insert]: found traceinfo from execution_context_traceinfo_map tid %lu traceid %u\n", tid, traceinfo.traceid);
    struct trace_info* to_traceinfo =  (struct trace_info*)bpf_sk_storage_get(&envoy_sk_storage, socket->sk, 0,BPF_SK_STORAGE_GET_F_CREATE);
    if(to_traceinfo != NULL){
        tcp_debug("[ep_insert]: \tsock addr %lu do not allowed to use get sk storage",socket->sk);
        __builtin_memcpy(to_traceinfo, &traceinfo, sizeof(struct trace_info));
    }
    return 0;
}
#endif


#endif // TCP_H
