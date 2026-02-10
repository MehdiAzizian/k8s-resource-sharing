#!/usr/bin/env python3
"""Generate evaluation charts from CSV results for presentation slides."""

import csv
import os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

RESULTS_DIR = os.path.join(os.path.dirname(__file__), 'results')
CHARTS_DIR = os.path.join(RESULTS_DIR, 'charts')
os.makedirs(CHARTS_DIR, exist_ok=True)

# Style
plt.rcParams.update({
    'figure.figsize': (10, 6),
    'font.size': 14,
    'axes.titlesize': 18,
    'axes.labelsize': 15,
    'xtick.labelsize': 13,
    'ytick.labelsize': 13,
    'legend.fontsize': 13,
    'figure.dpi': 150,
    'axes.grid': True,
    'grid.alpha': 0.3,
    'axes.spines.top': False,
    'axes.spines.right': False,
})
COLORS = ['#2196F3', '#FF5722', '#4CAF50', '#9C27B0', '#FF9800']


def read_csv(filename):
    path = os.path.join(RESULTS_DIR, filename)
    with open(path) as f:
        return list(csv.DictReader(f))


def chart1_broker_scalability():
    """Test 1: Broker CPU and Memory vs number of agents."""
    data = read_csv('1_broker_scalability.csv')
    agents = [int(r['agents']) for r in data]
    avg_cpu = [float(r['avg_cpu_percent']) for r in data]
    avg_mem = [float(r['avg_memory_mb']) for r in data]

    fig, ax1 = plt.subplots()
    ax1.set_xlabel('Number of Connected Agents')
    ax1.set_ylabel('Average CPU Usage (%)', color=COLORS[0])
    line1 = ax1.plot(agents, avg_cpu, 'o-', color=COLORS[0], linewidth=2.5,
                     markersize=8, label='Avg CPU %')
    ax1.tick_params(axis='y', labelcolor=COLORS[0])
    ax1.set_ylim(0, max(avg_cpu) * 1.3)

    ax2 = ax1.twinx()
    ax2.set_ylabel('Average Memory (MB)', color=COLORS[1])
    line2 = ax2.plot(agents, avg_mem, 's--', color=COLORS[1], linewidth=2.5,
                     markersize=8, label='Avg Memory MB')
    ax2.tick_params(axis='y', labelcolor=COLORS[1])
    ax2.set_ylim(0, max(avg_mem) * 1.5)
    ax2.spines['right'].set_visible(True)

    lines = line1 + line2
    labels = [l.get_label() for l in lines]
    ax1.legend(lines, labels, loc='upper left')

    ax1.set_title('Test 1: Broker Scalability')
    ax1.set_xticks(agents)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '1_broker_scalability.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 1 done")


def chart2_bandwidth():
    """Test 2: Agent bandwidth - summary bar."""
    data = read_csv('2_agent_bandwidth.csv')
    total_sent = int(data[-1]['cumulative_sent'])
    total_recv = int(data[-1]['cumulative_recv'])
    duration = int(data[-1]['elapsed_sec'])
    avg_rate_sent = total_sent / duration
    avg_rate_recv = total_recv / duration

    fig, ax = plt.subplots(figsize=(8, 5))
    bars = ax.bar(['Sent', 'Received'], [avg_rate_sent, avg_rate_recv],
                  color=[COLORS[0], COLORS[2]], width=0.5, edgecolor='white')
    for bar, val in zip(bars, [avg_rate_sent, avg_rate_recv]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 5,
                f'{val:.0f} B/s', ha='center', va='bottom', fontweight='bold', fontsize=14)

    ax.set_ylabel('Average Bandwidth (Bytes/sec)')
    ax.set_title('Test 2: Agent-Broker Bandwidth (5 min)')
    ax.set_ylim(0, max(avg_rate_sent, avg_rate_recv) * 1.3)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '2_agent_bandwidth.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 2 done")


def chart3_agent_footprint():
    """Test 3: Agent CPU and memory over time."""
    data = read_csv('3_agent_footprint.csv')
    elapsed = [int(r['elapsed_sec']) for r in data]
    cpu = [float(r['cpu_percent']) for r in data]
    mem = [float(r['memory_mb']) for r in data]

    avg_cpu = np.mean(cpu)
    avg_mem = np.mean(mem)

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))

    ax1.plot(elapsed, cpu, '-', color=COLORS[0], linewidth=1.5, alpha=0.7)
    ax1.axhline(y=avg_cpu, color=COLORS[1], linestyle='--', linewidth=2,
                label=f'Average: {avg_cpu:.2f}%')
    ax1.set_xlabel('Time (seconds)')
    ax1.set_ylabel('CPU Usage (%)')
    ax1.set_title('Agent CPU Usage')
    ax1.legend()
    ax1.set_ylim(-0.1, max(cpu) * 1.3)

    ax2.plot(elapsed, mem, '-', color=COLORS[2], linewidth=2)
    ax2.set_xlabel('Time (seconds)')
    ax2.set_ylabel('Memory (MB)')
    ax2.set_title('Agent Memory Usage')
    ax2.set_ylim(0, max(mem) * 1.3)

    fig.suptitle('Test 3: Single Agent Resource Footprint', fontsize=18, y=1.02)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '3_agent_footprint.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 3 done")


