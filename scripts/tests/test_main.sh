#!/bin/bash

DEFAULT_TAG=dev
DEFAULT_CONCURRENCY=2
DEFAULT_N_CHAINS=10
DEFAULT_SAMPLING_RATE=0.5
DEFAULT_EXIT_ON_FAILURE=false

build_ctrl=true
tag="test"
tests=(false false false)
exit_on_failure=$DEFAULT_EXIT_ON_FAILURE
concurrency=$DEFAULT_CONCURRENCY
n_chains=$DEFAULT_N_CHAINS
sampling_rate_t2=$DEFAULT_SAMPLING_RATE

FRED=$(tput setaf 1)
FGRN=$(tput setaf 2)
FYLW=$(tput setaf 3)
FGRY=$(tput setaf 238)
FRST=$(tput sgr0)


print_usage() {
  echo "Usage: $0 -t <tests> [-r <n requests>] [-c <n chains>] [-s <sampling rate>] [-e] [-h]"
  echo "Example: $0 -t 1,2 -r 4 -s 0.01"
  echo
  echo "Options:"
  echo "  -t    Comma-separated list of tests to run"
  echo "  -r    Number of concurrent requests (default $DEFAULT_CONCURRENCY)"
  echo "  -c    Number of chains to wait for (default $DEFAULT_N_CHAINS)"
  echo "  -s    Sampling rate for test 2 (default $DEFAULT_SAMPLING_RATE)"
  echo "  -e    Exit on failure (default $exit_on_failure)"
  echo "  -h    Print this help message"
  echo
  echo "Tests:"
  echo "   1:   sampling rate = 1"
  echo "   2:   sampling rate = $DEFAULT_SAMPLING_RATE"
  echo "   3:   no sampling"
}

while getopts ':t:r:c:s:eh' opt; do
  case "${opt}" in
    t) TESTS="${OPTARG}" ;;
    e) exit_on_failure=true ;;
    r) concurrency="${OPTARG}" ;;
    c) n_chains="${OPTARG}" ;;
    s) sampling_rate_t2="${OPTARG}" ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done

