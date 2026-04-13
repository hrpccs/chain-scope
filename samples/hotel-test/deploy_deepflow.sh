helm install deepflow -n deepflow deepflow/deepflow --create-namespace -f samples/hotel-test/deepflow-values-custom.yaml



NODE_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[0].address}")
deepflow-ctl --ip $NODE_IP agent-group list default
GROUP_ID=$(deepflow-ctl --ip $NODE_IP agent-group list default | awk '/default/ {print $2}')
deepflow-ctl --ip $NODE_IP agent-group-config create $GROUP_ID -f samples/hotel-test/deepflow-agent-config.yaml 

NODE_IP=$(kubectl get nodes -o jsonpath="{.items[0].status.addresses[0].address}")
deepflow-ctl --ip $NODE_IP agent-group list default
GROUP_ID=$(deepflow-ctl --ip $NODE_IP agent-group list default | awk '/default/ {print $2}')
deepflow-ctl --ip $NODE_IP agent-group-config update $GROUP_ID -f samples/hotel-test/deepflow-agent-config.yaml 