import re
import pandas as pd
import matplotlib.pyplot as plt
import seaborn as sns
import numpy as np
import pylab
import itertools
from matplotlib.lines import Line2D
from matplotlib.axes import Axes
from matplotlib import transforms
from matplotlib.ticker import FuncFormatter

# Read performance test results file
instance = 'latest'
file_path = f'benchmark/results/hotel/{instance}/loss.out'

with open(file_path, 'r') as file:
    content = file.read()

# Split file content by test scenarios
test_pattern = r'\[Test \d+\].*?(?=\[Test \d+\]|$)'
tests = re.findall(test_pattern, content, re.DOTALL)

print(f"Found {len(tests)} test scenarios")

def custom_formatter(x, pos):
    if x < 1000:
        return str(int(x))
    else:
        x_in_k = x / 1000
        return f'{int(round(x_in_k))}K'

def calculate_traffic_loss_rates_by_type(df):
    """
    Calculate traffic loss rates with different formulas for application injection and ip tagging
    """
    # Make a copy to avoid modifying the original dataframe
    result_df = df.copy()

    # Initialize columns with NaN
    loss_columns = [
        'intra_node_traffic_count', 'inter_node_traffic_count',
        'intra_node_loss_count', 'inter_node_loss_count',
        'intra_node_loss_rate', 'inter_node_loss_rate'
    ]

    for col in loss_columns:
        result_df[col] = np.nan

    # Calculate for ip tagging
    ip_tagging_mask = result_df['test_type'] == 'ip_tagging'
    if ip_tagging_mask:
        # # intra-node-arrived-but-not-used-loss = pnode->metric_tcp_recv_total_streams_count - pnode->metric_total_parse_streams_count
        # intra_node_arrived_but_not_used_loss = \
        #     result_df[ 'pnode_metric_tcp_recv_total_streams_count'] - \
        #     result_df[ 'pnode_metric_total_parse_streams_count']
        # result_df[ 'intra_node_arrived_but_not_used_loss'] = intra_node_arrived_but_not_used_loss


        # # inter-node-arrived-but-not-used-loss = node->metric_tcp_recv_total_streams_count - node->metric_total_parse_streams_count
        # inter_node_arrived_but_not_used_loss = \
        #     result_df[ 'node_metric_tcp_recv_total_streams_count'] - \
        #     result_df[ 'node_metric_total_parse_streams_count']
        # result_df[ 'inter_node_arrived_but_not_used_loss'] = inter_node_arrived_but_not_used_loss


        # # intra-node-merge-loss = pnode->metric_trace_count - pnode->metric_tcp_recv_total_streams_count
        # intra_node_merge_loss = \
        #     result_df[ 'pnode_metric_total_send_streams_count']/2 - \
        #     result_df[ 'pnode_metric_tcp_recv_total_streams_count']

        # # turn negative values to zero
        # intra_node_merge_loss = np.maximum(intra_node_merge_loss, 0)
        # result_df[ 'intra_node_merge_loss'] = intra_node_merge_loss

        # # inter-node-merge-loss = metric_rpc_drop_at_merge - intra-node-merge-loss + node.metric_rpc_drop_at_merge
        # inter_node_merge_loss = \
        #     result_df[ 'pnode_metric_rpc_drop_at_merge'] - \
        #     intra_node_merge_loss + \
        #     result_df[ 'node_metric_rpc_drop_at_merge']
        # result_df[ 'inter_node_merge_loss'] = inter_node_merge_loss

        # # intra-node-traffic-count = pnode->metric_trace_count
        # result_df[ 'intra_node_traffic_count'] = \
        #     result_df[ 'pnode_metric_trace_count']

        # # inter-node-traffic-count = pnode->metric_total_send_streams_count - intra-node-traffic-count
        # result_df[ 'inter_node_traffic_count'] = \
        #     result_df[ 'pnode_metric_total_send_streams_count'] - \
        #     result_df[ 'intra_node_traffic_count']

        # # inter-node-propagation-count (needed for propagation loss)
        # inter_node_propagation_count = \
        #     result_df[ 'pnode_metric_tcp_send_total_streams_count'] - \
        #     result_df[ 'pnode_metric_tcp_recv_total_streams_count']

        # # inter-node-propagation-loss = inter-node-propagation-count - pnode.metric_total_ip_tagging_streams_count
        # inter_node_propagation_loss = \
        #     inter_node_propagation_count - \
        #     result_df[ 'pnode_metric_total_ip_tagging_streams_count']

        # result_df[ 'inter_node_propagation_loss'] = \
        #     inter_node_propagation_loss
        # # intra-node-propagation-loss = 0
        # intra_node_propagation_loss = 0
        # result_df[ 'intra_node_propagation_loss'] = \
        #     intra_node_propagation_loss

        # inter-node-loss-count = pnode_metric_rpc_drop_at_ip_tagging_non_split
        # intra-node-loss-count = pnode_metric_rpc_drop_at_merge
        # total = pnode_metric_total_send_streams_count
        result_df[ 'inter_node_loss_count'] = \
            result_df[ 'pnode_metric_rpc_drop_at_ip_tagging_non_split']

        result_df[ 'intra_node_loss_count'] = \
            result_df[ 'pnode_metric_rpc_drop_at_merge']

        result_df['total_traffic_count'] = result_df[ 'pnode_metric_total_send_streams_count']

        result_df[ 'inter_node_loss_rate'] =  result_df[ 'inter_node_loss_count'] / result_df[ 'total_traffic_count']

        result_df[ 'intra_node_loss_rate'] = result_df[ 'intra_node_loss_count'] / result_df[ 'total_traffic_count']
        result_df['intra_node_loss_rate_pct'] = result_df['intra_node_loss_rate'] * 100
        result_df['inter_node_loss_rate_pct'] = result_df['inter_node_loss_rate'] * 100

        # turn to 0 if smaller than 0.1, for the loss_rate_pct
        result_df['intra_node_loss_rate_pct'] = np.where(result_df['intra_node_loss_rate_pct'] < 0.1, 0, result_df['intra_node_loss_rate_pct'])
        result_df['inter_node_loss_rate_pct'] = np.where(result_df['inter_node_loss_rate_pct'] < 0.1, 0, result_df['inter_node_loss_rate_pct'])

        result_df['total_loss_rate_pct'] = (result_df['intra_node_loss_rate_pct'] + result_df['inter_node_loss_rate_pct'])
        result_df['accuracy'] = 100 - (result_df['intra_node_loss_rate_pct'] + result_df['inter_node_loss_rate_pct'])

    return result_df

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

    # Extract sampling_rate and concurrency from description
    sampling_match = re.search(r'sampling_rate=([0-9.]+)', test_content)
    concurrency_match = re.search(r'concurrency=(\d+)', test_content)

    if sampling_match:
        result['sampling_rate'] = float(sampling_match.group(1))
    if concurrency_match:
        result['concurrency'] = int(concurrency_match.group(1))

    # Extract test type (application injection or ip tagging)
    if "application injection" in result['description']:
        result['test_type'] = "application_injection"
    elif "ip tagging" in result['description']:
        result['test_type'] = "ip_tagging"
    elif "beyla" in result['description']:
        result['test_type'] = "beyla"
    elif "deepflow" in result['description']:
        result['test_type'] = "deepflow"
    else:
        result['test_type'] = "unknown"

    skipped_match = re.search('Test skipped', test_content)
    if skipped_match:
        result['skipped'] = True
    else:
        result['skipped'] = False

    if result['skipped']:
        return result

    if result['test_type'] == 'application_injection' or result['test_type'] == 'ip_tagging':
        # Extract metrics for pnode
        pnode_metrics = {}
        pnode_pattern = r'\[pnode\]:\s*\n((?:\s+\"[^\"]+\":\s*\d+\s*\n)*)'
        pnode_match = re.search(pnode_pattern, test_content, re.MULTILINE)
        if pnode_match:
            metrics_text = pnode_match.group(1)
            metric_pattern = r'\"([^\"]+)\":\s*(\d+)'
            for metric_match in re.finditer(metric_pattern, metrics_text):
                metric_name = metric_match.group(1)
                metric_value = int(metric_match.group(2))
                pnode_metrics[metric_name] = metric_value

        # Add pnode metrics to result with prefix
        for key, value in pnode_metrics.items():
            result[f'pnode_{key}'] = value

        # Extract metrics for node
        node_metrics = {}
        node_pattern = r'\[node\]:\s*\n((?:\s+\"[^\"]+\":\s*\d+\s*\n)*)'
        node_match = re.search(node_pattern, test_content, re.MULTILINE)
        if node_match:
            metrics_text = node_match.group(1)
            metric_pattern = r'\"([^\"]+)\":\s*(\d+)'
            for metric_match in re.finditer(metric_pattern, metrics_text):
                metric_name = metric_match.group(1)
                metric_value = int(metric_match.group(2))
                node_metrics[metric_name] = metric_value

        # Add node metrics to result with prefix
        for key, value in node_metrics.items():
            result[f'node_{key}'] = value
        return calculate_traffic_loss_rates_by_type(result)
    elif result['test_type'] == 'beyla':
        intra_node_loss_count_match = re.search(r'intra_node_loss_count: (\d+)', test_content)
        if intra_node_loss_count_match:
            result['intra_node_loss_count'] = int(intra_node_loss_count_match.group(1))
        inter_node_loss_count_match = re.search(r'inter_node_loss_count: (\d+)', test_content)
        if inter_node_loss_count_match:
            result['inter_node_loss_count'] = int(inter_node_loss_count_match.group(1))
        total_match = re.search(r'total: (\d+)', test_content)
        if total_match:
            result['total'] = int(total_match.group(1))

        result['intra_node_loss_rate_pct'] = result['intra_node_loss_count'] * 100.0 / result['total']
        result['inter_node_loss_rate_pct'] = result['inter_node_loss_count'] * 100.0 / result['total']
        accuracy_match = re.search(r'accuracy: (\d+\.\d+)', test_content)
        if accuracy_match:
            result['accuracy'] = float(accuracy_match.group(1))
        result['total_loss_rate_pct'] =100 - result['accuracy']
    elif result['test_type'] == 'deepflow':
        intra_node_loss_count_match = re.search(r'intra_node_loss_count: (\d+)', test_content)
        if intra_node_loss_count_match:
            result['intra_node_loss_count'] = int(intra_node_loss_count_match.group(1))
        inter_node_loss_count_match = re.search(r'inter_node_loss_count: (\d+)', test_content)
        if inter_node_loss_count_match:
            result['inter_node_loss_count'] = int(inter_node_loss_count_match.group(1))
        total_match = re.search(r'total: (\d+)', test_content)
        if total_match:
            result['total'] = int(total_match.group(1))

        recommendation_total_match = re.search(r'recommendation_total (\d+)', test_content)
        if recommendation_total_match:
            result['recommendation_total'] = int(recommendation_total_match.group(1))
        
        profile_total_match = re.search(r'profile_total (\d+)', test_content)
        if profile_total_match:
            result['profile_total'] = int(profile_total_match.group(1))
        

        # print(result)
        result['intra_node_loss_rate'] = result['intra_node_loss_count'] * 1.0 / result['profile_total']
        result['inter_node_loss_rate'] = result['inter_node_loss_count'] * 1.0 / result['recommendation_total']
        result['correct_rate'] = (1.0-result['intra_node_loss_rate']) * (1.0-result['inter_node_loss_rate'])
        result['total_loss_rate'] = 1.0 - result['correct_rate']
        result['total_loss_rate_pct'] =result['total_loss_rate'] * 100
        result['intra_node_loss_rate_pct'] = result['intra_node_loss_rate'] * 100
        result['inter_node_loss_rate_pct'] = result['inter_node_loss_rate'] * 100
        

    # calculate accuracy from metric for ip tagging/application injection
    return result

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

