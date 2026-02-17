#!/usr/bin/env python3
"""Generate evaluation charts from CSV results (synchronous architecture, 7 tests)."""

import csv
import os
from collections import defaultdict

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import numpy as np

RESULTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'results')
CHARTS_DIR = os.path.join(RESULTS_DIR, 'charts')
os.makedirs(CHARTS_DIR, exist_ok=True)

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
    with open(os.path.join(RESULTS_DIR, filename)) as f:
        return list(csv.DictReader(f))


# ── Test 1a: Broker CPU vs Agents ──────────────────────────
def chart_1a():
    data = read_csv('1a_broker_cpu.csv')
    agents = [int(r['agents']) for r in data]
    avg_cpu = [float(r['avg_cpu_percent']) for r in data]
    max_cpu = [float(r['max_cpu_percent']) for r in data]
    min_cpu = [float(r['min_cpu_percent']) for r in data]

    fig, ax = plt.subplots()
    ax.plot(agents, avg_cpu, 'o-', color=COLORS[0], linewidth=2.5, markersize=7, label='Average CPU %')
    ax.fill_between(agents, min_cpu, max_cpu, alpha=0.15, color=COLORS[0], label='Min–Max range')
    ax.set_xlabel('Number of Connected Agents')
    ax.set_ylabel('Broker CPU Usage (%)')
    ax.set_title('Test 1a: Broker CPU Scalability (1–100 Agents)')
    ax.legend()
    ax.set_xlim(0, 105)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '1a_broker_cpu.png'), bbox_inches='tight')
    plt.close(fig)
    print('  1a_broker_cpu.png')


# ── Test 1b: Broker Memory vs Agents ──────────────────────
def chart_1b():
    data = read_csv('1b_broker_memory.csv')
    agents = [int(r['agents']) for r in data]
    avg_mem = [float(r['avg_memory_mb']) for r in data]
    max_mem = [float(r['max_memory_mb']) for r in data]
    min_mem = [float(r['min_memory_mb']) for r in data]

    fig, ax = plt.subplots()
    ax.plot(agents, avg_mem, 's-', color=COLORS[2], linewidth=2.5, markersize=7, label='Average Memory (MB)')
    ax.fill_between(agents, min_mem, max_mem, alpha=0.15, color=COLORS[2], label='Min–Max range')
    ax.set_xlabel('Number of Connected Agents')
    ax.set_ylabel('Broker Memory (MB)')
    ax.set_title('Test 1b: Broker Memory Scalability (1–100 Agents)')
    ax.legend()
    ax.set_xlim(0, 105)
    ax.set_ylim(25, 55)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '1b_broker_memory.png'), bbox_inches='tight')
    plt.close(fig)
    print('  1b_broker_memory.png')


# ── Test 1c: Resource Exhaustion ───────────────────────────
def chart_1c():
    data = read_csv('1c_resource_exhaustion.csv')
    nums = [int(r['reservation_num']) for r in data]
    targets = [r['target_cluster'] for r in data]
    colors = [COLORS[0] if t == 'agent-1' else COLORS[4] for t in targets]

    fig, ax = plt.subplots(figsize=(10, 4))
    ax.bar(nums, [1] * len(nums), color=colors, edgecolor='white', linewidth=0.5)
    ax.set_xlabel('Reservation Number')
    ax.set_yticks([])
    ax.set_title('Test 1c: Resource Exhaustion – Cluster Assignment')
    ax.set_xticks(nums)
    p1 = mpatches.Patch(color=COLORS[0], label='agent-1 (8 reservations)')
    p2 = mpatches.Patch(color=COLORS[4], label='agent-2 (7 reservations)')
    ax.legend(handles=[p1, p2])
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '1c_resource_exhaustion.png'), bbox_inches='tight')
    plt.close(fig)
    print('  1c_resource_exhaustion.png')


