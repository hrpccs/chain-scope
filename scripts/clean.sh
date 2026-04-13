#!/bin/bash

DEFAULT_TAG=dev

tag=$DEFAULT_TAG
demo=false
test=false
java_plugin=false
golang_plugin=false
http_plugin=false
jaeger_plugin=false

print_usage() {
  echo "Usage: $0 [-t <images tag>] [-d] [-j] [-g] [-x] [-u] [-h]"
  echo
  echo "Options:"
  echo "  -t    Tag of the agent and controller images (default '$DEFAULT_TAG')"
  echo "  -d    Also delete the demo application"
  echo "  -T    Also delete the test application"
  echo "  -j    Delete the java plug-in for threadpool support"
  echo "  -g    Delete the golang plug-in for goroutines support"
  echo "  -x    Delete the HTTP tagging plug-in"
  echo "  -u    Delete the Jaeger UI plug-in"
  echo "  -h    Print this help message"
}

while getopts 'hdTjgxut:' opt; do
  case "${opt}" in
    t) tag=${OPTARG} ;;
    d) demo=true ;;
    T) test=true ;;
    j) java_plugin=true ;;
    g) golang_plugin=true ;;
    x) http_plugin=true ;;
    u) jaeger_plugin=true ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done

sed "s/:$DEFAULT_TAG/:$tag/g" deployment.yaml | kubectl delete -f -
kubectl -n chain-scope wait pods -l name=chain-scope-controller --for=delete &>/dev/null
kubectl -n chain-scope wait pods -l name=chain-scope-agent --for=delete &>/dev/null

if [[ "$java_plugin" == true ]]; then
  # shellcheck disable=SC2046
  ./plugins/java/scripts/clean.sh -t "$tag" $([[ "$demo" == true ]] && echo "-d")
fi

if [[ "$golang_plugin" == true ]]; then
  # shellcheck disable=SC2046
  ./plugins/golang/scripts/clean.sh -t "$tag" $([[ "$demo" == true ]] && echo "-d")
fi

if [[ "$http_plugin" == true ]]; then
  # shellcheck disable=SC2046
  ./plugins/http-tagging/scripts/clean.sh -t "$tag" $([[ "$demo" == true ]] && echo "-d")
fi

if [[ "$jaeger_plugin" == true ]]; then
  kubectl delete -f ./plugins/jaeger-ui/deployment.yaml
  kubectl -n chain-scope wait pods -l name=jaeger --for=delete &>/dev/null
  echo "Successfully deleted the Jaeger UI plug-in."
fi

if [[ "$demo" == true ]]; then
  kubectl delete -f samples/bookinfo/bookinfo.yaml
  kubectl -n bookinfo-demo wait pods --for=delete &>/dev/null
  echo "Successfully deleted the demo application."
fi

if [[ "$test" == true ]]; then
  kubectl delete -n hotel-test -Rf samples/DeathStarBench/hotelReservation/kubernetes/
  kubectl -n hotel-test wait pods --for=delete &>/dev/null
  kubectl delete -f samples/nginx-test/nginx.yaml
  kubectl -n nginx-test wait pods --for=delete &>/dev/null
  kubectl delete -f samples/nginx-test/nginx-otel.yaml
  kubectl -n nginx-test wait pods --for=delete &>/dev/null
  kubectl delete -f samples/haproxy-test/haproxy.yaml
  kubectl -n haproxy-test wait pods --for=delete &>/dev/null
  kubectl delete -f samples/haproxy-test/haproxy-synch.yaml
  kubectl -n haproxy-test wait pods --for=delete &>/dev/null
  echo "Successfully deleted test applications."
fi

# Kill any log collectors
processes=$(ps -aux | grep -E "[^]]/debug/tracing/trace_pipe" | tr -s " " | cut -d " " -f 2)
for process in $processes; do
  echo "kill $process"
  kill "$process"
done
nodes=$(kubectl get nodes --no-headers -o custom-columns=:metadata.name)
for node in $nodes; do
  processes=$(uvt-kvm ssh $node 'ps -aux | grep -E "[^]]/debug/tracing/trace_pipe" | tr -s " " | cut -d " " -f 2')
  for process in $processes; do
    echo "uvt-kvm ssh $node kill $process"
    uvt-kvm ssh "$node" kill "$process"
  done
done
processes=$(ps -aux | grep -E "[^]]view_agent_log" | tr -s " " | cut -d " " -f 2)
for process in $processes; do
  echo "kill $process"
  kill "$process"
done
processes=$(ps -aux | grep -E "[^]]view_controller_log" | tr -s " " | cut -d " " -f 2)
for process in $processes; do
  echo "kill $process"
  # shellcheck disable=SC2086
  kill $process
done
processes=$(ps -aux | grep -E "[^]]view_controller_collector" | tr -s " " | cut -d " " -f 2)
for process in $processes; do
  echo "kill $process"
  kill "$process"
done
processes=$(ps -aux | grep -E "kubectl logs" | grep -E "[^]]-c istio-proxy" | tr -s " " | cut -d " " -f 2)
for process in $processes; do
  echo "kill $process"
  kill "$process"
done

# Clean old kernel logs
nodes=$(kubectl get nodes --no-headers -o custom-columns=:metadata.name)
for node in $nodes; do
  echo "uvt-kvm ssh $node 'sudo sh -c \"echo > /sys/kernel/debug/tracing/trace\"'"
  uvt-kvm ssh "$node" 'sudo sh -c "echo > /sys/kernel/debug/tracing/trace"'
done

# Clean any ip-tagging related stuff
for node in $nodes; do
  # Find and remove clsact qdiscs
  echo "Checking for clsact qdiscs..."
  uvt-kvm ssh "$node" 'sudo sh -c "tc qdisc show"' | grep clsact | while read -r line; do
      dev=$(echo "$line" | grep -o 'dev [^ ]*' | cut -d' ' -f2)
      echo "Removing clsact from $dev"
      uvt-kvm ssh "$node" 'sudo sh -c "tc qdisc del dev '"$dev"' clsact 2>/dev/null"'
  done
  uvt-kvm ssh "$node" 'sudo sh -c "ip link delete veth-gso 2>/dev/null"'
done

# Remove any benchmark lock
rm -f /tmp/benchmark.*.lock