# Parse all test scenarios
test_results = [parse_test_scenario(test) for test in tests]

# Create DataFrame
df = pd.DataFrame(test_results)

# Save DataFrame to CSV for further analysis
df.to_csv('hotel_benchmark_data.csv', index=False)
print("\nDataFrame saved to hotel_benchmark_data.csv")

# Filter data for the first plot (fixed sampling rates)
sampling_rates = [1, 0.1, 0.01]
concurrency_values = [1, 10, 100, 500, 1000]

# Set up the figure
_, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)

# Plot 1: Total Loss Rate vs Concurrency for different sampling rates

# Define colors and line styles
color_cycle = itertools.cycle(plt.get_cmap('tab10').colors)
colors = [next(color_cycle) for _ in sampling_rates]
markers = ['o', 's', 'D']
# line_styles = {'ip_tagging': '-', 'application_injection': '--', 'deepflow':'-.','beyla': ':'}
line_styles = {'ip_tagging': '-',  'deepflow':'-.','beyla': ':'}

for sr, color, marker in zip(sampling_rates, colors, markers):
    for test_type, ls in line_styles.items():
        subset = df[(df['sampling_rate'] == sr) & (df['test_type'] == test_type)]
        if not subset.empty:
            sns.lineplot(
                ax=ax,
                data=subset,
                x='concurrency',
                y='total_loss_rate_pct',
                label=None,
                color=color if test_type != 'deepflow' else 'tab:red',
                linestyle=ls,
                marker=marker,
                markersize=8,
            )

