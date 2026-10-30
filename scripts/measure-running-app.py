#!/usr/bin/env python3
"""Measure an already launched development app and its descendants; no document data."""
import argparse
import json
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('pid', type=int)
parser.add_argument('--seconds', type=int, default=30)
parser.add_argument('--memory-helper', help='Compiled scripts/process-memory.c for kernel physical-footprint accounting')
args = parser.parse_args()


def seconds(value):
    parts = value.replace('-', ':').split(':')
    total = 0.0
    for part in parts:
        total = total * 60 + float(part)
    return total


def sample():
    rows = {}
    output = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,time='], text=True)
    for line in output.splitlines():
        pid, parent, rss, cpu = line.split()
        rows[int(pid)] = (int(parent), int(rss), seconds(cpu))
    selected = {args.pid}
    while True:
        children = {pid for pid, row in rows.items() if row[0] in selected}
        if children <= selected:
            break
        selected |= children
    return {pid: rows[pid] for pid in selected if pid in rows}

started = time.monotonic()
first = sample()
if args.pid not in first:
    raise SystemExit('Application process is not running')
peak = sum(row[1] for row in first.values())
samples = []
for _ in range(args.seconds):
    time.sleep(1)
    current = sample()
    if args.pid not in current:
        raise SystemExit('Application exited during measurement')
    peak = max(peak, sum(row[1] for row in current.values()))
    samples.append(current)
elapsed = time.monotonic() - started
last = samples[-1]
cpu = sum(max(0, row[2] - first.get(pid, (0, 0, 0))[2]) for pid, row in last.items())
result = {
    'duration_seconds': round(elapsed, 3),
    'sample_count': len(samples),
    'average_cpu_percent_one_core': round(cpu / elapsed * 100, 3),
    'final_rss_mib_sum': round(sum(row[1] for row in last.values()) / 1024, 2),
    'peak_sampled_rss_mib_sum': round(peak / 1024, 2),
    'process_count_final': len(last),
    'metric': 'ps accumulated CPU delta / wall time; sum RSS of app and surviving descendant processes; shared pages may be counted more than once; exited helpers are not included',
}
if args.memory_helper:
    physical = [json.loads(subprocess.check_output([args.memory_helper, str(pid)], text=True)) for pid in last]
    result['final_physical_footprint_mib_sum'] = round(sum(item['physical_footprint_bytes'] for item in physical) / (1024 * 1024), 2)
    result['lifetime_peak_physical_footprint_mib_sum'] = round(sum(item['peak_physical_footprint_bytes'] for item in physical) / (1024 * 1024), 2)
    result['physical_metric'] = 'Kernel proc_pid_rusage v4; sum of surviving app/descendant footprints. Sum of individual lifetime peaks is an upper bound, not simultaneous peak.'
print(json.dumps(result, indent=2))
