#!/bin/bash

LOCKFILE="/tmp/benchmark.$(kubectl config current-context).lock"
if [ -e "${LOCKFILE}" ]; then
    echo "Another benchmark instance is already running on this cluster"
    exit 1
fi
echo $$ > "${LOCKFILE}"
trap 'rm -f "${LOCKFILE}"' EXIT

DEFAULT_TAG=dev
DEFAULT_MEASURE_DURATION=5
DEFAULT_AGENT_NODE=chain-scope-benchmark-agent
DEFAULT_AGENT_USER=ubuntu
DEFAULT_OUTPUT_DIR=benchmark/results
DEFAULT_TEST_APP=nginx

build_ctrl=true
tag=bench-time
tests=(false false false false false false)
perf_duration=$DEFAULT_MEASURE_DURATION
agent_node_name=$DEFAULT_AGENT_NODE
proxy_node_name=
agent_user=$DEFAULT_AGENT_USER
output_dir=$DEFAULT_OUTPUT_DIR
test_app=$DEFAULT_TEST_APP
nic_name=

FRED=$(tput setaf 1)
FGRN=$(tput setaf 2)
FYLW=$(tput setaf 3)
FGRY=$(tput setaf 238)
FRST=$(tput sgr0)

print_usage() {
  echo "Evaluates ChainScope performance in terms of hook execution time hooks under different configurations."
  echo "Uses an nginx-based server (and an intermediate proxy, based on option -a) as target application."
  echo
  echo "Usage: $0 [-t <tests>] [-d <perf duration>] [-n <service node>] [-p <proxy node>] [-u <node username>]
        [-o <output dir>] [-h]"
  echo
  echo "Options:"
  echo "  -t    Comma-separated list of tests to run (default runs all the tests)"
  echo "  -d    Duration in seconds of each metric collection period (default $DEFAULT_MEASURE_DURATION)"
  echo "  -n    Name of the target node used to run testing service (default '$DEFAULT_AGENT_NODE')"
  echo "  -p    Name of the node used to deploy the proxy (default is same as target node)"
  echo "  -u    Username used to log into the target agent node (default '$DEFAULT_AGENT_USER')"
  echo "  -o    Directory were results are stored (default '$DEFAULT_OUTPUT_DIR')"
  echo "  -a    Test application to use (nginx|haproxy|haproxy-synch)"
  echo "  -N    Name of the NICs for intra-node communication (only for ip-based tagging)"
  echo "  -h    Print this help message"
  echo
  echo "Tests:"
  echo "   1:   sampling rate = 1, server-only (-> server ->)"
  echo "   2:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->)"
  echo "   3:   sampling_rate = 0.01, server-only (-> server ->)"
  echo "   4:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->)"
  echo "   5:   no sampling, server-only (-> server ->)"
  echo "   6:   no sampling, with proxy (-> proxy -> server -> proxy ->)"
}

while getopts ':t:ha:d:n:p:u:o:N:' opt; do
  case "${opt}" in
    t) TESTS="${OPTARG}" ;;
    d) perf_duration=${OPTARG} ;;
    n) agent_node_name=${OPTARG} ;;
    p) proxy_node_name=${OPTARG} ;;
    u) agent_user=${OPTARG} ;;
    o) output_dir=${DEFAULT_OUTPUT_DIR} ;;
    a) test_app=${OPTARG} ;;
    N) nic_name=${OPTARG} ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done

if [ -z "$proxy_node_name" ]; then
  proxy_node_name=$agent_node_name
fi

if [ ${test_app} == nginx ]; then
  service_user="systemd-resolve"
  proxy_user="www-data"
  test_app_base=nginx
elif [[ ${test_app} == haproxy ]] || [[ ${test_app} == haproxy-synch ]]; then
  service_user="systemd-resolve"
  proxy_user="99"
  test_app_base=haproxy
else
  echo "Unknown test app: $test_app"
  exit 1
fi

