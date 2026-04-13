#!/bin/bash

if [[ -n "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR"/utils/registry.sh
else
  source utils/registry.sh
fi

DEFAULT_REGISTRY=$(get_default_registry)
IMAGE_REGISTRY=$(get_registry)

LOCKFILE="/tmp/benchmark.$(kubectl config current-context).lock"
if [ -e "${LOCKFILE}" ]; then
    echo "Another benchmark instance is already running on this cluster"
    exit 1
fi
echo $$ > "${LOCKFILE}"
trap 'rm -f "${LOCKFILE}"' EXIT

DEFAULT_TAG=dev
DEFAULT_PERF_DURATION=60
DEFAULT_AGENT_NODE=chain-scope-benchmark-agent
DEFAULT_AGENT_USER=ubuntu
DEFAULT_OUTPUT_DIR=benchmark/results
DEFAULT_TEST_APP=nginx

build_ctrl=true
tag=bench
tests=(false false false false false false false false false false false false false false false false false false false false false false false false false false false false false)
perf_duration=$DEFAULT_PERF_DURATION
agent_node_name=$DEFAULT_AGENT_NODE
proxy_node_name=
agent_user=$DEFAULT_AGENT_USER
output_dir=$DEFAULT_OUTPUT_DIR
test_app=$DEFAULT_TEST_APP
nic_name=
interactive=false
update_latest=true

# set colors
FRED=$(tput setaf 1)
FGRN=$(tput setaf 2)
FYLW=$(tput setaf 3)
FGRY=$(tput setaf 238)
FRST=$(tput sgr0)

print_usage() {
  echo "Evaluates ChainScope performance in terms of CPU overhead under different configurations."
  echo "Uses an nginx-based server (and an intermediate proxy) as target application."
  echo
  echo "Usage: $0 [-t <tests>] [-d <perf duration>] [-n <service node>] [-p <proxy node>] [-i <NIC>]
        [-u <node username>] [-o <output dir>] [-h]"
  echo
  echo "Options:"
  echo "  -t    Comma-separated list of tests to run (default runs all the tests)"
  echo "  -d    Duration in seconds of each perf record (default $DEFAULT_PERF_DURATION)"
  echo "  -n    Name of the target node used to run testing service (default '$DEFAULT_AGENT_NODE')"
  echo "  -p    Name of the node used to deploy the proxy (default is same as target node)"
  echo "  -u    Username used to log into the target agent node (default '$DEFAULT_AGENT_USER')"
  echo "  -o    Directory were results are stored (default '$DEFAULT_OUTPUT_DIR')"
  echo "  -a    Test application to use (nginx|haproxy|haproxy-synch)"
  echo "  -i    Name of the NICs for intra-node communication (only for ip-based tagging)"
  echo "  -I    Interactive (asks for input before executing each benchmark routine)"
  echo "  -h    Print this help message"
  echo
  echo "Tests:"
  echo "   1:   sampling rate = 1, server-only (-> server ->) event based with span"
  echo "   2:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->) event based with span"
  echo "   3:   sampling_rate = 0.01, server-only (-> server ->) event based with span"
  echo "   4:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->) event based with span"
  echo "   5:   no sampling, server-only (-> server ->)"
  echo "   6:   no sampling, with proxy (-> proxy -> server -> proxy ->)"
  echo "   7:   IDLE programs, server-only (-> server ->)"
  echo "   8:   IDLE programs, with proxy (-> proxy -> server -> proxy ->)"
  echo "   9:   plain app (no hooks), server-only (-> server ->)"
  echo "  10:   plain app (no hooks), with proxy (-> proxy -> server -> proxy ->)"
  echo "  11:   sampling rate = 1, server-only (-> server ->), span based"
  echo "  12:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), span based"
  echo "  13:   sampling rate = 0.10, server-only (-> server ->), span based"
  echo "  14:   sampling_rate = 0.10, with proxy (-> proxy -> server -> proxy ->), span based"
  echo "  15:   sampling_rate = 0.01, server-only (-> server ->), span based"
  echo "  16:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), span based"
  echo "  17:   sampling rate = 1, server-only (-> server ->), event based with log"
  echo "  18:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), event based with log"
  echo "  19:   sampling rate = 0.10, server-only (-> server ->), event based with log"
  echo "  20:   sampling_rate = 0.10, with proxy (-> proxy -> server -> proxy ->), event based with log"
  echo "  21:   sampling_rate = 0.01, server-only (-> server ->), event based with log"
  echo "  22:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), event based with log"
  echo "  23:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), beyla"
  echo "  24:   sampling_rate = 0.1, with proxy (-> proxy -> server -> proxy ->), beyla"
  echo "  25:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), beyla"
  echo "  26:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), application with opentelemetry auto-instrumentation"
  echo "  27:   sampling_rate = 0.1, with proxy (-> proxy -> server -> proxy ->), application with opentelemetry auto-instrumentation"
  echo "  28:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), application with opentelemetry auto-instrumentation"
  echo "  29:   no sampling, with proxy (-> proxy -> server -> proxy ->), deepflow"
}

while getopts ':t:ha:d:n:p:u:o:i:IL' opt; do
  case "${opt}" in
    t) TESTS="${OPTARG}" ;;
    d) perf_duration=${OPTARG} ;;
    n) agent_node_name=${OPTARG} ;;
    p) proxy_node_name=${OPTARG} ;;
    u) agent_user=${OPTARG} ;;
    o) output_dir=${DEFAULT_OUTPUT_DIR} ;;
    a) test_app=${OPTARG} ;;
    i) nic_name=${OPTARG} ;;
    L) update_latest=false ;;
    I) interactive=true ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done

