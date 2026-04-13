from enum import IntEnum

import matplotlib.pyplot as plt
import matplotlib.pylab as pylab

from matplotlib.axes import Axes
from matplotlib import transforms
from matplotlib.ticker import FuncFormatter
import numpy as np
import pylab
import itertools

plots_dir = "benchmark/plots"
instance="latest"
results_paths = f'benchmark/results/hotel-qps-cpu/{instance}/exec_cpu.out'

class TestNum(IntEnum):
    SAMP_1_BEYLA = 1
    SAMP_10_BEYLA = 2
    SAMP_100_BEYLA = 3
    NO_SAMP_DEEPFLOW = 4
    PLAIN = 5
    SAMP_1_CS = 6
    SAMP_10_CS = 7
    SAMP_100_CS = 8

# Parse results from files
def parse_results(results_path, n_tests) -> dict[int, dict[str, float]]:

    # if multiple experiments are provided, they will be concatenated (e.g., test 1 of experiment 2 will be at index N_TEST)
    results_: dict[int, dict[str, float]] = {}
    current_test = 0
    sub_prog = False
    node = 'Node 1'

    with open(results_path, 'r') as file:
        for line in file:
            line = line.strip()

            # Check if line is a header
            if f'[Test {(current_test%n_tests) + 1}]' in line:
                # Start new section
                current_test += 1
                results_[current_test] = {}

            # Set node
            elif '[' in line and ']:' in line:
                node = line.replace('[', '').replace(']:', '')

            # Add content to current section
            elif 'Requests per second:' in line:
                rps = float(line.split(':')[1].split()[0])
                results_[current_test]['RPS'] = rps
            elif 'Time per request:' in line:
                time = float(line.split(':')[1].split()[0])
                results_[current_test]['Time per request'] = time
            elif 'Transfer rate:' in line:
                rate = float(line.split(':')[1].split()[0])
                results_[current_test]['Throughput'] = rate
            elif 'bpf_prog_' in line:
                l = line.split()
                l = l if l[0] != '-' else l[1:]
                prog = l[2][1:-1]
                cpu = float(l[0][:-1])
                results_[current_test][f'{node}:{prog}{":sub" if sub_prog else ""}'] = cpu
            elif 'TOTAL' in line:
                results_[current_test][f'{node}:total'] = float(line.split()[0][:-1])
            elif 'bpf programs:' in line:
                sub_prog = False
            elif 'of which:' in line:
                sub_prog = True
    return results_

N_TESTS = len(TestNum)
results = parse_results(results_paths, N_TESTS)

# style
plt.rcdefaults()
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
default_palette = plt.rcParams['axes.prop_cycle']

def custom_formatter(x, pos):
    if x < 1000:
        return str(int(x))
    else:
        x_in_k = x / 1000
        return f'{int(round(x_in_k))}K'

def plot_line(
        ax: Axes,
        data_: list[list[float]],
        x_values: list[list[float]],
        baselines_data: list[float],
        baselines_labels: list[str],
        labels: list[str],
        y_label: str,
        x_label: str,
        legend_col=1,
        padding=1.3,
        palette: str=None
) -> None:
    if palette:
        color_cycle = itertools.cycle(plt.get_cmap(palette).colors)
        colors = color_cycle
    else:
        color_cycle = itertools.cycle(pylab.rcParams['axes.prop_cycle'].by_key()['color'])
        colors = color_cycle

    for x, y, label, marker in zip(x_values, data_, labels, ['o', 's', '^', 'D', '*', 'x', '+', 'v', '<', '>']):
        ax.plot(x, y, label=label, marker=marker, color=next(colors))

    for baseline, label, style, color in zip(baselines_data, baselines_labels, ['--', '-.'], ['black', 'tab:red']):
        ax.axhline(y=baseline, color=color, linestyle=style, label=label)

    ax.legend(ncol=legend_col,
              columnspacing=0.5 if legend_col > 1 else None,
              handletextpad=0.5 if legend_col > 1 else None,
              borderaxespad=0.3 if legend_col > 1 else None,
              borderpad=0.3 if legend_col > 1 else None,
              frameon=False,)
    ax.grid(axis='y', linestyle='--', alpha=0.7)

    ax.set_xlabel(x_label, linespacing=1.5)
    ax.set_ylabel(y_label, linespacing=1.5)
    ax.set_xscale('log')
    ax.yaxis.set_major_formatter(FuncFormatter(custom_formatter))

    if padding > 0:
        max_value=max(max([max(d) for d in data_]), max(baselines_data))
        ax.set_ylim(0, max_value*padding)
    if palette:
        plt.rcParams['axes.prop_cycle'] = default_palette

    ax.grid(axis='y', linestyle='--', alpha=0.7)
    ax.set_axisbelow(True)

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
    max_value = max([max([max(sub) for sub in group]) for group in data_])

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