# First Legend (Sampling Rate)
legend_sr_handles = []
for sr, color, marker in zip(sampling_rates, colors, markers):
    # The comma in "line," is used to unpack the single-item list returned by plot
    line, = ax.plot([], [], color=color, marker=marker, markersize=8, label=f'{sr}')
    legend_sr_handles.append(line)
title_handle = Line2D([], [], color='none', label='sampling: ')
legend_sr_handles = [title_handle] + legend_sr_handles
legend_sr = ax.legend(handles=legend_sr_handles,
                      frameon=False,
                    #   loc='upper left',
                      bbox_to_anchor=(0.5, 0.1),
                      loc='lower center',
                      ncol=len(legend_sr_handles),
                      borderaxespad=0.7,
                      columnspacing=0.3,
                      handletextpad=0.2,
                      handlelength=1.0)
ax.add_artist(legend_sr)

# Second Legend (Method)
handle_beyla, = ax.plot([], [], color='black', linestyle=':', label='Beyla')
handle_ip, = ax.plot([], [], color='black', linestyle='-', label='ChainScope')
#handle_app, = ax.plot([], [], color='black', linestyle='--', label='Enhanced Beyla')
handle_deepflow, = ax.plot([], [], color='tab:red', linestyle='-.', label='Deepflow')
legend_method_handles = [handle_beyla, handle_ip, handle_deepflow]
_ = ax.legend(handles=legend_method_handles,
              loc='lower center',
              bbox_to_anchor=(0.5, 1.0),
              borderaxespad=0.1,
              ncols=3,
              columnspacing=0.5,
              handletextpad=0.5,
              frameon=False)

