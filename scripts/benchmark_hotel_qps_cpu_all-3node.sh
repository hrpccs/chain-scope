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
tests=(false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false)
perf_duration=$DEFAULT_PERF_DURATION
agent_node_name=$DEFAULT_AGENT_NODE
proxy_node_name=
b_agent_node_name=
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
  echo "  1:    sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), beyla"
  echo "  2:    sampling_rate = 0.1, with proxy (-> proxy -> server -> proxy ->), beyla"
  echo "  3:    sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), beyla"
  echo "  4:    no sampling, with proxy (-> proxy -> server -> proxy ->), deepflow"
  echo "  5:    plain app (no hooks), with proxy (-> proxy -> server -> proxy ->)"
  echo "  6:    sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), jaeger"
  echo "  7:    sampling_rate = 0.1, with proxy (-> proxy -> server -> proxy ->), jaeger"
  echo "  8:    sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), jaeger"
  echo "  9:    sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), app injection"
  echo "  10:   sampling_rate = 0.1, with proxy (-> proxy -> server -> proxy ->), app injection"
  echo "  11:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), app injection"
  echo "  12:   sampling_rate = 1, with proxy (-> proxy -> server -> proxy ->), ip tagging"
  echo "  13:   sampling_rate = 0.1, with proxy (-> proxy -> server -> proxy ->), ip tagging"
  echo "  14:   sampling_rate = 0.01, with proxy (-> proxy -> server -> proxy ->), ip tagging"
}

while getopts ':t:ha:d:n:p:u:o:i:b:' opt; do
  case "${opt}" in
    t) TESTS="${OPTARG}" ;;
    d) perf_duration=${OPTARG} ;;
    n) agent_node_name=${OPTARG} ;;
    p) proxy_node_name=${OPTARG} ;;
    b) b_agent_node_name=${OPTARG} ;;
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
  # tests=(false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false false)
  tests=(true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true true)
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
  echo "wait for 20 seconds for chainscope to start..."
  sleep 20
  echo -n "${FRST}"
}

