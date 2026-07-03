#!/usr/bin/env python3
"""Find all modal/dialog usages in lib/"""
import pathlib

root = pathlib.Path(r'lib')
files = sorted(f for f in root.rglob('*.dart'))
for f in files:
    text = f.read_text(encoding='utf-8')
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if 'showDialog' in line or 'showModalBottomSheet' in line or 'showCupertinoDialog' in line:
            print(f'{f}:{i+1}: {line.strip()}')