plt.xlabel('Concurrency')
plt.ylabel('Loss rate [%]')
ax.grid(axis='y', linestyle='--', alpha=0.7)
ax.set_axisbelow(True)

plt.savefig('benchmark/plots/grpc_loss.pdf', dpi=300)
plt.show()

# Plot 2: Inter-node and Intra-node Loss Rates vs Sampling Rate (fixed concurrency=1000)
_, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)

sampling_rates = [1, 0.1, 0.01]
fixed_concurrency_df = df[df['concurrency'] == 1000]
fixed_concurrency_df = fixed_concurrency_df[fixed_concurrency_df['sampling_rate'].isin(sampling_rates)]

# Define colors for loss types
loss_types = ['inter_node_loss_rate_pct', 'intra_node_loss_rate_pct']
color_cycle = itertools.cycle(plt.get_cmap('Set1').colors)
colors = {'deepflow':'tab:red','ip_tagging':'tab:orange','beyla':'tab:blue'}
markers = ['o', 's']
# line_styles = {'ip_tagging': '-', 'application_injection': '--', 'deepflow':'-.','beyla': ':'}
line_styles = {'inter_node_loss_rate_pct': '-', 'intra_node_loss_rate_pct': ':'}

fixed_concurrency_df['inter_node_loss_rate_pct'] = fixed_concurrency_df['inter_node_loss_rate_pct'].astype(float)
fixed_concurrency_df['intra_node_loss_rate_pct'] = fixed_concurrency_df['intra_node_loss_rate_pct'].astype(float)
deepflow_template = fixed_concurrency_df[fixed_concurrency_df['test_type'] == 'deepflow'].iloc[0]
df_without_deepflow = fixed_concurrency_df[fixed_concurrency_df['test_type'] != 'deepflow'].copy()
new_entries = []
for rate in sampling_rates:
    new_row = deepflow_template.copy()
    new_row['sampling_rate'] = rate
    new_entries.append(new_row)