deploy_beyla() {
  local sampling_rate=$1
  
  echo "Deploying Beyla..."
  sed 's/BEYLASAMPLINGRATE/'${sampling_rate}'/g' samples/hotel-test/beyla.yaml | \
    kubectl apply -f - &>/dev/null
  if ! kubectl -n beyla wait pod --all --for=condition=Ready --timeout=300s; then
    echo -n "${FRST}"
    echo "Beyla did not start correctly, aborting."
    exit 1
  fi
  
  echo "wait for 30 seconds for Beyla to start..."
  sleep 30
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
  http_proxy= https_proxy= deepflow-ctl --ip $NODE_IP agent-group list default
  GROUP_ID=$(http_proxy= https_proxy= deepflow-ctl --ip $NODE_IP agent-group list default | awk '/default/ {print $2}')
  http_proxy= https_proxy= deepflow-ctl --ip $NODE_IP agent-group-config create $GROUP_ID -f samples/hotel-test/deepflow-agent-config.yaml
  # deepflow-ctl --ip $NODE_IP agent-group-config update $GROUP_ID -f agent-config.yaml
  # frontend_nodes=("10.10.1.79" "10.10.0.128" "10.10.1.35" "10.10.3.152" "10.10.3.111" )
  # profile_nodes=("10.10.1.79" "10.10.0.128" "10.10.1.35" "10.10.3.152" "10.10.3.111" )
  frontend_nodes=("10.10.1.79" "10.10.0.128" "10.10.1.35"  )
  profile_nodes=("10.10.1.79" "10.10.0.128" "10.10.1.35"  )
  # profile_nodes=("10.10.3.152" "10.10.1.183" "10.10.3.176")
  recommendation_nodes=("10.10.3.176" "10.10.1.183" "10.10.2.91")
  all_ready=false
  local n=100
  while [ $n -gt 0 ]; do
    all_ready=true  # 假设所有节点都已就绪

    # 检查每个节点
    for node in "${frontend_nodes[@]}"; do
        output=$(ssh "$agent_user"@"$node" 'sudo cat /proc/$(pgrep frontend)/maps | grep uprobe' 2>/dev/null)
        
        # 如果当前节点未部署 uprobe，标记为未就绪
        if [[ ! $output =~ "uprobe" ]]; then
            echo "节点 $node 尚未部署 uprobe"
            all_ready=false
            break  # 跳过剩余节点检查
        fi
    done

    for node in "${profile_nodes[@]}"; do
        output=$(ssh "$agent_user"@"$node" 'sudo cat /proc/$(pgrep profile)/maps | grep uprobe' 2>/dev/null)
        
        # 如果当前节点未部署 uprobe，标记为未就绪
        if [[ ! $output =~ "uprobe" ]]; then
            echo "节点 $node 尚未部署 uprobe"
            all_ready=false
            break  # 跳过剩余节点检查
        fi
    done

    for node in "${recommendation_nodes[@]}"; do
        output=$(ssh "$agent_user"@"$node" 'sudo cat /proc/$(pgrep recommendation)/maps | grep uprobe' 2>/dev/null)
        
        # 如果当前节点未部署 uprobe，标记为未就绪
        if [[ ! $output =~ "uprobe" ]]; then
            echo "节点 $node 尚未部署 uprobe"
            all_ready=false
            break  # 跳过剩余节点检查
        fi
    done
    # 如果所有节点都就绪，退出循环
    if [ "$all_ready" = true ]; then
        echo "所有节点均已部署 uprobe，继续执行..."
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

deploy_otel_auto_go() {
  local sampling_rate=$1
  ./samples/hotel-test/odigos install
  kubectl wait --for=condition=ready pod --all -n odigos-system --timeout=300s

  ./samples/hotel-test/odigos sources create frontend-source --workload-kind=Deployment --workload-name=frontend --workload-namespace=hotel-test -n hotel-test
  ./samples/hotel-test/odigos sources create recommendation-source --workload-kind=Deployment --workload-name=recommendation --workload-namespace=hotel-test -n hotel-test
  ./samples/hotel-test/odigos sources create profile-source --workload-kind=Deployment --workload-name=profile --workload-namespace=hotel-test -n hotel-test
  kubectl apply -f samples/hotel-test/otel-auto-jaeger.yaml
  sed 's/OTELAUTOSAMPLINGRATE/'${sampling_rate}'/g' samples/hotel-test/otel-auto-sampling-rate.yaml | \
    kubectl apply -f - &>/dev/null

  kubectl wait --for=condition=ready pod --all -n odigos-system --timeout=300s
  echo "Waiting 120s for otel auto ebpf programs to be ready..."
  sleep 120
}

delete_otel_auto_go() {
  kubectl delete -f samples/hotel-test/otel-auto-jaeger.yaml
  ./samples/hotel-test/odigos uninstall --yes
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
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/frontend/frontend-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/geo/geo-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/profile/profile-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/rate/rate-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/reccomend/recommendation-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/reserve/reservation-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/search/search-deployment.yaml"
    "samples/DeathStarBench/hotelReservation/kubernetes-3node/user/user-deployment.yaml"
  )

  for yaml_file in "${yaml_files[@]}"; do
    # 替换镜像地址
  # samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml
    sed -i "s!image: $base_image:.*!image: $target_image!g" "$yaml_file"
    # sed -i "s|image: $base_image:$notracing_image_tag|image: $target_image|g" "$yaml_file"

    sed '/JAEGER_SAMPLE_RATIO/{n; s/value:.*/value: "'"${sample_ratio}"'"/}' -i "$yaml_file"
    # sed '/JAEGER_SAMPLE_RATIO/{n; s/value:.*/value: "'0.5'"/}' -i samples/DeathStarBench/hotelReservation/kubernetes/geo/geo-deployment.yaml
    # 替换采样
  done

  tmpdir=$(mktemp -d)

  find samples/DeathStarBench/hotelReservation/kubernetes-3node/ -name '*.yaml' -o -name '*.yml' | while read file; do
    sed "s|$DEFAULT_REGISTRY|$IMAGE_REGISTRY|g" "$file" > "$tmpdir/$(basename "$file")"
  done

  kubectl apply -n hotel-test -Rf "$tmpdir"
  rm -r "$tmpdir"

  kubectl wait --for=condition=Ready pods --all -n hotel-test --timeout=300s

  sleep 5
}

