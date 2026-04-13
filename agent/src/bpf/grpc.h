// SPDX-License-Identifier: GPL-2.0 OR BSD-3-Clause
/* Copyright (c) 2020 Facebook */
#include "event.h"
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include "context.h"
#include "trace_info.h"
#include "common/config.h"

u64 metric_grpc_header_inject_fail_count = 0;
u64 metric_total_send_streams_count = 0;
u64 metric_total_parse_streams_count = 0;
u64 metric_grpc_event = 0;

#define DEBUG_GRPC
#if DEBUG_LEVEL > 0 && defined(DEBUG_GRPC)
#define grpc_debug(fmt, ...) bpf_printk(fmt, ##__VA_ARGS__)
#else
#define grpc_debug(fmt, ...)
#endif


struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u64);
    __type(value, struct trace_info);
} item_traceinfo_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u64);
    __type(value, struct trace_info);
} dataframe_traceinfo_map SEC(".maps");

struct go_app_specific_info {
    u64 grpc_task_ptr;
    u64 grpc_dataframe_ptr;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u32);
    __type(value, struct go_app_specific_info);
} pid_go_info_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, struct context_t);
    __type(value, u64);
} temp_item_map SEC(".maps");


typedef struct grpc_header_field {
    u8 *key_ptr;
    u64 key_len;
    u8 *val_ptr;
    u64 val_len;
    u64 sensitive;
} grpc_header_field_t;


// // demultiplex
// //google.golang.org/grpc/internal/transport.(*http2Server).operateHeaders
#if GRPC_IP_TAGGING == 1
SEC("uprobe")
int BPF_KPROBE(grpc_operate_headers){
    // go routine pass as ctx->r14
    void* metaframe = (void*)ctx->bx;
    void* headerframe;
    u32 streamid;

    bpf_probe_read(&headerframe, sizeof(headerframe), metaframe);
    bpf_probe_read(&streamid, sizeof(u32),headerframe+0x8);

    struct demultiplex_context_t demultiplex_context = {
        .streamid = streamid,
        .context = {
            .execution_context = ctx->r14, // r14 is the goroutine pointer
            .pid = bpf_get_current_pid_tgid() >> 32,
            .type = CONTEXT_GOROUTINE,
        },
    };


    struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&demultiplex_execution_context_traceinfo_map,&demultiplex_context);
    if(traceinfo){
        traceinfo->stream_count = 0;
        traceinfo->propogate = 1; // mark as propogate
        traceinfo->from_grpc_operate_header = 1; // mark as from network thread

        struct grpc_headers_event* grpc_event = (struct grpc_headers_event*)bpf_ringbuf_reserve(&event_ringbuf, sizeof(struct grpc_headers_event), 0);
        if(grpc_event){
            grpc_event->traceid=traceinfo->traceid;
            grpc_event->streamid = streamid;
            grpc_event->header_count = 0;
            // parse header fied
            void* fields = 0;
            u64 fields_off = 8;
            bpf_probe_read(&fields, sizeof(fields), (void *)(metaframe + fields_off));
            u64 fields_len = 0;
            bpf_probe_read(&fields_len, sizeof(fields_len), (void *)(metaframe + fields_off + 8));
            grpc_debug("fields ptr %llx, len %d", fields, fields_len);
            if (fields && fields_len > 0) {
                for (u8 i = 0; i < MAX_GRPC_HEADERS; i++) {
                    if (i >= fields_len) {
                        break;
                    }
                    void *field_ptr = fields + (i * sizeof(grpc_header_field_t));
                    //bpf_dbg_printk("field_ptr %llx", field_ptr);
                    grpc_header_field_t field = {};
                    bpf_probe_read(&field, sizeof(grpc_header_field_t), field_ptr);
                    //bpf_dbg_printk("grpc header %s:%s", field.key_ptr, field.val_ptr);
                    //bpf_dbg_printk("grpc sizes %d:%d", field.key_len, field.val_len);
                    bpf_probe_read(&grpc_event->headers_key[i * MAX_GRPC_HEADER_KEY_LENGTH], field.key_len & (MAX_GRPC_HEADER_KEY_LENGTH - 1), (void *)field.key_ptr);
                    bpf_probe_read(&grpc_event->headers_val[i * MAX_GRPC_HEADER_VAL_LENGTH], field.val_len & (MAX_GRPC_HEADER_VAL_LENGTH - 1), (void *)field.val_ptr);
                    grpc_event->headers_key[(i+1) * MAX_GRPC_HEADER_KEY_LENGTH - 1] = 0; // null terminate
                    grpc_event->headers_val[(i+1) * MAX_GRPC_HEADER_VAL_LENGTH - 1] = 0;
                    grpc_debug("grpc header %s:%s", &grpc_event->headers_key[i * MAX_GRPC_HEADER_KEY_LENGTH], &grpc_event->headers_val[i * MAX_GRPC_HEADER_VAL_LENGTH]);
                    grpc_event->header_key_lens[i]=field.key_len;
                    grpc_event->header_val_lens[i]=field.val_len;
                    grpc_event->header_count++;
                }
            }
            bpf_ringbuf_submit(grpc_event, 0);
        }
        
         __sync_fetch_and_add(&metric_total_parse_streams_count, 1);
         bpf_map_update_elem(&execution_context_traceinfo_map, &demultiplex_context.context, traceinfo, BPF_ANY);
         bpf_map_delete_elem(&demultiplex_execution_context_traceinfo_map, &demultiplex_context);
    }
}