# cpu bpf
node1 = 'Frontend'
deepflow = [
    results[TestNum.NO_SAMP_DEEPFLOW][f'{node1}:total'],
    float(np.mean([results[TestNum.NO_SAMP_DEEPFLOW][f'{n}:total'] for n in [k.split(':')[0] for k in results[TestNum.NO_SAMP_DEEPFLOW].keys() if ':' in k]]))
]

data = [
    # Frontend node
    [
        [results[TestNum.SAMP_1_BEYLA][f'{node1}:total'], results[TestNum.SAMP_1_CS][f'{node1}:total']],  # sampling 1
        [results[TestNum.SAMP_10_BEYLA][f'{node1}:total'], results[TestNum.SAMP_10_CS][f'{node1}:total']],   # sampling .1
        [results[TestNum.SAMP_100_BEYLA][f'{node1}:total'], results[TestNum.SAMP_100_CS][f'{node1}:total']]   # sampling .01
    ],
    # All nodes (mean)
    [
        [float(np.mean([results[TestNum.SAMP_1_BEYLA][f'{n}:total'] for n in [k.split(':')[0] for k in results[TestNum.SAMP_1_BEYLA].keys() if ':' in k]])), float(np.mean([results[TestNum.SAMP_1_CS][f'{n}:total'] for n in [k.split(':')[0] for k in results[TestNum.SAMP_1_CS].keys() if ':' in k]]))],
        [float(np.mean([results[TestNum.SAMP_10_BEYLA][f'{n}:total'] for n in [k.split(':')[0] for k in results[TestNum.SAMP_10_BEYLA].keys() if ':' in k]])), float(np.mean([results[TestNum.SAMP_10_CS][f'{n}:total'] for n in [k.split(':')[0] for k in results[TestNum.SAMP_10_CS].keys() if ':' in k]]))],
        [float(np.mean([results[TestNum.SAMP_100_BEYLA][f'{n}:total'] for n in [k.split(':')[0] for k in results[TestNum.SAMP_100_BEYLA].keys() if ':' in k]])), float(np.mean([results[TestNum.SAMP_100_CS][f'{n}:total'] for n in [k.split(':')[0] for k in results[TestNum.SAMP_100_CS].keys() if ':' in k]]))]
    ]
]

fig, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)
plot_hierarchical_bars_with_baseline(
    ax,
    data_=data,
    labels=['Beyla', 'ChainScope'],
    x_names=['Frontend node', 'All nodes (mean)'],
    subgroup_names=['1', '.1', '.01'],
    baseline_data=deepflow,
    baseline_label='DeepFlow',
    y_label='BPF compute\noverhead [%]',
    x_label='Sampling rate',
    bar_label=" {:.2f}% ",
    legend_col=2,
    colors='tab10',
    padding=4

)

plt.savefig(f'{plots_dir}/hotel.cpu.bpf.pdf')

plt.show()

# throughput
plain_app = results[TestNum.PLAIN]['RPS']
deepflow = results[TestNum.NO_SAMP_DEEPFLOW]['RPS']
#sampling_values = [0.001, 0.01, 0.1, 1]
sampling_values = [0.01, 0.1, 1]
sampling_beyla_data = [results[TestNum.SAMP_100_BEYLA]['RPS'], results[TestNum.SAMP_10_BEYLA]['RPS'], results[TestNum.SAMP_1_BEYLA]['RPS']]
# sampling_beyla_pp_data = [results[TestNum.SAMP_100_BEYLA_PP]['RPS'], results[TestNum.SAMP_10_BEYLA_PP]['RPS'], results[TestNum.SAMP_1_BEYLA_PP]['RPS']]
sampling_chainscope_data = [results[TestNum.SAMP_100_CS]['RPS'], results[TestNum.SAMP_10_CS]['RPS'], results[TestNum.SAMP_1_CS]['RPS']]

fig, ax = plt.subplots(1, 1, figsize=(6, 3.5), constrained_layout=True)
# plot_line(ax,
#           data_=[sampling_beyla_data, sampling_chainscope_data, sampling_beyla_pp_data],
#           x_values=[sampling_values, sampling_values, sampling_values],
#           baselines_data=[plain_app, deepflow],
#           baselines_labels=['app baseline', 'DeepFlow'],
#           labels=['Beyla', 'ChainScope', 'Enhanced Beyla'],
#           x_label='Sampling rate',
#           y_label='Requests per second',
#           legend_col=2,
#           palette='tab10')
plot_line(ax,
          data_=[sampling_beyla_data, sampling_chainscope_data],
          x_values=[sampling_values, sampling_values],
          baselines_data=[plain_app, deepflow],
          baselines_labels=['app baseline', 'DeepFlow'],
          labels=['Beyla', 'ChainScope'],
          x_label='Sampling rate',
          y_label='Requests per second',
          legend_col=2,
          palette='tab10')
plt.savefig(f'{plots_dir}/hotel.rps.pdf')

plt.show()