if [[ -z "$proxy_node_name" ]]; then
  proxy_node_name=$agent_node_name
fi


if [[ "${test_app}" == nginx ]]; then
  service_user="101"
  proxy_user="www-data"
  test_app_base=nginx
elif [[ ${test_app} == haproxy ]] || [[ ${test_app} == haproxy-synch ]]; then
  service_user="101"
  proxy_user="99"
  test_app_base=haproxy
else
  echo "Unknown test app: $test_app"
  exit 1
fi

# read tests to run
read -r -a tests_input <<< "$(echo "$TESTS" | tr ',' ' ')"
if [ ${#tests_input[@]} -eq 0 ]; then
  tests=(true true true true true true true true true true true true true true true true true true true true true true true true true true true true true)
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
  if [ "${test_app}" == nginx ]; then
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
  kubectl delete -f deployment.yaml &>/dev/null
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
  local sampling_interval=$6
  local span_based=$7
  local event_with_log=$8

  if [ "$build_image" = true ]; then
    # build and push images
    sed -i 's/#define MEASURE_EXECUTION_TIME [[:digit:]]/#define MEASURE_EXECUTION_TIME 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define SENDPAGE_SUPPORT [[:digit:]]/#define SENDPAGE_SUPPORT 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define THREADPOOL_SUPPORT [[:digit:]]/#define THREADPOOL_SUPPORT 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define ENVOY_SUPPORT [[:digit:]]/#define ENVOY_SUPPORT 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define DEBUG_LEVEL [[:digit:]]/#define DEBUG_LEVEL 0/g' agent/src/bpf/common/config.h
    sed -i "s/#define IDLE [[:digit:]]/#define IDLE $idle/g" agent/src/bpf/common/config.h
    sed -i 's/#define TAGS_QUEUE_MAXLENGTH [[:digit:]]\+/#define TAGS_QUEUE_MAXLENGTH 16/g' agent/src/bpf/common/config.h
    sed -i 's/#define NIC_NAME ".*"/#define NIC_NAME "'"${nic_name}"'"/g' agent/src/bpf/common/config.h

    echo "Building ChainScope..."
    # shellcheck disable=SC2046
    # if ! ./scripts/build_push_image.sh -t "$tag" -a $([[ "$build_ctrl" == true ]] && echo "-c") $([[ "$sampling" == true ]] && echo "-s") &>/dev/null; then
    if ! ./scripts/build_push_image.sh -t "$tag" -a \
        $([[ "$build_ctrl" == true ]] && echo "-c") \
        $([[ "$sampling" == true ]] && echo "-s") \
        $([[ "$span_based" == true ]] && echo "-j"); then
      echo "Failed building image, aborting."
      exit 1
    fi
  fi

  echo "Deploying ChainScope..."
  sed "s/:$DEFAULT_TAG/:$tag/g" deployment.yaml | \
    sed "s|$DEFAULT_REGISTRY|$IMAGE_REGISTRY|g" - | \
    sed "/ENTRYPOINT_LABELS/{n; s/\(value: \"\)\(.*\)\"/\1\2,$entrypoint_labels\"/}" - | \
    sed "/ENTRYPOINT_STATIC_IPS/{n; s/\(value: \"\)\(.*\)\"/\1\2,$entrypoint_ips\"/}" - | \
    sed '/RUST_BACKTRACE/{n; s/value:.*/value: "0"/}' - | \
    sed '/DEBUG/{n; s/value:.*/value: "false"/}' - | \
    sed '/KUBE_POLL_INTERVAL/{n; s/value:.*/value: "30000"/}' - | \
    sed '/EBPF_POLL_INTERVAL/{n; s/value:.*/value: "20000"/}' - | \
    sed '/NIC_NAME/{n; s/value:.*/value: "'"${nic_name}"'"/}' - | \
    sed '/SAMPLING_INTERVAL/{n; s/value:.*/value: "'"${sampling_interval}"'"/}' - | \
    sed '/EVENT_WITH_LOG/{n; s/value:.*/value: "'"${event_with_log}"'"/}' - | \
    sed 's/,"/"/g' - | \
    sed 's/: ",/: "/g' - | \
    kubectl apply -f - &>/dev/null
  sleep 2
  echo -n "${FGRY}"
  kubectl -n chain-scope wait pods -l name=chain-scope-agent --for condition=Ready
  kubectl -n chain-scope wait pods -l name=chain-scope-controller --for=condition=Ready
  kubectl -n chain-scope get pods -o wide
  echo -n "${FRST}"
  echo "ChainScope$( [ "$idle" -eq 1 ] && echo " (idle)" ) is up and running!"

  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
}

deploy_beyla() {
  local sampling_rate=$1
  
  echo "Deploying Beyla..."
  sed 's/BEYLASAMPLINGRATE/'${sampling_rate}'/g' samples/nginx-test/beyla.yaml | \
    kubectl apply -f - &>/dev/null
  if ! kubectl -n beyla wait pod --all --for=condition=Ready; then
    echo -n "${FRST}"
    echo "Beyla did not start correctly, aborting."
    exit 1
  fi
  
  echo "wait for 10 seconds for Beyla to start..."
  sleep 10
  echo -n "${FRST}"

  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
}

delete_beyla() {
  echo "Deleting Beyla..."
  kubectl delete -f samples/nginx-test/beyla.yaml
  kubectl -n beyla wait pods --for=delete &>/dev/null
}

deploy_deepflow() {
  helm repo add deepflow https://deepflowio.github.io/deepflow
  helm repo update deepflow # use `helm repo update` when helm < 3.7.0
  helm install deepflow -n deepflow deepflow/deepflow --version 6.6.018 --create-namespace -f samples/nginx-test/deepflow-values-custom.yaml
  # Wait for all DeepFlow pods to be ready
  echo "Waiting for DeepFlow pods to be ready..."
  kubectl wait --for=condition=ready pod --all -n deepflow --timeout=300s

  Version=v6.6
  if ! command -v deepflow-ctl &> /dev/null; then
    sudo curl -o /usr/bin/deepflow-ctl \
      "https://deepflow-ce.oss-cn-beijing.aliyuncs.com/bin/ctl/$Version/linux/$(arch | sed 's|x86_64|amd64|' | sed 's|aarch64|arm64|')/deepflow-ctl"
    sudo chmod a+x /usr/bin/deepflow-ctl
  else
    echo "deepflow-ctl already exists, skipping download"
  fi

  NODE_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[0].address}")
  http_proxy= https_proxy= deepflow-ctl --ip $NODE_IP agent-group list default
  GROUP_ID=$(http_proxy= https_proxy= deepflow-ctl --ip $NODE_IP agent-group list default | awk '/default/ {print $2}')
  http_proxy= https_proxy= deepflow-ctl --ip $NODE_IP agent-group-config create $GROUP_ID -f samples/nginx-test/deepflow-agent-config.yaml
  # deepflow-ctl --ip $NODE_IP agent-group-config update $GROUP_ID -f agent-config.yaml 

  # wait until the frontend is injected with uprobe
  # check the output of ssh "agent_user"@"$p_node_ip" "sudo cat /proc/$(pgrep frontend)/maps | grep uprobe"
  local n=100
  while [ $n -gt 0 ]; do
    output=$(ssh "$agent_user"@"$p_node_ip" 'sudo bpftool prog | grep df_T')
    #if output contains "uprobe" then break
    if [[ $output =~ "df_T" ]]; then
      break
    fi
    n=$((n-1))
    sleep 10 
  done

  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
}

