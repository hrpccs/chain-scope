#!/bin/bash

if [[ -n "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR"/utils/registry.sh
else
  source utils/registry.sh
fi

DEFAULT_TAG=dev
IMAGE_REGISTRY=$(get_registry)

build_agent=false
build_ctrl=false
sampling=false
benchmark=false
event_based=1
span_based=0
debug=0
tag=$DEFAULT_TAG


# 新增测试用例映射表
declare -A TEST_CASES
TEST_CASES[1]="COROUTINE_EXTENSION_SUPPORT=1 GRPC_IP_TAGGING=0 COROUTINE_INKERNEL_SUPPORT=1 GRPC_IP_TAGGING_WITH_REDISTRIBUTE=0"
TEST_CASES[2]="COROUTINE_EXTENSION_SUPPORT=1 GRPC_IP_TAGGING=1 COROUTINE_INKERNEL_SUPPORT=1 GRPC_IP_TAGGING_WITH_REDISTRIBUTE=0"
TEST_CASES[3]="COROUTINE_EXTENSION_SUPPORT=1 GRPC_IP_TAGGING=1 COROUTINE_INKERNEL_SUPPORT=1 GRPC_IP_TAGGING_WITH_REDISTRIBUTE=1"
TEST_CASES[4]="COROUTINE_EXTENSION_SUPPORT=1 GRPC_IP_TAGGING=0 COROUTINE_INKERNEL_SUPPORT=0"
TEST_CASES[5]="COROUTINE_EXTENSION_SUPPORT=1 GRPC_IP_TAGGING=0 COROUTINE_INKERNEL_SUPPORT=1"

test_case=""

print_usage() {
  echo "Usage: $0 [-a] [-c] [-s] [-t <images tag>] [-h]"
  echo
  echo "Options:"
  echo "  -a    Build agent"
  echo "  -c    Build controller"
  echo "  -t    Tag of the agent and controller images (default '$DEFAULT_TAG')"
  echo "  -s    Enable sampling feature (requires building the agent)"
  echo "  -b    Enable benchmark feature (requires building the agent)"
  echo "  -j    Enable span based chainscope"
  echo "  -d    Enable debug info"
  echo "  -T    select grpc test case"
  echo "  -h    Print this help message"
}

while getopts 'hacsbjdt:T:' opt; do
  case "${opt}" in
    a) build_agent=true ;;
    c) build_ctrl=true ;;
    s) sampling=true ;;
    b) benchmark=true ;;
    t) tag=${OPTARG} ;;
    j) span_based=1
       event_based=0 ;;
    d) debug=1 ;;
    T) test_case=${OPTARG} ;;
    h) print_usage
       exit 0 ;;
    *) print_usage
       exit 1 ;;
  esac
done

if [[ "$build_agent" == false && "$build_ctrl" == false ]]; then
  print_usage
  exit 1
fi

if [ "$build_agent" = true ]; then
# 新增测试用例参数处理
  if [[ -n "$test_case" ]]; then
    if [[ ! "$test_case" =~ ^[1-5]$ ]]; then
      echo "Error: Test case must be 1-5"
      print_usage
      exit 1
    fi
    eval "${TEST_CASES[$test_case]}"
  fi
fi

# build agent
if [ "$build_agent" = true ]; then
  echo "Building the chain-scope agent..."
  echo " - sampling-feature=$sampling"
  echo " - benchmark-feature=$benchmark"
  echo " - span-based-feature=$span_based"
  echo " - event-based-feature=$event_based"
  echo " - debug=$debug"
  sed -i '32s/$/a/' agent/src/bpf/hooks.bpf.c
  if ! docker build \
    --build-arg SAMPLING=$sampling \
    --build-arg BENCHMARK=$benchmark \
    --build-arg DEBUG_LEVEL=$debug \
    --build-arg EXPORT_EVENTS_AT_TCP=$event_based \
    --build-arg EXPORT_SPANS=$span_based \
    --build-arg COROUTINE_EXTENSION_SUPPORT=${COROUTINE_EXTENSION_SUPPORT:-0} \
    --build-arg COROUTINE_INKERNEL_SUPPORT=${COROUTINE_INKERNEL_SUPPORT:-0} \
    --build-arg GRPC_IP_TAGGING=${GRPC_IP_TAGGING:-0} \
    --build-arg GRPC_IP_TAGGING_WITH_REDISTRIBUTE=${GRPC_IP_TAGGING_WITH_REDISTRIBUTE:-0} \
    -t agent:"$tag" \
    agent/; then exit 1; fi
  docker tag agent:"$tag" "$IMAGE_REGISTRY"/agent:"$tag"
  docker push "$IMAGE_REGISTRY"/agent:"$tag"
  echo "The chain-scope agent was built successfully."
fi

# build controller
if [ "$build_ctrl" = true ]; then
  echo "Building the chain-scope controller..."
  if ! docker build -t controller:"$tag" controller/; then exit 1; fi
  docker tag controller:"$tag" "$IMAGE_REGISTRY"/controller:"$tag"
  docker push "$IMAGE_REGISTRY"/controller:"$tag"
  echo "The chain-scope controller was built successfully."
fi