#else
struct framer_params {
    u64 f_ptr;
    u64 offset;
    struct trace_info traceinfo;
};
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, struct context_t);
    __type(value, struct framer_params);
} framer_traceinfo_map SEC(".maps");



static unsigned char *hex = (unsigned char *)"0123456789abcdef";
static unsigned char *reverse_hex =
    (unsigned char *)"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\xff\xff\xff\xff\xff\xff"
                     "\xff\x0a\x0b\x0c\x0d\x0e\x0f\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\x0a\x0b\x0c\x0d\x0e\x0f\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff"
                     "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff";
static __always_inline void decode_hex(unsigned char *dst, const unsigned char *src, int src_len) {
    for (int i = 1, j = 0; i < src_len; i += 2) {
        unsigned char p = src[i - 1];
        unsigned char q = src[i];

        unsigned char a = reverse_hex[p & 0xff];
        unsigned char b = reverse_hex[q & 0xff];

        a = a & 0x0f;
        b = b & 0x0f;

        dst[j++] = ((a << 4) | b) & 0xff;
    }
}

static __always_inline void encode_hex(unsigned char *dst, const unsigned char *src, int src_len) {
    for (int i = 0, j = 0; i < src_len; i++) {
        unsigned char p = src[i];
        dst[j++] = hex[(p >> 4) & 0xff];
        dst[j++] = hex[p & 0x0f];
    }
}

static __always_inline bool is_traceparent(const unsigned char *p) {
    if (((p[0] == 'T') || (p[0] == 't')) && (p[1] == 'r') && (p[2] == 'a') && (p[3] == 'c') &&
        (p[4] == 'e') && ((p[5] == 'p') || (p[5] == 'P')) && (p[6] == 'a') && (p[7] == 'r') &&
        (p[8] == 'e') && (p[9] == 'n') && (p[10] == 't') && (p[11] == ':') && (p[12] == ' ')) {
        return true;
    }

    return false;
}

#define bpf_clamp_umax(VAR, UMAX)                                                                  \
    asm volatile("if %0 <= %[max] goto +1\n"                                                       \
                 "%0 = %[max]\n"                                                                   \
                 : "+r"(VAR)                                                                       \
                 : [max] "i"(UMAX))

#define HTTP2_ENCODED_HEADER_LEN                                                                   \
66 // 1 + 1 + 8 + 1 + 55 = type byte + hpack_len_as_byte("traceparent") + strlen(hpack("traceparent")) + len_as_byte(55) + generated traceparent id

#define FLAGS_SIZE_BYTES 1
#define TRACE_ID_CHAR_LEN 32
#define SPAN_ID_CHAR_LEN 16
#define FLAGS_CHAR_LEN 2
#define TP_MAX_VAL_LENGTH 55
#define TP_MAX_KEY_LENGTH 11
#define TP_ENCODED_LEN 8
static unsigned char tp_encoded[TP_ENCODED_LEN] = {
    0x4d, 0x83, 0x21, 0x6b, 0x1d, 0x85, 0xa9, 0x3f}; // hpack encoded "traceparent"



