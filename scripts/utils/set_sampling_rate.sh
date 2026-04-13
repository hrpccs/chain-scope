#!/bin/bash

if [[ -z $1 ]]; then
  echo "Usage: $0 <sampling_interval>"
  exit 1
fi

sampling_interval=$1
curl_param="{\"sampling_interval\":$sampling_interval}"

echo "Setting sampling rate to 1 every $sampling_interval..."
node_ips=$(kubectl get nodes -o custom-columns=node_ip:.status.addresses[0].address --no-headers=true)
for node_ip in $node_ips
do
    curl -X POST -H "Content-Type: application/json" -d "$curl_param" http://"$node_ip":9898/config/rate/sampling
done