# ── Test 2: Agent Bandwidth ───────────────────────────────
def chart_2():
    data = read_csv('2_agent_bandwidth.csv')
    elapsed = [int(r['elapsed_sec']) for r in data]
    cumulative = [int(r['bytes_sent_cumulative']) for r in data]
    interval = [int(r['bytes_sent_interval']) for r in data]

    total_bytes = cumulative[-1]
    duration = elapsed[-1]
    avg_rate = total_bytes / duration

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))

    ax1.plot(elapsed, [c / 1024 for c in cumulative], 'o-', color=COLORS[0], linewidth=2.5, markersize=7)
    ax1.set_xlabel('Elapsed Time (s)')
    ax1.set_ylabel('Cumulative Bytes Sent (KB)')
    ax1.set_title('Cumulative Bandwidth')

    ax2.bar(elapsed, [i / 1024 for i in interval], width=20, color=COLORS[2], edgecolor='white')
    ax2.set_xlabel('Elapsed Time (s)')
    ax2.set_ylabel('Bytes per 30 s Interval (KB)')
    ax2.set_title('Per-Interval Bandwidth')

    fig.suptitle(f'Test 2: Agent Network Bandwidth (5 min, avg {avg_rate:.0f} B/s)', fontsize=16, fontweight='bold')
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '2_agent_bandwidth.png'), bbox_inches='tight')
    plt.close(fig)
    print('  2_agent_bandwidth.png')


# ── Test 3: Agent Footprint ───────────────────────────────
def chart_3():
    data = read_csv('3_agent_footprint.csv')
    elapsed = [int(r['elapsed_sec']) for r in data]
    cpu = [float(r['cpu_percent']) for r in data]
    mem = [float(r['memory_mb']) for r in data]

    avg_cpu = np.mean(cpu)
    avg_mem = np.mean(mem)

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), sharex=True)

    ax1.plot(elapsed, cpu, '-', color=COLORS[0], linewidth=1.5, alpha=0.8)
    ax1.fill_between(elapsed, 0, cpu, alpha=0.15, color=COLORS[0])
    ax1.axhline(y=avg_cpu, color=COLORS[1], linestyle='--', linewidth=2, label=f'Average: {avg_cpu:.2f}%')
    ax1.set_ylabel('CPU Usage (%)')
    ax1.set_title('Agent CPU Usage Over Time')
    ax1.set_ylim(-0.1, 3.5)
    ax1.legend()

    ax2.plot(elapsed, mem, '-', color=COLORS[2], linewidth=2)
    ax2.set_xlabel('Elapsed Time (s)')
    ax2.set_ylabel('Memory (MB)')
    ax2.set_title(f'Agent Memory Usage (avg {avg_mem:.1f} MB)')
    ax2.set_ylim(38, 42)

    fig.suptitle('Test 3: Single Agent Resource Footprint (5 min)', fontsize=16, fontweight='bold')
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '3_agent_footprint.png'), bbox_inches='tight')
    plt.close(fig)
    print('  3_agent_footprint.png')


# ── Test 4: Reservation Latency ───────────────────────────
def chart_4():
    data = read_csv('4_reservation_latency.csv')
    trials = [int(r['trial']) for r in data]
    resolve = [int(r['resolve_ms']) for r in data]
    requester = [int(r['requester_instruction_ms']) for r in data]
    provider = []
    for r in data:
        v = r['provider_instruction_ms']
        provider.append(int(v) if v != 'N/A' else 0)

    valid_resolve = [int(r['resolve_ms']) for r in data if r['resolve_ms'] != 'N/A']
    valid_provider = [int(r['provider_instruction_ms']) for r in data if r['provider_instruction_ms'] != 'N/A']
    avg_resolve = np.mean(valid_resolve)
    avg_requester = np.mean([int(r['requester_instruction_ms']) for r in data if r['requester_instruction_ms'] != 'N/A'])
    avg_provider = np.mean(valid_provider) if valid_provider else 0

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 6))

    # Left: average breakdown
    categories = ['Broker\nDecision', 'Requester\nInstruction', 'Provider\nInstruction']
    values = [avg_resolve, avg_requester, avg_provider]
    cols = [COLORS[0], COLORS[2], COLORS[4]]
    bars = ax1.bar(categories, values, color=cols, width=0.6, edgecolor='white')
    for bar, val in zip(bars, values):
        label = f'{val:.0f} ms'
        ax1.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 40, label,
                 ha='center', fontweight='bold', fontsize=13)
    ax1.set_ylabel('Latency (ms)')
    ax1.set_title('Average Latency by Phase')

    # Right: per-trial grouped bars
    x = np.arange(len(trials))
    w = 0.25
    ax2.bar(x - w, resolve, w, label='Resolve', color=COLORS[0])
    ax2.bar(x, requester, w, label='Requester Instr.', color=COLORS[2])
    ax2.bar(x + w, provider, w, label='Provider Instr.', color=COLORS[4])
    ax2.set_xlabel('Trial')
    ax2.set_ylabel('Latency (ms)')
    ax2.set_title('Per-Trial Breakdown')
    ax2.set_xticks(x)
    ax2.set_xticklabels(trials)
    ax2.legend(fontsize=11)
    ax2.annotate('N/A', (0 + w, 50), ha='center', fontsize=10, color='red')

    fig.suptitle('Test 4: Reservation Latency (Synchronous Flow)', fontsize=16, fontweight='bold')
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '4_reservation_latency.png'), bbox_inches='tight')
    plt.close(fig)
    print('  4_reservation_latency.png')


