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

perf_header_file=$file'.head'
perf_report_file=$file'.report'
bpftool_prog_file=$file'.prog'

perf report --header-only -i "$file" --stdio > "$perf_header_file"
perf report -i "$file" --stdio --percentage relative -g none > "$perf_report_file"

# get the name of bpf programs
parsed_names="$(./parse_perf_report_header.sh "$bpftool_prog_file" "$perf_header_file")"

# print cycles of whole functions
echo "whole functions:"
grep -w "\[k\] tcp_recvmsg" "$perf_report_file" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   tcp_recvmsg\n", $1)}'
grep -w "\[k\] tcp_sendmsg" "$perf_report_file" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   tcp_sendmsg\n", $1)}'
grep -w "\[k\] tcp_v4_destroy_sock" "$perf_report_file" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   tcp_v4_destroy_sock\n", $1)}'
grep -w "\[k\] tcp_v4_rcv" "$perf_report_file" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   tcp_v4_rcv\n", $1)}'
grep -w "\[k\] skb_copy_datagram_iter" "$perf_report_file" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   skb_copy_datagram_iter\n", $1)}'
grep -w "\[k\] bpf_skops_write_hdr_opt.isra.0" "$perf_report_file" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   bpf_skops_write_hdr_opt\n", $1)}'
grep -w "\[k\] skb_release_data" "$perf_report_file" | awk '{sub(/%$/, "", $1); printf ("%5.2f%%   skb_release_data\n", $1)}'
echo "bpf programs:"
# print cycles of each program
ebpf_total=0
while IFS= read -r line; do
  hook_name="${line%%: *}"
  prog_name="${line##*: }"
  value=$(grep "\[k\] $prog_name" "$perf_report_file" | awk '{sub(/%$/, "", $1); print $1}')
  printf "%5.2f%%   %-41s   (%s)\n" "$value" "$prog_name" "$hook_name"
  ebpf_total=$(bc <<< "scale=2; $ebpf_total + ${value:-0}")
done < <(grep -Ev "subprog" <<< "$parsed_names")
printf "%5.2f%%   TOTAL\n" "$ebpf_total"
echo "of which:"

while IFS= read -r line; do
  remaining="${line#* }"
  hook_name="${remaining%%: *}"
  prog_name="${remaining##*: }"
  grep "\[k\] $prog_name" "$perf_report_file" | awk -v name="$prog_name" -v symbol="$hook_name" '{sub(/%$/, "", $1); printf (" - %5.2f%%   %-41s   (%s)\n", $1, name, symbol)}';
done < <(grep -E "subprog" <<< "$parsed_names")
