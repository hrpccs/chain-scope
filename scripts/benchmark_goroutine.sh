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
DEFAULT_TEST_APP=hotel
interactive=false

build_ctrl=true
tag=bench
tests=(false false false false false false false false false false false false false false false false false false false false false false false false false false false)
perf_duration=$DEFAULT_PERF_DURATION
agent_node_name=$DEFAULT_AGENT_NODE
proxy_node_name=
agent_user=$DEFAULT_AGENT_USER
output_dir=$DEFAULT_OUTPUT_DIR
test_app=hotel
test_app_base=hotel
nic_name=

# set colors
FRED=$(tput setaf 1)
FGRN=$(tput setaf 2)
FYLW=$(tput setaf 3)
FGRY=$(tput setaf 238)
FRST=$(tput sgr0)

print_usage() {
  echo "Evaluates ChainScope performance on gRPC demo in terms of Accuracy and CPU overhead under different configurations."
  echo "Uses an deathstar hotel demo as a test app."
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
  echo "   1:   plain app baseline"
  echo "   2:   userspace goroutine"
  echo "   3:   in-kernel goroutine"
}

while getopts ':t:ha:d:n:p:u:o:i:I' opt; do
  case "${opt}" in
    t) TESTS="${OPTARG}" ;;
    d) perf_duration=${OPTARG} ;;
    n) agent_node_name=${OPTARG} ;;
    p) proxy_node_name=${OPTARG} ;;
    u) agent_user=${OPTARG} ;;
    o) output_dir=${DEFAULT_OUTPUT_DIR} ;;
    a) test_app=${OPTARG} ;;
    i) nic_name=${OPTARG} ;;
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

# read tests to run
read -r -a tests_input <<< "$(echo "$TESTS" | tr ',' ' ')"
if [ ${#tests_input[@]} -eq 0 ]; then
  tests=(true true true true true true true true true true true true true true true true true true true true true true true true true true true)
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
  local grpc_test_case=$9

  local grpc_beyla_injection="True"
  local goroutines_inkernel_support="True"
  local test_goroutine="True"

  case "$grpc_test_case" in
    4)
      goroutines_inkernel_support="False"
      ;;
  esac


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
    if ! ./scripts/build_push_image.sh -t "$tag" -a -T "$grpc_test_case"\
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
    sed '/GRPC_BEYLA_INJECTION/{n; s/value:.*/value: "'"${grpc_beyla_injection}"'"/}' - | \
    sed '/GOROUTINES_INKERNEL_SUPPORT/{n; s/value:.*/value: "'"${goroutines_inkernel_support}"'"/}' - | \
    sed '/TEST_GOROUTINE/{n; s/value:.*/value: "'"${test_goroutine}"'"/}' - | \
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
}

deploy_beyla() {
  local sampling_rate=$1
  
  echo "Deploying Beyla..."
  sed 's/BEYLASAMPLINGRATE/'${sampling_rate}'/g' samples/hotel-test/beyla.yaml | \
    kubectl apply -f - &>/dev/null
  if ! kubectl -n beyla wait pod --all --for=condition=Ready; then
    echo -n "${FRST}"
    echo "Beyla did not start correctly, aborting."
    exit 1
  fi
  
  echo "wait for 10 seconds for Beyla to start..."
  sleep 10
  echo -n "${FRST}"

}

delete_beyla() {
  echo "Deleting Beyla..."
  kubectl delete -f samples/hotel-test/beyla.yaml
  kubectl -n beyla wait pods --for=delete &>/dev/null
}

