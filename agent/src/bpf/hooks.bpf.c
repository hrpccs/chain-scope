#include "common/config.h"
#include "trace_info.h"
#include "net_helpers.h"
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "common/macros.h"
#include "event.h"
#include "tcp.h"
#include "udp.h"
#include "ip.h"
#include "grpc.h"
#include "sampling.h"
#include "socket.h"
#include "test/goroutine.h"


// Dummy instance to get skeleton for rs code
struct tcp_event _val = {0};
struct socket_data_event _val4 = {0};
struct go_app_specific_info _val5 = {0};
struct skb_event _val6 = {0};
struct spaninfo_t _val7 = {0};
struct tcp_event_with_streamid _val8 = {0};
struct grpc_headers_event _val9 = {0};
// Dummy instance to get queue_size
//HINT: size of option is multiple of 4
struct tcp_hdr_opt_tracing expected_opt = {252, sizeof(struct tcp_hdr_opt_tracing), __bpf_htons(0xeB9F)};
struct ip_hdr_opt_tracing ip_expected_opt = {((1<<7) | (2<<5) | 0xe),sizeof(struct ip_hdr_opt_tracing),__bpf_htons(0xeb9f)};
struct ip_hdr_opt_tracing_with_span ip_expected_opt_with_span = {((1<<7) | (2<<5) | 0xe),sizeof(struct ip_hdr_opt_tracing_with_span),__bpf_htons(0xeb8f)};
// u32 sample_interval = 5;aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
#define RECOMPILE aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

u64 metric_rpc_drop_at_ip_tagging_non_split = 0;
u64 metric_rpc_drop_at_ip_tagging_when_split = 0;
u64 metric_total_ip_tagging_streams_count = 0;
u64 metric_total_ip_tagging_before_tagging_streams_count = 0;
u64 metric_total_ip_tagging_parse_streams_count = 0;
u64 metric_total_ip_tagging_count = 0;
u64 metric_total_ip_tagging_parse_count = 0;

#if DEBUG_LEVEL > 0 && defined(DEBUG_IP)
#define ip_debug(fmt, ...) bpf_printk(fmt, ##__VA_ARGS__)
#else
#define ip_debug(fmt, ...)
#endif


u32 veth_gso_ifindex = 0;
u32 pnic_ifindex = 0;

//u8 count
//u32 stream_base
//u8 stream_offset
#if GRPC_IP_TAGGING == 1
static __always_inline
void parse_additional_info(struct trace_info *traceinfo,void* info_start,u32 info_len){
    u32 buf[MAX_STREAMS_IN_IP_OPTION + 1] = {0};
    bpf_probe_read_kernel(buf,sizeof(buf),info_start);
    u32 stream_count = buf[0];
    for(int i = 1;i <= stream_count;i++){
        if(i-1 >= MAX_STREAMS_IN_IP_OPTION) break;
        traceinfo->streamids[i-1] = buf[i];
        traceinfo->stream_count++;
        ip_debug("\t parse streamid[%u] %u",i-1,buf[i]);
    }

}
/* IP flags. */
#define IP_CE		0x8000		/* Flag: "Congestion"		*/
#define IP_DF		0x4000		/* Flag: "Don't Fragment"	*/
#define IP_MF		0x2000		/* Flag: "More Fragments"	*/
#define IP_OFFSET	0x1FFF		/* "Fragment Offset" part	*/
static inline bool ip_is_fragment(const struct iphdr *iph)
{
	return (iph->frag_off & __bpf_htons(IP_MF | IP_OFFSET)) != 0;
}

