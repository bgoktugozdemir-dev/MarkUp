#!/usr/bin/env python3
"""Opt-in local process-cold launch benchmark. Never controls an existing app process."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('fixture', type=Path)
parser.add_argument('--samples', type=int, default=3)
args = parser.parse_args()
app = args.app.resolve()
fixture = args.fixture.resolve()
executable = str(app / 'Contents/MacOS/MarkUp')


def processes():
    matches = []
    for row in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
        pid, command = row.strip().split(' ', 1)
        if command == executable:
            matches.append(int(pid))
    return matches


if processes():
    raise SystemExit('Close this local app copy before measuring; existing processes are never terminated.')
results = []
for sample in range(args.samples):
    pid = None
    started = datetime.now(timezone.utc)
    try:
        subprocess.run(['open', '-n', '-a', str(app), str(fixture), '--args', '-MarkUpMeasure', 'YES', '-ApplePersistenceIgnoreState', 'YES'], check=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            running = processes()
            if running:
                pid = running[0]
                break
            time.sleep(0.1)
        if pid is None:
            raise RuntimeError('App did not launch')
        while time.monotonic() < deadline:
            raw = subprocess.check_output(['/usr/bin/log', 'show', '--last', '1m', '--style', 'json', '--predicate', f'subsystem == "com.bgoktugozdemir.MarkUp.performance" AND processID == {pid}'], text=True)
            events = json.loads(raw)
            event = next((item for item in events if 'launch_to_first_layout_ms=' in item.get('eventMessage', '') and 'launch_to_first_layout_ms=-1.' not in item['eventMessage']), None)
            if event:
                message = event['eventMessage']
                values = {key: float(value) for key, value in re.findall(r'(\w+)=(-?[\d.]+)', message)}
                timestamp = datetime.fromisoformat(event['timestamp'])
                values.update(sample=sample + 1, command_to_layout_ms=(timestamp - started).total_seconds() * 1000)
                results.append(values)
                break
            time.sleep(0.2)
        else:
            raise RuntimeError('No completed native layout within 30 seconds')
    finally:
        if pid is not None and pid in processes():
            subprocess.run(['kill', '-TERM', str(pid)], check=True)
            for _ in range(50):
                if pid not in processes():
                    break
                time.sleep(0.1)
print(json.dumps({'definition': 'Fresh app process; OS filesystem/framework caches are not purged. command_to_layout includes LaunchServices; app-init-to-layout excludes pre-main work. Native layout in a visible mounted window at settled reading width; compositor presentation and asynchronous local-image completion are excluded.', 'fixture_bytes': fixture.stat().st_size, 'samples': results}, indent=2))