deploy_deepflow() {
  helm repo add deepflow https://deepflowio.github.io/deepflow
  helm repo update deepflow # use `helm repo update` when helm < 3.7.0
  helm install deepflow -n deepflow deepflow/deepflow --version 6.6.018 --create-namespace -f samples/hotel-test/deepflow-values-custom.yaml
  # Wait for all DeepFlow pods to be ready
  echo "Waiting for DeepFlow pods to be ready..."
  kubectl wait --for=condition=ready pod --all -n deepflow --timeout=300s

  Version=v6.6
  if ! command -v deepflow-ctl &> /dev/null; then
    curl -o /usr/bin/deepflow-ctl \
      "https://deepflow-ce.oss-cn-beijing.aliyuncs.com/bin/ctl/$Version/linux/$(arch | sed 's|x86_64|amd64|' | sed 's|aarch64|arm64|')/deepflow-ctl"
    chmod a+x /usr/bin/deepflow-ctl
  else
    echo "deepflow-ctl already exists, skipping download"
  fi

  NODE_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[0].address}")
  deepflow-ctl --ip $NODE_IP agent-group list default
  GROUP_ID=$(deepflow-ctl --ip $NODE_IP agent-group list default | awk '/default/ {print $2}')
  deepflow-ctl --ip $NODE_IP agent-group-config create $GROUP_ID -f samples/hotel-test/deepflow-agent-config.yaml 
  # deepflow-ctl --ip $NODE_IP agent-group-config update $GROUP_ID -f agent-config.yaml 

  # check the output of ssh "agent_user"@"$p_node_ip" "sudo cat /proc/$(pgrep frontend)/maps | grep uprobe"
  local n=100
  while [ $n -gt 0 ]; do
    output=$(ssh "$agent_user"@"$p_node_ip" 'sudo cat /proc/$(pgrep frontend)/maps | grep uprobe')
    #if output contains "uprobe" then break
    if [[ $output =~ "uprobe" ]]; then
      break
    fi
    n=$((n-1))
    sleep 10 
  done
  # wait for all agents to be ready
  # echo "Waiting 450s for DeepFlow agents ebpf programs to be ready..."
  # sleep 450

  echo "DeepFlow is up and running!"
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
  clickhouse_node_ip=${clickhouse_node_ip:-$(get_deepflow_clickhouse_node_ip)}
  mysql_node_ip=${mysql_node_ip:-$(get_deepflow_mysql_node_ip)}
  helm uninstall deepflow -n deepflow
  kubectl wait --for=delete pod --all -n deepflow --timeout=300s
  ssh "$agent_user"@"$clickhouse_node_ip" 'sudo rm -rf /opt/deepflow-clickhouse/'
  ssh "$agent_user"@"$mysql_node_ip" 'sudo rm -rf /opt/deepflow-mysql/'
}

deploy_test_application() {
  local sampling_enabled=$1
  local sampling_rate=$2

  echo "Deploying the test application ($test_app) with sampling: $sampling_enabled, rate: $sampling_rate"
  echo -n "${FGRY}"

  local notracing_with_symbol_image="chainscope1234/hotelreservation:notracing-with-symbol"
  local tracing_sampling_image="deathstarbench/hotel-reservation:latest"

  if [ "$sampling_enabled" = true ]; then
    local target_image=tracing_sampling_image
    local sample_ratio="${sampling_rate:-1}"
  else
    local target_image=notracing_with_symbol_image
    local sample_ratio="0"
  fi

  local yaml_files=(
    "samples/DeathStarBench/hotelReservation/kubernetes/frontend/frontend-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes/profile/profile-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes/rate/rate-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes/reccomend/recommendation-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes/reserve/reservation-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes/search/search-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes/user/user-deployment.yaml"
  )

  for yaml_file in "${yaml_files[@]}"; do
  #   sed -i 's!image: chainscope1234/hotelreservation:.*!image: chainscope1234/hotelreservation:notracing-with-symbol!g' \
  # samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml
    sed -i "s!image: $base_image:.*!image: $target_image!g" "$yaml_file"
    # sed -i "s|image: $base_image:$notracing_image_tag|image: $target_image|g" "$yaml_file"
    # sed -i "s/image: */image: chainscope1234/hotelreservation:notracing-with-symbol/g" samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml

    sed '/JAEGER_SAMPLE_RATIO/{n; s/value:.*/value: "'"${sample_ratio}"'"/}' -i "$yaml_file"
    # sed '/JAEGER_SAMPLE_RATIO/{n; s/value:.*/value: "'0.5'"/}' -i samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml
    # 替换采样
  done

  tmpdir=$(mktemp -d)

  find samples/DeathStarBench/hotelReservation/kubernetes -name '*.yaml' -o -name '*.yml' | while read file; do
    sed "s|$DEFAULT_REGISTRY|$IMAGE_REGISTRY|g" "$file" > "$tmpdir/$(basename "$file")"
  done

  kubectl apply -n hotel-test -Rf "$tmpdir"
  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
  rm -r "$tmpdir"

  kubectl wait --for=condition=Ready pods --all -n hotel-test --timeout=300s
}