delete_test_application() {
  echo "Deleting the test application..."
  kubectl delete -n hotel-test -Rf samples/DeathStarBench/hotelReservation/kubernetes-3node/
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

benchmark_throughput_median() {
  local ip=$1
  local port=$2
  local n=$3

  port=$(kubectl get svc frontend -n hotel-test -o json | jq -r '.spec.ports[] | select(.name=="5000") | .nodePort')
  n=1
  # A temporary directory to store output files for all runs
  local run_dir
  run_dir=$(mktemp -d)

  # A file to store the "RPS /path/to/output" for sorting
  local results_file
  results_file=$(mktemp)

  local successful_runs=0
  local service_path="recommendations?require=price&lat=37.883&lon=-122.252"

  for i in $(seq 1 "$n"); do
    #echo "[$i/$n] Benchmarking throughput..."
    # Store each run's output in its own file inside the temp directory
    local tmp_file="$run_dir/run_$i.txt"

    # Run the benchmark
    ab -k -r -q -d -c 1000 -t 60s -n 30000000 "http://$ip:$port/$service_path" > "$tmp_file"
    # fortio load -c 1000 -t 30s -quiet -k -qps 0 "http://$ip:$port/$service_path" 2>&1 &> "$tmp_file"

    # Skip failed or problematic runs
    if grep -q "WARNING" "$tmp_file"; then
      #echo "Run #$i had warnings, skipping."
      continue
    fi

    local rps
    rps=$(grep "Requests per second" "$tmp_file" | awk '{print $4}')
    # rps=$(grep "All done" "$tmp_file" | awk '{print $11}')

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

benchmark_accuracy_routine() { #parameters srv proxy file ip port
  local ip=$1
  local port=$2
  local concurrent_users=$3

  local service_path="recommendations?require=price&lat=37.883&lon=-122.252"
  echo "Benchmarking accuracy for $concurrent_users concurrent users.."
  # do not use -k option
  port=$(kubectl get svc frontend -n hotel-test -o json | jq -r '.spec.ports[] | select(.name=="5000") | .nodePort')
  ab -r -q -d -c $concurrent_users -t 999s -n 100000 http://$ip:$port/$service_path | tee -a "$output_file"
  sleep 10

  wait
}

benchmark_bpf_cpu() {
  local data_file_frontend=$1
  local data_file_backend=$2
  local ip_frontend=$3
  local ip_backend=$4
  local port=$5


  #  初始化空数组
  frontend_nodes=()
  profile_nodes=()
  recommendation_nodes=()

  # 遍历所有节点
  while read -r node_name node_type; do
      case "$node_type" in
          "hotel-node1")
              frontend_nodes+=("$node_name")
              profile_nodes+=("$node_name")
              ;;
          "hotel-node2")
              recommendation_nodes+=("$node_name")
              ;;
      esac
  done < <(kubectl get nodes -o json | jq -r '.items[] | .metadata.name + " " + (.metadata.labels."node-type" // "")')

  # local frontend_nodes=("10.10.1.79" "10.10.0.128" "10.10.1.35"  )
  # local profile_nodes=("10.10.1.79" "10.10.0.128" "10.10.1.35"  )
  # local recommendation_nodes=("10.10.3.176" "10.10.1.183" "10.10.2.91")


  port=$(kubectl get svc frontend -n hotel-test -o json | jq -r '.spec.ports[] | select(.name=="5000") | .nodePort')
  local service_path="recommendations?require=price&lat=37.883&lon=-122.252"
  ab -k -r -q -d -c 1000 -t $((perf_duration+10))s -n 9999999 http://$ip_frontend:$port/$service_path &>/dev/null &
  sleep 5

  ssh "$agent_user"@"$ip_frontend" 'sudo bpftool prog list > '"$data_file_frontend"'.prog'
  ssh "$agent_user"@"$ip_frontend" 'sudo perf record -F 1000 -o '"$data_file_frontend"' --call-graph fp -e cpu-cycles -p $(pgrep frontend) sleep '"$perf_duration" &

  ssh "$agent_user"@"$ip_backend" 'sudo bpftool prog list > '"$data_file_backend"'.prog'
  ssh "$agent_user"@"$ip_backend" 'sudo perf record -F 1000 -o '"$data_file_backend"' --call-graph fp -e cpu-cycles -p $(pgrep recommendation) sleep '"$perf_duration" &

  ssh "$agent_user"@"$ip_frontend" 'sudo bpftool prog list > '"$data_file_backend"'.prog'
  ssh "$agent_user"@"$ip_frontend" 'sudo perf record -F 1000 -o '"$data_file_backend"' --call-graph fp -e cpu-cycles -p $(pgrep profile) sleep '"$perf_duration" &

# # 检查每个节点
#   for node in "${frontend_nodes[@]}"; do
#     ssh "$agent_user"@"$node" 'sudo bpftool prog list > '"$data_file_frontend"'.prog'
#     ssh "$agent_user"@"$node" 'sudo perf record -F 1000 -o '"$data_file_frontend"' --call-graph fp -e cpu-cycles -p $(pgrep frontend) sleep '"$perf_duration" &
#   done

#   for node in "${profile_nodes[@]}"; do
#     ssh "$agent_user"@"$node" 'sudo bpftool prog list > '"$data_file_backend"'.prog'
#     ssh "$agent_user"@"$node" 'sudo perf record -F 1000 -o '"$data_file_backend"' --call-graph fp -e cpu-cycles -p $(pgrep recommendation) sleep '"$perf_duration" &
#   done

#   for node in "${recommendation_nodes[@]}"; do
#     ssh "$agent_user"@"$node" 'sudo bpftool prog list > '"$data_file_backend"'.prog'
#     ssh "$agent_user"@"$node" 'sudo perf record -F 1000 -o '"$data_file_backend"' --call-graph fp -e cpu-cycles -p $(pgrep profile) sleep '"$perf_duration" &
#   done

  wait
}



