# while true; do
#     curl -H 'Host: hotel.com' 'http://10.10.3.198/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194'
#     sleep 1  # 延迟1秒
# done
# # 10.10.0.180,10.10.1.93,10.10.2.192,10.10.2.207,10.10.3.65
# #  wrk -D exp -t 32 -c 100 -d 120 -L -H "Host: hotel.com" 'http://10.10.3.198/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194' -R 100
# wrk -D exp -t 16 -c 32 -d 120 -L -s /home/ubuntu/workspace/fullstack-tracer/samples/DeathStarBench/hotelReservation/wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua http://10.10.0.180:30555 -R -1

curl 'http://10.10.0.180:30001/test'
fortio load -c 32 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30001/test'
fortio load -c 100 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30001/test'


fortio load -c 1000 -keepalive -t 600s -quiet -qps 0 'http://localhost:5000/recommendations?require=price&lat=37.883&lon=-122.252'
fortio load -c 1000 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'
fortio load -c 32 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'
fortio load -c 32 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30555/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194'

fortio load -c 1 -keepalive -t 6000s -quiet -qps 2 'http://10.10.0.180:30555/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194'

curl 'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'
curl  'http://10.10.0.180:30555/hotels?inDate=2015-04-09&outDate=2015-04-10&lat=37.7749&lon=-122.4194'
fortio load -c 32 -keepalive -t 600s -quiet -qps 3500 'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'
fortio load -c 1 -keepalive -t 6000s -quiet -qps 2 'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'

fortio load -c 1000 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'

fortio load -c 1000 -keepalive -t 600s -quiet -qps 0 'http://10.10.1.120:30555/recommendations?require=price&lat=37.883&lon=-122.252'

ab -r -q -d -c 1000 -t 60s -n 10000000  'http://10.10.1.120:30555/recommendations?require=price&lat=37.883&lon=-122.252'
fortio load -c 1000 -t 60s -quiet -qps 0 'http://10.10.1.120:30555/recommendations?require=price&lat=37.883&lon=-122.252'
ab -r -q -d -c 1000 -t 600s -n 10000000  'http://localhost:5000/recommendations?require=price&lat=37.883&lon=-122.252'

ab -r -q -d -c 1000 -t 60s -n 10000000  'http://10.10.4.75:30555/recommendations?require=price&lat=37.883&lon=-122.252'
ab -r -q -d -c 1000 -t 600s -n 10000000  'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'
ab -r -q -d -c 1000 -t 600s -n 10000  'http://10.10.0.180:30555/recommendations?require=price&lat=37.883&lon=-122.252'

fortio load -c 32 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30555/'

curl 'http://10.10.0.180:30555/'
fortio load -c 1000 -keepalive -t 600s -quiet -qps 0 'http://10.10.0.180:30555/'

ab -k -r -q -d -c 32 -t 600s -n 9999999 'http://10.10.0.180:30555/'
fortio load -c 1000 -keepalive -t 600s -quiet -qps 10000 'http://10.10.0.180:30555/'

curl "http://10.10.1.79:30555/recommendations?require=price&lat=37.883&lon=-122.252"
ab -r -q -d -c 1000 -t 600s -n 10000000  'http://10.10.1.79:30555/recommendations?require=price&lat=37.883&lon=-122.252'
fortio load -c 1000 -t 60s -quiet -qps 0 'http://10.10.1.79:30555/recommendations?require=price&lat=37.883&lon=-122.252'