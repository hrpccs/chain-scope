#!/bin/bash

FOLDER=debug
TAG=debug
get_controller_log=false
get_agents_logs=false
get_envoys_logs=false
get_agents_kernel_logs=false

print_usage() {
  echo "Usage: $0 [-f <FOLDER path for logs>]"
  echo
  echo "Options:"
  echo "  -t    Image tag (default '$TAG')"
  echo "  -f    Folder path where to store logs (default '$FOLDER')"
  echo "  -c    Get ChainScope controller log"
  echo "  -a    Get ChainScope agents logs"
  echo "  -k    Get ChainScope agents kernel logs (need to change DEBUG level in agent)"
  echo "  -e    Get microservice Envoys logs"
  echo "  -h    Print this help"
}

while getopts 'ht:f:cake' opt; do
  case "${opt}" in
    t) TAG=${OPTARG} ;;
    f) FOLDER=${OPTARG} ;;
    c) get_controller_log=true ;;
    a) get_agents_logs=true ;;
    k) get_agents_kernel_logs=true ;;
    e) get_envoys_logs=true ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done
shift $((OPTIND-1))

# Check if the output directory exists
if [[ ! -d "$FOLDER" ]]; then
  mkdir -p "$FOLDER"
  echo "Directory $FOLDER created."
fi

# Launch the bookinfo + ChainScope
./scripts/run.sh -t "$TAG" -a -c -s --test-nginx

sleep 10

# Get the logs

# Get ChainScope controller's log
if [[ "$get_controller_log" == true ]]; then
  ./scripts/view_controller_log.sh > "${FOLDER}"/controller.log &
  ./scripts/view_controller_collector.sh > "${FOLDER}"/controller_collector.log &
fi


# Get ChainScope agents' logs
if [[ "$get_agents_logs" == true ]]; then
  nodes=$(kubectl get nodes --no-headers -o custom-columns=:metadata.name)
  for node in $nodes; do
    echo "./scripts/view_agent_log.sh -n $node > ${FOLDER}/${node}.log"
    ./scripts/view_agent_log.sh -n "$node" > "${FOLDER}/${node}.log" &
  done
fi

if [[ "$get_agents_kernel_logs" == true ]]; then
  nodes=$(kubectl get nodes --no-headers -o custom-columns=:metadata.name)
  for node in $nodes; do
    echo "ssh $node sudo cat /sys/kernel/debug/tracing/trace_pipe > ${FOLDER}/${node}.kernel.log"
    uvt-kvm ssh "$node" sudo cat /sys/kernel/debug/tracing/trace_pipe > "${FOLDER}/${node}.kernel.log" &
  done
fi 

# Get Envoy logs
if [[ "$get_envoys_logs" == true ]]; then
  pods=$(kubectl -n bookinfo-demo get pods --no-headers -o custom-columns=:metadata.name)
  for pod in $pods; do
      # Skip the pod if it contains "loadgenerator"
      if [[ $pod == *"loadgenerator"* ]]; then
        continue
      fi
      
      # Collect logs from this pod envoy
      echo "kubectl logs pods/${pod} -c istio-proxy -n bookinfo-demo -f > ${FOLDER}/${pod-envoy}.log"
      kubectl logs pods/${pod} -c istio-proxy -n bookinfo-demo -f > ${FOLDER}/${pod-envoy}.log &
  done
fi