#define TRACE_ID_SIZE_BYTES 16
#define SPAN_ID_SIZE_BYTES 8
static __always_inline void make_tp_string(unsigned char *buf, struct trace_info *tp) {
    // Version
    *buf++ = '0';
    *buf++ = '0';
    *buf++ = '-';
    
    unsigned char trace_id[TRACE_ID_SIZE_BYTES] = {0};
    
    // TraceID
    encode_hex(buf, trace_id, TRACE_ID_SIZE_BYTES);
    buf += TRACE_ID_CHAR_LEN;
    *buf++ = '-';
    
    // SpanID
    encode_hex(buf, (const unsigned char*)&tp->traceid, SPAN_ID_SIZE_BYTES);
    buf += SPAN_ID_CHAR_LEN;
    *buf++ = '-';
    
    // Flags
    *buf++ = '0';
    *buf = '1';
}
enum { W3C_KEY_LENGTH = 11, W3C_VAL_LENGTH = 55 };
// typedef struct grpc_header_field {
//     u8 *key_ptr;
//     u64 key_len;
//     u8 *val_ptr;
//     u64 val_len;
//     u64 sensitive;
// } grpc_header_field_t;

static __always_inline int bpf_memicmp(const char *s1, const char *s2, s32 size) {
    for (int i = 0; i < size; i++) {
        if (s1[i] != s2[i] && s1[i] != (s2[i] - 32)) // compare with each uppercase character
        {
            return i + 1;
        }
    }

    return 0;
}

static __always_inline void decode_go_traceparent(unsigned char *buf,
    unsigned char *trace_id,
    unsigned char *span_id) {
    unsigned char *t_id = buf + 2 + 1; // strlen(ver) + strlen("-")
    unsigned char *s_id =
    buf + 2 + 1 + 32 + 1; // strlen(ver) + strlen("-") + strlen(trace_id) + strlen("-")
    unsigned char *f_id =
    buf + 2 + 1 + 32 + 1 + 16 +
    1; // strlen(ver) + strlen("-") + strlen(trace_id) + strlen("-") + strlen(span_id) + strlen("-")

    decode_hex(span_id, s_id, SPAN_ID_CHAR_LEN);
}
static __always_inline void process_meta_frame_headers(void *frame, struct trace_info *tp) {
    if (!frame) {
        return;
    }


    void *fields = 0;
    u64 fields_off = 0x8;
    bpf_probe_read(&fields, sizeof(fields), (void *)(frame + fields_off));
    u64 fields_len = 0;
    bpf_probe_read(&fields_len, sizeof(fields_len), (void *)(frame + fields_off + 8));
    grpc_debug("fields ptr %llx, len %d", fields, fields_len);
    if (fields && fields_len > 0) {
        for (u8 i = 0; i < 16; i++) {
            if (i >= fields_len) {
                break;
            }
            void *field_ptr = fields + (i * sizeof(grpc_header_field_t));
            //bpf_dbg_printk("field_ptr %llx", field_ptr);
            grpc_header_field_t field = {};
            bpf_probe_read(&field, sizeof(grpc_header_field_t), field_ptr);
            //bpf_dbg_printk("grpc header %s:%s", field.key_ptr, field.val_ptr);
            //bpf_dbg_printk("grpc sizes %d:%d", field.key_len, field.val_len);
            if (field.key_len == W3C_KEY_LENGTH && field.val_len == W3C_VAL_LENGTH) {
                u8 temp[W3C_VAL_LENGTH];

                bpf_probe_read(&temp, W3C_KEY_LENGTH, field.key_ptr);
                if (!bpf_memicmp((const char *)temp, "traceparent", W3C_KEY_LENGTH)) {
                    bpf_probe_read(&temp, W3C_VAL_LENGTH, field.val_ptr);
                    uint8_t tp_str[TP_MAX_VAL_LENGTH];
                    decode_go_traceparent(temp, tp_str, (unsigned char*)&tp->traceid);
                    break;
                }
            }
        }
    }
}