get_deepflow_mysql_node_ip() {
  kubectl -n deepflow get pod -l component=mysql -o jsonpath='{.items[0].spec.nodeName}' \
    | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}'
}

get_deepflow_clickhouse_node_ip() {
  kubectl -n deepflow get pod -l component=clickhouse -o jsonpath='{.items[0].spec.nodeName}' \
    | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}'
}

delete_deepflow() {
  local clickhouse_node_ip=$1
  local mysql_node_ip=$2
  clickhouse_node_ip=$(get_deepflow_clickhouse_node_ip)
  mysql_node_ip=$(get_deepflow_mysql_node_ip)
  helm uninstall deepflow -n deepflow
  kubectl wait --for=delete pod --all -n deepflow --timeout=300s
  ssh "$agent_user"@"$clickhouse_node_ip" 'sudo rm -rf /opt/deepflow-clickhouse/'
  ssh "$agent_user"@"$mysql_node_ip" 'sudo rm -rf /opt/deepflow-mysql/'
}

deploy_test_application() {
  echo "Deploying the test application ($test_app)..."
  echo -n "${FGRY}"
  kubectl apply -f samples/${test_app_base}-test/"${test_app}".yaml
  if ! kubectl -n ${test_app_base}-test wait pod --all --for=condition=Ready --timeout=100s; then
    echo -n "${FRST}"
    echo "The test application did not start correctly, aborting."
    exit 1
  fi
  kubectl -n "${test_app}"-test get pods -o wide
  echo -n "${FRST}"

  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
}

delete_test_application() {
  echo "Deleting the test application..."
  kubectl delete -f samples/${test_app_base}-test/"${test_app}".yaml
  kubectl -n ${test_app_base}-test wait pods --for=delete &>/dev/null
}