collect_results() {
  local data_file=$1
  local output_file=$2
  local target_ip=$3

  ssh "$agent_user"@"$target_ip" 'sudo ./perf_head_custom_report.sh -i '"$data_file" | tee -a "$output_file"
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
# for node in $nodes; do
#   kubectl label node "$node" node-type-
# done
# kubectl label node "$b_agent_node_name" node-type=hotel-node3
# kubectl label node "$agent_node_name" node-type=hotel-node2
# kubectl label node "$proxy_node_name" node-type=hotel-node1

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
delete_chain_scope
delete_beyla
delete_deepflow
delete_test_application

echo ""
test_id=$(date +%Y-%m-%d_%H%M%S)
echo "Experiment $test_id"
experiment_type="${test_app}-qps-cpu"
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
echo "--- Benchmarking with beyla ---"
echo ""


((test_no++))
echo "[Test $test_no] beyla,sampling_rate=1" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  deploy_beyla 1
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.beyla.sampling1.frontend.data
  data_file_backend="$test_id"/perf.beyla.sampling1.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_test_application
  delete_beyla
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi


((test_no++))
echo "[Test $test_no] beyla,sampling_rate=0.1" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  deploy_beyla 0.1
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.beyla.sampling0.1.frontend.data
  data_file_backend="$test_id"/perf.beyla.sampling0.1.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_test_application
  delete_beyla
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] beyla,sampling_rate=0.01" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  deploy_beyla 0.01
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.beyla.sampling0.01.frontend.data
  data_file_backend="$test_id"/perf.beyla.sampling0.01.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_test_application
  delete_beyla
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi


