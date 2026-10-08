"""icon-src.py - turn one illustration into the four PNGs an .ico is packed from.

WHY THIS EXISTS. make-icon.ps1 used to crop with GDI+ and hand the result
straight to the packer, which meant two things went wrong at once:

  1. The orange in the source is not a background choice, it is the CHROMA KEY
     this project paints behind every generation so it can be removed later
     (prekey.py, and 'key #EA8A3F' in build-belka.ps1's log). Baking it into the
     icon framed her in the studio backdrop.

  2. Shrinking a keyed image with an ordinary filter puts that same orange back
     as a fringe. A fully transparent pixel still carries its colour, and the
     filter lets it vote. The fix is order, and it is the same one [R-067]
     records for the sprites:

         key at full size -> PREMULTIPLY by alpha -> shrink -> un-premultiply

     Premultiplying is what takes the vote away from pixels that are not there.

Soft alpha is kept on purpose here. The sprites harden alpha to 0 or 255
because they are pixel art; an icon is a smooth illustration and its edge
should stay smooth at 16px.

    icon-src.py <src.png> <outdir> [--crop x,y,w,h] [--key auto|#RRGGBB|none]
                [--backdrop none|#RRGGBB] [--sizes 16,32,48,256]
"""
import argparse
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

TOL = 40           # same window prekey.py uses
CORNER_AGREE = 24  # corners must agree this closely before 'auto' trusts them


def parse_hex(s):
    s = s.lstrip('#')
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def auto_key(im):
    """The four corners, and only if they agree. A picture that does not have a
    flat backdrop must not be guessed at - it is better to refuse."""
    w, h = im.size
    px = im.convert('RGB').load()
    c = [px[0, 0], px[w - 1, 0], px[0, h - 1], px[w - 1, h - 1]]
    for i in range(3):
        lo = min(v[i] for v in c)
        hi = max(v[i] for v in c)
        if hi - lo > CORNER_AGREE:
            raise SystemExit(
                'the four corners disagree (channel %d spans %d..%d); this image has no flat '
                'backdrop to key. Pass --key #RRGGBB or --key none.' % (i, lo, hi))
    return tuple(sum(v[i] for v in c) // 4 for i in range(3))


def key_out(im, key):
    """Per-pixel, at FULL resolution, while the background is still pure."""
    im = im.convert('RGBA')
    px = im.load()
    w, h = im.size
    hit = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if abs(r - key[0]) <= TOL and abs(g - key[1]) <= TOL and abs(b - key[2]) <= TOL:
                px[x, y] = (r, g, b, 0)
                hit += 1
    return im, hit


def defringe(im, key, passes, tol):
    """Peel off pixels that sit ON the boundary and still look like the key.

    Keying is per-pixel with a fixed window, so wherever the studio backdrop
    shaded off - a vignette, a soft gradient - the last ring of it falls
    outside the window and survives as a rim. Measured on this source: 78 of
    the 103 surviving orange pixels were touching transparency, i.e. they were
    the rim and nothing else.

    Done HERE, at full resolution, for the same reason the key is: once the
    image has been shrunk the rim has been blended into real colour and can no
    longer be told apart from her.
    """
    killed = 0
    for _ in range(passes):
        a = im.split()[3]
        # A pixel is on the boundary when eroding alpha turns it off.
        eroded = a.filter(ImageFilter.MinFilter(3))
        ap, ep, px = a.load(), eroded.load(), im.load()
        w, h = im.size
        hit = 0
        for y in range(h):
            for x in range(w):
                if ap[x, y] == 0 or ep[x, y] != 0:
                    continue
                r, g, b, _ = px[x, y]
                if (abs(r - key[0]) <= tol and abs(g - key[1]) <= tol
                        and abs(b - key[2]) <= tol):
                    px[x, y] = (r, g, b, 0)
                    hit += 1
        killed += hit
        if hit == 0:
            break
    return killed


def shrink(im, size):
    """Premultiply, resize, un-premultiply. Skipping the first step is what puts
    the key colour back along the edge."""
    r, g, b, a = im.split()
    pm = Image.merge('RGBA', [
        Image.eval(ch, lambda v: v) for ch in (r, g, b)] + [a])
    pmb = pm.load()
    w, h = pm.size
    for y in range(h):
        for x in range(w):
            R, G, B, A = pmb[x, y]
            f = A / 255.0
            pmb[x, y] = (int(R * f), int(G * f), int(B * f), A)

    pm = pm.resize((size, size), Image.LANCZOS)

    out = pm.load()
    for y in range(size):
        for x in range(size):
            R, G, B, A = out[x, y]
            if A == 0:
                out[x, y] = (0, 0, 0, 0)
            else:
                f = 255.0 / A
                out[x, y] = (min(255, int(R * f)), min(255, int(G * f)), min(255, int(B * f)), A)
    return pm


def on_backdrop(face, colour):
    """A rounded square behind her. At 16px a transparent face is a smear of
    hair against whatever the taskbar happens to be; a solid ground gives it an
    outline to be read against. Radius scales so the shape is the same at every
    size."""
    size = face.size[0]
    bg = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(bg)
    r = max(2, int(size * 0.18))
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=colour + (255,))
    bg.alpha_composite(face)
    return bg


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('outdir')
    ap.add_argument('--crop', default='')
    ap.add_argument('--key', default='auto')
    ap.add_argument('--backdrop', default='none')
    ap.add_argument('--sizes', default='16,32,48,256')
    ap.add_argument('--defringe', type=int, default=2,
                    help='passes of boundary cleanup after keying (0 = off)')
    a = ap.parse_args()

    im = Image.open(a.src).convert('RGBA')
    print('source: %s  %dx%d' % (os.path.basename(a.src), im.width, im.height))

    if a.key != 'none':
        key = auto_key(im) if a.key == 'auto' else parse_hex(a.key)
        im, hit = key_out(im, key)
        print('key:    #%02X%02X%02X +/-%d, %d of %d px removed (%.0f%%)'
              % (key[0], key[1], key[2], TOL, hit, im.width * im.height,
                 100.0 * hit / (im.width * im.height)))
        if a.defringe:
            gone = defringe(im, key, a.defringe, TOL * 2)
            print('rim:    %d more px peeled off the boundary (%d pass, +/-%d)'
                  % (gone, a.defringe, TOL * 2))
    else:
        print('key:    none (left as it is)')

    if a.crop:
        x, y, w, h = (int(v) for v in a.crop.split(','))
        if x < 0 or y < 0 or x + w > im.width or y + h > im.height:
            raise SystemExit('crop %s is outside %dx%d' % (a.crop, im.width, im.height))
        im = im.crop((x, y, x + w, y + h))
        print('crop:   x=%d y=%d %dx%d' % (x, y, w, h))

    back = None if a.backdrop == 'none' else parse_hex(a.backdrop)
    os.makedirs(a.outdir, exist_ok=True)
    for s in (int(v) for v in a.sizes.split(',')):
        face = shrink(im, s)
        out = on_backdrop(face, back) if back else face
        p = os.path.join(a.outdir, 'icon.%d.png' % s)
        out.save(p)
        opaque = sum(1 for px in out.getdata() if px[3] > 0)
        print('  %3dpx -> %s   %d/%d px opaque' % (s, p, opaque, s * s))


if __name__ == '__main__':
    main()
