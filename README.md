# README

This repository contains an implementation of ChainScope.

ChainScope, a non-invasive distributed tracing system that delivers high-accuracy, full-scope observability for complex microservices while using sampling to control performance overhead under heavy loads.

## Repository Organization

- agent:  the final version used in state of the art benchmark
  - src/bpf: implement the kernel space tracing plane 
    - grpc.h: the uprobe hooks for grpc-go
    - tcp.h: the tracing hooks at tcp layer
    - hooks.bpf.c: the tc and tracing hooks for IP tagging
  - src/*.rs: implement the userspace part of the agent
- controller: implement the event collecting and trace reconstruction logic.
- scripts: including  benchmark script


## run grpc benchmark

```bash
# we assume that we have six node: bench1-6 to run the benchmark, and the ingress/egress NIC of each node is the same, ens3.
# first change the node-name of run_hotel.sh to your node name in your k8s cluster, then run the script
./run_hotel.sh
# then, run the grpc benchmark
./scripts/benchmark_hotel_accuracy_all-3node.sh -p bench-1 -b bench-1 -n bench-4 -i ens3 
./scripts/benchmark_hotel_qps_cpu_all-3node.sh -p bench-1 -b bench-1 -n bench-4 -i ens3 
# we can see the result in the benchmark/result folder
python3 plot_hotel_loss.py
python3 plot_hotel_qps_cpu.py
```


## run nginx benchmark

```bash
# we assume that we have two node: bench1-2 to run the benchmark, and the ingress/egress NIC of each node is the same, ens3.
# then, run the grpc benchmark
./scripts/benchmark_cpu.sh -p bench-1 -n bench-2 -i ens3 -t 10,18,20,22,23,24,25,29
# we can see the result in the benchmark/result folder
python3 plot_nginx.py
```
