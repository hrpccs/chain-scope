#!/bin/bash

kube_addresses=false
istiod_address=false

print_usage() {
  echo "Usage: $0 [-k] [-i] [-h]"
  echo
  echo "Options:"
  echo "  -k    also add CIDRs k8s addresses"
  echo "  -i    also add istio daemon address"
  echo "  -h    Print this help message"
}

while getopts 'hki' opt; do
  case "${opt}" in
    k) kube_addresses=true ;;
    i) istiod_address=true ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done

# prometheus ip address
prometheus_ip=$(kubectl get pods -o wide -n chain-scope | grep prometheus | awk '{print $6}')
prometheus_param="{\"ipv4\":\"$prometheus_ip\"}"

# istio ip address
istiod_ip=$(kubectl get services -o wide -n istio-system | grep istiod | awk '{print $3}')
istiod_param="{\"ipv4\":\"$istiod_ip\"}"

# ip addresses from k8s CIDRs (used as source ips for nodePort services)
declare -a cidr_params=()
nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $nodes; do
  cidr=$(kubectl get node "$node" -o jsonpath='{.spec.podCIDR}')
  network=$(echo "$cidr" | cut -d'/' -f1)
  cidr_params+=("{\"ipv4\":\"$network\"}")
  IFS='.' read -r -a octets <<< "$network"
  ((octets[3]++))
  cidr_params+=("{\"ipv4\":\"${octets[0]}.${octets[1]}.${octets[2]}.${octets[3]}\"}")
done

node_ips=$(kubectl get nodes -o custom-columns=ip:.status.addresses[0].address --no-headers=true)

echo "Adding IPs not to be monitored..."
for node_ip in $node_ips; do
  if [[ -n "$prometheus_ip" ]]; then
    curl -X POST -H "Content-Type: application/json" -d "$prometheus_param" http://"$node_ip":9898/config/ip-filter
  fi
  if [[ "$kube_addresses" == true ]]; then
    for cidr_param in "${cidr_params[@]}"; do
      curl -X POST -H "Content-Type: application/json" -d "$cidr_param" http://"$node_ip":9898/config/ip-filter
    done
  fi
  if [[ "$istiod_address" == true && -n "$istiod_ip" ]]; then
    curl -X POST -H "Content-Type: application/json" -d "$istiod_param" http://"$node_ip":9898/config/ip-filter
  fi
done
