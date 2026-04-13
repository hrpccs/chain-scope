#!/bin/bash

file=perf.data

print_usage() {
  echo "Usage: $0 -i <file> [-h]"
  echo
  echo "Options:"
  echo "  -i    Input perf file name"
  echo "  -h    Print this help message"
}

while getopts 'hi:' opt; do
  case "${opt}" in
    i) file=${OPTARG} ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done

# get the name of bpf programs
recv_prog_names=$(perf script -i "$file" --max-stack 3 | awk '/bpf_prog_[0-9a-fA-F]{16}_F/{a[1]=$0; p=NR} NR==p+1 && /bpf_trampoline/{a[2]=$0; p=NR} NR==p+1 && /tcp_recvmsg\+/{a[3]=$0; print a[1]; p=0}' | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_F/); print substr($0, RSTART, RLENGTH)}' | sort -u)
send_prog_names=$(perf script -i "$file" --max-stack 3 | awk '/bpf_prog_[0-9a-fA-F]{16}_F/{a[1]=$0; p=NR} NR==p+1 && /bpf_trampoline/{a[2]=$0; p=NR} NR==p+1 && /tcp_sendmsg\+/{a[3]=$0; print a[1]; p=0}' | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_F/); print substr($0, RSTART, RLENGTH)}' | sort -u)
bpf_prog_report_tcp_event=$(comm -12 <(printf "%s\n" "${recv_prog_names[@]}") <(printf "%s\n" "${send_prog_names[@]}"))
bpf_prog_tcp_recvmsg_exit=$(printf '%s\n' "${recv_prog_names[@]}" | grep -v "$bpf_prog_report_tcp_event")
bpf_prog_tcp_sendmsg_exit=$(printf '%s\n' "${send_prog_names[@]}" | grep -v "$bpf_prog_report_tcp_event")
bpf_prog_tcp_recvmsg_enter=$(perf script -i "$file" --max-stack 3 | awk '/bpf_prog_[0-9a-fA-F]{16}_tcp/{a[1]=$0; p=NR} NR==p+1 && /bpf_trampoline/{a[2]=$0; p=NR} NR==p+1 && /tcp_recvmsg\+/{a[3]=$0; print a[1]; p=0}' | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_tcp_recvmsg_ent/); print substr($0, RSTART, RLENGTH)}' | head -1)
bpf_prog_tcp_sendmsg_enter=$(perf script -i "$file" --max-stack 3 | awk '/bpf_prog_[0-9a-fA-F]{16}_tcp/{a[1]=$0; p=NR} NR==p+1 && /bpf_trampoline/{a[2]=$0; p=NR} NR==p+1 && /tcp_sendmsg\+/{a[3]=$0; print a[1]; p=0}' | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_tcp_sendmsg_ent/); print substr($0, RSTART, RLENGTH)}' | head -1)
bpf_prog_skb_release_data=$(perf script -i "$file" --max-stack 1 | grep "_skb_release_dat" | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_skb_release_dat/); print substr($0, RSTART, RLENGTH)}' | head -1)
bpf_prog_tcp_v4_rcv=$(perf script -i "$file" --max-stack 1 | grep tcp_v4_rcv_ente | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_tcp_v4_rcv_ente/); print substr($0, RSTART, RLENGTH)}' | head -1)
bpf_prog_skb_copy_datagram_iter=$(perf script -i "$file" --max-stack 1 | grep enter_skb_copy | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_enter_skb_copy_/); print substr($0, RSTART, RLENGTH)}' | head -1)
bpf_prog_bpf_skops_write_hdr_opt=$(perf script -i "$file" --max-stack 1 | awk '/bpf_prog_[0-9a-fA-F]{16}_bpf_skops_write\+/{a[1]=$0; print a[1]}' | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_bpf_skops_write/); print substr($0, RSTART, RLENGTH)}' | head -1)
bpf_prog_BPF_SOCKOPS=$(perf script -i "$file" --max-stack 1 | awk '/bpf_prog_[0-9a-fA-F]{16}_BPF_SOCKOPS\+/{a[1]=$0; print a[1]}' | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_BPF_SOCKOPS/); print substr($0, RSTART, RLENGTH)}' | head -1)
bpf_prog_trace_syscall=$(perf script -i "$file" --max-stack 1 | grep "_trace_syscall" | awk '{match($0, /bpf_prog_[0-9a-fA-F]{16}_trace_syscall/); print substr($0, RSTART, RLENGTH)}' | head -1)

# print cycles of whole functions
echo "whole functions:"
perf report -i "$file" --stdio --percentage relative -g none | grep -w "\[k\] tcp_recvmsg" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   tcp_recvmsg\n", $1)}'
perf report -i "$file" --stdio --percentage relative -g none | grep -w "\[k\] tcp_sendmsg" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   tcp_sendmsg\n", $1)}'
perf report -i "$file" --stdio --percentage relative -g none | grep -w "\[k\] skb_release_data" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   skb_release_data\n", $1)}'
perf report -i "$file" --stdio --percentage relative -g none | grep -w "\[k\] tcp_v4_rcv" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   tcp_v4_rcv\n", $1)}'
perf report -i "$file" --stdio --percentage relative -g none | grep -w "\[k\] skb_copy_datagram_iter" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   skb_copy_datagram_iter\n", $1)}'
perf report -i "$file" --stdio --percentage relative -g none | grep -w "\[k\] bpf_skops_write_hdr_opt.isra.0" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   bpf_skops_write_hdr_opt\n", $1)}'
echo "bpf programs:"
# print cycles of each program
ebpf_total=0
if [ -n "$bpf_prog_tcp_recvmsg_enter" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_tcp_recvmsg_enter" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_tcp_recvmsg_enter" tcp_recvmsg_enter
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_tcp_recvmsg_exit" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_tcp_recvmsg_exit" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_tcp_recvmsg_exit" tcp_recvmsg_exit
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_tcp_sendmsg_enter" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_tcp_sendmsg_enter" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_tcp_sendmsg_enter" tcp_sendmsg_enter
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_tcp_sendmsg_exit" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_tcp_sendmsg_exit" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_tcp_sendmsg_exit" tcp_sendmsg_exit
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_skb_release_data" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_skb_release_data" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_skb_release_data" skb_release_data
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_tcp_v4_rcv" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_tcp_v4_rcv" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_tcp_v4_rcv" tcp_v4_rcv
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_skb_copy_datagram_iter" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_skb_copy_datagram_iter" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_skb_copy_datagram_iter" skb_copy_datagram_iter
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_bpf_skops_write_hdr_opt" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_bpf_skops_write_hdr_opt" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_bpf_skops_write_hdr_opt" bpf_skops_write_hdr_opt
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_trace_syscall" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none  | grep "\[k\] $bpf_prog_trace_syscall" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_trace_syscall" trace_syscall
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
if [ -n "$bpf_prog_BPF_SOCKOPS" ]; then
  value=$(perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_BPF_SOCKOPS" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$bpf_prog_BPF_SOCKOPS" BPF_SOCKOPS
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + $value")
fi
printf "%5.2f%%   TOTAL\n" "$ebpf_total"
echo "of which:"
if [ -n "$bpf_prog_report_tcp_event" ]; then        perf report -i "$file" --stdio --percentage relative -g none | grep "\[k\] $bpf_prog_report_tcp_event" | awk -v name="$bpf_prog_report_tcp_event" -v symbol=report_tcp_event '{sub(/%$/, "", $1); printf (" - %5.2f%%   %-41s   (%s)\n", $1, name, symbol)}'; fi
