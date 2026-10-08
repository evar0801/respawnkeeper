# -*- coding: utf-8 -*-
"""gen-eye.py - draw the console eye frames. Generated, not hand-drawn.

WHY GENERATED. An iris here is a few dozen dots and there are two dozen frames.
Hand-drawing that is not craft, it is arithmetic - and arithmetic that has to be
redone the moment a colour, a speed or a direction is questioned. As a script,
"slower", "greener", "more shades" are one number each.

WHY IT IS ITS OWN LAYER. The body draws at the stage's 2x. This region is lifted
out and given "scale": 1 in stage.json, so the same strip of screen carries twice
the dots along each axis. That is the only reason anything can happen inside an
iris at all - and one dot here is already ONE PIXEL ON THE SCREEN, so there is
no finer to go. More detail can only come from the eye being painted larger.

THE LAYER HOLDS THE IRIS AND NOTHING ELSE.
Every dot outside the iris is transparent and the body shows through untouched.
That is not tidiness, it is the whole colour budget: a .rkspr legend is one
character per colour with 36 characters in it, and the first version spent 22 of
them on skin, lashes and hair it was merely copying. Dropping them leaves ALL
THIRTY-SIX for gradient tones - three times what the eye had before.

THE IRIS IS PAINTED, NOT GUESSED, AND THE COLOUR DOES NOT MATTER.
It was guessed once, from "anything that is not lash or skin", and the guess was
wrong in both directions at the same time: grey holes where it missed, eyelid
where it over-reached. An eye is a shape, and no rule written in terms of colour
follows a shape.

So it is painted by hand - and this reads the paint by COMPARING against the
untouched region rather than by looking for a marker colour. Whatever is
different is the iris. Eva painted it green both times she was asked for
magenta, which is the correct instinct and not a mistake to design around.

  1. python gen-eye.py            writes iris-mask.png if it is not there yet
  2. paint the iris of BOTH eyes in it, any colour, and save over it
  3. python gen-eye.py            writes the frames into draw-eye\\
  4. rk-draw.ps1 -Name belka-eye -From draw-eye -Colors 36 -NoPng
"""
import io
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'draw-eye')
# The mask lives OUTSIDE draw-eye on purpose: rk-draw.ps1 imports every PNG in
# that folder as a frame, so a mask sitting in it became a 38th frame made
# entirely of skin and lashes - and median cut allocates by area, so those
# 2320 pixels ate the palette and collapsed 29 gradient tones down to 10.
MASK = os.path.join(HERE, 'eye-iris-mask.png')

RX, RY, RW, RH = 94, 40, 29, 20          # the region, in the console sprite
FRAMES = 12                               # 12 x 100ms = one and a fifth seconds

# THE COLOUR BUDGET, spent deliberately. 36 characters, no more.
# Green gets the most because green is the state the window is in almost always;
# the other two exist to be recognised in a glance, not admired.
TONES = {'run': 16, 'care': 9, 'halt': 9}
SLEEP_TONES = 2                           # 16 + 9 + 9 + 2 = 36

# The ends of each ramp. Everything between them is built, not listed - that is
# what "all the greens" means here.
ENDS = {
    'run':  [(0x06, 0x2B, 0x18), (0x14, 0x6B, 0x36), (0x2E, 0xC4, 0x62),
             (0x8C, 0xFF, 0xB4), (0xE8, 0xFF, 0xF2)],
    'care': [(0x3A, 0x27, 0x02), (0x8A, 0x5F, 0x0A), (0xE0, 0xA0, 0x14),
             (0xFF, 0xDC, 0x7A), (0xFF, 0xF6, 0xD8)],
    'halt': [(0x33, 0x06, 0x0C), (0x84, 0x14, 0x1D), (0xE0, 0x30, 0x3A),
             (0xFF, 0x8E, 0x96), (0xFF, 0xE2, 0xE4)],
}
SLEEP = [(0x0A, 0x1E, 0x15), (0x18, 0x3E, 0x28)]


