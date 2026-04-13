# Import necessary libraries

import re
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import pylab
from matplotlib.ticker import FuncFormatter
import numpy as np
import os
from typing import Dict, List, Tuple, Optional

# Read performance test results file
# file_path = 'benchmark/results/goroutine/2025-08-01_005348/exec_cpu.out'
# file_path = 'benchmark/results/goroutine/2025-08-01_010902/exec_cpu.out'
file_path = 'benchmark/results/goroutine/latest/exec_cpu.out'

with open(file_path, 'r') as file:
    content = file.read()

# Split file content by test scenarios
test_pattern = r'\[Test \d+\].*?(?=\[Test \d+\]|$)'
tests = re.findall(test_pattern, content, re.DOTALL)

print(f"Found {len(tests)} test scenarios")
# Display first few lines of the first test scenario to understand the data structure
print("First few lines of the first test scenario:")
print("\n".join(tests[0].split("\n")[:10]))

def parse_test_scenario(test_content):
    """Parse the content of a single test scenario and extract key performance metrics"""
    result = {}

    # Extract test scenario name and description
    title_match = re.search(r'.Test (\d+).(.*)', test_content)
    if title_match:
        result['test_id'] = int(title_match.group(1))
        result['description'] = title_match.group(2)
    else:
        result['test_id'] = -1
        result['description'] = 'Unknown'

    # Check if the test was skipped
    if "--- Test skipped ---" in test_content:
        result['skipped'] = True
        return result
    else:
        result['skipped'] = False

    # Extract QPS information
    qps_match = re.search(r'All done \d+ calls .+ (\d+\.\d+) qps', test_content)
    if qps_match:
        result['qps'] = float(qps_match.group(1))

        # 在parse_test_scenario函数中添加min/max解析
    latency_match = re.search(r'Aggregated Function Time.*?avg ([\d.]+).*?\+/- ([\d.]+).*?min ([\d.]+).*?max ([\d.]+)', test_content, re.DOTALL)
    if latency_match:
        result['avg_latency_s'] = float(latency_match.group(1))
        result['std_dev_s'] = float(latency_match.group(2))
        result['min_latency_s'] = float(latency_match.group(3))
        result['max_latency_s'] = float(latency_match.group(4))
    else:
        result['avg_latency_s'] = None
        result['std_dev_s'] = None
        result['min_latency_s'] = None
        result['max_latency_s'] = None



    p50_match = re.search(r'# target 50% (\d+\.\d+)', test_content)
    p90_match = re.search(r'# target 90% (\d+\.\d+)', test_content)
    p99_match = re.search(r'# target 99% (\d+\.\d+)', test_content)
    p999_match = re.search(r'# target 99\.9% (\d+\.\d+)', test_content)

    if p50_match: result['p50_latency'] = float(p50_match.group(1))
    if p90_match: result['p90_latency'] = float(p90_match.group(1))
    if p99_match: result['p99_latency'] = float(p99_match.group(1))
    if p999_match: result['p999_latency'] = float(p999_match.group(1))


    # Extract Web server CPU usage
    cpu_match = re.search(r'([\d\.]+) msec task-clock\s+#\s+([\d\.]+) CPUs utilized', test_content)
    if cpu_match:
        result['task_clock_msec'] = float(cpu_match.group(1))
        result['cpus_utilized'] = float(cpu_match.group(2))

    bpf_program_cpu_patern = r'(\d+\.\d+)%.*\((.+)\)'
    bpf_total_match = re.findall(bpf_program_cpu_patern, test_content)
    # print all match that first group is non 0.00
    bpf_cpu = []
    for match in bpf_total_match:
        if match[0] != "0.00":
            new_name=match[1].replace("test_","kprobe_")
            new_name=new_name.replace("runtime","uprobe_runtime")
            bpf_cpu.append((match[0],new_name))
    result['bpf_cpu'] = bpf_cpu
    bpf_total_match = re.search(r'(\d+\.\d+)%\s+TOTAL', test_content, re.DOTALL)
    if bpf_total_match:
        result['bpf_total_percent'] = float(bpf_total_match.group(1))

    # Extract test type information (server-only or with proxy)
    if "plain" in result['description']:
        result['test_type'] = "baseline"
    elif "userspace" in result['description']:
        result['test_type'] = "zerotracer\n/deepflow"
    elif "inkernel" in result['description']:
        result['test_type'] = "chainscope"
    else:
        result['test_type'] = "unknown"

    return result


# Parse all test scenarios
test_results = [parse_test_scenario(test) for test in tests]

print(test_results)
# Create DataFrame
df = pd.DataFrame(test_results)

# Display non-skipped test scenario data
df_not_skipped = df[~df['skipped']]
print(f"Number of non-skipped test scenarios:")
print(df_not_skipped.columns.tolist())
print(df_not_skipped)

# plot, compare the baseline and zerotracer and in-kernel
# I want to compare the latency and cpu usage, and the cpu usage of each bpf program

# Convert task-clock to percentage
df_not_skipped['cpu_percent'] = df_not_skipped['cpus_utilized'] * 100

