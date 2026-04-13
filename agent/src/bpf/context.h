#ifndef CONTEXT_H
#define CONTEXT_H

#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include "trace_info.h"
#include "common/config.h"

enum context_type {
    CONTEXT_GOROUTINE = 1,
    CONTEXT_PYTHON_ASYNCIO = 2,
    CONTEXT_THREAD = 3,
    CONTEXT_NODEJS_CALLBACK = 4, // TODO: nodejs callback
    CONTEXT_ISTIO = 5,
    CONTEXT_PYTHON_GREENLET = 6,
    CONTEXT_TRAEFIK = 7,
};

struct context_t {
    u32 pid; // user level routine id is unique in each process
    enum context_type type;
    u64 execution_context;
} __attribute__((packed));

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, u32);
    __type(value, struct context_t);
} thread_execution_context_map SEC(".maps");


// // unified execution context for different languages
// struct {
//     __uint(type,BPF_MAP_TYPE_HASH);
//     __uint(max_entries,1<<10);
//     __type(key, u32); // tid
//     __type(value, struct trace_info);
// } tid_context_traceinfo_map SEC(".maps");

// unified execution context for different languages
struct {
    __uint(type,BPF_MAP_TYPE_HASH);
    __uint(max_entries,1<<10);
    __type(key, struct context_t);
    __type(value, struct trace_info);
} execution_context_traceinfo_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1<<10);
    __type(key, u32); // process id, e.g. tgid
    __type(value, enum context_type);
} context_type_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1<<10);
    __type(key, u32); // process id, e.g. tgid
    __type(value, u64);
} greenlet_tstate_tls_map SEC(".maps");

struct demultiplex_context_t {
    u32 streamid;
    struct context_t context;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10240);
    __type(key, struct demultiplex_context_t);
    __type(value, struct trace_info);
} demultiplex_execution_context_traceinfo_map SEC(".maps");


//cpu_tss_rw ksym
extern struct tss_struct cpu_tss_rw __ksym;

static inline
u64 get_goid_v1_23_0(){
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    u64 fsbase;
    bpf_probe_read(&fsbase,sizeof(fsbase),&task->thread.fsbase);
    // %rdx,%fs:0xfffffffffffffff8

	// maybe get goroutine addr from R14 Register
    if(fsbase == 0) return 1;
    u64 goroutine_addr;
    bpf_probe_read(&goroutine_addr,sizeof(goroutine_addr),(void*)(fsbase + 0xfffffffffffffff8));

    u64 goid_offset_v1_23_0 =  160;

    u64 goid;
    bpf_probe_read(&goid,sizeof(goid),(void*)(goroutine_addr + goid_offset_v1_23_0));
    return goid;
}

u64 get_gp(){ //5.15
    struct pt_regs *regs = (struct pt_regs *)bpf_task_pt_regs((struct task_struct*)bpf_get_current_task_btf());
    u64 gp = regs->r14; // R14 is used to store the goroutine pointer in Go 
    return gp;
}

static inline
u64 get_gp_from_fsbase(){
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    u64 fsbase;
    bpf_probe_read(&fsbase,sizeof(fsbase),&task->thread.fsbase);
    // %rdx,%fs:0xfffffffffffffff8

	// maybe get goroutine addr from R14 Register
    if(fsbase == 0) return 1;
    u64 goroutine_addr;
    bpf_probe_read(&goroutine_addr,sizeof(goroutine_addr),(void*)(fsbase + 0xfffffffffffffff8));

    return goroutine_addr;
}
static inline
u64 get_goid_v1_21_13(){
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    u64 fsbase;
    bpf_probe_read(&fsbase,sizeof(fsbase),&task->thread.fsbase);
    // %rdx,%fs:0xfffffffffffffff8

	// maybe get goroutine addr from R14 Register
    if(fsbase == 0) return 1;
    u64 goroutine_addr;
    bpf_probe_read(&goroutine_addr,sizeof(goroutine_addr),(void*)(fsbase + 0xfffffffffffffff8));


    u64 goid_offset_v1_21_13 =  152;

    u64 goid;
    bpf_probe_read(&goid,sizeof(goid),(void*)(goroutine_addr + goid_offset_v1_21_13));
    return goid;
}

