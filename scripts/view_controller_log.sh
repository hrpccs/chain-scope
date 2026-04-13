#!/bin/bash
kubectl -n chain-scope wait pods -l name=chain-scope-controller --for=condition=Ready
name=$(kubectl -n chain-scope get pods -o wide | grep chain-scope-controller | grep Running | awk '{print $1}')
kubectl logs "$name" -n chain-scope -f
