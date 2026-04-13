#!/bin/bash
kubectl -n chain-scope wait pods -l name=chain-scope-controller --for=condition=Ready
name=$(kubectl -n chain-scope get pods -o wide | grep chain-scope-controller | grep Running | awk '{print $1}')
kubectl -n chain-scope exec -it "$name" -- tail -n +1 -F collected_events.out