delete_test_application() {
  echo "Deleting the test application..."
  kubectl delete -n hotel-test -Rf samples/DeathStarBench/hotelReservation/kubernetes/
  kubectl -n ${test_app_base}-test wait pods --all --for=delete &>/dev/null
}

get_test_services() {
  kubectl -n ${test_app_base}-test get services -o jsonpath="{.items[*].metadata.name}"
}

get_ctrl_node_ip() {
  kubectl -n chain-scope get pod -l name=chain-scope-controller -o jsonpath='{.items[0].spec.nodeName}' \
    | xargs -I{} kubectl get node {} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}'
}

benchmark_routine() { #parameters srv proxy file ip port
  local data_file_frontend=$1
  local data_file_recommendation=$2
  local data_file_agent=$3
  local data_file_ctrl=$4
  local ip=$5
  local port=$6
  local concurrent_users=$7

  local service_path=""

  echo "Warming up the service..."
#   ab -k -r -q -d -c $concurrent_users -t 30s -n 9999999 http://$ip:$port/$service_path &>/dev/null
  fortio load -c $concurrent_users -keepalive -t 30s -quiet -qps 0 http://$ip:$port/$service_path 2>&1 &>/dev/null
  sleep 5

  # measure throughput
  echo "Benchmarking throughput..."
#   ab -k -r -q -d -c $concurrent_users -t 60s -n 9999999  http://$ip:$port/$service_path | tee -a "$output_file"
  fortio load -c $concurrent_users -keepalive -t $((perf_duration+30))s -quiet -qps 0 http://$ip:$port/$service_path 2>&1 | tee -a "$output_file"

  # measure cpu overhead
  echo "Benchmarking cpu overhead..."
  #curl http://"$node_ip":"$port"/test
  #siege -b -c 48 -t 100s http://"$node_ip":"$port"/test &>/dev/null &
  fortio load -c $concurrent_users -keepalive -t $((perf_duration+30))s -quiet -qps 20000 http://$ip:$port/$service_path 2>&1 &>/dev/null &
#   ab -k -r -q -d -c $concurrent_users -t $((perf_duration+10))s -n 9999999 http://$ip:$port/$service_path &>/dev/null &
  #wrk -t32 -c32 -d$((perf_duration+30))s http://"$ip":"$port"/test &>/dev/null &
  sleep 10

  ssh "$agent_user"@"$p_node_ip" 'sudo bpftool prog list > '"$data_file_frontend"'.prog'
  ssh "$agent_user"@"$p_node_ip" 'sudo perf record -F 1000 -o '"$data_file_frontend"' --call-graph fp -e cpu-cycles -p $(pgrep frontend) sleep '"$perf_duration" &
  ssh "$agent_user"@"$p_node_ip" 'sudo perf stat -o '"$data_file_agent"' -a -p $(pgrep frontend) sleep '"$perf_duration" &

  wait
}

collect_results() {
  local data_file=$1
  local output_file=$2
  local target_ip=$3

  ssh "$agent_user"@"$target_ip" 'sudo ./perf_head_custom_report.sh -i '"$data_file" | tee -a "$output_file"
  ssh "$agent_user"@"$target_ip" 'sudo bpftool map dump name hooks_bp.bss | grep metric' | tee -a "$output_file"
}

