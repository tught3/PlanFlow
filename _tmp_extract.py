import sys

path = sys.argv[1]
ranges = []
for r in sys.argv[2:]:
    ranges.append(int(r))

with open(path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

out = []
out.append('total lines %d' % len(lines))
for start in ranges:
    out.append('===== %d =====' % start)
    for i in range(start - 1, min(start + 70, len(lines))):
        out.append('%d: %s' % (i + 1, lines[i].rstrip()))

with open('_tmp_out.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(out))
