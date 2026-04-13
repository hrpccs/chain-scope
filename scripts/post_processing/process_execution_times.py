import sys

input_file_name=sys.argv[1] if len(sys.argv)>=2 else "out.txt"
output_file_name=sys.argv[2] if len(sys.argv)>=3 else "execution_times.csv"
overhead_of_each_prog={}
with open(input_file_name) as f:
    lines=f.readlines()
    for line in lines:
        datas=line.split(" ")
        if len(datas)>=6 and datas[-6]=="PROGRAM":
            name, time = datas[-5],datas[-2]
            if name in overhead_of_each_prog:
                overhead_of_each_prog[name].append(float(time))
            else:
                overhead_of_each_prog[name]=[float(time)]
                
with open(output_file_name,"w") as f:
    f.write("hook,total_time(ns),count,mean_time(ns)\n")
    for prog_name, times in overhead_of_each_prog.items():
        total_time=sum(times)
        count=len(times)
        f.write(prog_name+","+str(int(total_time))+","+str(count)+","+str(int(total_time/count))+"\n")
# print(overhead_of_each_prog)