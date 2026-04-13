#!/bin/bash

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <namespace> <service1> [service2 ...]"
  exit 1
fi

NAMESPACE="$1"
shift
REQUIRED_SERVICES=("$@")

node_ips=$(kubectl get nodes -o custom-columns=ip:.status.addresses[0].address --no-headers=true)

echo "Waiting for all ChainScope agents to detect all the required services..."
while true; do
  all_ok=true

  for ip in $node_ips; do
    response=$(curl -s -X GET "http://$ip:9898/services")

    for service in "${REQUIRED_SERVICES[@]}"; do
      if ! [[ "$response" == *"\"name\":\"$service\""* && "$response" == *"\"namespace\":\"$NAMESPACE\""* ]]; then
         #echo "- service '$service' in namespace '$NAMESPACE' not found by agent at '$ip'. Retrying..."
        all_ok=false
        break 2
      fi
      #echo " - service '$service' detected from agent at '$ip'"
    done
  done

  if $all_ok; then
    echo "All required services have been detected by all agents."
    break
  else
    sleep 5
  fi
done