SEC("uprobe")
int BPF_KPROBE(grpc_operate_headers){
    // go routine pass as ctx->r14
    void* metaframe = (void*)ctx->bx;
    void* headerframe;
    u32 streamid;

    bpf_probe_read(&headerframe, sizeof(headerframe), metaframe);
    bpf_probe_read(&streamid, sizeof(u32),headerframe+0x8);

    struct context_t context = {
        .execution_context = ctx->r14, // r14 is the goroutine pointer
        .pid = bpf_get_current_pid_tgid() >> 32,
        .type = CONTEXT_GOROUTINE,
    };

    struct trace_info traceinfo = {0};
    process_meta_frame_headers(metaframe, &traceinfo);
    if(traceinfo.traceid == 0){
        grpc_debug("[grpc-operate-headers]: no traceid found in meta frame, skip\n");
        return 0; // no traceid found
    }
    traceinfo.from_network_thread=1;
    __sync_fetch_and_add(&metric_total_parse_streams_count, 1);
    grpc_debug("[grpc-operate-headers]: found traceid %lu in meta frame, streamid %u, goid %p\n",traceinfo.traceid,streamid,context.execution_context);
    bpf_map_update_elem(&execution_context_traceinfo_map,&context,&traceinfo,BPF_ANY);

    return 0;
}

#endif // GRPC_IP_TAGGING

#if GRPC_IP_TAGGING == 1
// runtime.newproc1 return
SEC("uprobe")
int BPF_KPROBE(runtime_newproc1_exit){
    u64 new_goroutine_addr = ctx->ax;
    // u64 current_goroutine_addr = ctx->r14; // r14 is the goroutine pointer
    u64 rsp = ctx->sp;
    u64 current_goroutine_addr = 0;
    bpf_probe_read_user(&current_goroutine_addr, sizeof(current_goroutine_addr), (void*)(rsp + 0x10)); // read the current goroutine address from stack


    struct context_t parent_context = {
        .execution_context = current_goroutine_addr,
        .pid = bpf_get_current_pid_tgid() >> 32,
        .type = CONTEXT_GOROUTINE,
   };

   struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map,&parent_context);
   if(traceinfo){
        // just propogate the 
        struct context_t new_context = {
            .execution_context = new_goroutine_addr,
            .pid = bpf_get_current_pid_tgid() >> 32,
            .type =CONTEXT_GOROUTINE,
        };
        u32 temp_from_network_thread = traceinfo->from_grpc_operate_header;
        traceinfo->from_grpc_operate_header = 0; // reset the from_network_thread flag, just work for network thread
        bpf_map_update_elem(&execution_context_traceinfo_map,&new_context,traceinfo,BPF_ANY);
        grpc_debug("[grpc-newproc]: propogate traceid %lu from goid %p to new goid %p\n",traceinfo->traceid,parent_context.execution_context,new_context.execution_context);
        if(temp_from_network_thread){
            // if the parent goroutine is from network thread, we can delete it
            bpf_map_delete_elem(&execution_context_traceinfo_map,&parent_context);
        }
        
   }
}
#else
SEC("uprobe")
int BPF_KPROBE(runtime_newproc1_exit){
    u64 new_goroutine_addr = ctx->ax;
    // u64 current_goroutine_addr = ctx->r14; // r14 is the goroutine pointer
    u64 rsp = ctx->sp;
    u64 current_goroutine_addr = 0;
    bpf_probe_read_user(&current_goroutine_addr, sizeof(current_goroutine_addr), (void*)(rsp + 0x10)); // read the current goroutine address from stack


    struct context_t parent_context = {
        .execution_context = current_goroutine_addr,
        .pid = bpf_get_current_pid_tgid() >> 32,
        .type = CONTEXT_GOROUTINE,
   };

   struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map,&parent_context);
   if(traceinfo) {
       // just propogate the
       struct context_t new_context = {
           .execution_context = new_goroutine_addr,
           .pid = bpf_get_current_pid_tgid() >> 32,
           .type =CONTEXT_GOROUTINE,
       };
       grpc_debug("[grpc-newproc]: propogate traceid %lu from goid %p to new goid %p\n",traceinfo->traceid,parent_context.execution_context,new_context.execution_context);
       struct trace_info new_traceinfo = {
           .traceid = traceinfo->traceid,
           .spanid = traceinfo->spanid,
           .from_network_thread = 0,
       };
       bpf_map_update_elem(&execution_context_traceinfo_map,&new_context,&new_traceinfo,BPF_ANY);
       if(traceinfo->from_network_thread){
           bpf_map_delete_elem(&execution_context_traceinfo_map,&parent_context);
       }
   }
   return 0;
}
#endif

