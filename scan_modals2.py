#!/usr/bin/env python3
"""AlertDialog/showDialog/showModalBottomSheet 블록 추출 및 PlanFlowActionButtons 미사용 여부 확인"""
import os, re

root = 'lib'
files = [os.path.join(dp, f) for dp, dn, fn in os.walk(root) for f in fn if f.endswith('.dart')]

# Already-migrated files (have PlanFlowActionButtons)
migrated = set()

for f in sorted(files):
    try:
        lines = open(f, encoding='utf-8', errors='replace').readlines()
    except Exception:
        continue
    
    content = ''.join(lines)
    has_pfab = 'PlanFlowActionButtons' in content
    
    # Find all showDialog/showModalBottomSheet/AlertDialog blocks
    for i, line in enumerate(lines):
        if re.search(r'showDialog\(', line) or re.search(r'showModalBottomSheet\(', line):
            # Look forward for actions: or button patterns in the next ~40 lines
            chunk = ''.join(lines[i:min(i+50, len(lines))])
            has_actions_col = 'actions:' in chunk
            has_text_btn = 'TextButton' in chunk
            has_pfab_chunk = 'PlanFlowActionButtons' in chunk
            has_row_btn = ('FilledButton' in chunk or 'OutlinedButton' in chunk or 'ElevatedButton' in chunk)
            
            # Check if buttons are in Column (vertical)
            has_column = bool(re.search(r'Column\s*\(', chunk))
            
            line_num = i + 1
            kind = 'showDialog' if 'showDialog' in line else 'showModalBottomSheet'
            
            if has_actions_col and not has_pfab_chunk:
                print(f"\n{'!'*60}")
                print(f"FILE: {f}:{line_num} ({kind})")
                print(f"  AlertDialog actions: YES, PlanFlowActionButtons: NO")
                if has_text_btn:
                    print(f"  TextButton detected (no border by default)")
                if has_column:
                    print(f"  Column detected (possible vertical layout)")
            elif not has_pfab_chunk and has_row_btn and has_column:
                print(f"\n{'!'*60}")
                print(f"FILE: {f}:{line_num} ({kind})")
                print(f"  Buttons in Column (possible vertical layout, no PlanFlowActionButtons)")