new_entries_df = pd.DataFrame(new_entries)
fixed_concurrency_df = pd.concat([df_without_deepflow, new_entries_df], ignore_index=True)

for test_type, color in colors.items():
    subset = fixed_concurrency_df[fixed_concurrency_df['test_type'] == test_type]
    if not subset.empty:
        for loss_type, marker in zip(loss_types, markers):
            sns.lineplot(
                ax=ax,
                data=subset,
                x='sampling_rate',
                y=loss_type,
                label=None,
                color=color,
                linestyle=line_styles[loss_type],
                marker=marker,
                markersize=8,
            )

# First Legend (loss type)
legend_lt_handles = []
for loss_type, color, marker in zip(loss_types, colors, markers):
    # The comma in "line," is used to unpack the single-item list returned by plot
    line, = ax.plot([], [], linestyle=line_styles[loss_type], marker=marker, markersize=8, label=f'{loss_type.split("_")[0]}-node')
    legend_lt_handles.append(line)
legend_lt = ax.legend(handles=legend_lt_handles,
                      frameon=False)
ax.add_artist(legend_lt)

# Second Legend (Method)
handle_beyla, = ax.plot([], [], color='tab:blue', linestyle=':', label='Beyla')
handle_ip, = ax.plot([], [], color='tab:orange', linestyle='-', label='ChainScope')
# handle_app, = ax.plot([], [], color='black', linestyle='--', label='Enhanced Beyla')
handle_deepflow, = ax.plot([], [], color='tab:red', linestyle='-.', label='Deepflow')
legend_method_handles = [handle_beyla, handle_ip, handle_deepflow]
_ = ax.legend(handles=legend_method_handles,
              loc='lower center',
              bbox_to_anchor=(0.5, 1.0),
              borderaxespad=0.1,
              ncols=3,
              columnspacing=0.5,
              frameon=False)

plt.xlabel('Sampling rate')
plt.ylabel('Loss Rate [%]')
plt.xscale('log')
ax.grid(axis='y', linestyle='--', alpha=0.7)
ax.set_axisbelow(True)

plt.savefig('benchmark/plots/grpc_loss_diff.pdf', dpi=300)

plt.show()