// multiplex
//google.golang.org/grpc/internal/transport.(*controlBuffer).executeAndPut
SEC("uprobe")
int BPF_KPROBE(grpc_control_buffer_execute_and_put)
{
    struct context_t context = {
        .execution_context = ctx->r14, // r14 is the goroutine pointer
        .pid = bpf_get_current_pid_tgid() >> 32,
        .type = CONTEXT_GOROUTINE,
    };
    struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map,&context);
    if(!traceinfo)  return 0;
    struct go_app_specific_info* info = (struct go_app_specific_info*)bpf_map_lookup_elem(&pid_go_info_map,&context.pid);
    if(!info){
        grpc_debug("[grpc-execute-put]:not found go app info for pid %u\n",context.pid);
        return 0;
    }
    if(info->grpc_dataframe_ptr == ctx->cx){
        u64 dataframe = ctx->di;
        u32 streamid = 0;
        bpf_probe_read_user(&streamid,sizeof(streamid),(void*)dataframe);
        grpc_debug("[grpc-execute-put]: attach traceid %u to dataframe %x streamid %u\n",traceinfo->traceid,dataframe,streamid);
        bpf_map_update_elem(&dataframe_traceinfo_map,&dataframe,traceinfo,BPF_ANY);
    }
    return 0;
}

#if GRPC_IP_TAGGING == 0
// replace the get function
//google.golang.org/grpc/internal/transport.(*loopyWriter).handle
SEC("uprobe")
int BPF_KPROBE(grpc_internal_transport_loopyWriter_headerHandler)
{
    u64 loopyWriter = ctx->ax;
    u64 headerframe = ctx->bx;
    u64 side = 0;
    u32 streamid = 0;
    u32 end_stream = 0;
    struct trace_info *traceinfo = (struct trace_info*)bpf_map_lookup_elem(&dataframe_traceinfo_map,&headerframe);
    // traceinfo->multiplex_info_idx == 0
    if(traceinfo){
        bpf_probe_read(&side,sizeof(side),(void*)loopyWriter);

        if(side == 0){
            //client side
            // generate a sendmsg event, tcp_seq is the streamid
            bpf_probe_read_user(&streamid,sizeof(streamid),(void*)headerframe);

            // mark current goroutine need to propogate the traceinfo
            struct context_t context = {
                .execution_context = ctx->r14, // r14 is the goroutine pointer
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = CONTEXT_GOROUTINE,
            };
            __sync_fetch_and_add(&metric_total_send_streams_count, 1);
            bpf_map_update_elem(&execution_context_traceinfo_map,&context,traceinfo,BPF_ANY);
            grpc_debug("[grpc-loopyWriter-handle]: client side, traceid %u, streamid %u propogate to context %p\n",traceinfo->traceid,streamid,context.execution_context);
        }else{
            //server side
            bpf_probe_read_user(&streamid,sizeof(streamid),(void*)headerframe);
            bpf_probe_read_user(&end_stream,sizeof(end_stream),(void*)headerframe+0x20);
            if(end_stream){
                bpf_map_delete_elem(&dataframe_traceinfo_map,&headerframe);
                return 0;
            }
            grpc_debug("[grpc-loopyWriter-handle]: server side, traceid %u, streamid %u, end_stream %u\n",traceinfo->traceid,streamid,end_stream);
            //generate a sendmsg event, tcp_seq is the streamid
        }
        bpf_map_delete_elem(&dataframe_traceinfo_map,&headerframe);
    }
    return 0;
}
#else