# ── Test 5: Concurrent Reservations ───────────────────────
def chart_5():
    data = read_csv('5_concurrent_reservations.csv')

    groups = defaultdict(list)
    p95_groups = defaultdict(list)
    for r in data:
        c = int(r['concurrent_requests'])
        groups[c].append(float(r['median_resolve_ms']))
        p95_groups[c].append(float(r['p95_resolve_ms']))

    concurrency = sorted(groups.keys())
    avg_median = [np.mean(groups[c]) for c in concurrency]
    min_median = [np.min(groups[c]) for c in concurrency]
    max_median = [np.max(groups[c]) for c in concurrency]
    avg_p95 = [np.mean(p95_groups[c]) for c in concurrency]

    fig, ax = plt.subplots()
    ax.plot(concurrency, avg_median, 'o-', color=COLORS[0], linewidth=2.5, markersize=8, label='Avg Median (ms)')
    ax.fill_between(concurrency, min_median, max_median, alpha=0.15, color=COLORS[0], label='Median Min–Max')
    ax.plot(concurrency, avg_p95, 's--', color=COLORS[1], linewidth=2, markersize=7, label='Avg P95 (ms)')
    ax.set_xlabel('Concurrent Requests')
    ax.set_ylabel('Resolve Time (ms)')
    ax.set_title('Test 5: Concurrent Reservation Performance (5 reps)')
    ax.set_xticks(concurrency)
    ax.legend()
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '5_concurrent_reservations.png'), bbox_inches='tight')
    plt.close(fig)
    print('  5_concurrent_reservations.png')


# ── Test 6: Decision Accuracy ─────────────────────────────
def chart_6():
    data = read_csv('6_decision_accuracy.csv')

    scenarios = [r['scenario'].replace('_', ' ').title() for r in data]
    pass_counts = []
    for r in data:
        num, denom = r['pass_rate'].split('/')
        pass_counts.append(int(num) / int(denom) * 100)

    fig, ax = plt.subplots(figsize=(10, 5))
    cols = [COLORS[2] if p == 100 else COLORS[1] for p in pass_counts]
    bars = ax.bar(scenarios, pass_counts, color=cols, edgecolor='white')
    ax.axhline(y=100, color='green', linestyle='--', alpha=0.4)
    ax.set_ylabel('Pass Rate (%)')
    ax.set_ylim(0, 115)

    for bar, pr in zip(bars, [r['pass_rate'] for r in data]):
        ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 2,
                pr, ha='center', fontweight='bold', fontsize=13)

    correct = sum(1 for p in pass_counts if p == 100)
    ax.set_title(f'Test 6: Decision Accuracy – {correct}/{len(data)} Scenarios Pass (5 reps each)')
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '6_decision_accuracy.png'), bbox_inches='tight')
    plt.close(fig)
    print('  6_decision_accuracy.png')