# read tests to run
read -r -a tests_input <<< "$(echo "$TESTS" | tr ',' ' ')"
if [ ${#tests_input[@]} -eq 0 ]; then
  tests=(true true true true true true)
else
  for a in "${tests_input[@]}"; do
    if ! [[ $a =~ ^[0-9]+$ ]] || (( a < 1 || a > ${#tests[@]} )); then
      echo "Unknown test number: $a"
      exit 1
    fi
    tests[a-1]=true
  done
fi

get_entrypoint_ips() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.spec.podCIDR}{"\n"}{end}' \
    | awk -F/ '{print $1}' \
    | awk -F. '{print $1 "." $2 "." $3 ".1"}' \
    | paste -sd,
}

get_proxy_pid() {
  if [ ${test_app} == nginx ]; then
    ssh ubuntu@"$p_node_ip" 'pgrep -u '"$proxy_user"' -f "nginx: worker process" | head -1'
  elif [[ ${test_app} == haproxy ]] || [[ ${test_app} == haproxy-synch ]]; then
    ssh ubuntu@"$p_node_ip" 'pgrep -u '$proxy_user' -f "haproxy" | tail -1'
  fi
}

get_server_pid() {
  ssh ubuntu@"$node_ip" 'pgrep -u '"$service_user"' -f "nginx: worker process" | head -1'
}

delete_chain_scope() {
  echo "Deleting ChainScope..."
  echo -n "${FGRY}"
  sed "s/:$DEFAULT_TAG/:$tag/g" deployment.yaml | kubectl delete -f - &>/dev/null
  kubectl -n chain-scope wait pods -l name=chain-scope-controller --for=delete &>/dev/null
  kubectl -n chain-scope wait pods -l name=chain-scope-agent --for=delete &>/dev/null
  echo -n "${FRST}"
}

deploy_chain_scope() {
  local build_image=$1
  local sampling=$2
  local idle=$3
  local entrypoint_labels=$4
  local entrypoint_ips=$5

  if [ "$build_image" = true ]; then
    # build and push images
    sed -i 's/#define MEASURE_EXECUTION_TIME [[:digit:]]/#define MEASURE_EXECUTION_TIME 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define SENDPAGE_SUPPORT [[:digit:]]/#define SENDPAGE_SUPPORT 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define THREADPOOL_SUPPORT [[:digit:]]/#define THREADPOOL_SUPPORT 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define ENVOY_SUPPORT [[:digit:]]/#define ENVOY_SUPPORT 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define DEBUG_LEVEL [[:digit:]]/#define DEBUG_LEVEL 0/g' agent/src/bpf/common/config.h
    sed -i "s/#define IDLE [[:digit:]]/#define IDLE $idle/g" agent/src/bpf/common/config.h
    sed -i 's/#define TAGS_QUEUE_MAXLENGTH [[:digit:]]\+/#define TAGS_QUEUE_MAXLENGTH 16/g' agent/src/bpf/common/config.h

    echo "Building ChainScope..."
    # shellcheck disable=SC2046
    if ! ./scripts/build_push_image.sh -t "$tag" -a $([[ "$build_ctrl" == true ]] && echo "-c") $([[ "$sampling" == true ]] && echo "-s") -b &>/dev/null; then
      echo "Failed building image, aborting."
      exit 1
    fi
  fi

  echo "Deploying ChainScope..."
  sed "s/:$DEFAULT_TAG/:$tag/g" deployment.yaml | \
    sed "/ENTRYPOINT_LABELS/{n; s/\(value: \"\)\(.*\)\"/\1\2,$entrypoint_labels\"/}" - | \
    sed "/ENTRYPOINT_STATIC_IPS/{n; s/\(value: \"\)\(.*\)\"/\1\2,$entrypoint_ips\"/}" - | \
    sed '/RUST_BACKTRACE/{n; s/value:.*/value: "0"/}' - | \
    sed '/EXPORT_EVENTS_AT_TCP/{n; s/value:.*/value: "false"/}' - | \
    sed '/DEBUG/{n; s/value:.*/value: "false"/}' - | \
    sed '/KUBE_POLL_INTERVAL/{n; s/value:.*/value: "30000"/}' - | \
    sed '/EBPF_POLL_INTERVAL/{n; s/value:.*/value: "20000"/}' - | \
    sed 's/,"/"/g' - | \
    sed 's/: ",/: "/g' - | \
    kubectl apply -f - &>/dev/null
  sleep 2
  echo -n "${FGRY}"
  if ! kubectl -n chain-scope wait pods -l name=chain-scope-agent --for condition=Ready; then
    exit 1
  fi
  if ! kubectl -n chain-scope wait pods -l name=chain-scope-controller --for=condition=Ready; then
    exit 1
  fi
  kubectl -n chain-scope get pods -o wide
  echo -n "${FRST}"
  sleep 5
  echo "ChainScope$( [ "$idle" -eq 1 ] && echo " (idle)" ) is up and running!"
}

deploy_test_application() {
  echo "Deploying the test application ($test_app)..."
  echo -n "${FGRY}"
  kubectl apply -f samples/${test_app_base}-test/${test_app}.yaml
  if ! kubectl -n ${test_app_base}-test wait pod --all --for=condition=Ready; then
    echo -n "${FRST}"
    echo "The test application did not start correctly, aborting."
    exit 1
  fi
  kubectl -n ${test_app}-test get pods -o wide
  echo -n "${FRST}"
}

delete_test_application() {
  echo "Deleting the test application..."
  kubectl delete -f samples/${test_app_base}-test/${test_app}.yaml
  kubectl -n ${test_app_base}-test wait pods --for=delete &>/dev/null
}

benchmark_routine_exec_time() {
  local data_file_service=$1
  local data_file_proxy=$2
  local ip=$3
  local port=$4

  #curl http://"$node_ip":"$port"/test
  #siege -b -c 48 -t 100s http://"$node_ip":"$port"/test &
  ab -k -r -q -d -c 1 -t $((perf_duration*2+30))s -n 9999999 http://"$ip":"$port"/test | tee -a "$output_file" &
  sleep 10

  if [ -n "$data_file_proxy" ]; then
    agent_pod=$(kubectl -n chain-scope get pods -l name=chain-scope-agent --field-selector spec.nodeName="$proxy_node_name" -o jsonpath='{.items[0].metadata.name}')
    pid=$(get_proxy_pid)
    ./scripts/utils/set_bench_pid_filter.sh "$pid"
    sleep "$perf_duration"
    ./scripts/utils/set_bench_pid_filter.sh 0
    sleep 1
    kubectl -n chain-scope exec -it "$agent_pod" -- cat exec_time.csv > "$data_file_proxy".exec.proxy.csv
  fi

  agent_pod=$(kubectl -n chain-scope get pods -l name=chain-scope-agent --field-selector spec.nodeName="$agent_node_name" -o jsonpath='{.items[0].metadata.name}')
  pid=$(get_server_pid)
  ./scripts/utils/set_bench_pid_filter.sh "$pid"
  sleep "$perf_duration"
  ./scripts/utils/set_bench_pid_filter.sh 0
  sleep 1
  kubectl -n chain-scope exec -it "$agent_pod" -- cat exec_time.csv > "$data_file_service".exec.service.csv

  wait
}

no_previous_tests() {
  # Return true if no tests in the range was run
  local start=$(($1-1))
  local end=$(($2-1))

  for ((i=start; i<=end; i++)); do
    if [[ "${tests[i]}" != false ]]; then
      echo false
      return 0  # at least one element is not false
    fi
  done
  echo true  # all elements in the range are false
}

echo "Tests to run:"
for i in "${!tests[@]}"; do
  printf "Test %2s: %s\n" $((i+1)) "$([[ ${tests[$i]} == true ]] && echo "${FGRN}yes${FRST}" || echo "${FRED}no${FRST}")"
done
echo ""

echo ""
echo "--- Preliminary setup ---"
echo ""

echo "Checking target nodes..."
node_ip=$(kubectl get node "$agent_node_name" -o custom-columns=ip:.status.addresses[0].address --no-headers=true)
p_node_ip=$(kubectl get node "$proxy_node_name" -o custom-columns=ip:.status.addresses[0].address --no-headers=true)
if [ -z "$node_ip" ] || [ -z "$p_node_ip" ]; then
  echo "Please specify a valid Kubernetes node to be used as agent."
  exit 1
fi

nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $nodes; do
  kubectl label node "$node" benchmark-web-
  kubectl label node "$node" benchmark-proxy-
done
kubectl label node "$agent_node_name" benchmark-web=true
kubectl label node "$proxy_node_name" benchmark-proxy=true

# delete any existing deployment
echo "Cleaning environment..."
./scripts/clean.sh -t "$tag" -d -T -j &>/dev/null

echo ""
test_id=$(date +%Y-%m-%d_%H%M%S)
echo "Experiment $test_id"
if [[ "$node_ip" != "$p_node_ip" ]]; then
  experiment_type="${test_app}.two_nodes"
else
  experiment_type="${test_app}.same_node"
fi
latest="$output_dir"/"$experiment_type"/latest
output_dir="$output_dir"/"$experiment_type"/"$test_id"
output_file="$output_dir"/exec_time.out
mkdir -p "$output_dir"
ln -s "$test_id" "$latest"
touch "$output_file"
echo "Target service node: $agent_node_name"
echo "Target proxy node: $proxy_node_name"
if [[ -n ${nic_name} ]]; then
  ssh "$agent_user"@"$node_ip" 'sudo sh -c "echo f > /sys/class/net/'"${nic_name}"'/queues/rx-0/rps_cpus"'
  ssh "$agent_user"@"$p_node_ip" 'sudo sh -c "echo f > /sys/class/net/'"${nic_name}"'/queues/rx-0/rps_cpus"'
fi
echo "Copying tools to benchmark nodes..."
ssh "$agent_user"@"$node_ip" 'mkdir -p '"$output_dir"
if [[ "$node_ip" != "$p_node_ip" ]]; then
  ssh "$agent_user"@"$p_node_ip" 'mkdir -p '"$output_dir"
fi
echo ""

test_no=0

echo ""
echo "--- Benchmarking with ChainScope ---"
echo ""

((test_no++))
echo "[Test $test_no] sampling_rate=1, server-only (-> server ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)"
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  data_file_server="$output_dir"/perf.sampling1.serveronly.server.data
  benchmark_routine_exec_time "$data_file_server" "" "$node_ip" 30000
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=1, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests 1 $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)"
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  sleep 5
  deploy_test_application
  sleep 5
  data_file_server="$output_dir"/perf.sampling1.withproxy.server.data
  data_file_proxy="$output_dir"/perf.sampling1.withproxy.proxy.data
  benchmark_routine_exec_time "$data_file_server" "$data_file_proxy" "$p_node_ip" 30001
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.01, server-only (-> server ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests 1 $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)"
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  data_file_server="$output_dir"/perf.sampling0.01.serveronly.server.data
  benchmark_routine_exec_time "$data_file_server" "" "$node_ip" 30000
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.01, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests 1 $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)"
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  data_file_server="$output_dir"/perf.sampling0.01.withproxy.server.data
  data_file_proxy="$output_dir"/perf.sampling0.01.withproxy.proxy.data
  benchmark_routine_exec_time "$data_file_server" "$data_file_proxy" "$p_node_ip" 30001
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"


echo ""
echo "--- Benchmarking with plain ChainScope (no sampling) ---"
echo ""

# Deploy the test app once as persistent connections are not a concerns for the next tests
for (( i=4; i<${#tests[@]}; i++ )); do
  if [[ "${tests[i]}" == true ]]; then
    deploy_test_application
    echo ""
    break
  fi
done

((test_no++))
no_sampling_no=$test_no
echo "[Test $test_no] no sampling, server-only (-> server ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true false 0 "" "$(get_entrypoint_ips)"
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  data_file_server="$output_dir"/perf.nosampling.serveronly.server.data
  benchmark_routine_exec_time "$data_file_server" "" "$node_ip" 30000
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] no sampling, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $no_sampling_no $((test_no-1)))
  deploy_chain_scope "$need_build" false 0 "" "$(get_entrypoint_ips)"
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  data_file_server="$output_dir"/perf.nosampling.withproxy.server.data
  data_file_proxy="$output_dir"/perf.nosampling.withproxy.proxy.data
  benchmark_routine_exec_time "$data_file_server" "$data_file_proxy" "$p_node_ip" 30001
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Clean ---"
echo ""
echo "All benchmarking complete, cleaning..."
echo -n "${FGRY}"
./scripts/clean.sh -t "$tag"
kubectl label nodes "$agent_node_name" benchmark-web-
kubectl label nodes "$proxy_node_name" benchmark-proxy-
echo -n "${FRST}"
echo ""

echo "Done. Results saved at $output_dir."
