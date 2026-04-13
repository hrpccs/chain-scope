#ifndef __HTTP_H__
#define __HTTP_H__

#include "../vmlinux.h"
#include "../event.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>

#include "config.h"


#define DEBUG_HTTP
#if DEBUG_LEVEL > 0 && defined(DEBUG_HTTP)
#define http_debug(fmt, ...) bpf_printk(fmt, ##__VA_ARGS__)
#else
#define http_debug(fmt, ...)
#endif

struct payload {
    char *data;
    u32 length;
};

enum msg_ptr_type {
    MSGHDR,
    SK_BUFF,
};

struct trace_key {
    u64 pid_tgid;
    enum event_type type;
};
// #if GROUND_TRUTH == 1

#if GROUND_TRUTH == 1

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1<<10);
    __type(key, struct trace_key);
    __type(value, u32);
} request_gt_map SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1<<10);
    __type(key, struct sock *);
    __type(value, u32);
} response_gt_map SEC(".maps");

inline int __strncmp(const char *s1, size_t n, const char *s2) {
    while (n && *s1 && (*s1 == *s2)) {
        ++s1;
        ++s2;
        --n;
    }

    if (n == 0) {
        return 0; // Strings are equal up to n characters
    } else {
        // Compare characters as unsigned char
        return (*(unsigned char *)s1 - *(unsigned char *)s2);
    }
}

static
void _extract_payload(void *msg_ptr, enum msg_ptr_type ptr_type, struct payload *ret) {

    if (msg_ptr == NULL) {
        return;
    }
    if (ptr_type == MSGHDR) {
        struct msghdr *msghdr = (struct msghdr *) msg_ptr;
        const struct iovec *iov = NULL;
        if (msghdr->msg_iter.iter_type == ITER_UBUF) {
            iov = &msghdr->msg_iter.__ubuf_iovec;
        } else {
            iov = msghdr->msg_iter.__iov;
        }
        if (iov) {
            ret->data = (char *) BPF_CORE_READ(iov, iov_base);
            ret->length = BPF_CORE_READ(iov, iov_len);
        }
    } else if (ptr_type == SK_BUFF) {
        /** TODO: not sure it works */
        struct sk_buff *skb = (struct sk_buff *) msg_ptr;
        ret->data = (char *) BPF_CORE_READ(skb, data);
        ret->length = skb->data_len; //BPF_CORE_READ(skb, data_len);
    }
}
#endif

static
int debug_push_ground_truth(void *msg_ptr, const enum msg_ptr_type ptr_type, const enum event_type type, const u32 skip_first) {
#if GROUND_TRUTH == 1
    const u32 max_len = skip_first + 325;

    struct payload payload = {NULL, 0};

    _extract_payload(msg_ptr, ptr_type, &payload);

    if (payload.data == NULL) {
        return 0;
    }

    char *payload_data = payload.data;

    if (payload.length > skip_first + 18) {
        char buff[21];
        bpf_core_read_user(buff, 20, payload_data);
        if (__strncmp(buff, 3, "GET") == 0) {
            buff[20] = '\0';
            //http_debug(" - %s '%s'", EVENT_TYPE_STR(type), buff);
            for (u32 i = 0; skip_first + i < payload.length - 18 && skip_first + i < max_len; i++) {
                bpf_core_read_user(buff, 18, payload_data + skip_first + i);
                buff[18] = '\0';
                if (__strncmp(buff, 12, "x-request-id") == 0) {
                    buff[12] = '\0';
                    struct trace_key key = {};
                    key.pid_tgid = bpf_get_current_pid_tgid();
                    key.type = type;
                    //const u32 value = (u8) buff[14] | (__u8)buff[15] << 8 | (__u8)buff[16] << 16 | (__u8)buff[17] << 24;
                    const u32 value = (u8) buff[14];
                    //http_debug(" - %s '%s: %c'", EVENT_TYPE_STR(type), buff, buff[14]);
                    bpf_map_update_elem(&request_gt_map, &key, &value, 0);
                    break;
                }
            }
        }
    }
#endif
    return 0;
}


static
u32 debug_pop_ground_truth(const u64 pid_tgid, const enum event_type type, struct sock *sk) {
#if GROUND_TRUTH == 1
    if (sk == NULL)
        return 0;
    struct trace_key key = {};
    key.pid_tgid = pid_tgid;
    key.type = type;
    // check first if this is the response to a pending request
    http_debug("Searching gt for key %lu", sk);
    u32 *value = bpf_map_lookup_elem(&response_gt_map, &sk);
    if (value != NULL) {
        bpf_map_delete_elem(&response_gt_map, &sk);
        http_debug("FOUND is response");
        return *value;
    }
    http_debug("NOT FOUND");

    // assume this is a request
    value = bpf_map_lookup_elem(&request_gt_map, &key);
    if (value != NULL) {
        http_debug("Is request, gt=%u", *value);
        bpf_map_delete_elem(&request_gt_map, &key);
        http_debug("Storing gt for key %lu", sk);
        bpf_map_update_elem(&response_gt_map, &sk, value, 0);
        return *value;
    }
#endif
    return 0;
}

#endif // __HTTP_H__