SEC("uprobe")
int BPF_KPROBE(grpc_internal_transport_loopyWriter_headerHandler)
{
    u64 loopyWriter = ctx->ax;
    u64 headerframe = ctx->bx;
    u64 side = 0;
    u32 streamid = 0;
    u32 end_stream = 0;
    struct trace_info *traceinfo = (struct trace_info*)bpf_map_lookup_elem(&dataframe_traceinfo_map,&headerframe);
    // traceinfo->multiplex_info_idx == 0
    if(traceinfo){
        bpf_probe_read(&side,sizeof(side),(void*)loopyWriter);

        struct context_t context = {
            .execution_context = ctx->r14, // r14 is the goroutine pointer
            .pid = bpf_get_current_pid_tgid() >> 32,
            .type = CONTEXT_GOROUTINE,
        };
        if(side == 0){
            //client side
            // generate a sendmsg event, tcp_seq is the streamid
            bpf_probe_read_user(&streamid,sizeof(streamid),(void*)headerframe);
            traceinfo->stream_count=1;
            traceinfo->streamids[0] = streamid;
            traceinfo->tcp_seq = 0;
            traceinfo->is_response=0;
            // mark current goroutine need to propogate the traceinfo
            __sync_fetch_and_add(&metric_total_send_streams_count, 1);
            // check and merge the traceinfo
            // struct trace_info *to_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map,&context);
            // if(to_traceinfo){
            //     grpc_debug("[grpc-loopyWriter-handle]: merge traceinfo for goid %p, traceid %u, streamid %u\n",context.execution_context,traceinfo->traceid,streamid);
            //     merge_trace_infos(to_traceinfo,traceinfo);
            // }else{
            //     grpc_debug("[grpc-loopyWriter-handle]: found new traceinfo for goid %p, traceid %u, streamid %u\n",context.execution_context,traceinfo->traceid,streamid);
            //     bpf_map_update_elem(&execution_context_traceinfo_map,&context,traceinfo,BPF_ANY);
            // }

            grpc_debug("[grpc-loopyWriter-handle]: client side, traceid %u, streamid %u propogate\n",traceinfo->traceid,streamid);
        }else{
            //server side
            bpf_probe_read_user(&streamid,sizeof(streamid),(void*)headerframe);
            bpf_probe_read_user(&end_stream,sizeof(end_stream),(void*)headerframe+0x20);
            if(end_stream){
                bpf_map_delete_elem(&dataframe_traceinfo_map,&headerframe);
                return 0;
            }
            grpc_debug("[grpc-loopyWriter-handle]: server side, traceid %u, streamid %u, end_stream %u\n",traceinfo->traceid,streamid,end_stream);
            traceinfo->stream_count=1;
            traceinfo->streamids[0] = streamid;
            traceinfo->tcp_seq = 0;
            traceinfo->is_response=1;
            //generate a sendmsg event, tcp_seq is the streamid
        }


        struct grpc_headers_event* grpc_event = (struct grpc_headers_event*)bpf_ringbuf_reserve(&event_ringbuf, sizeof(struct grpc_headers_event), 0);
        if(grpc_event){
            grpc_event->traceid=traceinfo->traceid;
            grpc_event->streamid = streamid;
            grpc_event->header_count = 0;
            // parse header fied
            void* fields = 0;
            u64 fields_off = 8;
            bpf_probe_read(&fields, sizeof(fields), (void *)(headerframe + fields_off));
            u64 fields_len = 0;
            bpf_probe_read(&fields_len, sizeof(fields_len), (void *)(headerframe + fields_off + 8));
            grpc_debug("fields ptr %llx, len %d", fields, fields_len);
            if (fields && fields_len > 0) {
                for (u8 i = 0; i < MAX_GRPC_HEADERS; i++) {
                    if (i >= fields_len) {
                        break;
                    }
                    void *field_ptr = fields + (i * sizeof(grpc_header_field_t));
                    //bpf_dbg_printk("field_ptr %llx", field_ptr);
                    grpc_header_field_t field = {};
                    bpf_probe_read(&field, sizeof(grpc_header_field_t), field_ptr);
                    //bpf_dbg_printk("grpc header %s:%s", field.key_ptr, field.val_ptr);
                    //bpf_dbg_printk("grpc sizes %d:%d", field.key_len, field.val_len);
                    bpf_probe_read(&grpc_event->headers_key[i], field.key_len & (MAX_GRPC_HEADER_KEY_LENGTH - 1), (void *)field.key_ptr);
                    bpf_probe_read(&grpc_event->headers_val[i], field.val_len & (MAX_GRPC_HEADER_VAL_LENGTH - 1), (void *)field.val_ptr);
                    grpc_event->header_key_lens[i]=field.key_len;
                    grpc_event->header_val_lens[i]=field.val_len;
                    grpc_event->header_count++;
                }
            }
            bpf_ringbuf_submit(grpc_event, 0);
        }

        struct trace_info *to_traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map,&context);
        if(to_traceinfo){
            grpc_debug("[grpc-loopyWriter-handle]: merge traceinfo for goid %p, traceid %u, streamid %u\n",context.execution_context,traceinfo->traceid,streamid);
            merge_trace_infos(to_traceinfo,traceinfo);
        }else{
            grpc_debug("[grpc-loopyWriter-handle]: found new traceinfo for goid %p, traceid %u, streamid %u\n",context.execution_context,traceinfo->traceid,streamid);
            bpf_map_update_elem(&execution_context_traceinfo_map,&context,traceinfo,BPF_ANY);
        }

        bpf_map_delete_elem(&dataframe_traceinfo_map,&headerframe);
    }
    return 0;
}

