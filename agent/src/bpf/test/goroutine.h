#include "../event.h"
#include "../vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>
#include "../context.h"
#include "../trace_info.h"
#include "../common/config.h"


struct {
    __uint(type,BPF_MAP_TYPE_HASH);
    __uint(max_entries,1<<10);
    __type(key, u32);
    __type(value, struct context_t);
} tid_context_map SEC(".maps");

#if COROUTINE_INKERNEL_SUPPORT == 0
// runtime.execute
SEC("uprobe")
int BPF_KPROBE(runtime_execute){
    // keep track which goroutine is executing on the thread
    u32 tid = bpf_get_current_pid_tgid();
    u32 pid = bpf_get_current_pid_tgid() >> 32;

    struct context_t context = {
        .pid = pid,
        .type = CONTEXT_GOROUTINE,
        .execution_context = ctx->ax, // r14 is the goroutine pointer
    };

    bpf_map_update_elem(&tid_context_map, &tid, &context, BPF_ANY);
    return 0;
}

SEC("kprobe")
// int BPF_PROG(test_tcp_recvmsg_exit,struct sock *sk, struct msghdr *msg, size_t len, int flags, int *addr_len,int ret){
int BPF_KPROBE(test_tcp_recvmsg_exit){
    u32 tid = bpf_get_current_pid_tgid();
    struct context_t *context = (struct context_t*)bpf_map_lookup_elem(&tid_context_map, &tid);
    if (!context) {
        // No context found for this goroutine
        return 1;
    }
    // bpf_printk("context %p type %u exited tcp_recvmsg\n", 
    //         context->execution_context, context->type);
    return 0;
}

SEC("kprobe")
int BPF_KPROBE(test_tcp_sendmsg_locked_enter){
    u32 tid = bpf_get_current_pid_tgid();
    struct context_t *context = (struct context_t*)bpf_map_lookup_elem(&tid_context_map, &tid);
    if (!context) {
        // No context found for this goroutine
        return 1;
    }
    // bpf_printk("context %p type %u entered tcp_sendmsg_locked\n",context->execution_context, context->type);
    return 0;
}
#else
// runtime.execute
SEC("uprobe")
int BPF_KPROBE(runtime_execute){
    return 0;
}

// SEC("fexit/tcp_recvmsg")
SEC("kprobe")
int BPF_KPROBE(test_tcp_recvmsg_exit){
    struct context_t context = get_current_execution_context(get_context_type(bpf_get_current_pid_tgid()));
    if(context.type == CONTEXT_THREAD){
        // if the context is thread, we don't need to track it
        return 1;
    }
    // bpf_printk("context %p type %u exited tcp_recvmsg", context.execution_context, context.type);
    return 0;
}

SEC("kprobe")
int BPF_KPROBE(test_tcp_sendmsg_locked_enter){
    struct context_t context = get_current_execution_context(get_context_type(bpf_get_current_pid_tgid()));
    if(context.type == CONTEXT_THREAD){
        // if the context is thread, we don't need to track it
        return 1;
    }
    // bpf_printk("context %p type %u entered tcp_sendmsg_locked", 
    //         context.execution_context, context.type);
    return 0;
}
#endif // INKERNEL_GOROUTINE_SUPPORT