def ramp(ends, n):
    """n shades along a path through the listed colours."""
    out = []
    segs = len(ends) - 1
    for i in range(n):
        p = (i / float(n - 1)) * segs if n > 1 else 0.0
        k = min(segs - 1, int(p))
        t = p - k
        a, b = ends[k], ends[k + 1]
        out.append(tuple(int(round(a[j] + (b[j] - a[j]) * t)) for j in range(3)))
    return out


def build_base():
    """The region, doubled. An exact factor of two with nearest neighbour, so
    the mask Eva paints on is exactly what the window is showing."""
    src = Image.open(os.path.join(HERE, 'art', 'belka.png')).convert('RGBA')
    crop = src.crop((RX, RY, RX + RW, RY + RH))
    return crop.resize((RW * 2, RH * 2), Image.NEAREST)


def _sprite_marks(base):
    """The * and + cells of the console sprite, in the doubled canvas.

    These are the status pixels the body already draws - i.e. that eye's iris as
    it was marked when the sprite was imported. Read out of the .rkspr rather
    than inferred from colour, because colour is what got this wrong before.
    """
    frames, cur, mode = {}, None, None
    for raw in io.open(os.path.join(HERE, 'art', 'belka.rkspr'), encoding='utf-8'):
        l = raw.rstrip('\n').rstrip()
        if l.startswith('@palette'):
            mode, cur = 'p', None
            continue
        if l.startswith('@frame'):
            p = l.split()
            cur = p[1]
            b = p[3] if len(p) > 3 and p[2] == 'from' else None
            frames[cur] = list(frames[b]) if b else []
            mode = 'diff' if b else 'f'
            continue
        if l.startswith('#') or not l.strip() or mode == 'p':
            continue
        if mode == 'f':
            frames[cur].append(l)
        elif mode == 'diff':
            i, row = l.split('=', 1)
            frames[cur][int(i.strip())] = row.strip()
    rows = frames.get('run.0') or frames[list(frames)[0]]
    out = []
    for y in range(RY, RY + RH):
        for x in range(RX, RX + RW):
            if y < len(rows) and x < len(rows[y]) and rows[y][x] in '*+':
                for dy in (0, 1):
                    for dx in (0, 1):
                        out.append(((x - RX) * 2 + dx, (y - RY) * 2 + dy))
    return out


def find_iris(base):
    """Whatever differs from the untouched region. Colour-agnostic on purpose."""
    if not os.path.exists(MASK):
        base.save(MASK)
        raise SystemExit(
            'wrote a fresh mask. Open it in Clip Studio, paint the iris of BOTH\n'
            'eyes in any colour you like, and save over it:\n\n    ' + MASK +
            '\n\nIt is 58x40 - zoom in. Anything you leave alone stays exactly as\n'
            'it is. Painting a bigger iris makes a bigger eye; that is the only\n'
            'way left to get more detail into it.')

    m = Image.open(MASK).convert('RGBA')
    if m.size != base.size:
        raise SystemExit('iris-mask.png is %dx%d but has to be %dx%d'
                         % (m.size + base.size))
    pb, pm = base.load(), m.load()
    hits = [(x, y) for y in range(base.size[1]) for x in range(base.size[0])
            if pb[x, y] != pm[x, y]]
    if not hits:
        raise SystemExit('iris-mask.png is identical to the original - nothing is painted')

    # AN EYE THAT WAS NOT PAINTED FALLS BACK TO THE MARKS ALREADY IN THE SPRITE.
    #
    # Eva painted one eye and said to leave the other alone - she had drawn the
    # first one TO MATCH the second, so changing the second would undo the
    # matching. But leaving it truly alone means it keeps the body's flat status
    # colour while its partner runs a gradient, which is worse than either.
    #
    # The sprite already carries that eye's iris as * and + cells. Measured: all
    # thirteen of them sit on iris, none on lash - so using them changes the
    # SHAPE by nothing at all and only changes what colour flows through it.
    #
    # Only eyes she did not touch are filled in this way. Anywhere she painted,
    # her outline wins outright.
    xs = [x for (x, _) in hits]
    lo, hi = min(xs) - 4, max(xs) + 4
    extra = [c for c in _sprite_marks(base) if c[0] < lo or c[0] > hi]
    if extra:
        print('  the unpainted eye keeps its own outline: %d dots from the sprite'
              % len(extra))
        hits = hits + extra

    # Split into two eyes only at a gap wide enough to BE the bridge of a nose.
    # Splitting at the widest gap unconditionally cut a single painted eye into
    # two clusters of 4 and 47 dots, and each then got its own gradient - so four
    # dots in the corner ran a full ramp of their own.
    xs = sorted(set(x for (x, _) in hits))
    gap, cut = 0, xs[0]
    for a, b in zip(xs, xs[1:]):
        if b - a > gap:
            gap, cut = b - a, a
    if gap < 9:
        return [hits]
    eyes = [[c for c in hits if c[0] <= cut], [c for c in hits if c[0] > cut]]
    return [e for e in eyes if e]


