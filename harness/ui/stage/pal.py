"""Print an .rkspr's palette with how many pixels use each entry, most used first."""
import collections
import sys

path = sys.argv[1]
top = int(sys.argv[2]) if len(sys.argv) > 2 else 12

pal, mode, cnt = {}, None, collections.Counter()
for l in open(path, encoding='utf-8').read().split('\n'):
    if l.startswith('@palette'):
        mode = 'p'; continue
    if l.startswith('@frame'):
        mode = 'f' if ' from ' not in l else 'd'; continue
    if l.startswith('#') or not l.strip():
        continue
    if mode == 'p' and '=' in l:
        k, v = l.split('=', 1); pal[k.strip()] = v.strip()
    elif mode == 'f':
        cnt.update(l)

for ch, n in cnt.most_common(top):
    print('%s  %-9s %7d' % (ch, pal.get(ch, '(marker)'), n))