static inline
u64 get_python_context_v3_12_3(){

    //bpf_this_cpu_ptr
    struct tss_struct* tss = (struct tss_struct*)bpf_this_cpu_ptr(&cpu_tss_rw);
    u64 sp2 = 0;
    bpf_probe_read(&sp2,sizeof(sp2),&tss->x86_tss.sp2);
    u64 python_tstate_addr;
    bpf_probe_read(&python_tstate_addr,sizeof(python_tstate_addr),(void*)(sp2 + 0x50));
    // to be determined
    u64 py_context_offset =  0xd0;
    u64 py_context_ver_offset = 0xd8;

    u64 py_context;
    bpf_probe_read(&py_context,sizeof(py_context),(void*)(python_tstate_addr + py_context_offset));

    return py_context;
}

__always_inline static
u64 get_greenlet_context(){
    u64 pid_tgid = bpf_get_current_pid_tgid();
    u32 tgid = pid_tgid >> 32;
    u64* greenlet_tls_addr_ptr = (u64*)bpf_map_lookup_elem(&greenlet_tstate_tls_map,&tgid);
    if(greenlet_tls_addr_ptr){
        u64 greenlet_tls_addr = *greenlet_tls_addr_ptr;
        u64 greenlet_tstate;
        u64 greenlet;
        // 通过分析objdump得到的汇编文件，然后和源代码文件进行比对，得到的。后续应该可以利用clang+llvm进行自动化
        bpf_probe_read_user(&greenlet_tstate,sizeof(greenlet_tstate),(void*)(greenlet_tls_addr + 0x8));
        bpf_probe_read_user(&greenlet,sizeof(greenlet),(void*)(greenlet_tstate + 0x8));
        return greenlet;
    }
    return pid_tgid; // fallback to thread id
}


__always_inline static
enum context_type get_context_type(u64 pid_tgid){
    // k8s keep track of pid and context type, of all mornitoring pod and the container
    // process  
    u32 tgid = pid_tgid >> 32;
    enum context_type* context_type_ptr = (enum context_type*)bpf_map_lookup_elem(&context_type_map, &tgid);
    if(context_type_ptr == NULL){
        return CONTEXT_THREAD;
    }
    return *context_type_ptr;
}

//TODO: groutine id may be overlap between different golang app,
__always_inline static
struct context_t get_current_execution_context(enum context_type type){
    switch(type){
        case CONTEXT_GOROUTINE:
        {
            u64 goid = get_gp();
            return (struct context_t){
                .execution_context = goid,
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = type
            };
        }
        case CONTEXT_PYTHON_ASYNCIO:
        {
            u64 python_context = get_python_context_v3_12_3();
            return (struct context_t){
                .execution_context = python_context,
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = type
            };

        }
        case CONTEXT_THREAD:
        {
            return (struct context_t) {
                .execution_context = bpf_get_current_pid_tgid(),
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = type
            };
        }
        case CONTEXT_PYTHON_GREENLET:
        {
            return (struct context_t) {
                .execution_context = get_greenlet_context(),
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = type
            };
        }
        case CONTEXT_ISTIO:
        {
            return (struct context_t) {
                .execution_context = bpf_get_current_pid_tgid(),
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = type
            };
        }
        case CONTEXT_TRAEFIK:
        {
            return (struct context_t) {
                .execution_context = get_gp(),
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = type
            };
        }
        default:
            return (struct context_t){
                .execution_context = bpf_get_current_pid_tgid(),
                .pid = bpf_get_current_pid_tgid() >> 32,
                .type = CONTEXT_THREAD,
            };
    }
}

#endif // CONTEXT_H