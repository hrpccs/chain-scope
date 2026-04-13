#!/bin/bash

if [[ -z $1 ]]; then
  echo "Usage: $0 <pid>"
  exit 1
fi

pid=$1
curl_param="{\"pid\":$pid}"

echo "Limit benchmark to pid $pid..."
node_ips=$(kubectl get nodes -o custom-columns=node_ip:.status.addresses[0].address --no-headers=true)
for node_ip in $node_ips
do
    curl -X POST -H "Content-Type: application/json" -d "$curl_param" http://"$node_ip":9898/bench/filter
done
