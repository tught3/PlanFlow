import os, re

root = r'lib'
files = [os.path.join(dp, f) for dp, _, fs in os.walk(root)
         for f in fs if f.endswith('.dart')]

# Find showModalBottomSheet blocks
for fp in files:
    with open(fp, encoding='utf-8', errors='ignore') as fh:
        text = fh.read()
    # showModalBottomSheet
    for m in re.finditer(r'showModalBottomSheet', text):
        start = m.start()
        line_no = text[:start].count('\n') + 1
        # grab next 1200 chars for analysis
        chunk = text[start:start+2000]
        has_pf = 'PlanFlowActionButtons' in chunk or 'planflowCancelConfirmButtons' in chunk
        has_tb = 'TextButton(' in chunk
        has_ob = 'OutlinedButton(' in chunk
        has_fb = 'FilledButton(' in chunk or 'FilledButton.icon(' in chunk
        btns = []
        if has_pf: btns.append('PlanFlow')
        if has_tb: btns.append('TextBtn')
        if has_ob: btns.append('OutlinedBtn')
        if has_fb: btns.append('FilledBtn')
        print(f'[BOTSHEET] {fp}:{line_no}: {",".join(btns)}')

    # showDialog blocks
    for m in re.finditer(r'showDialog', text):
        start = m.start()
        line_no = text[:start].count('\n') + 1
        chunk = text[start:start+2500]
        has_pf = 'PlanFlowActionButtons' in chunk or 'planflowCancelConfirmButtons' in chunk
        has_tb = 'TextButton(' in chunk
        has_ob = 'OutlinedButton(' in chunk
        has_fb = 'FilledButton(' in chunk or 'FilledButton.icon(' in chunk
        btns = []
        if has_pf: btns.append('PlanFlow')
        if has_tb: btns.append('TextBtn')
        if has_ob: btns.append('OutlinedBtn')
        if has_fb: btns.append('FilledBtn')
        print(f'[SHOWDIALOG] {fp}:{line_no}: {",".join(btns)}')
print('--- BOTSHEET/DIALOG SCAN DONE ---')
