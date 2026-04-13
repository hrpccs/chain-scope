processname=("frontend" "geo" "profile" "rate" "reservation" "search" "user" "recommendation")
for i in "${processname[@]}"
do
    echo "Generating offset for $i"
    objdump -Cd /proc/$(pgrep $i)/exe | grep "go:itab.*google.golang.org/grpc/internal/transport.headerFrame" | tee -a $i.offset
done