def chart4_reservation_latency():
    """Test 4: Reservation latency breakdown."""
    data = read_csv('4_reservation_latency.csv')
    resolve = [int(r['resolve_ms']) for r in data]
    provider = [int(r['provider_instruction_ms']) for r in data]
    total = [int(r['total_e2e_ms']) for r in data]

    avg_resolve = np.mean(resolve)
    avg_provider = np.mean(provider)
    avg_total = np.mean(total)
    instruction_time = avg_provider - avg_resolve

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5))

    # Left: bar chart of average breakdown
    categories = ['Broker\nDecision', 'Instruction\nDelivery', 'Total\nEnd-to-End']
    values = [avg_resolve, instruction_time, avg_total]
    colors = [COLORS[0], COLORS[2], COLORS[4]]
    bars = ax1.bar(categories, values, color=colors, width=0.6, edgecolor='white')
    for bar, val in zip(bars, values):
        if val > 1000:
            label = f'{val / 1000:.1f}s'
        else:
            label = f'{val:.0f}ms'
        ax1.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 500,
                 label, ha='center', va='bottom', fontweight='bold', fontsize=13)
    ax1.set_ylabel('Time (ms)')
    ax1.set_title('Average Latency Breakdown')

    # Right: resolve time per trial (the fast part)
    trials = list(range(1, len(resolve) + 1))
    ax2.bar(trials, resolve, color=COLORS[0], width=0.6, edgecolor='white')
    ax2.axhline(y=avg_resolve, color=COLORS[1], linestyle='--', linewidth=2,
                label=f'Average: {avg_resolve:.0f}ms')
    ax2.set_xlabel('Trial')
    ax2.set_ylabel('Resolve Time (ms)')
    ax2.set_title('Broker Decision Time per Trial')
    ax2.set_xticks(trials)
    ax2.legend()

    fig.suptitle('Test 4: End-to-End Reservation Latency', fontsize=18, y=1.02)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '4_reservation_latency.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 4 done")


def chart5_concurrent():
    """Test 5: Concurrent reservation performance."""
    data = read_csv('5_concurrent_reservations.csv')
    levels = [int(r['concurrent_requests']) for r in data]
    avg_ms = [int(r['avg_resolve_ms']) for r in data]
    min_ms = [int(r['min_resolve_ms']) for r in data]
    max_ms = [int(r['max_resolve_ms']) for r in data]

    fig, ax = plt.subplots()
    ax.plot(levels, avg_ms, 'o-', color=COLORS[0], linewidth=2.5, markersize=8, label='Average')
    ax.fill_between(levels, min_ms, max_ms, alpha=0.15, color=COLORS[0])
    ax.plot(levels, min_ms, 's--', color=COLORS[2], linewidth=1.5, markersize=6, label='Min')
    ax.plot(levels, max_ms, '^--', color=COLORS[1], linewidth=1.5, markersize=6, label='Max')

    ax.set_xlabel('Concurrent Requests')
    ax.set_ylabel('Resolution Time (ms)')
    ax.set_title('Test 5: Concurrent Reservation Performance')
    ax.set_xticks(levels)
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '5_concurrent_reservations.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 5 done")


def chart6_decision_accuracy():
    """Test 6: Decision accuracy table as figure."""
    data = read_csv('6_decision_accuracy.csv')

    fig, ax = plt.subplots(figsize=(11, 4))
    ax.axis('off')

    headers = ['Scenario', 'Requested', 'Chosen', 'Expected', 'Correct']
    table_data = []
    for r in data:
        req = f"{r['requested_cpu']} CPU, {r['requested_mem']}"
        correct = r['correct'].upper()
        table_data.append([
            r['scenario'].replace('_', ' ').title(),
            req,
            r['chosen_cluster'],
            r['expected_cluster'],
            correct
        ])

    table = ax.table(cellText=table_data, colLabels=headers, loc='center',
                     cellLoc='center')
    table.auto_set_font_size(False)
    table.set_fontsize(12)
    table.scale(1, 1.8)

    # Color header
    for j in range(len(headers)):
        table[0, j].set_facecolor('#2196F3')
        table[0, j].set_text_props(color='white', fontweight='bold')

    # Color correct/incorrect cells
    for i, row in enumerate(table_data):
        if row[-1] == 'YES':
            table[i + 1, 4].set_facecolor('#C8E6C9')
        else:
            table[i + 1, 4].set_facecolor('#FFCDD2')

    correct_count = sum(1 for r in data if r['correct'] == 'yes')
    total = len(data)
    ax.set_title(f'Test 6: Decision Accuracy ({correct_count}/{total} Correct)',
                 fontsize=18, pad=20)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '6_decision_accuracy.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 6 done")


