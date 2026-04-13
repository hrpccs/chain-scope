#!/bin/bash

# Create temporary files
tmp_perf=$(mktemp)

# Extract program info from perf data
awk '/^# bpf_prog_info [0-9]+:/ {
    in_prog = 1
    sub_prog = 0
    match($0, /^# bpf_prog_info ([0-9]+):/, id)
    prog_id = id[1]
    match($0, /bpf_prog_([a-f0-9]+)_([a-zA-Z0-9_]+)/, name)
    if (name[0] != "") {
        print prog_id " main " name[0]
    }
    next
}
in_prog && /^#[[:space:]]+sub_prog [0-9]+:/ {
    match($0, /bpf_prog_([a-f0-9]+)_([a-zA-Z0-9_]+)/, addr)
    if (addr[0] != "") {
        print prog_id (sub_prog > 0? " sub " : " main ") addr[0]
        sub_prog += 1
    }
}
/^[^#]/ { in_prog = 0 }' "$2" > "$tmp_perf"

# Find all programs from bpftool output
declare -A prog_names
while read -r line; do
    if [[ $line =~ ^([0-9]+):\ +(tracing|raw_tracepoint|kprobe|sock_ops|sched_cls|perf_event|tracepoint|socket)\ +name\ +([^ ]+) ]]; then
        prog_id="${BASH_REMATCH[1]}"
        prog_name="${BASH_REMATCH[3]}"
        prog_names[$prog_id]="$prog_name"
    fi
done < "$1"

# Process tcp message handling programs
for prog_id in "${!prog_names[@]}"; do
    prog_name=$(awk -v id="$prog_id" '$1 == id && $2 == "main" {print $3}' "$tmp_perf" | head -1)
    if [ -n "$prog_name" ]; then
        case "${prog_names[$prog_id]}" in
            "tcp_sendmsg_ent")
                echo "tcp_sendmsg_enter: $prog_name"
                ;;
            "tcp_sendmsg_exi")
                echo "tcp_sendmsg_exit: $prog_name"
                ;;
            "tcp_recvmsg_ent")
                echo "tcp_recvmsg_enter: $prog_name"
                ;;
            "tcp_recvmsg_exi")
                echo "tcp_recvmsg_exit: $prog_name"
                ;;
            "tcp_v4_destroy_")
                echo "tcp_v4_destroy_sock: $prog_name"
                ;;
            "tcp_v4_rcv_ente")
                echo "tcp_v4_rcv_enter: $prog_name"
                ;;
            "enter_skb_copy_")
                echo "skb_copy_datagram_iter: $prog_name"
                ;;
            "bpf_skops_write")
                echo "bpf_skops_write_hdr_opt: $prog_name"
                ;;
            "skb_release_dat")
                echo "skb_release_data: $prog_name"
                ;;
            *)
                echo "${prog_names[$prog_id]}: $prog_name"
        esac
    fi
done

grep "sub" "$tmp_perf" | \
awk '{
    # Extract the bpf_prog identifier (after "bpf_prog_")
    match($0, /bpf_prog_[a-f0-9]+_([a-zA-Z_]+)/, arr)
    if (arr[1]) {
        prog_name = arr[1]
        full_prog = $3  # The full bpf_prog_* identifier
        print "subprog " prog_name ": " full_prog
    }
}' | sort -u

# Cleanup
rm -f "$tmp_perf"