# ── Test 7: Startup Time (file: 8_startup_time.csv) ──────
def chart_7():
    data = read_csv('8_startup_time.csv')
    trials = [int(r['trial']) for r in data]
    cert_gen = [int(r['cert_gen_ms']) for r in data]
    agent_startup = [int(r['agent_startup_ms']) for r in data]
    first_adv = [int(r['first_adv_ms']) for r in data]
    total = [int(r['total_ms']) for r in data]

    x = np.arange(len(trials))
    w = 0.2

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(15, 6))

    # Left: all trials
    ax1.bar(x - 1.5 * w, cert_gen, w, label='Cert Generation', color=COLORS[4])
    ax1.bar(x - 0.5 * w, agent_startup, w, label='Binary Startup', color=COLORS[0])
    ax1.bar(x + 0.5 * w, first_adv, w, label='First Advertisement', color=COLORS[2])
    ax1.bar(x + 1.5 * w, total, w, label='Total', color=COLORS[3])
    ax1.set_xlabel('Trial')
    ax1.set_ylabel('Time (ms)')
    ax1.set_title('All Trials')
    ax1.set_xticks(x)
    ax1.set_xticklabels(trials)
    ax1.legend(fontsize=10)

    # Right: warm starts only (trials 2, 4, 5)
    warm_idx = [1, 3, 4]
    warm_labels = [str(trials[i]) for i in warm_idx]
    x2 = np.arange(len(warm_idx))

    ax2.bar(x2 - 1.5 * w, [cert_gen[i] for i in warm_idx], w, label='Cert Generation', color=COLORS[4])
    ax2.bar(x2 - 0.5 * w, [agent_startup[i] for i in warm_idx], w, label='Binary Startup', color=COLORS[0])
    ax2.bar(x2 + 0.5 * w, [first_adv[i] for i in warm_idx], w, label='First Advertisement', color=COLORS[2])
    ax2.bar(x2 + 1.5 * w, [total[i] for i in warm_idx], w, label='Total', color=COLORS[3])
    ax2.set_xlabel('Trial')
    ax2.set_ylabel('Time (ms)')
    ax2.set_title('Warm Starts Only (Trials 2, 4, 5)')
    ax2.set_xticks(x2)
    ax2.set_xticklabels(warm_labels)
    ax2.legend(fontsize=10)

    fig.suptitle('Test 7: Agent Startup Time Breakdown', fontsize=16, fontweight='bold')
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '7_startup_time.png'), bbox_inches='tight')
    plt.close(fig)
    print('  7_startup_time.png')


# ── Summary Table ─────────────────────────────────────────
def chart_summary():
    fig, ax = plt.subplots(figsize=(14, 5))
    ax.axis('off')

    headers = ['Test', 'Metric', 'Key Result']
    table_data = [
        ['1a. Broker CPU',      'CPU vs agents (1–100)',       '~0.26% at 2 agents, ~26% at 100 agents'],
        ['1b. Broker Memory',   'Memory vs agents (1–100)',    'Constant ~39 MB regardless of agent count'],
        ['1c. Resource Exhaust', 'Sustained reservations',     '15/15 successful, balanced 8/7 distribution'],
        ['2. Bandwidth',        'Agent network overhead',      '~506 B/s send-only over 5 minutes'],
        ['3. Agent Footprint',  'Single agent resources',      '~0.30% avg CPU, ~40 MB constant RAM'],
        ['4. Reservation Lat.', 'Synchronous e2e timing',      '~433 ms resolve, ~2.2 s provider (via polling)'],
        ['5. Concurrency',      'Latency under load',          '~201 ms@1 req, ~795 ms@10 concurrent, 0 timeouts'],
        ['6. Decision Accuracy', 'Correct cluster selection',  '5/5 scenarios pass (5 reps each)'],
        ['7. Startup Time',     'Agent bootstrap phases',      '~1–4 s warm start (cert gen dominates)'],
    ]

    table = ax.table(cellText=table_data, colLabels=headers, loc='center',
                     cellLoc='left', colWidths=[0.22, 0.25, 0.53])
    table.auto_set_font_size(False)
    table.set_fontsize(12)
    table.scale(1, 1.8)
    for j in range(len(headers)):
        table[0, j].set_facecolor('#2196F3')
        table[0, j].set_text_props(color='white', fontweight='bold')
    for i in range(1, len(table_data) + 1):
        bg = '#F5F5F5' if i % 2 == 0 else 'white'
        for j in range(len(headers)):
            table[i, j].set_facecolor(bg)

    ax.set_title('Evaluation Results Summary (Synchronous Architecture)', fontsize=18, pad=20)
    fig.tight_layout()
    fig.savefig(os.path.join(CHARTS_DIR, '0_summary.png'), bbox_inches='tight')
    plt.close(fig)
    print('  0_summary.png')


if __name__ == '__main__':
    print('Generating evaluation charts...')
    chart_summary()
    chart_1a()
    chart_1b()
    chart_1c()
    chart_2()
    chart_3()
    chart_4()
    chart_5()
    chart_6()
    chart_7()
    print(f'\nAll charts saved to: {CHARTS_DIR}/')
