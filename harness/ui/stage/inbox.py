"""inbox.py - which legend characters live inside a rectangle, and how many of each.

The companion to box.py. box.py answers "where is the eye"; this answers "what is
it made of", which is the question rk-derive.ps1 -Map actually needs.

It matters because the iris does not have to be green to be marked. Median cut
allocates by area, and an iris is forty pixels out of thirty thousand - so its
colour is routinely merged into a grey that the rest of the picture also uses.
Mapping that grey everywhere would be wrong; mapping it INSIDE THE RECTANGLE is
exactly right, and that is why -Boxes exists.

    python inbox.py <file.rkspr> <frame> <x0> <x1> <y0> <y1>
"""
import collections
import io
import sys


def read(path):
    pal, frames, cur, mode = {}, {}, None, None
    for raw in io.open(path, encoding='utf-8'):
        l = raw.rstrip('\n').rstrip()
        if l.startswith('@palette'):
            mode, cur = 'p', None
            continue
        if l.startswith('@frame'):
            parts = l.split()
            cur = parts[1]
            base = parts[3] if len(parts) > 3 and parts[2] == 'from' else None
            frames[cur] = list(frames[base]) if base else []
            mode = 'diff' if base else 'f'
            continue
        if l.startswith('#') or not l.strip():
            continue
        if mode == 'p' and '=' in l:
            k, v = l.split('=', 1)
            pal[k.strip()] = v.strip()
        elif mode == 'f':
            frames[cur].append(l)
        elif mode == 'diff':
            i, row = l.split('=', 1)
            frames[cur][int(i.strip())] = row.strip()
    return pal, frames


def main():
    path, frame = sys.argv[1], sys.argv[2]
    x0, x1, y0, y1 = (int(v) for v in sys.argv[3:7])
    pal, frames = read(path)
    if frame not in frames:
        raise SystemExit('no such frame: %s  (have: %s)' % (frame, ', '.join(frames)))
    rows = frames[frame]

    cnt = collections.Counter()
    for y in range(y0, min(y1 + 1, len(rows))):
        for x in range(x0, min(x1 + 1, len(rows[y]))):
            cnt[rows[y][x]] += 1

    total = sum(cnt.values())
    print('%s  frame %s  box x%d-%d y%d-%d  (%d px)'
          % (path.split('\\')[-1], frame, x0, x1, y0, y1, total))
    for ch, n in cnt.most_common():
        what = {'.': '(transparent)', '*': '(state colour)', '+': '(state, dimmed)'}.get(ch)
        print('   %s  %-9s %5d px  %5.1f%%' % (ch, what or pal.get(ch, '?'), n, 100.0 * n / total))


if __name__ == '__main__':
    main()
