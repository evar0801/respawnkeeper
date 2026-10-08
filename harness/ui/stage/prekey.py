"""prekey.py - cut the background at FULL resolution, then shrink. In that order.

WHY THE ORDER IS THE WHOLE POINT. rk-import-art.ps1 resamples first and keys
second, and the resampler blends: a pixel that is half her hair and half the
orange ground comes out a colour that is NEITHER, so the per-pixel key never
matches it and it survives as an orange rim. Raising the tolerance does not
reach it (measured: 28 -> 70 removed 221 pixels of 31,022) because the blend is
not near the key colour, it is between the key colour and her. -Deedge peels the
ring afterwards, which fixes the outline but cannot reach the gaps between hair
strands, because those are interior.

Doing it the other way round removes the cause instead of the symptom:

    1. key at full resolution      - every background pixel is still pure
    2. PREMULTIPLY by alpha        - so transparent pixels carry no colour
    3. shrink with an area filter  - blends now happen between her and NOTHING
    4. un-premultiply, harden      - alpha back to 0 or 255, no soft edge

Step 2 is the one that is easy to forget and is the reason a naive
Image.resize() on RGBA still haloes: Pillow resizes the colour channels without
weighting them by alpha, so fully transparent orange pixels still vote on the
colour of their neighbours. Multiplying first makes their vote zero.

Step 4 hardens the alpha because this is pixel art. A soft edge would be thrown
away by the .rkspr format anyway (a pixel is one legend character; there is no
partial coverage), so the choice is made here, on purpose, rather than by
whatever the importer's alpha threshold happens to be.

    python prekey.py <in.png> <out.png> <W> <H> [key] [tolerance]

key defaults to 'auto', which reads the four corners and demands they agree -
the same rule rk-import-art.ps1 uses, for the same reason: two different corner
colours means the picture does not HAVE a flat background, and quietly picking
one would punch a hole in it.
"""
import sys

from PIL import Image

KEEP = 128          # alpha at or above this survives the hardening
CORNER_AGREE = 24   # how far apart the four corners may be for 'auto'


def parse_key(arg, im):
    if arg and arg != 'auto':
        h = arg.lstrip('#')
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    w, h = im.size
    px = im.load()
    corners = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    corners = [c[:3] for c in corners]
    worst = max(max(abs(c[i] - corners[0][i]) for i in range(3)) for c in corners)
    if worst > CORNER_AGREE:
        raise SystemExit('the corners disagree by %d (limit %d): %s\n'
                         'This picture has no flat background. Pass an explicit #RRGGBB, '
                         'or generate it again on a plain ground.'
                         % (worst, CORNER_AGREE, ' '.join('#%02X%02X%02X' % c for c in corners)))
    return corners[0]


def main():
    src, dst, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
    keyarg = sys.argv[5] if len(sys.argv) > 5 else 'auto'
    tol = int(sys.argv[6]) if len(sys.argv) > 6 else 40

    im = Image.open(src).convert('RGB')
    key = parse_key(keyarg, im)
    sw, sh = im.size

    # ---- 1. key at full resolution -----------------------------------------
    px = im.load()
    alpha = Image.new('L', (sw, sh), 255)
    ap = alpha.load()
    cut = 0
    for y in range(sh):
        for x in range(sw):
            r, g, b = px[x, y]
            if abs(r - key[0]) <= tol and abs(g - key[1]) <= tol and abs(b - key[2]) <= tol:
                ap[x, y] = 0
                cut += 1

    # ---- 2. premultiply ----------------------------------------------------
    rgba = im.convert('RGBA')
    rgba.putalpha(alpha)
    r, g, b, a = rgba.split()

    # Channel by channel: Image.eval only ever sees one image, so weighting the
    # colour by the alpha has to be written out rather than expressed.
    def mul(ch):
        return Image.frombytes('L', (sw, sh),
                               bytes((c * al) // 255 for c, al in zip(ch.tobytes(), a.tobytes())))
    pm = Image.merge('RGB', (mul(r), mul(g), mul(b)))

    # ---- 3. shrink, colour and coverage together ---------------------------
    pm_s = pm.resize((W, H), Image.BOX)
    a_s = a.resize((W, H), Image.BOX)

    # ---- 4. un-premultiply and harden --------------------------------------
    def unmul(ch):
        return Image.frombytes('L', (W, H),
                               bytes(min(255, (c * 255) // al) if al else 0
                                     for c, al in zip(ch.tobytes(), a_s.tobytes())))
    rs, gs, bs = (unmul(c) for c in pm_s.split())
    hard = a_s.point(lambda v: 255 if v >= KEEP else 0)
    out = Image.merge('RGBA', (rs, gs, bs, hard))
    out.save(dst)

    kept = sum(1 for v in hard.tobytes() if v)
    print('  prekey: key #%02X%02X%02X +/-%d, %d/%d source px were background'
          % (key[0], key[1], key[2], tol, cut, sw * sh))
    print('  prekey: %s -> %dx%d, %d opaque px (%.0f%%)'
          % (dst.split('\\')[-1], W, H, kept, 100.0 * kept / (W * H)))


if __name__ == '__main__':
    main()
