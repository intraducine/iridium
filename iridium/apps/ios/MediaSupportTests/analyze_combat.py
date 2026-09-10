"""Compare sampled frame-gap peaks near observed pool growth with other windows.

The game log is polled at 50 ms and may be buffered. This is correlation, not
proof of causality. Gaps are presentation-submission gaps, not GPU execution time.
"""
import csv
from pathlib import Path
import statistics
import sys


def analyze(rows):
    gaps = [(float(r['uptime_s']), float(r['value'])) for r in rows if r['kind'] == 'frame_gap_ms']
    effects = [(float(r['uptime_s']), r['value']) for r in rows if r['kind'] == 'game_log_observed' and 'Object Pool attached' in r['value']]
    associated = [(text, max((g for t, g in gaps if when-.15 <= t <= when+.10), default=0)) for when, text in effects]
    baseline = [g for t, g in gaps if all(abs(t-when) > .5 for when, _ in effects)]
    return associated, baseline


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        events, baseline = analyze([
            {'uptime_s':'1','kind':'frame_gap_ms','value':'16'},
            {'uptime_s':'2','kind':'frame_gap_ms','value':'90'},
            {'uptime_s':'2.05','kind':'game_log_observed','value':'Object Pool attached: run out of Slash'},
        ])
        assert events[0][1] == 90 and baseline == [16.0]
        print('PASS: correlation window and baseline exclusion')
    else:
        with Path(sys.argv[1]).open() as f:
            events, baseline = analyze(list(csv.DictReader(f, delimiter='\t')))
        print('Effect growth observations:', len(events))
        for text, gap in events:
            print(f'{gap:.2f} ms nearby peak | {text}')
        if baseline:
            print(f'Other sampled windows: {len(baseline)}, median peak {statistics.median(baseline):.2f} ms, maximum {max(baseline):.2f} ms')
        print('Startup/loading, pauses and buffered logs must be excluded before causal conclusions.')