#endif

// runtime.goexit1
SEC("uprobe")
int BPF_KPROBE(runtime_goexit1){
    struct context_t context = {
        .execution_context = ctx->r14, // r14 is the goroutine pointer
        .pid = bpf_get_current_pid_tgid() >> 32,
        .type = CONTEXT_GOROUTINE,
    };
    bpf_map_delete_elem(&execution_context_traceinfo_map,&context);
    return 0;
}


#if GRPC_IP_TAGGING == 0
#define MAX_W_PTR_OFFSET 1024
// runtime.goexit1
SEC("uprobe")
int BPF_KPROBE(framer_WriteHeaders){
    struct context_t context = {
        .execution_context = ctx->r14, // r14 is the goroutine pointer
        .pid = bpf_get_current_pid_tgid() >> 32,
        .type = CONTEXT_GOROUTINE,
    };
    struct trace_info* traceinfo = (struct trace_info*)bpf_map_lookup_elem(&execution_context_traceinfo_map,&context);
    if(traceinfo){
        u64 f_ptr = ctx->ax;
        u64 w_ptr = 0;
        bpf_probe_read(&w_ptr, sizeof(w_ptr), (void*)(f_ptr + 0x78 + 0x8));
        u64 offset = 0;
        bpf_probe_read(&offset, sizeof(offset), (void*)(w_ptr + 0x18));
        grpc_debug("[grpc-framer-write-headers]: f_ptr %p, w_ptr %p, offset %llu\n", f_ptr, w_ptr, offset);
        if(offset > MAX_W_PTR_OFFSET){
            //TODO: produce a drop event
            grpc_debug("[grpc-framer-write-headers]: offset %llu exceeds max offset %u, skip\n",offset,MAX_W_PTR_OFFSET);
            __sync_fetch_and_add(&metric_grpc_header_inject_fail_count, 1);
            bpf_map_delete_elem(&execution_context_traceinfo_map,&context);
            return 0; // skip if offset is too large
        }
        struct framer_params params = {
            .f_ptr = f_ptr,
            .offset = offset,
            .traceinfo = *traceinfo, // copy the traceinfo
        };
        bpf_map_update_elem(&framer_traceinfo_map,&context,&params,BPF_ANY);
        bpf_map_delete_elem(&execution_context_traceinfo_map,&context);
    }
    return 0;
}

