import os, re

root = r'lib'
files = [os.path.join(dp, f) for dp, _, fs in os.walk(root)
         for f in fs if f.endswith('.dart')]

for fp in files:
    with open(fp, encoding='utf-8', errors='ignore') as fh:
        lines = fh.readlines()
    text = ''.join(lines)
    # Find each AlertDialog and analyze its actions
    for m in re.finditer(r'AlertDialog\(', text):
        start = m.start()
        # Find the matching close paren by counting
        depth = 0
        i = start
        while i < len(text):
            if text[i] == '(':
                depth += 1
            elif text[i] == ')':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        block = text[start:i+1]
        line_no = text[:start].count('\n') + 1
        # Check what's in actions
        has_planflow = 'PlanFlowActionButtons' in block or 'planflowCancelConfirmButtons' in block or 'planflowConfirmButtons' in block
        has_textbutton = 'TextButton(' in block
        has_outlined = 'OutlinedButton(' in block
        has_filled = 'FilledButton(' in block or 'FilledButton.icon(' in block
        # Check for Column in actions (vertical stacking)
        # Extract actions:[...] region
        status = 'COMPLIANT' if has_planflow else ('VIOLATION' if (has_textbutton or has_outlined or has_filled) else 'NO-STD-BUTTON')
        btns = []
        if has_textbutton: btns.append('TextButton')
        if has_outlined: btns.append('OutlinedButton')
        if has_filled: btns.append('FilledButton')
        if has_planflow: btns.append('PlanFlowActionButtons')
        print(f'{fp}:{line_no}: [{status}] {",".join(btns)}')
print('--- SCAN DONE ---')