struct vxlan_hdr {
    __be32 vx_flags;
    __be32 vx_vni;
} __attribute__((packed));
// trigger at vxlan packet
//int ip_options_compile(struct net *net, struct ip_options *opt, struct sk_buff *skb)
//TODO: fix this, for now, some time we can not read the udp header.
SEC("fentry/ip_options_compile")
int BPF_PROG(ip_options_compile_entry,struct net *net, struct ip_options *opt, struct sk_buff *skb){
    if(skb == NULL) return 0;
    int err=0;
    struct iphdr* iph_ptr = (struct iphdr*)(skb->head + skb->network_header);
    struct iphdr iph;
    bpf_probe_read_kernel(&iph, sizeof(iph), iph_ptr);
    u16 iph_len = iph.ihl << 2;
    void* opt_start = (void*)iph_ptr + sizeof(struct iphdr);
    u16 opt_size = iph_len - sizeof(struct iphdr);

    u8 index = 0;
    for(int i=0;i<40;i++){
        u8 remaining = opt_size - index;
        #if EXPORT_SPANS == 1
        struct ip_hdr_opt_tracing_with_span current_opt = {0};
        if(remaining < sizeof(struct ip_hdr_opt_tracing_with_span)){ // impossible to find a valid option
            break;
        }
        bpf_probe_read_kernel(&current_opt, sizeof(struct ip_hdr_opt_tracing), opt_start + index);
        #else
        struct ip_hdr_opt_tracing current_opt = {0};
        if(remaining < sizeof(struct ip_hdr_opt_tracing)){ // impossible to find a valid option
            break;
        }
        bpf_probe_read_kernel(&current_opt, sizeof(struct ip_hdr_opt_tracing), opt_start + index);
        #endif

        if(current_opt.option_len >  remaining){
            ip_debug("[ip-options-compile]: found ip option with invalid length\n");
            break;
        }

        if(current_opt.option_type == 0){
            break;
        }
        if(current_opt.option_type == 1){
            index++;
            continue;
        }
        if(current_opt.magic == ip_expected_opt.magic || current_opt.magic == ip_expected_opt_with_span.magic || current_opt.magic == 0xeb9f){
            u32 traceid = __bpf_ntohl(current_opt.traceid);
            u32 tcp_seq = __bpf_ntohl(current_opt.tcp_seq);
            u32 spanid = 0;
            #if EXPORT_SPANS == 1
            spanid = __bpf_ntohl(current_opt.spanid);
            #endif

            u32 percpu_map_key = 0;
            struct trace_info *traceinfo = bpf_map_lookup_elem(&percpu_tmp_traceinfo, &percpu_map_key);
            if(traceinfo == NULL){
                ip_debug("[ip-options-compile]: get percpu_tmp_traceinfo failed\n");
                return 0;
            }
            traceinfo->is_response=0;
            traceinfo->traceid = traceid;
            traceinfo->spanid = spanid;
            traceinfo->stream_count = 0;
            traceinfo->tcp_seq = tcp_seq; // update the traceinfo with the skb_seq
            if(current_opt.magic == 0xeb9f){
                traceinfo->is_response = 1; // server side
                ip_debug("[ip-options-compile]: found traceid %u from skb %p option_len %u is response\n",traceid,skb,current_opt.option_len);
            }
            // struct trace_info traceinfo = {
            //     .traceid = traceid,
            //     .spanid = spanid,
            //     .stream_count = 0
            // };
            ip_debug("[ip-options-compile]: found traceid %u from skb %p option_len %u\n",traceid,skb,current_opt.option_len);

            if(current_opt.option_len > sizeof(struct ip_hdr_opt_tracing)){
                ip_debug("[ip-options-compile]: there is additional traceinfo info_start %llx\n", opt_start + index + sizeof(struct ip_hdr_opt_tracing));
                u8 addition_len = current_opt.option_len - sizeof(struct ip_hdr_opt_tracing); 
                parse_additional_info(traceinfo, opt_start + index + sizeof(struct ip_hdr_opt_tracing), addition_len);
            }

            ip_debug("[ip-options-compile]: attach traceid %u with %u streamids to skb %p\n",traceinfo->traceid,traceinfo->stream_count,skb);

            err = bpf_map_update_elem(&tcp_seq_traceinfo_map,&tcp_seq,traceinfo,BPF_NOEXIST);
            if(err == 0){
                if(traceinfo->is_response == 0){
                    ip_debug("is not a response packet\n");
                    __sync_fetch_and_add(&metric_total_ip_tagging_parse_count, 1);
                    __sync_fetch_and_add(&metric_total_ip_tagging_parse_streams_count, traceinfo->stream_count);
                }else{
                    ip_debug("is a response packet\n");
                }
            }
            break;
        }
        index += current_opt.option_len; // next option start index
    }
    return 0;
}


#define MAX_PACKET_OFF 0xffff

__always_inline static 
__u16 csum_fold(__u32 csum)
{
	csum = (csum & 0xffff) + (csum >> 16);
	csum = (csum & 0xffff) + (csum >> 16);
	return (__u16)~csum;
}

// 辅助函数：解析以太网头部
static __always_inline struct ethhdr* parse_eth(void *data, void *data_end) {
    struct ethhdr *eth = data;
    
    if ((void *)(eth + 1) > data_end)
        return NULL;
        
    return eth;
}

