#!/usr/bin/env python3
"""Measure public-fixture opens/reloads in an already running local review app.

The caller owns the review process. This script does not close any windows or
processes. Generated copies stay under the supplied, disposable fixture folder.
"""
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
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--reload', action='store_true')
parser.add_argument('--samples', type=int, default=1)
args = parser.parse_args()
app = args.app.resolve()
fixture = args.fixture.resolve()
executable = str(app / 'Contents/MacOS/MarkUp')
pid = next((int(row.strip().split(' ', 1)[0]) for row in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines() if row.strip().split(' ', 1)[1] == executable), None)
if pid is None:
    raise SystemExit('Launch the opt-in local review app first')
results = []
for sample in range(args.samples):
    started = datetime.now(timezone.utc)
    if args.reload:
        # The path must be a disposable generated fixture; never mutate originals.
        if fixture.parent.name != 'generated':
            raise SystemExit('Reload mode requires a disposable generated fixture')
        with fixture.open('a') as stream:
            stream.write('\n<!-- public benchmark revision %d -->\n' % sample)
    else:
        subprocess.run(['open', '-a', str(app), str(fixture)], check=True)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        raw = subprocess.check_output(['/usr/bin/log', 'show', '--last', '2m', '--style', 'json', '--predicate', f'subsystem == "com.bgoktugozdemir.MarkUp.performance" AND processID == {pid}'], text=True)
        events = json.loads(raw)
        event = next((item for item in events if 'open_to_layout_ms=' in item.get('eventMessage', '') and datetime.fromisoformat(item['timestamp']) >= started), None)
        if event:
            values = {key: float(value) for key, value in re.findall(r'(\w+)=(-?[\d.]+)', event['eventMessage'])}
            values.update(sample=sample + 1, trigger_to_layout_ms=(datetime.fromisoformat(event['timestamp']) - started).total_seconds() * 1000, bytes=fixture.stat().st_size)
            results.append(values)
            args.output.write_text(json.dumps({'operation': 'in-place write' if args.reload else 'warm process open', 'samples': results}, indent=2) + '\n')
            print(json.dumps(values), flush=True)
            break
        time.sleep(0.2)
    else:
        raise SystemExit('No mounted layout within 90 seconds')
    if not args.reload and sample + 1 < args.samples:
        raise SystemExit('Close the document with native UI before another warm open; use --samples 1')
    time.sleep(1)
