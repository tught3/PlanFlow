#!/usr/bin/env python3
"""PlanFlow 모달/다이얼로그/바텀시트 버튼 패턴 스캔"""
import os, re

root = 'lib'
files = [os.path.join(dp, f) for dp, dn, fn in os.walk(root) for f in fn if f.endswith('.dart')]

patterns = {
    'AlertDialog': r'AlertDialog\b',
    'showDialog': r'showDialog\b',
    'showModalBottomSheet': r'showModalBottomSheet\b',
    'actions:': r'actions:',
    'TextButton': r'\bTextButton\b',
    'ElevatedButton': r'\bElevatedButton\b',
    'FilledButton': r'\bFilledButton\b',
    'OutlinedButton': r'\bOutlinedButton\b',
    'PlanFlowActionButtons': r'PlanFlowActionButtons|planflow_action_buttons',
}

for f in sorted(files):
    try:
        content = open(f, encoding='utf-8', errors='replace').read()
    except Exception:
        continue
    counts = {}
    for k, v in patterns.items():
        c = len(re.findall(v, content))
        if c > 0:
            counts[k] = c
    if counts:
        print(f"\n=== {f} ===")
        for k, c in counts.items():
            print(f"  {k}: {c}")