// 辅助函数：解析IP头部
static __always_inline struct iphdr* parse_ip(void *data, void *data_end) {
    struct iphdr *ip = data;
    
    if ((void *)(ip + 1) > data_end)
        return NULL;
        
    // 检查IP头部长度
    if (ip->ihl < 5)
        return NULL;
        
    if ((void *)ip + (ip->ihl * 4) > data_end)
        return NULL;
        
    return ip;
}

// 辅助函数：解析UDP头部
static __always_inline struct udphdr* parse_udp(void *data, void *data_end) {
    struct udphdr *udp = data;
    
    if ((void *)(udp + 1) > data_end)
        return NULL;
        
    return udp;
}

// 辅助函数：解析TCP头部
static __always_inline struct tcphdr* parse_tcp(void *data, void *data_end) {
    struct tcphdr *tcp = data;
    
    if ((void *)(tcp + 1) > data_end)
        return NULL;
        
    return tcp;
}

void *bpf_cast_to_kern_ctx(void *) __ksym;

#define VXLAN_PORT 8472

SEC("tc")
int veth_return_ingress(struct __sk_buff *ctx){
    struct trace_info* traceinfo = NULL;
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;   

    return bpf_redirect(pnic_ifindex, 0); // redirect to pnic interface
}


// ip tagging only for outgoing packets
SEC("tc")
int pnic_egress_ip_tagging(struct __sk_buff *ctx){
    struct trace_info* traceinfo = NULL;
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // Parse the outher Ethernet header
    struct ethhdr *outer_eth = parse_eth(data, data_end);
    if (!outer_eth || __bpf_ntohs(outer_eth->h_proto) != ETH_P_IP)
        return 0;

    struct iphdr *outer_ip = parse_ip(data + sizeof(*outer_eth), data_end);
    if (!outer_ip || outer_ip->protocol != IPPROTO_UDP)
        return 0;

    // Parse the outer UDP header
    void *udp_start = (void *)outer_ip + (outer_ip->ihl * 4);
    struct udphdr *outer_udp = parse_udp(udp_start, data_end);
    if (!outer_udp || __bpf_ntohs(outer_udp->dest) != VXLAN_PORT)
        return 0;
    // 4. Skip the VXLAN header
    void *vxlan = (void *)(outer_udp + 1);
    if (vxlan + 8 > data_end) return TC_ACT_OK; // VXLAN header 8 bytes

    // 5. Parse the inner Ethernet header
    struct ethhdr *inner_eth = vxlan + 8;
    if ((void *)(inner_eth + 1) > data_end) return TC_ACT_OK;
    if (__bpf_ntohs(inner_eth->h_proto) != ETH_P_IP) return TC_ACT_OK;

    // 6. Resolve the inner IP address.
    struct iphdr *inner_ip = (void *)(inner_eth + 1);
    if ((void *)(inner_ip + 1) > data_end) return TC_ACT_OK;

    u32 seq_end = 0;
    u32 seq = 0;
    // 7. Determine the inner protocol type
    // 需要在 trace context 里面放一个 tcp seq.
    if (inner_ip->protocol == IPPROTO_TCP) {
        struct tcphdr *inner_tcp = (void *)inner_ip + (inner_ip->ihl * 4);
        if ((void *)(inner_tcp + 1) > data_end) return TC_ACT_OK;
        // At this point, inner_tcp refers to the internal TCP header.
        // It can read TCP fields such as seq, ack, source, and dest.
        seq = __bpf_ntohl(inner_tcp->seq);
        seq_end = __bpf_ntohl(inner_tcp->seq) + __bpf_htons(inner_ip->tot_len) - inner_ip->ihl * 4 - sizeof(struct tcphdr);
        //ip_debug("[pnic tc egress]: inner tcp packet detected, skb %p seq %u\n", ctx, seq);
        traceinfo = (struct trace_info*)bpf_map_lookup_elem(&tcp_seq_traceinfo_map,&seq);
        u32 size = __bpf_htons(inner_ip->tot_len) - inner_ip->ihl * 4 - sizeof(struct tcphdr);
        if(!traceinfo){
            // ip_debug("[pnic tc egress]: no traceinfo found for tcp skb %p seq %u size %u gso_segs %u gso_size %u\n",
                    //  ctx, seq, size, ctx->gso_segs, ctx->gso_size);
            return TC_ACT_OK;
        }

        ip_debug("[pnic tc egress]: try attach traceid %u to tcp skb %p seq %u size %u gso_segs %u gso_size %u\n",
                 traceinfo->traceid, ctx, seq, size, ctx->gso_segs, ctx->gso_size);
        #if GRPC_IP_TAGGING_WITH_REDISTRIBUTE == 1
        if(ctx->gso_segs >= 2){ // no matter how many traceid here, we need to do segmentation first, to avoid tagging wrong tcp seq at later small packets, the same ip option will occur on all small packets
            ip_debug("[pnic tc egress]: gso_segs >= 2, force to GSO\n");
            if(veth_gso_ifindex == 0){
                ip_debug("[pnic tc egress] : \tno veth_gso_ifindex set, cannot redirect");
                return TC_ACT_OK;
            }

            if(traceinfo->stream_count > MAX_STREAMS_IN_IP_OPTION){
                u32 next_copy_index = MAX_STREAMS_IN_IP_OPTION;
                for (int i = 1;i< ctx->gso_segs && i<6;i++) {
                    if(next_copy_index >= traceinfo->stream_count){
                        ip_debug("[pnic tc egress]: all streams copied to new traceinfo\n");
                        break;
                    }
                    u32 next_seq = seq + i * ctx->gso_size;
                    u32 percpu_map_key = 0;
                    struct trace_info *new_traceinfo = bpf_map_lookup_elem(&percpu_tmp_traceinfo, &percpu_map_key);
                    if (!new_traceinfo) {
                        ip_debug("[pnic tc egress]: get percpu_tmp_traceinfo failed for gso_segs %u\n", i);
                        return TC_ACT_OK;
                    }
                    // copy traceinfo to new_traceinfo
                    new_traceinfo->traceid = traceinfo->traceid;
                    new_traceinfo->spanid = traceinfo->spanid;
                    new_traceinfo->stream_count = 0;
                    // new_traceinfo->streamids[0] = traceinfo->streamids[next_copy_index];
                    for(int j=0;j<MAX_STREAMS_IN_IP_OPTION && next_copy_index < traceinfo->stream_count;j++){
                        // bpf_clamp_umax(next_copy_index, MAX_MULTIPLEX_STREAMS - 1);
                        new_traceinfo->streamids[j] = traceinfo->streamids[next_copy_index];
                        new_traceinfo->stream_count++;
                        next_copy_index++;
                    }
                    ip_debug("[pnic tc egress]: copy traceinfo to new_traceinfo %p with traceid %u stream_count %u\n",
                            new_traceinfo, new_traceinfo->traceid, new_traceinfo->stream_count);
                    new_traceinfo->tcp_seq = next_seq; // update the traceinfo with the skb_seq
                    bpf_map_update_elem(&tcp_seq_traceinfo_map, &next_seq, new_traceinfo, BPF_ANY);
                }
                if(next_copy_index < traceinfo->stream_count){
                    ip_debug("[pnic tc egress]: still have %u streams left, will not copy to new traceinfo,drop\n",
                            traceinfo->stream_count - next_copy_index);
                    __sync_add_and_fetch(&metric_rpc_drop_at_ip_tagging_when_split,
                                        traceinfo->stream_count - next_copy_index);
                }
                traceinfo->stream_count = MAX_STREAMS_IN_IP_OPTION;

            }

            ip_debug("[pnic tc egress]:  forwarding skb %p with traceid %u to veth_gso_ifindex %u\n",ctx,traceinfo->traceid,veth_gso_ifindex);
            return bpf_redirect(veth_gso_ifindex, 0); // redirect to pnic interface
        }
        #endif
    } 

    if(!traceinfo){
        return TC_ACT_OK;
    }
    u8 curr_ip_option_len = (outer_ip->ihl << 2) - sizeof(struct iphdr);
    u8 available_ip_option_len = 40-curr_ip_option_len;

    if(traceinfo->stream_count > 0 && traceinfo->stream_count <= MAX_MULTIPLEX_STREAMS ){
        const u32 count = sizeof(struct ip_hdr_opt_tracing) + sizeof(struct ip_hdr_opt_tracing_additional_info);
        if(count > available_ip_option_len){
            ip_debug("<tc egress> : \tcount %u > available_ip_option_len %u",count,available_ip_option_len);
            return TC_ACT_OK;
        }
        if(bpf_skb_adjust_room(ctx, count, BPF_ADJ_ROOM_NET, 0)) {
            ip_debug("<tc egress> : bpf_skb_adjust_room err");
            return TC_ACT_OK;
        }

        // new data room is just after the orig ip header
        data = (void *)(long)ctx->data;
        data_end = (void *)(long)ctx->data_end;
                
        // update ip header
        struct iphdr* iph = data + sizeof(struct ethhdr);
        if((void*)(iph + 1) > data_end) {
            ip_debug("<tc egress> : ip header err");
            return TC_ACT_SHOT;
        }

        iph->tot_len = __bpf_htons(__bpf_ntohs(iph->tot_len)+ count);
        iph->ihl =iph->ihl + count/4;
                
        #if EXPORT_SPANS == 1
        struct ip_hdr_opt_tracing_with_span* new_ip_opt = data + sizeof(struct ethhdr) + sizeof(struct iphdr);
        #else
        struct ip_hdr_opt_tracing* new_ip_opt = data + sizeof(struct ethhdr) + sizeof(struct iphdr);
        #endif
        if((void*)(new_ip_opt + 1) > data_end){
            ip_debug("<tc egress> err : new_ip_opt + 1 > data_end");
            return TC_ACT_SHOT;
        }
                
        new_ip_opt->tcp_seq = __bpf_htonl(seq);
        #if EXPORT_SPANS == 1
        new_ip_opt->magic = ip_expected_opt_with_span.magic;
        #else
        if(traceinfo->is_response == 0){
            __sync_fetch_and_add(&metric_total_ip_tagging_count, 1);
            new_ip_opt->magic = ip_expected_opt.magic;
        }else{
            new_ip_opt->magic = 0xeb9f;
            ip_debug("[tc egress] : \tresponse packet, magic 0xeb9f");
        }
        #endif
        new_ip_opt->traceid = __bpf_htonl(traceinfo->traceid);
        #if EXPORT_SPANS == 1
        new_ip_opt->spanid = __bpf_htonl(traceinfo->spanid);
        #endif
        new_ip_opt->option_type = 206;
        new_ip_opt->option_len = count;
        struct ip_hdr_opt_tracing_additional_info *additional_info = (struct ip_hdr_opt_tracing_additional_info*)(new_ip_opt + 1);
        if((void*)(additional_info + 1) > data_end){
            ip_debug("additional_info out of bounds");
            return TC_ACT_SHOT;
        }

        additional_info->stream_count = 0;

        // #if EXPORT_SPANS == 1
        // u8 streamid_count = count - sizeof(struct ip_hdr_opt_tracing_with_span) - 1;
        // #else
        // u8 streamid_count = count - sizeof(struct ip_hdr_opt_tracing) - 1;
        // #endif
        ip_debug("[ip options insert]: traceid %u stream_count %u\n",traceinfo->traceid,traceinfo->stream_count);
        for(int i=0;i<MAX_STREAMS_IN_IP_OPTION;i++){
            if(i < traceinfo->stream_count){
                additional_info->streamids[i] = traceinfo->streamids[i];
                additional_info->stream_count++;
                ip_debug("\ttag streamid[%u] %u\n",i,traceinfo->streamids[i]);
            }
        }

        if(traceinfo->is_response == 0){
            __sync_fetch_and_add(&metric_total_ip_tagging_streams_count, additional_info->stream_count);
            if(traceinfo->stream_count > MAX_STREAMS_IN_IP_OPTION){
                __sync_add_and_fetch(&metric_rpc_drop_at_ip_tagging_non_split, traceinfo->stream_count - MAX_STREAMS_IN_IP_OPTION);
                ip_debug("<tc egress> : \ttraceinfo->stream_count %u > MAX_STREAMS_IN_IP_OPTION %u, drop %u streams",
                        traceinfo->stream_count, MAX_STREAMS_IN_IP_OPTION, traceinfo->stream_count - MAX_STREAMS_IN_IP_OPTION);
            }
        }

        /* Recalculate checksums. */
        s64 value=0;
        iph->check = 0;
        value = bpf_csum_diff(0, 0, (void *)iph, sizeof(struct iphdr) + count, 0);
        if (value < 0){
            ip_debug("<tc egress> : bpf_csum_diff err %d",value);
            return TC_ACT_SHOT;
        }
        iph->check = csum_fold(value);
        ip_debug("<tc egress> : \tnew ip checksum %u iph->tot_len %u ihl %u",
                 iph->check, __bpf_ntohs(iph->tot_len), iph->ihl);

        bpf_map_delete_elem(&tcp_seq_traceinfo_map,&seq); // delete the old trace info
    }else{
        #if EXPORT_SPANS == 1
        const u8 count = sizeof(struct ip_hdr_opt_tracing_with_span);
        #else
        const u8 count = sizeof(struct ip_hdr_opt_tracing);
        #endif
        if(bpf_skb_adjust_room(ctx, count, BPF_ADJ_ROOM_NET, 0)) {
            ip_debug("<tc egress> : bpf_skb_adjust_room err");
            return TC_ACT_OK;
        }

        // new data room is just after the orig ip header
        data = (void *)(long)ctx->data;
        data_end = (void *)(long)ctx->data_end;
                
        // update ip header
        struct iphdr* iph = data + sizeof(struct ethhdr);
        if((void*)(iph + 1) > data_end){
            ip_debug("<tc egress> : ip header err");
            return TC_ACT_SHOT;
        }
                
        iph->tot_len = __bpf_htons(__bpf_ntohs(iph->tot_len)+ count);
        iph->ihl =iph->ihl + count/4;
        ip_debug("<tc egress> : \tnew ip tot_len %d ihl %d",iph->tot_len,iph->ihl);
                
        #if EXPORT_SPANS == 1
        struct ip_hdr_opt_tracing_with_span* new_ip_opt = data + sizeof(struct ethhdr) + sizeof(struct iphdr);
        #else
        struct ip_hdr_opt_tracing* new_ip_opt = data + sizeof(struct ethhdr) + sizeof(struct iphdr);
        #endif
        if((void*)(new_ip_opt + 1) > data_end){
            ip_debug("<tc egress> err : new_ip_opt + 1 > data_end");
            return TC_ACT_SHOT;
        }
                
        new_ip_opt->tcp_seq = __bpf_htonl(seq);
        new_ip_opt->magic = ip_expected_opt.magic;
        new_ip_opt->traceid = __bpf_htonl(traceinfo->traceid);
        #if EXPORT_SPANS == 1
        new_ip_opt->spanid = __bpf_htonl(traceinfo->spanid);
        #endif
        new_ip_opt->option_type = 206;
        new_ip_opt->option_len = count;
        /* Recalculate checksums. */
        s64 value=0;
        iph->check = 0;
        value = bpf_csum_diff(0, 0, (void *)iph, sizeof(struct iphdr) + count, 0);
        if (value < 0){
            ip_debug("<tc egress> : bpf_csum_diff err %d",value);
            return TC_ACT_SHOT;
        }
        iph->check = csum_fold(value);

        bpf_map_delete_elem(&tcp_seq_traceinfo_map,&seq); // delete the old trace info
    }

    return TC_ACT_OK;
}
#else
// trigger at vxlan packet
//int ip_options_compile(struct net *net, struct ip_options *opt, struct sk_buff *skb)
SEC("fentry/ip_options_compile")
int BPF_PROG(ip_options_compile_entry,struct net *net, struct ip_options *opt, struct sk_buff *skb){
    if(skb == NULL) return 0;
    struct iphdr* iph_ptr = (struct iphdr*)(skb->head + skb->network_header);
    struct iphdr iph;
    bpf_probe_read_kernel(&iph, sizeof(iph), iph_ptr);
    u16 iph_len = iph.ihl << 2;
    void* opt_start = (void*)iph_ptr + sizeof(struct iphdr);
    u16 opt_size = iph_len - sizeof(struct iphdr);


    u8 index = 0;
    for(int i=0;i<40;i++){
        u8 remaining = opt_size - index;
        #if EXPORT_SPANS == 1
        struct ip_hdr_opt_tracing_with_span current_opt = {0};
        if(remaining < sizeof(struct ip_hdr_opt_tracing_with_span)){ // impossible to find a valid option
            break;
        }
        bpf_probe_read_kernel(&current_opt, sizeof(struct ip_hdr_opt_tracing), opt_start + index);
        #else
        struct ip_hdr_opt_tracing current_opt = {0};
        if(remaining < sizeof(struct ip_hdr_opt_tracing)){ // impossible to find a valid option
            break;
        }
        bpf_probe_read_kernel(&current_opt, sizeof(struct ip_hdr_opt_tracing), opt_start + index);
        #endif

        if(current_opt.option_len >  remaining){
            ip_debug("[ip-options-compile]: found ip option with invalid length\n");
            break;
        }

        if(current_opt.option_type == 0){
            break;
        }
        if(current_opt.option_type == 1){
            index++;
            continue;
        }
        if(current_opt.magic == ip_expected_opt.magic || current_opt.magic == ip_expected_opt_with_span.magic){
            u32 traceid = __bpf_ntohl(current_opt.traceid);
            u32 tcp_seq = __bpf_ntohl(current_opt.tcp_seq);
            u32 spanid = 0;
            #if EXPORT_SPANS == 1
            spanid = __bpf_ntohl(current_opt.spanid);
            #endif

            struct trace_info traceinfo = {
                .traceid = traceid,
                .spanid = spanid,
                .tcp_seq = tcp_seq,
            };
            ip_debug("[ip-options-compile]: found traceid %u from skb %p option_len %u\n",traceid,skb,current_opt.option_len);

            #ifdef DEBUG_IP
                ip_debug("[ip-options-compile]: attach traceid %u to skb %p\n",traceinfo.traceid,skb);
            #endif

            bpf_map_update_elem(&tcp_seq_traceinfo_map,&tcp_seq,&traceinfo,BPF_NOEXIST);
            break;
        }
        index += current_opt.option_len; // next option start index
    }
    return 0;
}