collect_user_results() {
  local data_file=$1
  local output_file=$2
  local target_ip=$3

  ssh "$agent_user"@"$target_ip" 'cat '"$data_file" | tee -a "$output_file"
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

nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
for node in $nodes; do
  kubectl label node "$node" node-type-
done
kubectl label node "$agent_node_name" node-type=hotel-node2
kubectl label node "$proxy_node_name" node-type=hotel-node1

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

# delete any existing deployment
echo "Cleaning environment..."
./scripts/clean.sh -t "$tag" -d -T -j &>/dev/null

echo ""
test_id=$(date +%Y-%m-%d_%H%M%S)
echo "Experiment $test_id"
experiment_type=goroutine
latest="$output_dir"/"$experiment_type"/latest
output_dir="$output_dir"/"$experiment_type"/"$test_id"
output_file="$output_dir"/exec_cpu.out
mkdir -p "$output_dir"
rm -f "$latest"
ln -s "$test_id" "$latest"
touch "$output_file"
echo "Target recommendation node: $agent_node_name"
echo "Target frontend node: $proxy_node_name"
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

# if there is no fortio tool in the system, install it
# wget https://github.com/fortio/fortio/releases/download/v1.69.5/fortio_1.69.5_amd64.deb
# dpkg -i fortio_1.69.5_amd64.deb
if ! command -v fortio &> /dev/null; then
  echo "installing fortio..."
  
  wget https://github.com/fortio/fortio/releases/download/v1.69.5/fortio_1.69.5_amd64.deb
  
  sudo dpkg -i fortio_1.69.5_amd64.deb
  
  if command -v fortio &> /dev/null; then
    echo "install success"
  else
    echo "fortio install failed"
    exit 1
  fi
else
  fortio version
fi


test_no=0


echo ""
echo "--- Benchmarking with Baseline ---"
echo ""

((test_no++))
echo "[Test $test_no] plain app, concurrency=32" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
  # shellcheck disable=SC2046
  data_file_frontend="$test_id"/perf.plain.c32.frontend.data
  data_file_frontend_stat="$test_id"/perf.plain.c32.frontend.stat.data
  benchmark_routine "$data_file_frontend" "" "$data_file_frontend_stat" "" "$p_node_ip" 30555 32
  echo "Test complete! Collecting results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  collect_user_results "$data_file_frontend_stat" "$output_file" "$p_node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

echo ""
echo "--- Benchmarking with goroutine intra-service propagation  mechanism ---"
echo ""

((test_no++))
echo "[Test $test_no] userspace goroutine, concurrency=32" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1000 false true 4
  ./scripts/utils/set_sampling_rate.sh 1000
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
  # shellcheck disable=SC2046
  data_file_frontend="$test_id"/perf.ug.c32.frontend.data
  data_file_frontend_stat="$test_id"/perf.ug.c32.stat.data
  benchmark_routine "$data_file_frontend" "" "$data_file_frontend_stat" "" "$p_node_ip" 30555 32
  echo "Test complete! Collecting results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  collect_user_results "$data_file_frontend_stat" "$output_file" "$p_node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi


((test_no++))
echo "[Test $test_no] inkernel goroutine, concurrency=32" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1000 false true 5
  ./scripts/utils/set_sampling_rate.sh 1000
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  if [[ "$interactive" == true ]]; then read -n 1 -s -r -p "Press any key to continue..."; fi
  # shellcheck disable=SC2046
  data_file_frontend="$test_id"/perf.kg.c32.frontend.data
  data_file_frontend_stat="$test_id"/perf.kg.c32.stat.data
  benchmark_routine "$data_file_frontend" "" "$data_file_frontend_stat" "" "$p_node_ip" 30555 32
  echo "Test complete! Collecting results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  collect_user_results "$data_file_frontend_stat" "$output_file" "$p_node_ip"
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
echo -n "${FRST}"
echo ""

echo "Done. Results saved at $output_file."
