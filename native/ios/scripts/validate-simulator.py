#!/usr/bin/env python3
"""Exercise the actual installed app, then validate fresh diagnostics (no audio is exported)."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

parser = argparse.ArgumentParser()
parser.add_argument('--device', default='booted', help='A booted simulator UUID, or booted')
parser.add_argument('--scenario', choices=['foreground', 'background', 'silence', 'direct', 'direct-live', 'direct-reuse'], default='background')
parser.add_argument('--keep-running', action='store_true', help='Keep the result open for manual UI inspection')
parser.add_argument('--output', type=Path, help='Optional path to preserve the report')
args = parser.parse_args()
os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
root = Path(__file__).resolve().parents[1]
app = root/'build/Build/Products/Debug-iphonesimulator/WakeOn.app'
if not app.exists():
    raise SystemExit('Build the Debug simulator app first; see README.md.')

def sim(*arguments):
    return subprocess.check_output(['xcrun', 'simctl', *arguments], text=True).strip()

sim('install', args.device, str(app))
sim('privacy', args.device, 'grant', 'microphone', 'dev.wakeon.ios')
container = Path(sim('get_app_container', args.device, 'dev.wakeon.ios', 'data'))
identifier = str(uuid.uuid4())
mode = '--silence' if args.scenario == 'silence' else '--fixture'
direct = args.scenario.startswith('direct')
launch_args = ['--intent-test' if direct else '--autostart']
if args.scenario not in ('direct-live', 'direct-reuse'):
    launch_args += [mode]
if direct:
    launch_args += ['--repeat-intent']
if args.scenario == 'direct-reuse':
    launch_args += ['--reuse-mic']
launch_args += ['--delay', '0' if direct else '10', '--test-id', identifier]
sim('launch', '--terminate-running-process', args.device, 'dev.wakeon.ios',
    *launch_args)
succeeded = False
try:
    print('Started fixture test. Handle a first-run notification prompt manually if shown.', flush=True)
    # Let foreground audio capture initialize before changing apps. The fixture starts after 10s.
    time.sleep(4)
    if args.scenario == 'background':
        sim('launch', args.device, 'com.apple.mobilesafari')
    report_file = container/'Documents/wake-report.json'
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        try:
            report = json.loads(report_file.read_text())
            if report.get('testID') == identifier:
                break
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        time.sleep(0.25)
    else:
        raise SystemExit('No fresh report. Check microphone permission, model files, and app errors.')
    assert report['engineRunning'], report
    assert report['source'] == ('microphone' if args.scenario in ('direct-live', 'direct-reuse') else 'fixture'), report
    if args.scenario == 'silence':
        assert not report['detected'], report
    else:
        assert report['detected'] and report['phrase'] == ('DIRECT_RECORDING' if direct else 'HEY_LOBBY'), report
        assert report['complete'], report
        if args.scenario not in ('direct-live', 'direct-reuse'):
            assert report['exactBufferMatch'], report
        assert report['sampleCount'] == 80_000, report
        assert report['wakeFrame'] - report['startFrame'] == (0 if direct else 32_000), report
        assert report['endFrame'] - report['wakeFrame'] == (80_000 if direct else 48_000), report
        assert report['backgroundAtWake'] == (args.scenario == 'background'), report
    if direct:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                traces = [json.loads(line) for line in (container/'Documents/latency.jsonl').read_text().splitlines()]
            except FileNotFoundError:
                traces = []
            matching = [run for run in traces if run.get('testID') == identifier and run['outcome'] == 'completed']
            if matching:
                break
            time.sleep(.1)
        assert len(matching) == 1, matching
        trace = matching[0]
        events = {e['name']: e['elapsedMs'] for e in trace['events']}
        assert trace['source'] == 'app_intent', trace
        assert 'model_begin' not in events, trace
        assert 'duplicate_request_joined' in events, trace
        if args.scenario == 'direct-reuse':
            assert 'reuse_microphone' in events, trace
        assert events['first_samples'] <= events['ready_ui'] <= events['handoff_ui_ready'], trace
        assert trace['summary']['frames'] == 80_000, trace
        assert 'microphone_stopped' in events, trace
        if args.scenario in ('direct-live', 'direct-reuse'):
            assert 'first_callback' in events and trace['summary']['callbackCount'] > 0, trace
        print('Latency:', json.dumps(trace, indent=2))
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.with_suffix('.latency.jsonl').write_text(json.dumps(trace) + '\n')
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))
    print('PASS:', args.scenario)
    succeeded = True
finally:
    if not (args.keep_running and succeeded):
        subprocess.run(['xcrun', 'simctl', 'terminate', args.device, 'dev.wakeon.ios'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