#define MAX_PACKET_OFF 0xffff

__always_inline static
__u16 csum_fold(__u32 csum)
{
	csum = (csum & 0xffff) + (csum >> 16);
	csum = (csum & 0xffff) + (csum >> 16);
	return (__u16)~csum;
}

// 辅助函数：解析以太网头部
static __always_inline struct ethhdr* parse_eth(void *data, void *data_end) {
    struct ethhdr *eth = data;

    if ((void *)(eth + 1) > data_end)
        return NULL;

    return eth;
}

// 辅助函数：解析IP头部
static __always_inline struct iphdr* parse_ip(void *data, void *data_end) {
    struct iphdr *ip = data;

    if ((void *)(ip + 1) > data_end)
        return NULL;

    // 检查IP头部长度
    if (ip->ihl < 5)
        return NULL;

    if ((void *)ip + (ip->ihl * 4) > data_end)
        return NULL;

    return ip;
}

// 辅助函数：解析UDP头部
static __always_inline struct udphdr* parse_udp(void *data, void *data_end) {
    struct udphdr *udp = data;

    if ((void *)(udp + 1) > data_end)
        return NULL;

    return udp;
}

// 辅助函数：解析TCP头部
static __always_inline struct tcphdr* parse_tcp(void *data, void *data_end) {
    struct tcphdr *tcp = data;

    if ((void *)(tcp + 1) > data_end)
        return NULL;

    return tcp;
}

