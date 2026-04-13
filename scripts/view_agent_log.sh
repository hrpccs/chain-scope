#!/bin/bash

app=productpage

print_usage() {
  echo "Usage: $0 [-n <node name>] [-a <app name>]"
  echo
  echo "Options:"
  echo "  -n    Agent node name (if not set, look for the node running the app passed with -a)"
  echo "  -a    Look for the agent node running this app (default is 'productpage')"
  echo "  -h    Print this help message"
}

while getopts 'n:a:h' opt; do
  case "${opt}" in
    n) node=${OPTARG} ;;
    a) app=${OPTARG} ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done
shift $((OPTIND-1))

if [ -z "$node" ]; then
  node="$(kubectl -n bookinfo-demo get pods -l app="$app" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)"
fi

echo "Showing log for agent on node $node..."
echo ""

kubectl -n chain-scope wait pods -l name=chain-scope-agent --field-selector spec.nodeName="${node}" --for=condition=Ready
name=$(kubectl -n chain-scope get pods -l name=chain-scope-agent --field-selector spec.nodeName="${node}" | grep Running | awk '{print $1}')
kubectl logs "$name" -n chain-scope -f