def plot_hierarchical_bars_with_baseline(
        ax: Axes,
        data_: list[list[list[float]]],  # shape: N groups × K subgroups × len(labels)
        labels: list[str],               # len(labels) == number of bars inside each subgroup
        x_names: list[str],              # N x groups
        subgroup_names: list[str],       # names to display under subgroups
        baseline_data: list[float],      # one per x_names
        baseline_label: str,
        y_label: str,
        x_label: str=None,
        bar_label: str=None,
        legend_col=1,
        padding=1.3,
        colors: list[str]|str=None,       # optional: list of colors per label
        skip_colors: int=0
) -> None:
    """
    Plot: each x group split into K subgroups, each subgroup has len(labels) bars.
    All bars with the same label get the same color.
    """
    N = len(x_names)
    K = len(subgroup_names)
    num_labels = len(labels)

    # Compute bar and subgroup widths
    subgroup_margin_rate = .1
    bar_width = min(0.2 if N < 6 else 0.25, 1/(K*num_labels + 1))
    subgroup_width = num_labels * bar_width
    group_width = K * subgroup_width
    subgroup_margin = bar_width*subgroup_margin_rate
    bar_width = bar_width - subgroup_margin

    x_indices = np.arange(N)
    max_value = max(max([max([max(sub) for sub in group]) for group in data_]), max(baseline_data))

    label_font = min(230 / (1/bar_width * N), pylab.rcParams['legend.fontsize'])

    # Choose colors: if none, cycle default colors
    if colors is None:
        color_cycle = itertools.cycle(pylab.rcParams['axes.prop_cycle'].by_key()['color'])
        for _ in range(skip_colors):
            next(color_cycle)
        colors = [next(color_cycle) for _ in labels]
    elif type(colors) is str:
        color_cycle = itertools.cycle(plt.get_cmap(colors).colors)
        for _ in range(skip_colors):
            next(color_cycle)
        colors = [next(color_cycle) for _ in labels]

    # Loop over groups, subgroups and bars
    bar_positions = []
    bar_labels = []
    bar_colors = []

    for group_idx, x in enumerate(x_indices):
        group = data_[group_idx]
        for sub_idx, subgroup in enumerate(group):
            for bar_idx, value in enumerate(subgroup):
                # bar position inside the group
                bar_x = (x - group_width/2
                         + sub_idx * subgroup_width
                         + bar_idx * bar_width
                         + bar_width/2
                         + subgroup_margin)

                # Draw the bars
                ax.bar(
                    bar_x, value,
                    width=bar_width,
                    edgecolor='black',
                    color=colors[bar_idx],
                    label=labels[bar_idx] if group_idx==0 and sub_idx==0 else None
                )

                # numerical labels
                if bar_label:
                    in_bar_threshold = max_value*(padding if padding else 1)/(35/label_font)
                    c, v_align = ("white", "top") if value > in_bar_threshold else ("black", "bottom")
                    relative_offset_x = label_font * 0.3
                    text_offset = transforms.ScaledTranslation(relative_offset_x / 72, 0, ax.figure.dpi_scale_trans)
                    ax.text(
                        s=bar_label.format(value),
                        x=bar_x,
                        y=value,
                        c=c, size=label_font, fontweight='demibold',
                        verticalalignment=v_align, horizontalalignment='center',
                        rotation=90, transform=ax.transData + text_offset
                    )

                # collect positions for x-ticks
                bar_positions.append(bar_x)
                bar_labels.append(subgroup_names[sub_idx])
                bar_colors.append(colors[bar_idx])
        group_start = x - group_width / 2
        group_end = x + group_width / 2
        ax.hlines(y=baseline_data[group_idx], xmin=group_start, xmax=group_end, color='tab:red', linestyle='--', linewidth=2, label=baseline_label if group_idx == 0 else None)
        if legend_col == 2:
            for _ in range(len(labels)-1):
                ax.axhline(y=0, alpha=0, label=' ' if group_idx == 0 else None)

    # Set x-ticks under each subgroup
    # So total number of subgroups: N*K
    subgroup_centers = [
        (x - group_width/2 + sub_idx*subgroup_width + subgroup_width/2)
        for x in x_indices
        for sub_idx in range(K)
    ]
    subgroup_labels = subgroup_names * N  # repeat for each x group

    ax.set_xticks(subgroup_centers)
    ax.set_xticklabels(subgroup_labels, rotation=0)

    # Add a second x-axis level for x_names (web server, proxy)
    ax_secondary = ax.twiny()
    ax_secondary.set_xlim(ax.get_xlim())
    ax_secondary.set_xticks(x_indices)
    ax_secondary.set_xticklabels(x_names)
    ax_secondary.spines["bottom"].set_visible(False)
    ax_secondary.spines["top"].set_visible(False)
    ax_secondary.tick_params(bottom=False, labelbottom=False, top=True, labeltop=True)

    # Labels and grid
    ax.set_ylabel(y_label, linespacing=1.5)
    if x_label:
        ax.set_xlabel(x_label, linespacing=1.5)
    ax.yaxis.set_major_formatter(FuncFormatter(custom_formatter))
    ax.legend(ncol=legend_col,
              frameon=False,
              columnspacing=0.5 if legend_col > 1 else None,
              handletextpad=0.5 if legend_col > 1 else None,
              borderaxespad=0.3 if legend_col > 1 else None,
              borderpad=0.3 if legend_col > 1 else None,
              loc=None if legend_col > 1 else 'upper left')

    if padding > 0:
        ax.set_ylim(0, max_value * padding)
    ax.grid(axis='y', linestyle='--', alpha=0.7)
    ax.set_axisbelow(True)