# Beautify program names
def beautify_program_name(program_name_):
    names = {
        'pnic_egress_ip_tagging': 'tc',
        'skb_copy_datagram_iter_enter': 'tcp_recvmsg',
        'tcp_recvmsg_exit': 'tcp_recvmsg',
        'tcp_sendmsg_locked_enter': 'tcp_sendmsg',
        'uprobe_runtime_goexit1': 'uprobe goexit',
        'uprobe_runtime_newproc1_exit': 'uprobe newproc',
        'kprobe_tcp_recvmsg_exit': 'tcp_recvmsg',
        'kprobe_tcp_sendmsg_locked_enter': 'tcp_sendmsg',
        'uprobe_runtime_execute': 'uprobe (golang)',
    }
    return names.get(program_name_, program_name_)

# Extract BPF program CPU usage into separate columns
bpf_data = []
for _, row in df_not_skipped.iterrows():
    test_type = row['test_type']
    for cpu_percent, program_name in row['bpf_cpu']:
        bpf_data.append({
            'test_type': test_type,
            'program': beautify_program_name(program_name),
            'cpu_percent': float(cpu_percent)
        })

bpf_data.sort(key=lambda x: x['program'])
bpf_df = pd.DataFrame(bpf_data)

# Create aggregated data for BPF programs
bpf_agg = bpf_df.groupby(['test_type', 'program'])['cpu_percent'].sum().reset_index()

def custom_formatter(x, pos):
    if x < 1000:
        return str(int(x))
    else:
        x_in_k = x / 1000
        return f'{int(round(x_in_k))}K'

# style
sns.reset_defaults()
params = {
    'legend.fontsize': 16,
    'legend.title_fontsize': 16,
    'axes.labelsize': 20,
    'axes.titlesize': 22,
    'xtick.labelsize': 18,
    'ytick.labelsize': 18,
    'figure.titlesize': 25,
}
plt.rc('font', size=16)
plt.rc('pdf', fonttype=42)
pylab.rcParams.update(params)

# 1. QPS comparison
_, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)

qps_palette = {'baseline': 'skyblue', 'zerotracer\n/deepflow': 'salmon', 'chainscope': 'lightgreen'}

sns.barplot(ax=ax, data=df_not_skipped, x='test_type', y='qps', hue='test_type',
            palette=qps_palette, errorbar=None, edgecolor='black')
ax.set_xlabel(None)
ax.set_ylabel('Requests per second')
ax.grid(axis='y', linestyle='--', alpha=0.7)
ax.yaxis.set_major_formatter(FuncFormatter(custom_formatter))
ax.set_axisbelow(True)

plt.savefig('benchmark/plots/goroutine_qps.pdf', dpi=300)
plt.show()

# 2. Latency comparison with grouped bar chart
_, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)
latency_palette = {'50 pct': 'skyblue', '90 pct': 'salmon', '99 pct': 'lightgreen'}

# Create latency data with percentile metrics
latency_data = []

for _, row in df_not_skipped.iterrows():
    test_type = row['test_type']
    if not pd.isna(row['p50_latency']):
        latency_data.append({'test_type': test_type, 'latency': row['p50_latency']*1000, 'type': '50 pct'})
    if not pd.isna(row['p90_latency']):
        latency_data.append({'test_type': test_type, 'latency': row['p90_latency']*1000, 'type': '90 pct'})
    if not pd.isna(row['p99_latency']):
        latency_data.append({'test_type': test_type, 'latency': row['p99_latency']*1000, 'type': '99 pct'})

latency_df = pd.DataFrame(latency_data)

# Create grouped bar chart for latency percentiles
sns.barplot(ax=ax, data=latency_df, x='test_type', y='latency', hue='type', palette=latency_palette, errorbar=None, edgecolor='black')
ax.set_ylabel('Latency (ms)')
ax.set_xlabel(None)
ax.legend(loc='upper left', frameon=False)
ax.grid(axis='y', linestyle='--', alpha=0.7)
ax.set_axisbelow(True)

plt.savefig('benchmark/plots/goroutine_latency.pdf', dpi=300)
plt.show()

# 3. CPU Usage as percentage
_, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)

cpu_palette = {'baseline': 'skyblue', 'zerotracer\n/deepflow': 'salmon', 'chainscope': 'lightgreen'}
sns.barplot(ax=ax, data=df_not_skipped, x='test_type', y='cpu_percent', hue='test_type',
            palette=cpu_palette, errorbar=None, edgecolor='black')
ax.set_xlabel(None)
ax.set_ylabel('CPU Usage (%)')
ax.grid(axis='y', linestyle='--', alpha=0.7)
ax.set_axisbelow(True)
# Set y-axis limits to focus on the range of interest
# axes[2].set_ylim(80, 120)  # Adjust based on your actual data range

plt.savefig('benchmark/plots/goroutine_cpu_app.pdf', dpi=300)
plt.show()

# 4. BPF Program CPU Usage (Stacked Bar Chart)
_, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)

bpf_pivot = bpf_agg.pivot(index='test_type', columns='program', values='cpu_percent')
bpf_pivot.plot(kind='bar', stacked=True, ax=ax, color=sns.color_palette("Set3", len(bpf_pivot.columns)), edgecolor='black')
ax.set_ylabel('BPF compute\noverhead [%]')
ax.set_xlabel(None)
ax.grid(axis='y', linestyle='--', alpha=0.7)
ax.set_axisbelow(True)
ax.xaxis.set_tick_params(rotation=0)
ax.legend(bbox_to_anchor=(1, 1), loc='lower right', ncol=2, frameon=False, columnspacing=0.5, borderaxespad=0.1)

plt.savefig('benchmark/plots/goroutine_cpu_bpf.pdf', dpi=300)
plt.show()
