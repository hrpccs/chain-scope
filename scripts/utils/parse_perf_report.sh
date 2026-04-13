#!/bin/bash

DEBUG=${DEBUG:-0}

if [ -z "$2" ]; then
    echo "Usage: $0 <input_file> <function_name>"
    exit 1
fi

function_name="$2"

debug_print() {
    if [ "$DEBUG" -eq 1 ]; then
        echo "[DEBUG] $*" >&2
    fi
}

# Function to identify if a line contains a BPF program entry
get_bpf_prog() {
    echo "$1" | grep -o 'bpf_prog_[a-f0-9]\+\(_[A-Za-z_]\+\)\?'
}

# Function to determine the indentation level
get_indent() {
    #echo "$1" | awk 'BEGIN {FS = " --|\\|"} {print NF-1}'
    if echo "$1" | grep -q "--" -; then
      echo "$1" | awk '{ match($0, /[| ]*--/); print RLENGTH - 2 }'
    else
      echo "$1" | awk '{ r=0; for (i = 1; i <= length($0); i++) { if (substr($0, i, 1) == "|") { r = i; } } print r; }'
    fi
}

is_ringbuf_submit() {
    echo "$1" | grep -q "bpf_ringbuf_submit"
    return $?
}

is_report_tcp_event() {
    echo "$1" | grep -q "report_tcp_event"
    return $?
}

is_common_filter() {
    echo "$1" | grep -q "common_filter"
    return $?
}

# Function to process a TCP function section (recvmsg or sendmsg)
process_tcp_section() {
    local tcp_func="$1"
    local in_section=0
    local fentry_prog=""
    local fexit_prog=""
    local parent_prog=""
    local parent_indent=0
    local report_tcp_event_f=""
    local common_filter_f=""
    declare -A prog_hierarchy
    declare -A prog_indent
    declare -A prog_has_ringbuf

    while IFS= read -r line; do
        # Skip empty lines
        [[ -z "${line//$'\r'}" ]] && continue

        debug_print "-"
        debug_print "next line:"
        debug_print "$line"

        # Check if we're entering the TCP function section
        if echo "$line" | grep -q "\[k\] ${tcp_func} .*$"; then
            in_section=1
            parent_indent=0
            parent_prog=$tcp_func
            prog_indent["$parent_prog"]="$parent_indent"
            debug_print "entering section $tcp_func..."
            continue
        fi

        # Skip if we're not in the relevant section
        [[ $in_section -eq 0 ]] && continue

        # Check if we're leaving the section (new [k] entry)
        if [[ $in_section -eq 1 ]] && echo "$line" | grep -q "\[k\]"; then
            debug_print "leaving section $tcp_func..."
            break
        fi

        # Get indentation level
        indent=$(get_indent "$line")
        debug_print "indent=$indent, parent_indent=$parent_indent"

        # Check if we exited previous node
        while [[ $indent -le $parent_indent ]]; do
            debug_print "leaving node '$parent_prog'..."
            parent_prog="${prog_hierarchy[$parent_prog]}"
            parent_indent="${prog_indent[$parent_prog]}"
            debug_print "back to node '$parent_prog'."
        done

        # Get BPF program name if present
        bpf_prog=$(get_bpf_prog "$line")

        if [[ -n "$bpf_prog" ]]; then
            debug_print "BPF prog: '$bpf_prog'"
            # If it's a direct hook name (contains tcp_recvmsg_ent or similar)
            if echo "$bpf_prog" | grep -q "_${tcp_func}_"; then
                if echo "$bpf_prog" | grep -q "_ent$"; then
                    fentry_prog="$bpf_prog"
                elif echo "$bpf_prog" | grep -q "_ext$"; then
                    fexit_prog="$bpf_prog"
                fi
                continue
            fi

            # Store the program in our hierarchy
            if [[ $indent -gt $parent_indent ]]; then

                # In case the prog already appeared somewhere else, append '*' until we find an unused key
                while [[ -n "${prog_hierarchy[$bpf_prog]+x}" ]]; do
                    bpf_prog="${bpf_prog}*"
                done

                prog_hierarchy["$bpf_prog"]="$parent_prog"
                prog_indent["$bpf_prog"]="$indent"

                debug_print "stored '$bpf_prog' as child of '$parent_prog'..."
            fi

            parent_prog="$bpf_prog"
            parent_indent=$indent
        elif is_report_tcp_event "$line"; then
            debug_print "found report_tcp_event (no BPF program)"
            report_tcp_event_f="report_tcp_event"
        elif is_ringbuf_submit "$line"; then
            debug_print "found ringbuf_submit"
            debug_print "marking parent $parent_prog as having ringbuf_submit..."
            # Mark the current program as having ringbuf_submit
            prog_has_ringbuf["$parent_prog"]=1
            # Label the current program as report_tcp_event
            if [ -z "$report_tcp_event_f" ]; then
              report_tcp_event_f=$parent_prog
            fi
        elif is_common_filter "$line"; then
            debug_print "found common_filter (no BPF program)"
            common_filter_f="common_filter"
        fi
    done

    if ! [[ -v prog_indent["$tcp_func"] ]]; then
      echo "$tcp_func section not found."
      return
    fi

    debug_print ""

    # Process the collected information
    debug_print "looking for fexit..."
    for prog in "${!prog_hierarchy[@]}"; do
        parent="${prog_hierarchy[$prog]}"
        # If this program has ringbuf_submit, its parent is fexit
        if [[ ${prog_has_ringbuf[$prog]} == 1 ]]; then
            debug_print "found: $parent"
            fexit_prog="$parent"
        fi
    done

    # Find fentry - it's the program at the same level as fexit but without ringbuf_submit
    debug_print "looking for fentry..."
    fexit_parent="${prog_hierarchy[$fexit_prog]}"
    for prog in "${!prog_hierarchy[@]}"; do
        parent="${prog_hierarchy[$prog]}"
        if [[ "$parent" == "$fexit_parent" ]] && [[ "$prog" != "$fexit_prog" ]]; then
            debug_print "found: $prog"
            fentry_prog="$prog"
            break
        fi
    done

    if [ -z "$common_filter_f" ]; then
        debug_print "looking for common_filter..."
        for prog in "${!prog_hierarchy[@]}"; do

            if [[ "$prog" == *"*" ]]; then
                continue
            fi

            local key="$prog"
            found_parent1=0
            found_parent2=0
            while [[ -n "${prog_hierarchy[$key]+x}" ]]; do
                if [[ "${prog_hierarchy[$key]}" == "$fentry_prog" ]]; then
                    found_parent1=1
                elif [[ "${prog_hierarchy[$key]}" == "$fexit_prog" ]]; then
                    found_parent2=1
                fi
                key="${key}*"
            done

            if [[ $found_parent1 -eq 1 && $found_parent2 -eq 1 ]]; then
                debug_print "found: $prog"
                common_filter_f="$common_filter_f $prog"
            fi
        done
        common_filter_f="${common_filter_f# }"
    fi

    # Output results for this section
    echo "${tcp_func}_enter: $fentry_prog"
    echo "${tcp_func}_exit: $fexit_prog"
    echo "report_tcp_event: $report_tcp_event_f"
    echo "common_filter: $common_filter_f"
}

# Main script
{
    echo "Analyzing perf report output..."
    echo "------------------------------"

    # Process the specified function section
    echo "processing $function_name section..."
    process_tcp_section "$function_name"

    echo "------------------------------"
}