void *bpf_cast_to_kern_ctx(void *) __ksym;

#define VXLAN_PORT 8472

SEC("tc")
int veth_return_ingress(struct __sk_buff *ctx){
    struct trace_info* traceinfo = NULL;
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    return bpf_redirect(pnic_ifindex, 0); // redirect to pnic interface
}


// ip tagging only for outgoing packets
SEC("tc")
int pnic_egress_ip_tagging(struct __sk_buff *ctx){
    struct trace_info* traceinfo = NULL;
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析外层以太网头部
    struct ethhdr *outer_eth = parse_eth(data, data_end);
    if (!outer_eth || __bpf_ntohs(outer_eth->h_proto) != ETH_P_IP)
        return 0;

    struct iphdr *outer_ip = parse_ip(data + sizeof(*outer_eth), data_end);
    if (!outer_ip || outer_ip->protocol != IPPROTO_UDP)
        return 0;

    // 解析外层UDP头部
    void *udp_start = (void *)outer_ip + (outer_ip->ihl * 4);
    struct udphdr *outer_udp = parse_udp(udp_start, data_end);
    if (!outer_udp || __bpf_ntohs(outer_udp->dest) != VXLAN_PORT)
        return 0;
        // 4. 跳过 VXLAN 头部
    void *vxlan = (void *)(outer_udp + 1);
    if (vxlan + 8 > data_end) return TC_ACT_OK; // VXLAN header 8 bytes

    // 5. 解析内层以太网
    struct ethhdr *inner_eth = vxlan + 8;
    if ((void *)(inner_eth + 1) > data_end) return TC_ACT_OK;
    if (__bpf_ntohs(inner_eth->h_proto) != ETH_P_IP) return TC_ACT_OK;

    // 6. 解析内层 IP
    struct iphdr *inner_ip = (void *)(inner_eth + 1);
    if ((void *)(inner_ip + 1) > data_end) return TC_ACT_OK;

    u32 seq_end = 0;
    u32 seq = 0;
    // 7. 判断内层协议类型
    if (inner_ip->protocol == IPPROTO_TCP) {
        struct tcphdr *inner_tcp = (void *)inner_ip + (inner_ip->ihl * 4);
        if ((void *)(inner_tcp + 1) > data_end) return TC_ACT_OK;
        // 此时 inner_tcp 就是内部 TCP 报文头
        // 可以读取 seq、ack、source、dest 等 TCP 字段
        seq = __bpf_ntohl(inner_tcp->seq);
        seq_end = __bpf_ntohl(inner_tcp->seq) + __bpf_htons(inner_ip->tot_len) - inner_ip->ihl * 4 - sizeof(struct tcphdr);
        //ip_debug("[pnic tc egress]: inner tcp packet detected, skb %p seq %u\n", ctx, seq);
        traceinfo = (struct trace_info*)bpf_map_lookup_elem(&tcp_seq_traceinfo_map,&seq);
        if(!traceinfo){
            return TC_ACT_OK;
        }
        u32 size = __bpf_htons(inner_ip->tot_len) - inner_ip->ihl * 4 - sizeof(struct tcphdr);
        ip_debug("[pnic tc egress]: attach traceid %u to tcp skb %p seq %u size %u gso_segs %u gso_size %u\n",
                 traceinfo->traceid, ctx, seq, size, ctx->gso_segs, ctx->gso_size);
    }

    if(!traceinfo){
        return TC_ACT_OK;
    }
    u8 curr_ip_option_len = (outer_ip->ihl << 2) - sizeof(struct iphdr);
    u8 available_ip_option_len = 40-curr_ip_option_len;

    #if EXPORT_SPANS == 1
    const u8 count = sizeof(struct ip_hdr_opt_tracing_with_span);
    #else
    const u8 count = sizeof(struct ip_hdr_opt_tracing);
    #endif
    if(bpf_skb_adjust_room(ctx, count, BPF_ADJ_ROOM_NET, 0)) {
        ip_debug("<tc egress> : bpf_skb_adjust_room err");
        return TC_ACT_OK;
    }

    // new data room is just after the orig ip header
    data = (void *)(long)ctx->data;
    data_end = (void *)(long)ctx->data_end;

    // update ip header
    struct iphdr* iph = data + sizeof(struct ethhdr);
    if((void*)(iph + 1) > data_end){
        ip_debug("<tc egress> : ip header err");
        return TC_ACT_SHOT;
    }

    iph->tot_len = __bpf_htons(__bpf_ntohs(iph->tot_len)+ count);
    iph->ihl =iph->ihl + count/4;
    ip_debug("<tc egress> : \tnew ip tot_len %d ihl %d",iph->tot_len,iph->ihl);

    #if EXPORT_SPANS == 1
    struct ip_hdr_opt_tracing_with_span* new_ip_opt = data + sizeof(struct ethhdr) + sizeof(struct iphdr);
    #else
    struct ip_hdr_opt_tracing* new_ip_opt = data + sizeof(struct ethhdr) + sizeof(struct iphdr);
    #endif
    if((void*)(new_ip_opt + 1) > data_end){
        ip_debug("<tc egress> err : new_ip_opt + 1 > data_end");
        return TC_ACT_SHOT;
    }

    new_ip_opt->tcp_seq = __bpf_htonl(seq);
    new_ip_opt->magic = ip_expected_opt.magic;
    new_ip_opt->traceid = __bpf_htonl(traceinfo->traceid);
    #if EXPORT_SPANS == 1
    new_ip_opt->spanid = __bpf_htonl(traceinfo->spanid);
    #endif
    new_ip_opt->option_type = 206;
    new_ip_opt->option_len = count;
    /* Recalculate checksums. */
    s64 value=0;
    iph->check = 0;
    value = bpf_csum_diff(0, 0, (void *)iph, sizeof(struct iphdr) + count, 0);
    if (value < 0){
        ip_debug("<tc egress> : bpf_csum_diff err %d",value);
        return TC_ACT_SHOT;
    }
    iph->check = csum_fold(value);

    bpf_map_delete_elem(&tcp_seq_traceinfo_map,&seq); // delete the old trace info

    return TC_ACT_OK;
}

#endif // GRPC_IP_TAGGING

//If not GPL, you get "cannot call GPL-restricted function from non-GPL compatible program". Is it an issue?
char LICENSE[] SEC("license") = "Dual BSD/GPL"; 