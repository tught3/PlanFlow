import os
root = 'lib'
fns = [os.path.join(dp, f) for dp, dn, fn in os.walk(root) for f in fn if f.endswith('.dart')]
loading_hits = []
error_hits = []
empty_hits = []
for fn in fns:
    try:
        txt = open(fn, 'r', encoding='utf-8', errors='ignore').read()
        if 'CircularProgressIndicator' in txt:
            loading_hits.append(fn)
        if "Text('오류" in txt or 'Text("오류' in txt or '에러' in txt and 'Container' in txt:
            error_hits.append(fn)
        if '데이터가 없' in txt or '일정이 없' in txt or '항목이 없' in txt:
            empty_hits.append(fn)
    except Exception:
        pass
print("=== CircularProgressIndicator files ===")
print('\n'.join(sorted(set(loading_hits))))
print()
print("=== empty state-ish files ===")
print('\n'.join(sorted(set(empty_hits))))