def paint(cells, tones, phase):
    """Two currents crossing, at different speeds and angles.

    A single band travelling straight down reads as a shutter. Two of them, one
    slower and leaning the other way, never line up the same way twice inside a
    loop - which is what makes it look like something flowing rather than
    something blinking.
    """
    xs = [c[0] for c in cells]
    ys = [c[1] for c in cells]
    x0, y0 = min(xs), min(ys)
    w = max(1, max(xs) - x0 + 1)
    h = max(1, max(ys) - y0 + 1)
    top = len(tones) - 1
    out = {}
    for (x, y) in cells:
        u = (x - x0) / float(w)
        v = (y - y0) / float(h)
        # the standing shape of an eye: dark at the top lid, bright at the base
        base = 0.18 + 0.62 * v
        # two travelling currents
        a = 0.5 + 0.5 * _wave(v * 1.6 + u * 0.5 - phase * 1.0)
        b = 0.5 + 0.5 * _wave(v * 2.7 - u * 0.9 + phase * 1.7)
        val = base + 0.30 * a + 0.16 * b - 0.20
        out[(x, y)] = tones[max(0, min(top, int(round(val * top))))]
    return out


def _wave(t):
    """A triangle wave on 0..1, so the ramp is walked evenly instead of
    lingering at the ends the way a sine does."""
    t = t % 1.0
    return 4.0 * abs(t - 0.5) - 1.0


def main():
    base = build_base()
    os.makedirs(OUT, exist_ok=True)
    eyes = find_iris(base)
    print('iris dots: %s  (total %d)' % ([len(e) for e in eyes], sum(len(e) for e in eyes)))
    if len(eyes) < 2:
        print('WARNING: only ONE eye is painted. The other will be left as it is.')

    for f in os.listdir(OUT):
        if f.endswith('.png') and f != 'iris-mask.png':
            os.remove(os.path.join(OUT, f))

    blank = Image.new('RGBA', base.size, (0, 0, 0, 0))
    made = []
    for key, n in TONES.items():
        tones = ramp(ENDS[key], n)
        for i in range(FRAMES):
            im = blank.copy()
            px = im.load()
            for cells in eyes:
                for pos, col in paint(cells, tones, i / float(FRAMES)).items():
                    px[pos] = col + (255,)
            name = '%s.%d' % (key, i)
            im.save(os.path.join(OUT, name + '.png'))
            made.append(name)

    im = blank.copy()
    px = im.load()
    for cells in eyes:
        ys = [c[1] for c in cells]
        y0, h = min(ys), max(1, max(ys) - min(ys) + 1)
        for (x, y) in cells:
            px[x, y] = SLEEP[0 if (y - y0) / float(h) < 0.5 else 1] + (255,)
    im.save(os.path.join(OUT, 'sleep.0.png'))
    made.append('sleep.0')

    seen = set()
    for n in made:
        for p in Image.open(os.path.join(OUT, n + '.png')).convert('RGBA').getdata():
            if p[3]:
                seen.add(p[:3])
    print('frames: %d   distinct colours: %d  (the ceiling is 36)' % (len(made), len(seen)))
    if len(seen) > 36:
        raise SystemExit('over the palette ceiling - lower the numbers in TONES')


if __name__ == '__main__':
    main()