echo ""
echo "--- Benchmarking with deepflow ---"
echo ""

((test_no++))
echo "[Test $test_no] deepflow" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  deploy_deepflow
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.deepflow.frontend.data
  data_file_backend="$test_id"/perf.deepflow.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_deepflow
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi


echo ""
echo "--- Benchmarking with Baseline ---"
echo ""

((test_no++))
echo "[Test $test_no] plain app" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.plain.frontend.data
  data_file_backend="$test_id"/perf.plain.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

# echo ""
# echo "--- Benchmarking with jaeger ---"
# echo ""

# ((test_no++))
# echo "[Test $test_no] jaeger, sampling_rate=1" | tee -a "$output_file"
# if [ "${tests[test_no-1]}" == true ]; then
#   deploy_test_application true 1
#   # shellcheck disable=SC2046
#   benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
#   data_file_frontend="$test_id"/perf.jaeger.sampling1.frontend.data
#   data_file_backend="$test_id"/perf.jaeger.sampling1.backend.data
#   benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
#   echo "Test complete! Collecting Perf results..."
#   echo "[Frontend]:" | tee -a "$output_file"
#   collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
#   echo "[Backend]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$node_ip"
#   echo "[Backend pnode]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$p_node_ip"

#   delete_test_application
# else
#   echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
# fi

# ((test_no++))
# echo "[Test $test_no] jaeger, sampling_rate=0.1" | tee -a "$output_file"
# if [ "${tests[test_no-1]}" == true ]; then
#   deploy_test_application true 1
#   # shellcheck disable=SC2046
#   benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
#   data_file_frontend="$test_id"/perf.jaeger.sampling0.1.frontend.data
#   data_file_backend="$test_id"/perf.jaeger.sampling0.1.backend.data
#   benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
#   echo "Test complete! Collecting Perf results..."
#   echo "[Frontend]:" | tee -a "$output_file"
#   collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
#   echo "[Backend]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$node_ip"
#   echo "[Backend pnode]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$p_node_ip"

#   delete_test_application
# else
#   echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
# fi
# ((test_no++))
# echo "[Test $test_no] jaeger, sampling_rate=0.01" | tee -a "$output_file"
# if [ "${tests[test_no-1]}" == true ]; then
#   deploy_test_application true 1
#   # shellcheck disable=SC2046
#   benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
#   data_file_frontend="$test_id"/perf.jaeger.sampling0.01.frontend.data
#   data_file_backend="$test_id"/perf.jaeger.sampling0.01.backend.data
#   benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
#   echo "Test complete! Collecting Perf results..."
#   echo "[Frontend]:" | tee -a "$output_file"
#   collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
#   echo "[Backend]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$node_ip"
#   echo "[Backend pnode]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$p_node_ip"

#   delete_test_application
# else
#   echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
# fi

# echo ""
# echo "--- Benchmarking with grpc tagging : application tagging ---"
# echo ""

# ((test_no++))
# echo "[Test $test_no] application injection,sampling_rate=1" | tee -a "$output_file"
# if [ "${tests[test_no-1]}" == true ]; then
#   deploy_test_application false 0
#   deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1 false true 1
#   ./scripts/utils/set_sampling_rate.sh 1
#   ./scripts/utils/add_unmonitored_ip.sh
#   # shellcheck disable=SC2046
#   benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
#   data_file_frontend="$test_id"/perf.aj.sampling1.frontend.data
#   data_file_backend="$test_id"/perf.aj.sampling1.backend.data
#   benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
#   echo "Test complete! Collecting Perf results..."
#   echo "[Frontend]:" | tee -a "$output_file"
#   collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
#   echo "[Backend]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$node_ip"
#   echo "[Backend pnode]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$p_node_ip"

#   delete_chain_scope
#   delete_test_application
# else
#   echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
# fi

