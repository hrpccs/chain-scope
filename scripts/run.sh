#!/bin/bash

if [[ -n "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR"/utils/registry.sh
else
  source utils/registry.sh
fi

DEFAULT_REGISTRY=$(get_default_registry)
IMAGE_REGISTRY=$(get_registry)

DEFAULT_TAG=dev

tag=$DEFAULT_TAG
ctrl=true
build_agent=false
build_ctrl=false
sampling=false
benchmark=false
demo=false
java_plugin=false
build_java_plugin=false
golang_plugin=false
build_golang_plugin=false
http_plugin=false
build_http_plugin=false
jaeger_plugin=false
test_nginx=false
test_haproxy=false
test_haproxy_synch=false
test=false

print_usage() {
  echo "Usage: $0 [options]"
  echo
  echo "Options:"
  echo "  -t|--tag <tag>          Image tag (default '$DEFAULT_TAG')"
  echo "  -a|--build-agent        Build agent"
  echo "  -c|--build-ctrl         Build controller"
  echo "  -s|--sampling           Enable sampling feature (requires building agent)"
  echo "  -b|--benchmark          Enable benchmark feature (requires building agent)"
  echo "  -d|--demo               Also deploy demo application"
  echo "  --no-ctrl               Do not deploy the controller"
  echo "  --java-plugin           Deploy the java plug-in for threadpool support"
  echo "  --build-java-plugin     Build the java plug-in for threadpool support"
  echo "  --golang-plugin         Deploy the golang plug-in for goroutines support"
  echo "  --build-golang-plugin   Build the golang plug-in for goroutines support"
  echo "  --http-plugin           Deploy the HTTP tagging plug-in"
  echo "  --build-http-plugin     Build the HTTP tagging plug-in"
  echo "  --jaeger-plugin         Deploy the Jaeger UI plug-in"
  echo "  --test-nginx            Deploy the nginx test application"
  echo "  --test-haproxy          Deploy the haproxy test application"
  echo "  --test-haproxy          Deploy the haproxy test application (synch version)"
  echo "  -h|--help               Show this help message"
}

OPTS=$(getopt \
  -o t:acsbdh \
  --long \
tag:,help,build-agent,build-ctrl,sampling,benchmark,demo,no-ctrl,test-nginx,test-haproxy,\
java-plugin,golang-plugin,http-plugin,jaeger-plugin,\
build-java-plugin,build-golang-plugin,build-http-plugin,build-jaeger-plugin \
  -n "$0" -- "$@"
)
if [ $? != 0 ]; then
  echo "Failed parsing options." >&2
  exit 1
fi
eval set -- "$OPTS"
while true; do
  case "$1" in
    -t|--tag)               tag="$2";                     shift 2 ;;
    -a|--build-agent)       build_agent=true;             shift ;;
    -c|--build-ctrl)        build_ctrl=true;              shift ;;
    -s|--sampling)          sampling=true;                shift ;;
    -b|--benchmark)         benchmark=true;               shift ;;
    -d|--demo)              demo=true;                    shift ;;
    --no-ctrl)              ctrl=false;                   shift ;;
    --java-plugin)          java_plugin=true;             shift ;;
    --build-java-plugin)    build_java_plugin=true;       shift ;;
    --golang-plugin)        golang_plugin=true;           shift ;;
    --build-golang-plugin)  build_golang_plugin=true;     shift ;;
    --http-plugin)          http_plugin=true;             shift ;;
    --build-http-plugin)    build_http_plugin=true;       shift ;;
    --jaeger-plugin)        jaeger_plugin=true;           shift ;;
    --test-nginx)           test_nginx=true;
                            test=true;                    shift ;;
    --test-haproxy)         test_haproxy=true;
                            test=true;                    shift ;;
    --test-haproxy-synch)   test_haproxy_synch=true;
                            test=true;                    shift ;;
    -h|--help)              print_usage;                  exit 0 ;;
    --)                     shift;                        break ;;
    *)                      echo "Unexpected option: $1";
                            print_usage;                  exit 1 ;;
  esac
done

# check compatibility between agent and controller configuration
if [[ "$sampling" == false ]] && [[ "$ctrl" == true ]]; then
  supported_algorithms="depth-first|breadth-first|span-based"
  if ! grep -A1 -E 'name: ALGORITHM' deployment.yaml | grep -E "value: \"($supported_algorithms)\"" &> /dev/null; then
    echo "ERROR: Chosen controller algorithm is not supported without the agent sampling feature (supported algorithms are: $supported_algorithms)."
    echo "       Please modify the controller configuration in your deployment file before running ChainScope."
    exit 1
  fi
