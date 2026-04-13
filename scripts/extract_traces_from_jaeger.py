#!/usr/bin/env python

import os
import json
import requests
import argparse
import subprocess
import atexit
import signal
import time

JAEGER_TRACES_ENDPOINT = "http://localhost:16686/api/traces?limit=100000000&"
JAEGER_TRACES_PARAMS = "service="

def get_traces(service):
    """
    Returns list of all traces for a service
    """
    url = JAEGER_TRACES_ENDPOINT + JAEGER_TRACES_PARAMS + service
    try:
        response = requests.get(url)
        response.raise_for_status()
    except requests.exceptions.HTTPError as err:
        raise err

    response = json.loads(response.text)
    traces = response["data"]
    return traces

JAEGER_SERVICES_ENDPOINT = "http://localhost:16686/api/services"

def get_services():
    """
    Returns list of all services
    """
    try:
        response = requests.get(JAEGER_SERVICES_ENDPOINT)
        response.raise_for_status()
    except requests.exceptions.HTTPError as err:
        raise err
        
    response = json.loads(response.text)
    services = response["data"]
    return services

def write_traces(directory, traces):
    """
    Write traces locally to files
    """
    for trace in traces:
        traceid = trace["traceID"]
        path = directory + "/" + traceid + ".json"
        with open(path, 'w') as fd:
            fd.write(json.dumps(trace))

def write_traces_to_one_file(directory, traces):
    filename = directory + "/traces.json"
    with open(filename, 'w') as fd:
        for trace in traces:
            fd.write(json.dumps(trace) + "\n")
        # fd.write(json.dumps(traces))

def analyze_beyla_traces(traces,correct_span_number,correct_process_number):
    total_nr_trace=0
    nr_correct_trace=0
    nr_profile_loss_count=0
    nr_recommendation_loss_count=0
    for trace in traces:
        # skip the consul trace
        processes = trace["processes"]
        has_profile=False
        has_recommendation=False
        is_consul = False
        for pname,p in processes.items():
            if p["serviceName"] == "consul":
                is_consul = True
            elif p["serviceName"] == "profile":
                has_profile = True
            elif p["serviceName"] == "recommendation":
                has_recommendation = True
                # break
        
        if not is_consul:
            spans = trace["spans"]
            nr_spans = len(spans)
            if nr_spans > correct_span_number:
                continue
            total_nr_trace += 1
            nr_processes = len(processes)
            if nr_processes != correct_process_number:
                if not has_profile:
                    nr_profile_loss_count += 1
                if not has_recommendation:
                    nr_recommendation_loss_count += 1
                continue
            if nr_spans == correct_span_number:
                nr_correct_trace += 1
    
    return total_nr_trace, nr_correct_trace, nr_profile_loss_count, nr_recommendation_loss_count
            
        

def analyze_beyla():
# Pull traces for all the services & store locally as json files
    for service in get_services():
        if service != "frontend":
            continue 
        traces = get_traces(service)
        # if not os.path.exists(service):
        #     os.mkdir(service)
        # write_traces_to_one_file(service, traces)
        total_nr_trace, nr_correct_trace,nr_profile_loss_count,nr_recommendation_loss_count = analyze_beyla_traces(traces, 7,3)
        # echo "total ${total}"
        # echo "correct ${correct}"
        # echo "accuracy: ${accuracy}%"
        print(f'total: {total_nr_trace}')
        print(f'correct: {nr_correct_trace}')
        print(f'profile_loss: {nr_profile_loss_count}')
        print(f'recommendation_loss: {nr_recommendation_loss_count}')
        print(f'intra_node_loss_count: {nr_profile_loss_count}')
        print(f'inter_node_loss_count: {nr_recommendation_loss_count}')
        print(f'intra_node_loss_rate_pct: {nr_profile_loss_count/total_nr_trace*100:.2f}%')
        print(f'inter_node_loss_rate_pct: {nr_recommendation_loss_count/total_nr_trace*100:.2f}%')
        print(f'accuracy: {nr_correct_trace/total_nr_trace*100:.2f}%')

def analyze_otel_auto_traces(traces,correct_span_number,correct_process_number):
    total_nr_trace=0
    nr_correct_trace=0
    for trace in traces:
        # skip the consul trace
        processes = trace["processes"]
        is_consul = False
        for pname,p in processes.items():
            if p["serviceName"] == "consul":
                is_consul = True
                break
        
        if not is_consul:
            if len(trace["spans"]) == 1:
                # only if the span is server span, we increase the total number of traces
                tags = trace["spans"][0]["tags"]
                for tag in tags:
                    if tag["key"] == "span.kind":
                        if tag["value"] == "server":
                            total_nr_trace += 1
                            break
                continue
            else:
                total_nr_trace += 1
                nr_processes = len(processes)
                if nr_processes != correct_process_number:
                    continue
                spans = trace["spans"]
                nr_spans = len(spans)
                if nr_spans == correct_span_number:
                    nr_correct_trace += 1
    
    return total_nr_trace, nr_correct_trace


def analyze_otel_auto():
# Pull traces for all the services & store locally as json files
    for service in get_services():
        if service != "frontend":
            continue 
        traces = get_traces(service)
        total_nr_trace, nr_correct_trace = analyze_otel_auto_traces(traces, 5,4)
        print(f'total {total_nr_trace}')
        print(f'correct {nr_correct_trace}')
        print(f'accuracy: {nr_correct_trace/total_nr_trace*100:.2f}%')
    
def dump_to_file():
    for service in get_services():
        if not os.path.exists(service):
            os.mkdir(service)
        traces = get_traces(service)
        write_traces_to_one_file(service, traces)

def start_port_forward(namespace):
    """Start kubectl port-forward and return the process object."""
    cmd = ["kubectl", "-n", namespace, "port-forward", "svc/jaeger", "16686:16686"]
    process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(2)  # Wait for port-forward to establish
    return process

def cleanup_port_forward(process):
    """Terminate the port-forward process."""
    if process.poll() is None:  # Check if process is still running
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def main():
    parser = argparse.ArgumentParser(description="Extract traces from Jaeger and analyze them.")
    parser.add_argument("--type", type=str, choices=["beyla", "otel-auto"], required=True, help="Specify the type of analysis (beyla or otel-auto)")
    args = parser.parse_args()

    # Start port-forward based on type
    if args.type == "beyla":
        pf_process = start_port_forward("beyla")
    elif args.type == "otel-auto":
        pf_process = start_port_forward("odigos-system")
    
    # Register cleanup function
    atexit.register(cleanup_port_forward, pf_process)

    if args.type == "beyla":
        analyze_beyla()
    elif args.type == "otel-auto":
        analyze_otel_auto()

if __name__ == "__main__":
    main()