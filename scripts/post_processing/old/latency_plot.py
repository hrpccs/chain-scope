# TRANSLATED FROM CHINESE:
# Description: This script is used to view the latency of the data
# There is now a csv file with each line of data representing the start of a single request at a different time node in
# seconds and a header, sample data is below:
# time_namelookup,time_connect,time_pretransfer,time_starttransfer,time_total
# 0.005570,0.000000,0.000000,0.000000,0.005748
# 0.003825,0.003942,0.003985,0.008078,0.008198
# 0.007044,0.007148,0.007204,0.197939,0.198019

# Now you need to read this csv file and calculate the following latency for a single request
# DNS parse delay:              time_namelookup
# TCP connection delay:         time_connect - time_namelookup
# HTTP request response delay:  time_total - time_pretransfer
# total delay:                  time_total - time_namelookup

# Then the data are counted separately for several delay metrics to get a CFG (Cumulative Frequency Graph) plot of delay
# with delay on the horizontal axis and cumulative frequency on the vertical axis, respectively, as shown in the
# following figure:

import pandas as pd
import matplotlib.pyplot as plt


"""
Reads a csv file and converts it to a DataFrame object:
"""
def clean_data(df):
    # Calculate the required latency and add it to the DataFrame
    df['dns_latency'] = df['time_namelookup']
    df['tcp_latency'] = df['time_connect'] - df['time_namelookup']
    df['http_latency'] = df['time_total'] - df['time_pretransfer']
    df['total_latency'] = df['time_total'] - df['time_namelookup']

    # Converting seconds to milliseconds
    df['dns_latency'] *= 1000
    df['tcp_latency'] *= 1000
    df['http_latency'] *= 1000
    df['total_latency'] *= 1000

    # Remove the top 1% of data
    df = df[df['total_latency'] < df['total_latency'].quantile(0.95)]
    # Remove the lowest 1% of data
    df = df[df['total_latency'] > df['total_latency'].quantile(0.05)]

df_sampling = pd.read_csv('with_agent_sampling.csv')
df_no_agent = pd.read_csv('without_agent.csv')
df_demo_v2 = pd.read_csv('with_agent_demo_v2.csv')

clean_data(df_sampling)
clean_data(df_no_agent)
clean_data(df_demo_v2)

# Print out the maximum value of each group of data
print(df_sampling['total_latency'].max())
print(df_no_agent['total_latency'].max())
print(df_demo_v2['total_latency'].max())

# CFG plotting
fig, ax = plt.subplots()
ax.hist(df_sampling['total_latency'], cumulative=False, density=True, bins=100, label='With Agent - sample by 2')
ax.hist(df_no_agent['total_latency'], cumulative=False, density=True, bins=100, alpha=0.7, label='Without Agent')
ax.hist(df_demo_v2['total_latency'], cumulative=False, density=True, bins=100, alpha=0.5, label='With Agent - demo v2')
ax.legend(loc='upper right')
ax.set_xlabel('Latency (ms)')
ax.set_ylabel('Frequency')
plt.savefig('latency.pdf')