# read tests to run
read -r -a tests_input <<< "$(echo "$TESTS" | tr ',' ' ')"
if [ ${#tests_input[@]} -eq 0 ]; then
  print_usage
  exit 1
fi
for a in "${tests_input[@]}"; do
  if ! [[ $a =~ ^[0-9]+$ ]] || (( a < 1 || a > ${#tests[@]} )); then
    echo "Unknown test number: $a"
    exit 1
  fi
  tests[a-1]=true
done

delete_chain_scope() {
  echo "Deleting ChainScope..."
  echo -n "${FGRY}"
  sed "s/:$DEFAULT_TAG/:$tag/g" deployment.yaml | kubectl delete -f - &>/dev/null
  kubectl -n chain-scope wait pods -l name=chain-scope-controller --for=delete &>/dev/null
  kubectl -n chain-scope wait pods -l name=chain-scope-agent --for=delete &>/dev/null
  echo -n "${FRST}"
}

delete_app() {
  echo "Deleting Bookinfo test application..."
  echo -n "${FGRY}"
  kubectl delete -f samples/bookinfo/bookinfo.yaml --wait=true &>/dev/null
  echo -n "${FRST}"
}

delete_all() {
  delete_chain_scope
  delete_app
}

deploy_app() {
  echo "Deploying test application..."
  echo -n "${FGRY}"
  sed 's/curl.*&/#&/' samples/bookinfo/bookinfo.yaml | \
    awk -v n="$concurrency" -v RS='(\r\n|\n|\r)' -v ORS='\n' '{if($0 ~ /^[[:space:]]*curl.*[^&]$/) {for(i=0;i<n;i++) printf "%s%s", $0, (i<n-1 ? "& " : "\n")} else print $0}' | \
    kubectl apply -f - &>/dev/null
  kubectl -n bookinfo-demo wait pod --all --for=condition=Ready
  kubectl -n bookinfo-demo get pods -o wide
  echo -n "${FRST}"
}

deploy_chain_scope() {
  local build_image=$1
  local sampling=$2
  local idle=$3
  local entrypoint_labels=$4
  local entrypoint_ips=$5

  ctrl_algorithm=$([ "$sampling" = true ] && echo "tag-based" || echo "span-based")

  if [ "$build_image" = true ]; then
    # build and push images
    sed -i 's/#define MEASURE_EXECUTION_TIME [[:digit:]]/#define MEASURE_EXECUTION_TIME 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define SENDPAGE_SUPPORT [[:digit:]]/#define SENDPAGE_SUPPORT 0/g' agent/src/bpf/common/config.h
    sed -i 's/#define ENVOY_SUPPORT [[:digit:]]/#define ENVOY_SUPPORT 1/g' agent/src/bpf/common/config.h
    sed -i 's/#define DEBUG_LEVEL [[:digit:]]/#define DEBUG_LEVEL 0/g' agent/src/bpf/common/config.h
    sed -i "s/#define IDLE [[:digit:]]/#define IDLE $idle/g" agent/src/bpf/common/config.h
    sed -i 's/#define TAGS_QUEUE_MAXLENGTH [[:digit:]]\+/#define TAGS_QUEUE_MAXLENGTH 16/g' agent/src/bpf/common/config.h

    echo "Building ChainScope..."
    # shellcheck disable=SC2046
    if ! ./scripts/build_push_image.sh -t "$tag" -a $([[ "$build_ctrl" == true ]] && echo "-c") $([[ "$sampling" == true ]] && echo "-s") &>/dev/null; then
      echo "Failed building image, aborting."
      exit 1
    fi
  fi

  echo "Deploying ChainScope..."
  sed "s/:$DEFAULT_TAG/:$tag/g" deployment.yaml | \
    sed "/ENTRYPOINT_LABELS/{n; s/\(value: \"\)[^\"]*\"/\1$entrypoint_labels\"/}" - | \
    sed "/ENTRYPOINT_STATIC_IPS/{n; s/\(value: \"\)[^\"]*\"/\1$entrypoint_ips\"/}" - | \
    sed '/RUST_BACKTRACE/{n; s/value:.*/value: "0"/}' - | \
    sed '/EXPORT_EVENTS_AT_TCP/{n; s/value:.*/value: "true"/}' - | \
    sed '/DEBUG/{n; s/value:.*/value: "false"/}' - | \
    sed '/KUBE_POLL_INTERVAL/{n; s/value:.*/value: "30000"/}' - | \
    sed '/EBPF_POLL_INTERVAL/{n; s/value:.*/value: "20000"/}' - | \
    sed "/ALGORITHM/{n; s/value:.*/value: \"$ctrl_algorithm\"/}" - | \
    sed 's/,"/"/g' - | \
    sed 's/: ",/: "/g' - | \
    kubectl apply -f - &>/dev/null
  sleep 2
  echo -n "${FGRY}"
  kubectl -n chain-scope wait pods -l name=chain-scope-agent --for condition=Ready
  if ! kubectl -n chain-scope wait pods -l name=chain-scope-controller --for condition=Ready; then
    echo -n "${FRST}"
    echo "The controller failed starting, aborting."
    exit 1
  fi
  kubectl -n chain-scope get pods -o wide
  echo -n "${FRST}"
  echo "ChainScope$( [ "$idle" -eq 1 ] && echo " (idle)" ) is up and running!"
  #./scripts/view_agent_log.sh -n chain-scope-benchmark-agent | grep -e TCP_RECVMSG -e TCP_SENDMSG &
}

test_routine() {
  local sampling=$1
  local istio=$2
  local n=$n_chains

  # fetch controller pod
  ctrl_pod=$(kubectl -n chain-scope get pods -o wide | grep chain-scope-controller | grep Running | awk '{print $1}')

  # get sampling rate
  rate=1
  if [ "$sampling" == true ]; then
    node_ips=$(kubectl get nodes -o custom-columns=node_ip:.status.addresses[0].address --no-headers=true)
    # shellcheck disable=SC2206
    node_ip=(${node_ips[0]})
    # shellcheck disable=SC2128
    rate=$(curl -s -X GET http://"$node_ip":9898/config/rate/sampling | awk -F'[^0-9]*' '{print $2}')
    n=$((n/rate))
    n=$((n < 1 ? 1 : n))
  fi

  # determine timeout (time for chains to happen + max phase shift for collecting events)
  load_interval=$(grep sleep < samples/bookinfo/bookinfo.yaml | awk -F'[^0-9]*' '{print $2}')
  echo "Test app is sending $concurrency requests per time"
  timeout=$((load_interval*(n*rate/concurrency+1)))
  ebpf_poll_interval=$(($(grep EBPF_POLL_INTERVAL -A 1 < deployment.yaml | grep value | awk -F'[^0-9]*' '{print $2}')/1000))
  kube_poll_interval=$(($(grep KUBE_POLL_INTERVAL -A 1 < deployment.yaml | grep value | awk -F'[^0-9]*' '{print $2}')/1000))
  collect_interval=$(grep COLLECT_INTERVAL -A 1 < deployment.yaml | grep value | awk -F'[^0-9]*' '{print $2}')
  chain_interval=$(grep CHAIN_INTERVAL -A 1 < deployment.yaml | grep value | awk -F'[^0-9]*' '{print $2}')
  max_interval=$(printf "%d\n" "$ebpf_poll_interval" "$kube_poll_interval" "$collect_interval" "$chain_interval" | sort -n | tail -1)
  timeout=$((timeout+max_interval*2))

  # wait for chains
  rm -f tmp*
  touch tmp_valid
  poll_interval=5
  iterations=0
  max_iterations=$((timeout/poll_interval+1))
  echo "Waiting for the first $n chains (timeout=$((max_iterations*poll_interval))s)..."
  while [ "$(wc -l < tmp_valid)" -lt "$n" ] && [ $iterations -lt $max_iterations ]; do
    # check for any discarded chain
    if kubectl -n chain-scope exec "$ctrl_pod" -c chain-scope-controller -- head service_chains.discarded.out >tmp_discarded 2>/dev/null; then
      echo -n "${FGRY}"
      cat tmp_discarded
      echo -n "${FRST}"
      echo "Error: some chains were incomplete and have been discarded."
      return 1
    fi
    # check for any invalid chain
    if kubectl -n chain-scope exec "$ctrl_pod" -c chain-scope-controller -- head service_chains.invalid.out >tmp_invalid 2>/dev/null; then
      echo -n "${FGRY}"
      cat tmp_invalid
      echo -n "${FRST}"
      echo "Error: there are some invalid chains."
      return 1
    fi
    # fetch reconstructed chains
    kubectl -n chain-scope exec "$ctrl_pod" -c chain-scope-controller -- head -"$n" service_chains.out >tmp_valid 2>/dev/null
    ((iterations++))
    sleep $poll_interval
  done

  echo "Collected $(wc -l < tmp_valid) chains."
  echo "Total waiting time: $((iterations*poll_interval))s."

  if [ $iterations -ge $max_iterations ] || ! kubectl -n chain-scope exec "$ctrl_pod" -c chain-scope-controller -- sh -c '[ -f "service_chains.out" ]'; then
    echo "Error: timeout waiting for chains."
    return 1
  fi

  # verify that all reconstructed chains match the expected pattern (bookinfo app)
  echo -n "${FGRY}"
  if ! awk -v istio="$istio" -f ./scripts/tests/match_bookinfo_chains.awk tmp_valid; then
    echo -n "${FRST}"
    echo "Error: some chains did not match the expected pattern."
    return 1
  fi
  echo -n "${FRST}"

  echo "Success!"
  return 0
}

check_istiod() {
    local namespace="istio-system"
    local deployment="istiod"

    ready_replicas=$(kubectl get "deployment.apps/$deployment" -n $namespace -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    desired_replicas=$(kubectl get "deployment.apps/$deployment" -n $namespace -o jsonpath='{.status.replicas}' 2>/dev/null)

    if [ -z "$ready_replicas" ] || [ -z "$desired_replicas" ]; then
        echo "Istio is not deployed"
        return 1
    fi

    if [ "$ready_replicas" -eq "$desired_replicas" ]; then
        echo "Istio is deployed"
        return 0
    else
        echo "Istio is deployed but not ready, ignoring..."
        return 1
    fi
}

check_istio_enabled() {
    local namespace="$1"
    label_value=$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.istio-injection}' 2>/dev/null)

    if [ "$label_value" = "enabled" ]; then
        echo "Namespace $namespace has istio injection enabled"
        return 0
    else
        echo "Namespace $namespace does not have istio injection enabled"
        return 1
    fi
}

echo "Tests to run:"
for i in "${!tests[@]}"; do
  echo "Test $((i+1)): $([[ ${tests[$i]} == true ]] && echo "${FGRN}yes${FRST}" || echo "${FRED}no${FRST}")"
done
echo ""

echo "--- Setup ---"
echo ""

# delete any existing deployment
echo "Cleaning environment..."
./scripts/clean.sh -t "$tag" -d -T -j -g -x &>/dev/null
echo "Checking Istio..."
istio=false
if check_istiod && check_istio_enabled "bookinfo-demo"; then
  echo "Expecting chains to match bookinfo+envoy patterns."
  istio=true
else
  echo "Expecting chains to match bookinfo without envoy patterns."
fi
echo ""

echo "--- Begin Tests ---"
echo ""

test_no=0

((test_no++))
echo "[Test $test_no] sampling_rate=1 (using tag-based controller)"
if [ "${tests[test_no-1]}" == true ]; then
  delete_all
  deploy_chain_scope true true 0 "loadgenerator" ""
  sleep 2
  ./scripts/utils/set_sampling_rate.sh 1
  ./scripts/utils/add_unmonitored_ip.sh -k -i &>/dev/null
  deploy_app
  if ! test_routine true $istio; then
    echo -e "${FRED} --- Test failed --- ${FRST}"
    if [ $exit_on_failure == true ]; then exit 1; fi
  else
    echo -e "${FGRN} +++ Test passed +++ ${FRST}"
  fi
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}"
fi
echo ""

((test_no++))
echo "[Test $test_no] sampling_rate=$sampling_rate_t2 (using tag-based controller)"
if [ "${tests[test_no-1]}" == true ]; then
  delete_all
  deploy_chain_scope true true 0 "loadgenerator" ""
  sleep 2
  ./scripts/utils/set_sampling_rate.sh "$(printf "%.0f" "$(echo "scale=10; 1/$sampling_rate_t2" | bc)")"
  ./scripts/utils/add_unmonitored_ip.sh -k -i &>/dev/null
  deploy_app
  if ! test_routine true $istio; then
    echo -e "${FRED} --- Test failed --- ${FRST}"
    if [ $exit_on_failure == true ]; then exit 1; fi
  else
    echo -e "${FGRN} +++ Test passed +++ ${FRST}"
  fi
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}"
fi
echo ""

((test_no++))
echo "[Test $test_no] no sampling (using span-based controller)"
if [ "${tests[test_no-1]}" == true ]; then
  delete_all
  deploy_chain_scope true false 0 "loadgenerator" ""
  sleep 2
  #./scripts/utils/set_sampling_rate.sh 1 &>/dev/null
  ./scripts/utils/add_unmonitored_ip.sh -k -i &>/dev/null
  deploy_app
  if ! test_routine false $istio; then
    echo -e "${FRED} --- Test failed --- ${FRST}"
    if [ $exit_on_failure == true ]; then exit 1; fi
  else
    echo -e "${FGRN} +++ Test passed +++ ${FRST}"
  fi
else
  echo -e "${FYLW} --- Test skipped --- ${FRST}"
fi
echo ""

echo "--- Clean ---"
echo ""
echo "All tests completed, cleaning..."
./scripts/clean.sh -t "$tag" -d &>/dev/null
rm -f tmp
echo ""
echo "Done."