# ((test_no++))
# echo "[Test $test_no] application injection,sampling_rate=0.1" | tee -a "$output_file"
# if [ "${tests[test_no-1]}" == true ]; then
#   deploy_test_application false 0
#   deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 1
#   ./scripts/utils/set_sampling_rate.sh 10
#   ./scripts/utils/add_unmonitored_ip.sh
#   # shellcheck disable=SC2046
#   benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
#   data_file_frontend="$test_id"/perf.aj.sampling0.1.frontend.data
#   data_file_backend="$test_id"/perf.aj.sampling0.1.backend.data
#   benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
#   echo "Test complete! Collecting Perf results..."
#   echo "[Frontend]:" | tee -a "$output_file"
#   collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
#   echo "[Backend]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$node_ip"
#   echo "[Backend pnode]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$p_node_ip"

#   delete_chain_scope
#   delete_test_application
# else
#   echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
# fi

# ((test_no++))
# echo "[Test $test_no] application injection,sampling_rate=0.01" | tee -a "$output_file"
# if [ "${tests[test_no-1]}" == true ]; then
#   deploy_test_application false 0
#   deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 1
#   ./scripts/utils/set_sampling_rate.sh 100
#   ./scripts/utils/add_unmonitored_ip.sh
#   # shellcheck disable=SC2046
#   benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
#   data_file_frontend="$test_id"/perf.aj.sampling0.01.frontend.data
#   data_file_backend="$test_id"/perf.aj.sampling0.01.backend.data
#   benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
#   echo "Test complete! Collecting Perf results..."
#   echo "[Frontend]:" | tee -a "$output_file"
#   collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
#   echo "[Backend]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$node_ip"
#   echo "[Backend pnode]:" | tee -a "$output_file"
#   collect_results "$data_file_backend" "$output_file" "$p_node_ip"

#   delete_chain_scope
#   delete_test_application
# else
#   echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
# fi

echo ""
echo "--- Benchmarking with grpc tagging : ip tagging ---"
echo ""

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=1" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  deploy_chain_scope true true 0 "" "$(get_entrypoint_ips)" 1 false true 2
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.ip.sampling1.frontend.data
  data_file_backend="$test_id"/perf.ip.sampling1.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_chain_scope
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.1" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 2
  ./scripts/utils/set_sampling_rate.sh 10
  ./scripts/utils/add_unmonitored_ip.sh
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.ip.sampling0.1.frontend.data
  data_file_backend="$test_id"/perf.ip.sampling0.1.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_chain_scope
  delete_test_application
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}" | tee -a "$output_file"
fi

((test_no++))
echo "[Test $test_no] ip tagging,sampling_rate=0.01" | tee -a "$output_file"
if [ "${tests[test_no-1]}" == true ]; then
  deploy_test_application false 0
  deploy_chain_scope false true 0 "" "$(get_entrypoint_ips)" 1 false true 2
  ./scripts/utils/set_sampling_rate.sh 100
  ./scripts/utils/add_unmonitored_ip.sh
  # shellcheck disable=SC2046
  benchmark_throughput_median "$p_node_ip" 30555 30 | tee -a "$output_file"
  data_file_frontend="$test_id"/perf.ip.sampling0.01.frontend.data
  data_file_backend="$test_id"/perf.ip.sampling0.01.backend.data
  benchmark_bpf_cpu "$data_file_frontend" "$data_file_backend" "$p_node_ip" "$node_ip" 30555
  echo "Test complete! Collecting Perf results..."
  echo "[Frontend]:" | tee -a "$output_file"
  collect_results "$data_file_frontend" "$output_file" "$p_node_ip"
  echo "[Backend]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$node_ip"
  echo "[Backend pnode]:" | tee -a "$output_file"
  collect_results "$data_file_backend" "$output_file" "$p_node_ip"

  delete_chain_scope
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
delete_chain_scope
delete_beyla
delete_deepflow
delete_test_application
echo -n "${FRST}"
echo ""

echo "Done. Results saved at $output_file."