deploy_test_otel_application() {
  local sampling_rate=$1

  echo "Deploying the otel test application ($test_app)..."
  echo -n "${FGRY}"
  # kubectl apply -f samples/${test_app_base}-test/"${test_app}".yaml
  sed 's/OTELSAMPLINGRATE/'${sampling_rate}'/g' samples/${test_app_base}-test/"${test_app}"-otel.yaml | \
    kubectl apply -f - &>/dev/null
  if ! kubectl -n ${test_app_base}-test wait pod --all --for=condition=Ready; then
    echo -n "${FRST}"
    echo "The test application did not start correctly, aborting."
    exit 1
  fi
  kubectl -n "${test_app}"-test get pods -o wide
  echo -n "${FRST}"

  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
}

delete_test_otel_application() {
  echo "Deleting the test application..."
  kubectl delete -f samples/${test_app_base}-test/"${test_app}"-otel.yaml
  kubectl -n ${test_app_base}-test wait pods --for=delete &>/dev/null
}

get_test_services() {
  kubectl -n ${test_app_base}-test get services -o jsonpath="{.items[*].metadata.name}"
}

get_ctrl_node_ip() {
  kubectl -n chain-scope get pod -l name=chain-scope-controller -o jsonpath='{.items[0].spec.nodeName}' \
    | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'  \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}'
}

get_deepflow_server_node_ip() {
  kubectl -n deepflow get pod -l component=deepflow-server -o jsonpath='{.items[0].spec.nodeName}' \
    | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}'
}

benchmark_throughput_median() {
  local ip=$1
  local port=$2
  local n=$3

  # A temporary directory to store output files for all runs
  local run_dir
  run_dir=$(mktemp -d)

  # A file to store the "RPS /path/to/output" for sorting
  local results_file
  results_file=$(mktemp)

  local successful_runs=0

  for i in $(seq 1 "$n"); do
    #echo "[$i/$n] Benchmarking throughput..."
    # Store each run's output in its own file inside the temp directory
    local tmp_file="$run_dir/run_$i.txt"

    # Run the benchmark
    ab -k -r -q -d -c 32 -n 200000 "http://$ip:$port/test" > "$tmp_file"

    # Skip failed or problematic runs
    if grep -q "WARNING" "$tmp_file"; then
      #echo "Run #$i had warnings, skipping."
      continue
    fi

    local rps
    rps=$(grep "Requests per second" "$tmp_file" | awk '{print $4}')

    if [[ -z "$rps" ]]; then
      #echo "Run #$i failed to produce a result, skipping."
      continue
    fi

    #echo "Run #$i got $rps req/sec"
    # Store the RPS value and the path to its corresponding output file
    echo "$rps $tmp_file" >> "$results_file"
    successful_runs=$((successful_runs + 1))
  done

  # --- Process the results ---
  if [[ $successful_runs -eq 0 ]]; then
    echo "No successful benchmark runs were completed."
    rm -rf "$run_dir"
    rm "$results_file"
    return 1
  fi

  # Calculate the line number of the median run.
  # For 5 runs, (5+1)/2 = 3rd item. For 4 runs, (4+1)/2 = 2nd item.
  local median_index=$(( (successful_runs + 1) / 2 ))

  # Sort the results numerically by RPS and get the file path of the median run
  local median_file
  median_file=$(sort -k1,1n "$results_file" | sed -n "${median_index}p" | awk '{print $2}')

  #echo "Found $successful_runs valid run(s). Displaying median run."

  # Display the full 'ab' output of the median run
  cat "$median_file"

  # Clean up the temporary directory and results file
  rm -rf "$run_dir"
  rm "$results_file"
}

