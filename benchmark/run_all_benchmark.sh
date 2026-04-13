./scripts/benchmark_hotel_qps_cpu_all-3node.sh -p bench-2 -b bench-2 -n bench-5 -i ens3 
./scripts/benchmark_hotel_accuracy_all-3node.sh -p bench-2 -b bench-2 -n bench-5 -i ens3 

python benchmark/plot_hotel_loss.py   
python benchmark/plot_hotel_qps_cpu.py