SEC("uprobe")
int BPF_KPROBE(framer_WriteHeaders_return){
    struct context_t context = {
        .execution_context = ctx->r14, // r14 is the goroutine pointer
        .pid = bpf_get_current_pid_tgid() >> 32,
        .type = CONTEXT_GOROUTINE,
    };
    struct framer_params* params = (struct framer_params*)bpf_map_lookup_elem(&framer_traceinfo_map,&context);
    if(params){
        u64 f_ptr = params->f_ptr;
        u64 w_ptr = 0;
        bpf_probe_read(&w_ptr, sizeof(w_ptr), (void*)(f_ptr + 0x78 + 0x8));

        if(w_ptr){
            void* buf_arr =0;
            bpf_probe_read(&buf_arr, sizeof(buf_arr), (void*)(w_ptr + 0x0));
            u64 cap = 0;
            bpf_probe_read(&cap, sizeof(cap), (void*)(w_ptr + 0x10));
            u64 n =0;
            bpf_probe_read(&n, sizeof(n), (void*)(w_ptr + 0x18));
            u64 off = params->offset;
            grpc_debug("[grpc-framer-write-headers-return]: w_ptr %p, buf_arr %p, cap %llu, n %llu, off %llu\n", w_ptr, buf_arr, cap, n, off);

            bpf_clamp_umax(off, MAX_W_PTR_OFFSET);
            if (buf_arr && n < (cap - HTTP2_ENCODED_HEADER_LEN)) {
                uint8_t tp_str[TP_MAX_VAL_LENGTH];

                // http2 encodes the length of the headers in the first 3 bytes of buf, we need to update those
                u8 size_1 = 0;
                u8 size_2 = 0;
                u8 size_3 = 0;

                bpf_probe_read(&size_1, sizeof(size_1), (void *)(buf_arr + off));
                bpf_probe_read(&size_2, sizeof(size_2), (void *)(buf_arr + off + 1));
                bpf_probe_read(&size_3, sizeof(size_3), (void *)(buf_arr + off + 2));

                grpc_debug("size 1:%x, 2:%x, 3:%x", size_1, size_2, size_3);

                u32 original_size = ((u32)(size_1) << 16) | ((u32)(size_2) << 8) | size_3;

                if (original_size > 0) {
                    u8 type_byte = 0;
                    u8 key_len =
                        TP_ENCODED_LEN | 0x80; // high tagged to signify hpack encoded value
                    u8 val_len = TP_MAX_VAL_LENGTH;

                    // We don't hpack encode the value of the traceparent field, because that will require that
                    // we use bpf_loop, which in turn increases the kernel requirement to 5.17+.
                    make_tp_string(tp_str, &params->traceinfo);
                    //bpf_dbg_printk("Will write %s, type = %d, key_len = %d, val_len = %d", tp_str, type_byte, key_len, val_len);

                    bpf_probe_write_user(buf_arr + (n & 0x0ffff), &type_byte, sizeof(type_byte));
                    n++;
                    // Write the length of the key = 8
                    bpf_probe_write_user(buf_arr + (n & 0x0ffff), &key_len, sizeof(key_len));
                    n++;
                    // Write 'traceparent' encoded as hpack
                    bpf_probe_write_user(buf_arr + (n & 0x0ffff), tp_encoded, sizeof(tp_encoded));
                    ;
                    n += TP_ENCODED_LEN;
                    // Write the length of the hpack encoded traceparent field
                    bpf_probe_write_user(buf_arr + (n & 0x0ffff), &val_len, sizeof(val_len));
                    n++;
                    bpf_probe_write_user(buf_arr + (n & 0x0ffff), tp_str, sizeof(tp_str));
                    n += TP_MAX_VAL_LENGTH;
                    // Update the value of n in w to reflect the new size
                    bpf_probe_write_user(
                        (void *)(w_ptr + 0x18),
                        &n,
                        sizeof(n));

                    u32 new_size = original_size + HTTP2_ENCODED_HEADER_LEN;

                    grpc_debug("Changing size from %d to %d", original_size, new_size);
                    size_1 = (u8)(new_size >> 16);
                    size_2 = (u8)(new_size >> 8);
                    size_3 = (u8)(new_size);

                    bpf_probe_write_user((void *)(buf_arr + off), &size_1, sizeof(size_1));
                    bpf_probe_write_user((void *)(buf_arr + off + 1), &size_2, sizeof(size_2));
                    bpf_probe_write_user((void *)(buf_arr + off + 2), &size_3, sizeof(size_3));
                }
            }
        }
        bpf_map_delete_elem(&framer_traceinfo_map,&context);
    }
    return 0;
}
#else
SEC("uprobe")
int BPF_KPROBE(framer_WriteHeaders){
    grpc_debug("[grpc-framer-write-headers]: framer_WriteHeaders called, but grpc_ip_tagging is disabled\n");
    return 0;
}

SEC("uprobe")
int BPF_KPROBE(framer_WriteHeaders_return){
    grpc_debug("[grpc-framer-write-headers]: framer_WriteHeaders_return called, but grpc_ip_tagging is disabled\n");
    return 0;
}
#endif // GRPC_IP_TAGGING == 0