benchmark_routine() { #parameters srv proxy file ip port
  local data_file_service=$1
  local data_file_proxy=$2
  local data_file_agent=$3
  local data_file_ctrl=$4
  local ip=$5
  local port=$6
  local perf_target=$7

  local agent_name=""
  local collector_name=""
  local collector_ip=""
  if [[ "$perf_target" == "chainscope" ]]; then
      agent_name="chain_scope"
      collector_name="main.py"
      collector_ip=$(get_ctrl_node_ip)
      #   ssh "$agent_user"@"$collector_ip" 'mkdir -p '"$test_id"
      ssh "$agent_user"@"$collector_ip" 'mkdir -p '"$test_id"
  elif [[ "$perf_target" == "deepflow" ]]; then
      agent_name="deepflow-agent"
      collector_name="deepflow-server"
      collector_ip=$(get_deepflow_server_node_ip)
      ssh "$agent_user"@"$collector_ip" 'mkdir -p '"$test_id"
  elif [[ "$perf_target" == "beyla" ]]; then
      # beyla use jaeger as collector and backend
      agent_name="beyla"
      collector_name=""
      collector_ip=""
  else
      agent_name=""
      collector_name=""
      collector_ip=""
  fi

  echo "Warming up the service..."
  ab -k -r -q -d -c 32 -n 500000 http://"$ip":"$port"/test &>/dev/null
  sleep 5

  # measure throughput
  echo "Benchmarking throughput..." | tee -a "$output_file"
  benchmark_throughput_median "$ip" "$port" 1 | tee -a "$output_file"

  # measure cpu overhead
  echo "Benchmarking cpu overhead..."
  #curl http://"$node_ip":"$port"/test
  #siege -b -c 48 -t 100s http://"$node_ip":"$port"/test &>/dev/null &
  #fortio load -c 32 -keepalive -t $((perf_duration+30))s -quiet -qps 0 http://"$ip":"$port"/test 2>&1 &>/dev/null &
  ab -k -r -q -d -c 32 -t $((perf_duration+10))s -n 9999999 http://"$ip":"$port"/test &>/dev/null &
  #wrk -t32 -c32 -d$((perf_duration+30))s http://"$ip":"$port"/test &>/dev/null &
  sleep 5

  if [ -n "$data_file_proxy" ]; then
    ssh "$agent_user"@"$p_node_ip" 'sudo bpftool prog list > '"$data_file_proxy"'.prog'
    ssh "$agent_user"@"$p_node_ip" 'sudo perf record -F 1000 -o '"$data_file_proxy"' --call-graph fp -e cpu-cycles -p $(pgrep -u '"$proxy_user"' -f "nginx: worker process" | head -1) sleep '"$perf_duration" &
  fi

  ssh "$agent_user"@"$node_ip" 'sudo bpftool prog list > '"$data_file_service"'.prog'
  ssh "$agent_user"@"$node_ip" 'sudo perf record -F 1000 -o '"$data_file_service"' --call-graph fp -e cpu-cycles -p $(pgrep -u '"$service_user"' -f "nginx: worker process" | head -1) sleep '"$perf_duration" &

  if [[ -n "$data_file_agent" ]]; then
    echo "TEST"
    # collect user component overhead
    if [[ -n "$agent_name" ]]; then
      echo "TEST 1"
      ssh "$agent_user"@"$node_ip" 'sudo perf stat -o '"$data_file_agent"' -a -p $(pgrep -f '"$agent_name"' | head -1) sleep '"$perf_duration" &
      if [[ "$node_ip" != "$p_node_ip" ]]; then
        echo "TEST 2"
        ssh "$agent_user"@"$p_node_ip" 'sudo perf stat -o '"$data_file_agent"' -p $(pgrep -f '"$agent_name"' | head -1) sleep '"$perf_duration" &
      fi
    fi
  fi

  if [[ -n "$data_file_ctrl" ]]; then
    if [[ -n $collector_name ]]; then
      ssh "$agent_user"@"$collector_ip" 'sudo perf stat -o '"$data_file_ctrl"' -a -p $(pgrep -f '"$collector_name"' | head -1) sleep '"$perf_duration" &
    fi
  fi

  wait
}

collect_results() {
  local data_file=$1
  local output_file=$2
  local target_ip=$3

  ssh "$agent_user"@"$target_ip" 'sudo ./perf_head_custom_report.sh -i '"$data_file" | tee -a "$output_file"
}