fi
if [[ "$sampling" == true ]] && [[ "$ctrl" == true ]]; then
  suggested_algorithms="tag-based"
  if ! grep -A1 -E 'name: ALGORITHM' deployment.yaml | grep -E "value: \"($suggested_algorithms)\"" &> /dev/null; then
    echo "WARNING: You are running the agent with the sampling feature enabled."
    echo "         You may probably want to use the $suggested_algorithms controller algorithm."
    echo "         If so, please modify the controller configuration in your deployment file, then run ChainScope again."
    echo "If this is intended, wait 5 seconds to continue..."
    sleep 5
  fi
fi

# delete any existing deployment
# shellcheck disable=SC2046
./scripts/clean.sh -t "$tag" $([[ "$demo" == true ]] && echo "-d") $([[ "$java_plugin" == true ]] && echo "-j") $([[ "$golang_plugin" == true ]] && echo "-g") $([[ "$test" == true ]] && echo "-T")

# build and push images
if [[ "$build_agent" == true || "$build_ctrl" == true ]]; then
  # shellcheck disable=SC2046
  if ! ./scripts/build_push_image.sh -t "$tag" $([[ "$build_agent" == true ]] && echo "-a") $([[ "$build_ctrl" == true ]] && echo "-c") $([[ "$sampling" == true ]] && echo "-s") $([[ "$benchmark" == true ]] && echo "-b"); then
    echo "Failed building image, aborting."
    exit 1
  fi
fi

# deploy chain-scope
sed "s/:$DEFAULT_TAG/:$tag/g" deployment.yaml | \
    sed "/$DEFAULT_REGISTRY/$IMAGE_REGISTRY/g" - | \
    kubectl apply -f -
sleep 2
kubectl -n chain-scope wait pods -l name=chain-scope-agent --for condition=Ready
if [[ "$ctrl" == true ]]; then
  kubectl -n chain-scope wait pods -l name=chain-scope-controller --for condition=Ready
fi

# configure chain-scope
./scripts/utils/set_sampling_rate.sh 1
./scripts/utils/add_unmonitored_ip.sh "$([[ "$test" == false ]] && echo "-k")" -i

# deploy java plug-in
if [[ "$java_plugin" == true ]]; then
  # shellcheck disable=SC2046
  if ! ./plugins/java/scripts/run.sh -t "$tag" $([[ "$build_java_plugin" == true ]] && echo "-b")  $([[ "$demo" == true ]] && echo "-d"); then
    echo "Failed deploying java plug-in."
    exit 1
  fi
fi

# deploy golang plug-in
if [[ "$golang_plugin" == true ]]; then
  # shellcheck disable=SC2046
  if ! ./plugins/golang/scripts/run.sh -t "$tag" $([[ "$build_golang_plugin" == true ]] && echo "-b")  $([[ "$demo" == true ]] && echo "-d"); then
    echo "Failed deploying golang plug-in."
    exit 1
  fi
fi

# deploy HTTP tagging plug-in
if [[ "$http_plugin" == true ]]; then
  # shellcheck disable=SC2046
  if ! ./plugins/http-tagging/scripts/run.sh -t "$tag" $([[ "$build_http_plugin" == true ]] && echo "-b")  $([[ "$demo" == true ]] && echo "-d"); then
    echo "Failed deploying HTTP tagging plug-in."
    exit 1
  fi
fi

# deploy Jaeger UI plug-in
if [[ "$jaeger_plugin" == true ]]; then
  # shellcheck disable=SC2046
  if ! ./plugins/jaeger-ui/scripts/run.sh; then
    echo "Failed deploying Jaeger UI plug-in."
    exit 1
  fi
fi

# deploy demo application
if [[ "$demo" == true && "$java_plugin" == false && "$golang_plugin" == false && "$http_plugin" == false ]]; then
  echo "Deploying the bookinfo-demo application..."
  kubectl apply -f samples/bookinfo/bookinfo.yaml
  kubectl -n bookinfo-demo wait pods --all --for condition=Ready
  kubectl -n bookinfo-demo get pods -o wide
  echo "The bookinfo-demo application was deployed successfully."
fi

# deploy test applications
if [[ "$test_nginx" == true ]]; then
  echo "Deploying the nginx-test application..."
  kubectl apply -f samples/nginx-test/nginx.yaml
  kubectl -n nginx-test wait pods --all --for condition=Ready
  kubectl -n nginx-test get pods -o wide
  echo "The nginx-test application was deployed successfully."
fi
if [[ "$test_haproxy" == true ]]; then
  echo "Deploying the haproxy-test application..."
  kubectl apply -f samples/haproxy-test/haproxy.yaml
  kubectl -n haproxy-test wait pods --all --for condition=Ready
  kubectl -n haproxy-test get pods -o wide
  echo "The haproxy-test application was deployed successfully."
fi
if [[ "$test_haproxy_synch" == true ]]; then
  echo "Deploying the haproxy-test application (synch version)..."
  kubectl apply -f samples/haproxy-test/haproxy-synch.yaml
  kubectl -n haproxy-test wait pods --all --for condition=Ready
  kubectl -n haproxy-test get pods -o wide
  echo "The haproxy-test application was deployed successfully."
fi