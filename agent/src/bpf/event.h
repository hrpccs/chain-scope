#ifndef EVENT_H
#define EVENT_H

#include "context.h"
#include "hooks.h"
#include "ip.h"
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "net_helpers.h"
#include "common/config.h"

#define MAX_MULTIPLEX_STREAMS (MAX_STREAMS_IN_IP_OPTION * 40) // 8 is max multiplex streams in one ip option

#if DEBUG_LEVEL > 0 && defined(DEBUG_EVENT)
#define event_debug(fmt, ...) bpf_printk(fmt, ##__VA_ARGS__)
#else
#define event_debug(fmt, ...)
#endif

#if GRPC_IP_TAGGING == 1
struct trace_info{
    // propogate
    u32 stream_count;
    u32 streamids[MAX_MULTIPLEX_STREAMS];
    u32 from_grpc_operate_header; // 1 if from network thread, 0 if not
    u32 propogate; // 1 if propogate, 0 if not
    u32 is_response; // 0 for client side, 1 for server side
    // normal trace info
    u32 traceid;//[] 
    u32 spanid;
    u32 tcp_seq;
    // streamids
// } __attribute__((packed));
};
#else
struct trace_info{
    u32 traceid;
    u32 spanid;
    u32 tcp_seq;
    u32 from_network_thread; // 1 if from network thread, 0 if not
} __attribute__((packed));
#endif

struct {
    __uint(type,BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1<<24);
} event_ringbuf SEC(".maps");

enum normal_event_type {
    START_SPAN,
    END_SPAN,
    FROM_QUEUE,
    NEW_EXECUTION_UNIT,
    MAP_ERROR,
};


enum buf_type {
    BUF_TYPE_UNKNOWN,
    BUF_TYPE_HTTP,
};
// Define possible events
enum event_type {
    SYS_RECVFROM,
    SYS_RECVMSG,
    SYS_SENDTO,
    SYS_SENDMSG,
    SYS_READ,
    SYS_WRITE,
    TCP_SENDMSG,
    TCP_SENDPAGE,
    TCP_RECVMSG_FROM_OUTSIDE,
    TCP_READ_SOCK,
    TCP_RECV_FROM_SKB,
};


// Values saved in the event map
struct tcp_event {
    u64 end_ts;
    u64 pid_tgid;
    enum event_type evtype;
    // help correlate with pod info
    u16 family;
	u32 saddr;
	u32 daddr;
    u16 sport;
    u16 dport; //dport is in network byte order; should be converted 
    u32 bytes;
    u32 skb_seq;
    u32 traceid;
    u32 spanid;
    u64 sk;
    u8 new_trace_flag; // 0 if not new traceid, 1 if new traceid
    u32 ground_truth;
};

struct tcp_event_with_streamid {
    u64 end_ts;
    u64 pid_tgid;
    enum event_type evtype;
    u16 family;
    u32 saddr;
    u32 daddr;
    u16 sport;
    u16 dport; //dport is in network byte order; should be converted 
    u32 bytes;
    u32 skb_seq;
    u32 traceid;
    u32 spanid;
    u16 sk_allow_write_option;
    u64 sk;

    u8 new_trace_flag; // 0 if not new traceid, 1 if new traceid
    // multiplex info
    u32 streamids[MAX_MULTIPLEX_STREAMS];
    u32 stream_count; // number of streams
};

enum skb_event_type {
    SKB_RENAME,
    SKB_DROP,
};

struct skb_event {
    u32 streamids[MAX_MULTIPLEX_STREAMS];
    enum skb_event_type evtype;
    u64 ts;
    u32 old_traceid;
    u32 old_tcp_seq;
    u32 new_traceid;
    u32 new_tcp_seq;
    u32 stream_count;
};


#define MAX_GRPC_HEADERS 10
#define MAX_GRPC_HEADER_KEY_LENGTH 64
#define MAX_GRPC_HEADER_VAL_LENGTH 64
struct grpc_headers_event {
    u32 traceid;
    u32 streamid;
    u32 header_count;
    u8 header_key_lens[MAX_GRPC_HEADERS]; // each header key length is 64 bytes
    u8 header_val_lens[MAX_GRPC_HEADERS]; // each header value length is 64 bytes
    // key and value are stored in a single array
    // key is stored first, then value
    // each key and value is null terminated
    u8 headers_key[MAX_GRPC_HEADERS * MAX_GRPC_HEADER_KEY_LENGTH]; // max 10 headers, each header key is 64 bytes
    u8 headers_val[MAX_GRPC_HEADERS * MAX_GRPC_HEADER_VAL_LENGTH];
};

#define MAX_SOCKET_DATA_SIZE 512
struct socket_data_event {
    u32 traceid;
    u32 buf_size;
    enum buf_type buf_type;
    u8 socket_data[MAX_SOCKET_DATA_SIZE];
};
static inline void get_ubuf_base(struct iov_iter* iter,void** ubuf_base,u32* ubuf_len){
    void* buf = 0;
    int  len = 0; 
    int iter_type = iter->iter_type;
    const struct kvec* iov = iter->kvec;
    if(iter_type != 0){
        buf = BPF_CORE_READ(iov,iov_base);
        len = BPF_CORE_READ(iov,iov_len);
    }else{
        buf = iter->ubuf;
        len = iter->count;
    }
    *ubuf_base = buf;
    *ubuf_len = len;
}

__always_inline static
void try_collect_socket_data(struct trace_info* traceinfo,struct iov_iter* iter,size_t size){
    // struct iov_iter* iter = &msg->msg_iter;
    void *ubuf = NULL;
    u32 ubuf_len = 0;
    int err = 0;
    get_ubuf_base(iter,&ubuf,&ubuf_len);

    if(ubuf == NULL){
        event_debug("<tcp sendmsg> : \tget ubuf failed");
        return;
    }

    

    struct socket_data_event* socket_data_ptr = (struct socket_data_event*)bpf_ringbuf_reserve(&event_ringbuf,sizeof(struct socket_data_event),0);
    if(socket_data_ptr == NULL){
        event_debug("<tcp sendmsg> : \tget socket data event failed");
        return;
    }

    socket_data_ptr->traceid = traceinfo->traceid;
    socket_data_ptr->buf_size = ubuf_len;
    err = bpf_probe_read(&socket_data_ptr->socket_data, size & (MAX_SOCKET_DATA_SIZE - 1), ubuf);
    if(err){
        event_debug("<tcp sendmsg> : \tget socket data failed");
        bpf_ringbuf_discard(socket_data_ptr, 0);
        return;
    }
    event_debug("<socket data> : \t%s", socket_data_ptr->socket_data);
    socket_data_ptr->socket_data[sizeof(socket_data_ptr->socket_data)-1] = 0;
    bpf_ringbuf_discard(socket_data_ptr, 0);
    // bpf_ringbuf_submit(socket_data_ptr, 0);
    return;
}



#endif // EVENT_H