collect_user_results() {
  local data_file=$1
  local output_file=$2
  local target_ip=$3

  ssh "$agent_user"@"$target_ip" 'cat '"$data_file" | grep "task-clock" | tee -a "$output_file"
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

if ! ssh "$agent_user"@"$node_ip" 'perf -h' 1>/dev/null || ! ssh "$agent_user"@"$p_node_ip" 'perf -h' 1>/dev/null; then
  echo "Please ensure target nodes have perf tools installed."
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
delete_test_application &>/dev/null
delete_chain_scope &>/dev/null
delete_beyla &>/dev/null
delete_test_otel_application &>/dev/null
delete_deepflow &>/dev/null

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
output_file="$output_dir"/exec_cpu.out
mkdir -p "$output_dir"
if [[ $update_latest == true ]]; then
  rm -f "$latest"
  ln -s "$test_id" "$latest"
fi
touch "$output_file"
echo "Target service node: $agent_node_name"
echo "Target proxy node: $proxy_node_name"
if [[ -n ${nic_name} ]]; then
  ssh "$agent_user"@"$node_ip" 'sudo sh -c "echo f > /sys/class/net/'"${nic_name}"'/queues/rx-0/rps_cpus"'
  ssh "$agent_user"@"$p_node_ip" 'sudo sh -c "echo f > /sys/class/net/'"${nic_name}"'/queues/rx-0/rps_cpus"'
fi
echo "Copying tools to benchmark nodes..."
ssh "$agent_user"@"$node_ip" 'mkdir -p '"$test_id"
scp ./scripts/utils/parse_perf_report_header.sh "$agent_user"@"$node_ip":
scp ./scripts/utils/perf_head_custom_report.sh "$agent_user"@"$node_ip":
ssh "$agent_user"@"$node_ip" 'chmod a+x parse_perf_report_header.sh'
ssh "$agent_user"@"$node_ip" 'chmod a+x perf_head_custom_report.sh'
ssh "$agent_user"@"$node_ip" 'sudo sh -c "echo 4000 > /proc/sys/kernel/perf_event_max_sample_rate"'
if [[ "$node_ip" != "$p_node_ip" ]]; then
  ssh "$agent_user"@"$p_node_ip" 'mkdir -p '"$test_id"
  scp ./scripts/utils/parse_perf_report_header.sh "$agent_user"@"$p_node_ip":
  scp ./scripts/utils/perf_head_custom_report.sh "$agent_user"@"$p_node_ip":
  ssh "$agent_user"@"$p_node_ip" 'chmod a+x parse_perf_report_header.sh'
  ssh "$agent_user"@"$p_node_ip" 'chmod a+x perf_head_custom_report.sh'
  ssh "$agent_user"@"$p_node_ip" 'sudo sh -c "echo 4000 > /proc/sys/kernel/perf_event_max_sample_rate"'
fi
echo ""

test_no=0

echo ""
echo "--- Benchmarking with ChainScope ---"
echo ""

((test_no++))
echo "[Test $test_no] sampling_rate=1, server-only (-> server ->)... event based with span" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" false false
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling1.serveronly.server.data
  data_file_agent="$test_id"/perf.sampling1.serveronly.agent.data
  data_file_ctrl="$test_id"/perf.sampling1.serveronly.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=1, with proxy (-> proxy -> server -> proxy ->)... event based with span" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests 1 $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 1 false false
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling1.withproxy.server.data
  data_file_proxy="$test_id"/perf.sampling1.withproxy.proxy.data
  data_file_agent="$test_id"/perf.sampling1.withproxy.agent.data
  data_file_ctrl="$test_id"/perf.sampling1.withproxy.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.01, server-only (-> server ->)... event based with span" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests 1 $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 100 false false
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.01.serveronly.server.data
  data_file_agent="$test_id"/perf.sampling0.01.serveronly.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.01.serveronly.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.01, with proxy (-> proxy -> server -> proxy ->) event based with span..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests 1 $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 100 false false
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.01.withproxy.server.data
  data_file_proxy="$test_id"/perf.sampling0.01.withproxy.proxy.data
  data_file_agent="$test_id"/perf.sampling0.01.withproxy.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.01.withproxy.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"


echo ""
echo "--- Benchmarking with plain ChainScope (no sampling) ---"
echo ""

# Deploy the test app once as persistent connections are not a concern for the next tests
for (( i="$test_no"+1; i<"$test_no"+6; i++ )); do
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
  deploy_chain_scope true false 0 "" "$(get_entrypoint_ips)" 1 false false
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.nosampling.serveronly.server.data
  data_file_agent="$test_id"/perf.nosampling.serveronly.agent.data
  data_file_ctrl="$test_id"/perf.nosampling.serveronly.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] no sampling, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $no_sampling_no $((test_no-1)))
  deploy_chain_scope "$need_build" false 0 "" "$(get_entrypoint_ips)" 1 false false
  ./scripts/utils/add_unmonitored_ip.sh
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.nosampling.withproxy.server.data
  data_file_proxy="$test_id"/perf.nosampling.withproxy.proxy.data
  data_file_agent="$test_id"/perf.nosampling.withproxy.agent.data
  data_file_ctrl="$test_id"/perf.nosampling.withproxy.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  ssh "$agent_user"@"$node_ip" 'cat '"$data_file_agent" | tee -a "$output_file"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Benchmarking with IDLE hooks ---"
echo ""

((test_no++))
idle_no=$test_no
echo "[Test $test_no] IDLE programs, server-only (-> server ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 1 "" "" 1 false false
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.idle.serveronly.server.data
  data_file_agent="$test_id"/perf.idle.serveronly.agent.data
  data_file_ctrl="$test_id"/perf.idle.serveronly.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] IDLE programs, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  if [[ $(no_previous_tests $idle_no $((test_no-1))) == true ]]; then
    delete_chain_scope
    deploy_chain_scope true true 1 "" "" 1 false false
    # shellcheck disable=SC2046
    ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  fi
  data_file_server="$test_id"/perf.idle.withproxy.server.data
  data_file_proxy="$test_id"/perf.idle.withproxy.proxy.data
  data_file_agent="$test_id"/perf.idle.withproxy.agent.data
  data_file_ctrl="$test_id"/perf.idle.withproxy.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Benchmarking plain application ---"
echo ""

((test_no++))
echo "[Test $test_no] plain app (no hooks), server-only (-> server ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  data_file_server="$test_id"/perf.plain.serveronly.server.data
  benchmark_routine "$data_file_server" "" "" "" "$node_ip" 30000 ""
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] plain app (no hooks), with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  data_file_server="$test_id"/perf.plain.withproxy.server.data
  data_file_proxy="$test_id"/perf.plain.withproxy.proxy.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "" "" "$p_node_ip" 30001 ""
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"


echo ""
echo "--- Benchmarking span based ChainScope"
echo ""