def chart7_resource_exhaustion():
    """Test 7: Resource exhaustion over consecutive reservations."""
    data = read_csv('7_resource_exhaustion.csv')
    nums = [int(r['reservation_num']) for r in data]
    targets = [r['target_cluster'] for r in data]

    # Parse CPU values (e.g., "94550m" -> 94.55)
    cpu_after = []
    for r in data:
        val = r['available_cpu_after']
        if val.endswith('m'):
            cpu_after.append(float(val[:-1]) / 1000)
        else:
            cpu_after.append(float(val))

    # Separate by cluster
    a1_nums = [n for n, t in zip(nums, targets) if t == 'agent-1']
    a1_cpu = [c for c, t in zip(cpu_after, targets) if t == 'agent-1']
    a2_nums = [n for n, t in zip(nums, targets) if t == 'agent-2']
    a2_cpu = [c for c, t in zip(cpu_after, targets) if t == 'agent-2']

    fig, ax = plt.subplots()
    ax.plot(a1_nums, a1_cpu, 'o-', color=COLORS[0], linewidth=2, markersize=8, label='Agent-1')
    ax.plot(a2_nums, a2_cpu, 's-', color=COLORS[1], linewidth=2, markersize=8, label='Agent-2')

    ax.set_xlabel('Reservation Number')
    ax.set_ylabel('Available CPU (cores)')
    ax.set_title('Test 7: Resource Exhaustion Under Load')
    ax.set_xticks(nums)
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '7_resource_exhaustion.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 7 done")


def chart8_freshness():
    """Test 8: Advertisement freshness delay."""
    data = read_csv('8_advertisement_freshness.csv')
    trials = [int(r['trial']) for r in data]
    delays = [int(r['delay_ms']) for r in data]

    avg_delay = np.mean(delays)

    fig, ax = plt.subplots(figsize=(8, 5))
    bars = ax.bar(trials, delays, color=COLORS[0], width=0.6, edgecolor='white')
    ax.axhline(y=avg_delay, color=COLORS[1], linestyle='--', linewidth=2,
               label=f'Average: {avg_delay:.0f}ms')

    for bar, val in zip(bars, delays):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 30,
                f'{val}ms', ha='center', va='bottom', fontsize=12)

    ax.set_xlabel('Trial')
    ax.set_ylabel('Propagation Delay (ms)')
    ax.set_title('Test 8: Advertisement Freshness')
    ax.set_xticks(trials)
    ax.legend()
    ax.set_ylim(0, max(delays) * 1.3)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '8_advertisement_freshness.png'), bbox_inches='tight')
    plt.close()
    print("  Chart 8 done")


def summary_table():
    """Generate an overall summary chart."""
    fig, ax = plt.subplots(figsize=(12, 5))
    ax.axis('off')

    headers = ['Test', 'Metric', 'Key Result']
    table_data = [
        ['1. Broker Scalability', 'CPU & Memory vs Agents', '~0.23% CPU/agent, ~40MB constant RAM'],
        ['2. Agent Bandwidth', 'Network overhead', '~233 B/s sent, ~229 B/s received'],
        ['3. Agent Footprint', 'Single agent resources', '~0.3% avg CPU, 41.25 MB RAM'],
        ['4. Reservation Latency', 'End-to-end timing', '~182ms broker decision, ~53s total e2e'],
        ['5. Concurrent Requests', 'Scalability under load', '79ms@1 req, 720ms@10 concurrent'],
        ['6. Decision Accuracy', 'Correct cluster selection', '5/6 scenarios correct'],
        ['7. Resource Exhaustion', 'Sustained reservations', '15/15 successful, balanced distribution'],
        ['8. Adv. Freshness', 'Propagation delay', '~1.65s average delay'],
    ]

    table = ax.table(cellText=table_data, colLabels=headers, loc='center',
                     cellLoc='left', colWidths=[0.25, 0.25, 0.50])
    table.auto_set_font_size(False)
    table.set_fontsize(12)
    table.scale(1, 1.8)

    for j in range(len(headers)):
        table[0, j].set_facecolor('#2196F3')
        table[0, j].set_text_props(color='white', fontweight='bold')

    for i in range(1, len(table_data) + 1):
        color = '#F5F5F5' if i % 2 == 0 else 'white'
        for j in range(len(headers)):
            table[i, j].set_facecolor(color)

    ax.set_title('Evaluation Results Summary', fontsize=20, pad=20)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '0_summary.png'), bbox_inches='tight')
    plt.close()
    print("  Summary table done")


if __name__ == '__main__':
    print("Generating evaluation charts...")
    summary_table()
    chart1_broker_scalability()
    chart2_bandwidth()
    chart3_agent_footprint()
    chart4_reservation_latency()
    chart5_concurrent()
    chart6_decision_accuracy()
    chart7_resource_exhaustion()
    chart8_freshness()
    print(f"\nAll charts saved to: {CHARTS_DIR}/")
