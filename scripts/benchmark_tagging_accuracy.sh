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
  echo "  24:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), beyla"
  echo "  25:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), application with opentelemetry auto-instrumentation"
  echo "  26:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), application with opentelemetry auto-instrumentation"
  echo "  27:   plain app, with proxy (-> proxy -> server -> proxy ->), deepflow"
}

while getopts ':t:ha:d:n:p:u:o:i:' opt; do
  case "${opt}" in
    t) TESTS="${OPTARG}" ;;
    d) perf_duration=${OPTARG} ;;
    n) agent_node_name=${OPTARG} ;;
    p) proxy_node_name=${OPTARG} ;;
    u) agent_user=${OPTARG} ;;
    o) output_dir=${DEFAULT_OUTPUT_DIR} ;;
    a) test_app=${OPTARG} ;;
    i) nic_name=${OPTARG} ;;
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
  local test_goroutine="False"

  case "$grpc_test_case" in
    2|3)
      grpc_beyla_injection="False"
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
  kubectl wait --for=condition=ready pod --all -n deepflow --timeout=500s

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

  # 定义基础镜像和采样镜像标签
  local base_image="chainscope1234/hotelreservation"
  local notracing_image_tag="notracing-with-symbol"
  local sampling_image_tag="with-symbol"

  # 判断是否启用采样
  if [ "$sampling_enabled" = true ]; then
    # 启用采样，使用带采样支持的镜像
    local target_image="$base_image:$sampling_image_tag"
    local sample_ratio="${sampling_rate:-1}"
  else
    # 禁用采样，使用不带采样的镜像
    local target_image="$base_image:$notracing_image_tag"
    local sample_ratio="0"
  fi

  # 遍历所有相关 deployment.yaml 文件并修改内容
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
    # 替换镜像地址
  #   sed -i 's!image: chainscope1234/hotelreservation:.*!image: chainscope1234/hotelreservation:notracing-with-symbol!g' \
  # samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml
    sed -i "s!image: $base_image:.*!image: $target_image!g" "$yaml_file"
    # sed -i "s|image: $base_image:$notracing_image_tag|image: $target_image|g" "$yaml_file"
    # sed -i "s/image: */image: chainscope1234/hotelreservation:notracing-with-symbol/g" samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml

    sed '/JAEGER_SAMPLE_RATIO/{n; s/value:.*/value: "'"${sample_ratio}"'"/}' -i "$yaml_file"
    # sed '/JAEGER_SAMPLE_RATIO/{n; s/value:.*/value: "'0.5'"/}' -i samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml
    # 替换采样
  done

  # 应用所有修改后的 YAML 文件
  kubectl apply -n hotel-test -Rf samples/DeathStarBench/hotelReservation/kubernetes/
  kubectl wait --for=condition=Ready pods --all -n hotel-test --timeout=300s

  sleep 30
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
  local ip=$1
  local port=$2
  local concurrent_users=$3

  local service_path="recommendations?require=price&lat=37.883&lon=-122.252"
  echo "Benchmarking.."
  # do not use -k option
  ab  -r -q -d -c $concurrent_users -t 999s -n 1000000 http://$ip:$port/$service_path | tee -a "$output_file"
  sleep 10

  wait
}

collect_results() {
  local target_ip=$1
  ssh "$agent_user"@"$target_ip" 'sudo bpftool map dump name hooks_bp.bss | grep metric' | tee -a "$output_file"
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
experiment_type="${test_app}"
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

test_no=0

echo ""
echo "--- Benchmarking with grpc tagging : application tagging ---"
echo ""

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=1, concurrency=10" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1 false true 1
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 10
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=1, concurrency=100" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 1
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 100
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=1, concurrency=500" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 1
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 500
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=1, concurrency=1000" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 1
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 1000
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.1, concurrency=10" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 1
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 10
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.1, concurrency=100" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 1
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 100
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.1, concurrency=500" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 1
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 500
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.1, concurrency=1000" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 1
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 1000
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.01, concurrency=10" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 1
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 10
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.01, concurrency=100" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 1
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 100
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.01, concurrency=500" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 1
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 500
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] application injection,sampling_rate=0.01, concurrency=1000" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 1
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 1000
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi


echo ""
echo "--- Benchmarking with grpc tagging : ip tagging ---"
echo ""


((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=1, concurrency=10" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1 false true 2
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 10
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=1, concurrency=100" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 2
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 100
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=1, concurrency=500" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 2
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 500
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=1, concurrency=1000" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 2
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 1000
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.1, concurrency=10" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 2
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  ./scripts/utils/set_sampling_rate.sh 10
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 10
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.1, concurrency=100" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 2
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  ./scripts/utils/set_sampling_rate.sh 10
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 100
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.1, concurrency=500" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 2
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  ./scripts/utils/set_sampling_rate.sh 10
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 500
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.1, concurrency=1000" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 10 false true 2
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  ./scripts/utils/set_sampling_rate.sh 10
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 1000
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi


((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.01, concurrency=10" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 2
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  ./scripts/utils/set_sampling_rate.sh 100
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 10
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.01, concurrency=100" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 2
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  deploy_test_application false 0
  ./scripts/utils/set_sampling_rate.sh 100
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 100
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.01, concurrency=500" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 2
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  ./scripts/utils/set_sampling_rate.sh 100
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 500
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi
((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.01, concurrency=1000" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  delete_chain_scope
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 100 false true 2
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  ./scripts/utils/set_sampling_rate.sh 100
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_routine "$p_node_ip" 30555 1000
  echo "Test complete! Collecting results..."
  echo "[pnode]:" | tee -a "$output_file"
  collect_results "$p_node_ip"
  echo "[node]:" | tee -a "$output_file"
  collect_results "$node_ip"
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