((test_no++))
first_span_no=$test_no
echo "[Test $test_no] sampling_rate=1, server only (-> server ->) span based..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1 true false
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling1.serveronly.spanbased.server.data
  data_file_agent="$test_id"/perf.sampling1.serveronly.spanbased.agent.data
  data_file_ctrl="$test_id"/perf.sampling1.serveronly.spanbased.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=1, with proxy (-> proxy -> server -> proxy ->) span based..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_span_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 1 true false
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling1.withproxy.spanbased.server.data
  data_file_proxy="$test_id"/perf.sampling1.withproxy.spanbased.proxy.data
  data_file_agent="$test_id"/perf.sampling1.withproxy.spanbased.agent.data
  data_file_ctrl="$test_id"/perf.sampling1.withproxy.spanbased.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.10, server-only (-> server ->) span based..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_span_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 10 true false
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.10.serveronly.spanbased.server.data
  data_file_agent="$test_id"/perf.sampling0.10.serveronly.spanbased.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.10.serveronly.spanbased.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.10, with proxy (-> proxy -> server -> proxy ->) span based..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_span_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 10 true false
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.10.withproxy.spanbased.server.data
  data_file_proxy="$test_id"/perf.sampling0.10.withproxy.spanbased.proxy.data
  data_file_agent="$test_id"/perf.sampling0.10.withproxy.spanbased.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.10.withproxy.spanbased.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"


((test_no++))
echo "[Test $test_no] sampling_rate=0.01, server-only (-> server ->) span based..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_span_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 100 true false
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.01.serveronly.spanbased.server.data
  data_file_agent="$test_id"/perf.sampling0.01.serveronly.spanbased.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.01.serveronly.spanbased.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.01, with proxy (-> proxy -> server -> proxy ->) span based..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_span_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 100 true false
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.01.withproxy.spanbased.server.data
  data_file_proxy="$test_id"/perf.sampling0.01.withproxy.spanbased.proxy.data
  data_file_agent="$test_id"/perf.sampling0.01.withproxy.spanbased.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.01.withproxy.spanbased.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Benchmarking event based with log ChainScope"
echo ""