deepflow = [
    df[(df['test_type'] == 'deepflow') & (df['concurrency'] == 5000)].reset_index().at[0, 'inter_node_loss_rate_pct'],
    df[(df['test_type'] == 'deepflow') & (df['concurrency'] == 5000)].reset_index().at[0, 'intra_node_loss_rate_pct']
]

data = [
    # inter-node
    [
        df[((df['test_type'] == 'beyla') | (df['test_type'] == 'ip_tagging')) & (df['concurrency'] == 5000) & (df['sampling_rate'] == 1)].sort_values('test_type', ascending=True)['inter_node_loss_rate_pct'].apply(lambda x: x.item() if hasattr(x, "item") else x).tolist(),  # sampling 1
        df[((df['test_type'] == 'beyla') | (df['test_type'] == 'ip_tagging')) & (df['concurrency'] == 5000) & (df['sampling_rate'] == 0.1)].sort_values('test_type', ascending=True)['inter_node_loss_rate_pct'].apply(lambda x: x.item() if hasattr(x, "item") else x).tolist(),   # sampling .1
        df[((df['test_type'] == 'beyla') | (df['test_type'] == 'ip_tagging')) & (df['concurrency'] == 5000) & (df['sampling_rate'] == 0.01)].sort_values('test_type', ascending=True)['inter_node_loss_rate_pct'].apply(lambda x: x.item() if hasattr(x, "item") else x).tolist()   # sampling .01
    ],
    # intra-node
    [
        df[((df['test_type'] == 'beyla') | (df['test_type'] == 'ip_tagging')) & (df['concurrency'] == 5000) & (df['sampling_rate'] == 1)].sort_values('test_type', ascending=True)['intra_node_loss_rate_pct'].apply(lambda x: x.item() if hasattr(x, "item") else x).tolist(),  # sampling 1
        df[((df['test_type'] == 'beyla') | (df['test_type'] == 'ip_tagging')) & (df['concurrency'] == 5000) & (df['sampling_rate'] == 0.1)].sort_values('test_type', ascending=True)['intra_node_loss_rate_pct'].apply(lambda x: x.item() if hasattr(x, "item") else x).tolist(),   # sampling .1
        df[((df['test_type'] == 'beyla') | (df['test_type'] == 'ip_tagging')) & (df['concurrency'] == 5000) & (df['sampling_rate'] == 0.01)].sort_values('test_type', ascending=True)['intra_node_loss_rate_pct'].apply(lambda x: x.item() if hasattr(x, "item") else x).tolist()   # sampling .01
    ],
]

fig, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)
plot_hierarchical_bars_with_baseline(
    ax,
    data_=data,
    labels=['Beyla', 'ChainScope'],
    x_names=['inter-node', 'intra-node'],
    subgroup_names=['1', '.1', '.01'],
    baseline_data=deepflow,
    baseline_label='DeepFlow',
    y_label='Loss rate [%]',
    x_label='Sampling rate',
    bar_label=" {:.2f}% ",
    legend_col=2,
    colors='tab10',
    padding=1.4
)

plt.savefig(f'benchmark/plots/grpc_loss_diff.bars.pdf')

plt.show()