#!/usr/bin/env python3
"""Configurable ratio + absolute-slack gates; no uncalibrated defaults."""
import json
import math
import sys

def evaluate(medians, gates):
    failed = []
    for key, budget in gates.items():
        ratio = budget['ratio']
        slack = budget.get('slack', 0)
        if (key not in medians['plus'] or not math.isfinite(ratio) or
                not math.isfinite(slack) or ratio < 1 or slack < 0):
            raise ValueError('invalid gate: ' + key)
        if medians['plus'][key] > medians['baseline'][key] * ratio + slack:
            failed.append(key)
    return failed

if __name__ == '__main__':
    with open(sys.argv[1]) as f: report = json.load(f)
    with open(sys.argv[2]) as f: gates = json.load(f)
    failed = evaluate(report['medians'], gates)
    print(json.dumps({'failed': failed, 'gates': gates}, indent=2))
    sys.exit(bool(failed))
