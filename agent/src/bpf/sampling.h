#ifndef SAMPLING_H
#define SAMPLING_H 

#include "vmlinux.h"
#include "common/config.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_tracing.h>

u32 global_rid;
u32 sampling_interval = DEFAULT_SAMPLING_INTERVAL;
u64 metric_trace_count = 0;

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, u32);
    __type(value, u32);
    __uint(max_entries, 1);
} sample_interval_map SEC(".maps");

static __maybe_inline
u32 get_new_traceid() { //TODO: use atomic increment
    u32 key = 0;
    u32 *sampling_interval_entry = (u32 *) bpf_map_lookup_elem(&sample_interval_map, &key);
    if(sampling_interval_entry != NULL){
        sampling_interval = *sampling_interval_entry;
    }
    // __sync_fetch_and_add(&global_rid, 1);
    if(sampling_interval == 0){
        // if sampling interval is 0, return 0
        // this means no sampling, so return 0
        return 0;
    }
    if(sampling_interval == 1){
        __sync_fetch_and_add(&metric_trace_count, 1);
        return bpf_get_prandom_u32(); // if sampling interval is 1, return a random number
    }
    // return global_rid % sampling_interval? 0 : (((u64)bpf_get_prandom_u32() << 32) | bpf_get_prandom_u32());
    bool is_sampling = bpf_get_prandom_u32() % sampling_interval == 0;
    if (!is_sampling) {
        return 0; // not sampling, return 0
    }
    // if sampling, increment the trace_count
    __sync_fetch_and_add(&metric_trace_count, 1);
    return bpf_get_prandom_u32();
    // return ((u64)bpf_get_prandom_u32() << 32) | bpf_get_prandom_u32();
}

#endif