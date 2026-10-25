#!/usr/bin/env python3
"""Summarize metadata-only JSONL traces, never mix hardware, source, or fixture timings."""
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('files', nargs='+', type=Path)
args = parser.parse_args()
groups = defaultdict(list)
for path in args.files:
    for line in path.read_text().splitlines():
        if line.strip():
            run = json.loads(line)
            key = (run['platform'], run['input'], run['source'], run.get('invocation', 'legacy'),
                   'first-request' if run.get('requestNumberInProcess', 1) == 1 else 'subsequent-request',
                   'mic-reused' if any(e['name'] == 'reuse_microphone' for e in run['events']) else 'mic-started',
                   run['os'], 'build-' + run['build'], run['outcome'])
            groups[key].append(run)

def percentile(values, proportion):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * proportion) - 1)]

for key, runs in sorted(groups.items()):
    print(' / '.join(key), f'n={len(runs)}')
    measures = defaultdict(list)
    for run in runs:
        events = {e['name']: e['elapsedMs'] for e in run['events']}
        for name in ['first_callback', 'first_samples', 'ready_ui', 'handoff_worker_ready', 'handoff_ui_ready', 'microphone_stopped']:
            if name in events:
                measures['request → ' + name].append(events[name])
        for start, end in [('permission_begin', 'permission_end'), ('model_begin', 'model_end'),
                           ('session_activation_begin', 'session_activation_end'),
                           ('first_samples', 'ready_ui'), ('handoff_worker_ready', 'handoff_ui_ready')]:
            if start in events and end in events:
                measures[start + ' → ' + end].append(events[end] - events[start])
        # Realtime voice: setup milestones, the server's share, and reply timing.
        for name in ['ice_gathering_done', 'http_response', 'remote_description_set', 'peer_connected',
                     'data_channel_open', 'session_started', 'first_audio_packet_received',
                     'delegation_created', 'backend:response.web_search_call.completed', 'backend:response.completed',
                     'first_reply_transcript', 'reply_audio_start', 'answer_transcript', 'answer_audio_start']:
            if name in events:
                measures['request → ' + name].append(events[name])
        for start, end in [('http_request_begin', 'http_response'), ('remote_description_begin', 'remote_description_set'),
                           ('remote_description_set', 'peer_connected')]:
            if start in events and end in events:
                measures[start + ' → ' + end].append(events[end] - events[start])
        for name in ['maxQueueDelayMs', 'maxConvertMs', 'meanQueueDelayMs', 'meanConvertMs', 'maxCopyMs', 'missingInputFrames',
                     'responseMs', 'roundTripMs', 'jitterBufferMs', 'readyMs']:
            if name in run['summary']:
                measures[name].append(run['summary'][name])
    for name, values in measures.items():
        print(f'  {name}: p50={percentile(values, .5):.3f} p95={percentile(values, .95):.3f} max={max(values):.3f} n={len(values)}')
print('Times are milliseconds except missingInputFrames. No physical button-press timestamp is available.')
print('Handoff includes the intentional recording duration. Small samples are observations, not stable percentiles.')