((test_no++))
first_event_no=$test_no
echo "[Test $test_no] sampling_rate=1, server-only (-> server ->) event based with log..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1 false true
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  #read -p "Press Enter to continue..."
  data_file_server="$test_id"/perf.sampling1.serveronly.eventbasedwithlog.server.data
  data_file_agent="$test_id"/perf.sampling1.serveronly.eventbasedwithlog.agent.data
  data_file_ctrl="$test_id"/perf.sampling1.serveronly.eventbasedwithlog.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=1, with proxy (-> proxy -> server -> proxy ->) event based with log..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_event_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 1 false true
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  #read -p "Press Enter to continue..."
  data_file_server="$test_id"/perf.sampling1.withproxy.eventbasedwithlog.server.data
  data_file_proxy="$test_id"/perf.sampling1.withproxy.eventbasedwithlog.proxy.data
  data_file_agent="$test_id"/perf.sampling1.withproxy.eventbasedwithlog.agent.data
  data_file_ctrl="$test_id"/perf.sampling1.withproxy.eventbasedwithlog.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.10, server-only (-> server ->) event based with log..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_event_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 10 false true
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.10.serveronly.eventbasedwithlog.server.data
  data_file_agent="$test_id"/perf.sampling0.10.serveronly.eventbasedwithlog.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.10.serveronly.eventbasedwithlog.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.10, with proxy (-> proxy -> server -> proxy ->) event based with log..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_event_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 10 false true
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.10.withproxy.eventbasedwithlog.server.data
  data_file_proxy="$test_id"/perf.sampling0.10.withproxy.eventbasedwithlog.proxy.data
  data_file_agent="$test_id"/perf.sampling0.10.withproxy.eventbasedwithlog.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.10.withproxy.eventbasedwithlog.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.01, server-only (-> server ->) event based with log..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_event_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 100 false true
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.01.serveronly.eventbasedwithlog.server.data
  data_file_agent="$test_id"/perf.sampling0.01.serveronly.eventbasedwithlog.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.01.serveronly.eventbasedwithlog.ctrl.data
  benchmark_routine "$data_file_server" "" "$data_file_agent" "$data_file_ctrl" "$node_ip" 30000 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] sampling_rate=0.01, with proxy (-> proxy -> server -> proxy ->) event based with log..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  need_build=$(no_previous_tests $first_event_no $((test_no-1)))
  deploy_chain_scope "$need_build" true 0 "" "$(get_entrypoint_ips)" 100 false true
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application
  # shellcheck disable=SC2046
  ./scripts/utils/wait_for_monitored_services.sh ${test_app_base}-test $(get_test_services)
  data_file_server="$test_id"/perf.sampling0.01.withproxy.eventbasedwithlog.server.data
  data_file_proxy="$test_id"/perf.sampling0.01.withproxy.eventbasedwithlog.proxy.data
  data_file_agent="$test_id"/perf.sampling0.01.withproxy.eventbasedwithlog.agent.data
  data_file_ctrl="$test_id"/perf.sampling0.01.withproxy.eventbasedwithlog.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "chainscope"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[ChainScope Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[ChainScope Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[ChainScope Controller]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_ctrl_node_ip)"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Benchmarking beyla on nginx ---"
echo ""

((test_no++))
echo "[Test $test_no] beyla sampling_rate=1, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_test_application
  deploy_beyla 1 # 100%
  data_file_server="$test_id"/perf.beyla.sampling1.withproxy.server.data
  data_file_proxy="$test_id"/perf.beyla.sampling1.withproxy.proxy.data
  data_file_agent="$test_id"/perf.beyla.sampling1.withproxy.agent.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "" "$p_node_ip" 30001 "beyla"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[Beyla Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[Beyla Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  delete_beyla
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] beyla sampling_rate=0.1, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_test_application
  deploy_beyla 0.1 # 10%
  data_file_server="$test_id"/perf.beyla.sampling0.1.withproxy.server.data
  data_file_proxy="$test_id"/perf.beyla.sampling0.1.withproxy.proxy.data
  data_file_agent="$test_id"/perf.beyla.sampling0.1.withproxy.agent.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "" "$p_node_ip" 30001 "beyla"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[Beyla Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[Beyla Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  delete_beyla
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"


((test_no++))
echo "[Test $test_no] beyla sampling_rate=0.01, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application
  delete_beyla
  deploy_beyla 0.01 # 1%
  data_file_server="$test_id"/perf.beyla.sampling0.01.withproxy.server.data
  data_file_proxy="$test_id"/perf.beyla.sampling0.01.withproxy.proxy.data
  data_file_agent="$test_id"/perf.beyla.sampling0.01.withproxy.agent.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "" "$p_node_ip" 30001 "beyla"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[Beyla Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[Beyla Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  delete_beyla
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Benchmarking application with opentelemetry auto-instrumentation"
echo ""

((test_no++))
echo "[Test $test_no] opentelemetry app sampling_rate=1, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  delete_test_application
  deploy_test_otel_application 100 # different with chainscope sampling rate
  data_file_server="$test_id"/perf.otel.sampling1.withproxy.server.data
  data_file_proxy="$test_id"/perf.otel.sampling1.withproxy.proxy.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "" "" "$p_node_ip" 30001 "otel"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  delete_test_otel_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] opentelemetry app sampling_rate=0.1, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_test_otel_application 10
  data_file_server="$test_id"/perf.otel.sampling0.1.withproxy.server.data
  data_file_proxy="$test_id"/perf.otel.sampling0.1.withproxy.proxy.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "" "" "$p_node_ip" 30001 "otel"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  delete_test_otel_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

((test_no++))
echo "[Test $test_no] opentelemetry app sampling_rate=0.01, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_test_otel_application 1
  data_file_server="$test_id"/perf.otel.sampling0.01.withproxy.server.data
  data_file_proxy="$test_id"/perf.otel.sampling0.01.withproxy.proxy.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "" "" "$p_node_ip" 30001 "otel"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  delete_test_otel_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Benchmarking application with deepflow"
echo ""

((test_no++))
echo "[Test $test_no] deepflow, with proxy (-> proxy -> server -> proxy ->)..." | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application 
  deploy_deepflow
  data_file_server="$test_id"/perf.deepflow.withproxy.server.data
  data_file_proxy="$test_id"/perf.deepflow.withproxy.proxy.data
  data_file_agent="$test_id"/perf.deepflow.withproxy.agent.data
  data_file_ctrl="$test_id"/perf.deepflow.withproxy.ctrl.data
  benchmark_routine "$data_file_server" "$data_file_proxy" "$data_file_agent" "$data_file_ctrl" "$p_node_ip" 30001 "deepflow"
  echo "Test complete! Collecting results..."
  echo "[Web server]:" | tee -a "$output_file"
  collect_results "$data_file_server" "$output_file" "$node_ip"
  echo "[Proxy]:" | tee -a "$output_file"
  collect_results "$data_file_proxy" "$output_file" "$p_node_ip"
  echo "[Deepflow Agent$( [[ "$node_ip" != "$p_node_ip" ]] && echo " - Web server" )]:" | tee -a "$output_file"
  collect_user_results "$data_file_agent" "$output_file" "$node_ip"
  if [[ "$node_ip" != "$p_node_ip" ]]; then
    echo "[Deepflow Agent - Proxy]:" | tee -a "$output_file"
    collect_user_results "$data_file_agent" "$output_file" "$p_node_ip"
  fi
  echo "[Deepflow Server]:" | tee -a "$output_file"
  collect_user_results "$data_file_ctrl" "$output_file" "$(get_deepflow_server_node_ip)"
  delete_deepflow
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
echo "" | tee -a "$output_file"

echo ""
echo "--- Clean ---"
echo ""
echo "All benchmarking complete, cleaning..."
echo -n "${FGRY}"
./scripts/clean.sh -t "$tag" -T
delete_test_application &>/dev/null
delete_chain_scope &>/dev/null
delete_beyla &>/dev/null
delete_test_otel_application &>/dev/null
delete_deepflow &>/dev/null
kubectl label nodes "$agent_node_name" benchmark-web-
kubectl label nodes "$proxy_node_name" benchmark-proxy-
echo -n "${FRST}"
echo ""

echo "Done. Results saved at $output_file."
