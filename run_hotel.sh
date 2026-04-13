kubectl label node bench-1 node-type- && \
kubectl label node bench-2 node-type- && \
kubectl label node bench-3 node-type- && \
kubectl label node bench-4 node-type- && \
kubectl label node bench-5 node-type- && \
kubectl label node bench-6 node-type- && \

kubectl label node bench-1 node-type=hotel-node1 && \
kubectl label node bench-2 node-type=hotel-node1 && \
kubectl label node bench-3 node-type=hotel-node1 && \
kubectl label node bench-4 node-type=hotel-node2 && \
kubectl label node bench-5 node-type=hotel-node2 && \
kubectl label node bench-6 node-type=hotel-node2 

kubectl delete -n hotel-test -Rf samples/DeathStarBench/hotelReservation/kubernetes-3node/
kubectl apply -n hotel-test -Rf samples/DeathStarBench/hotelReservation/kubernetes-3node/