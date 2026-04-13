ip link add veth-gso type veth peer name veth-return
ip link set veth-gso up
ip link set veth-return up

tc qdisc add dev ens3 clsact
tc qdisc add dev veth-return clsact

# mega-packet will be segmented at veth-gso and forward to veth-return. we need to forward the small packet
ethtool -K veth-gso gso off tso off
ethtool -K veth-return gro off
