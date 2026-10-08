# -*- coding: utf-8 -*-
"""
rk-part.py - the two image steps around a PART.

Eva, 2026-09-14: "I will draw the whole picture as a rough myself, and then
draw roughs of the parts the animation needs. Can it output a part? And when I
draw, I want Belka underneath as a layer."

WHAT A MODEL CAN AND CANNOT DO HERE
-----------------------------------
SDXL has no alpha. It always returns a filled rectangle, so "output a part" is
never something the model does - the transparency comes from CUTTING. What the
model IS for is making the part look finished and making it sit in the same
light as the body it will be layered over.

So the shape of this is:

  prep : Eva's part layer (transparent PNG, same canvas as the original)
         -> a composite (original + her part) that the model can read
         -> a mask (her alpha, grown) that says "only redraw here"

  cut  : the model's answer x that same mask
         -> a PNG that is JUST the part, transparent everywhere else

Two steps, because the model call sits between them and lives in rk-refine.ps1.

WHY THE MASK IS GROWN. Measured in the image-generation notes: grow_mask_by 24 beat
6 - a tight mask leaves a hard seam because the model never gets to blend the
boundary. Growing on the way IN and cutting tight on the way OUT gives a part
whose edge was painted in context.

WHY THE CUT IS NOT GROWN. The opposite: a part that carries a halo of the body
around it will show that halo when the part moves. The cut uses HER alpha, not
the grown one.
"""
import io
import os
import sys

from PIL import Image, ImageFilter


def grow(mask, px):
    # MaxFilter needs an odd window and it is a square, which is close enough
    # to a disc at this radius and an order of magnitude cheaper than a real
    # dilation. The mask only has to be generous, not exact.
    k = int(px) * 2 + 1
    if k < 3:
        return mask
    return mask.filter(ImageFilter.MaxFilter(k))


def prep(part_path, base_path, out_composite, out_mask, growpx=24):
    part = Image.open(part_path).convert('RGBA')
    base = Image.open(base_path).convert('RGBA')
    if part.size != base.size:
        raise SystemExit(
            'the part is %dx%d but the original is %dx%d. Draw on the original '
            'canvas so the part lands where you put it.' % (part.size + base.size))

    a = part.split()[3]
    if a.getextrema()[1] == 0:
        raise SystemExit('that layer is completely transparent - nothing was drawn on it.')

    comp = base.copy()
    comp.alpha_composite(part)
    comp.convert('RGB').save(out_composite)

    m = grow(a.point(lambda v: 255 if v > 8 else 0), growpx)
    # LoadImageMask reads the RED channel, so the mask is written as plain grey.
    Image.merge('RGB', (m, m, m)).save(out_mask)

    box = a.getbbox()
    print('part      : %s' % os.path.basename(part_path))
    print('canvas    : %dx%d   drawn area: %s' % (part.size[0], part.size[1], str(box)))
    print('mask grown: %d px' % growpx)


def cut(result_path, part_path, out_path):
    res = Image.open(result_path).convert('RGBA')
    part = Image.open(part_path).convert('RGBA')
    if res.size != part.size:
        res = res.resize(part.size, Image.LANCZOS)

    # HER alpha, hard. Anything softer drags a rim of the body along, and that
    # rim is exactly what shows when the part moves.
    a = part.split()[3].point(lambda v: 255 if v > 8 else 0)
    out = Image.new('RGBA', res.size, (0, 0, 0, 0))
    out.paste(res, (0, 0), a)

    box = a.getbbox()
    out.save(out_path)
    # Also written trimmed: the layer only needs the part, and a full-canvas
    # PNG makes the sprite import guess where the content is.
    if box:
        trimmed = os.path.splitext(out_path)[0] + '_trim.png'
        out.crop(box).save(trimmed)
        print('trimmed   : %s  %dx%d  at (%d,%d)' % (
            os.path.basename(trimmed), box[2] - box[0], box[3] - box[1], box[0], box[1]))
    print('cut       : %s' % os.path.basename(out_path))


def underlay(base_path, out_path, opacity=0.30):
    # A faded copy to trace over, for when lowering the layer opacity by hand is
    # one step too many. White ground on purpose: a faded picture on transparency
    # looks like nothing at all in most editors.
    base = Image.open(base_path).convert('RGBA')
    white = Image.new('RGBA', base.size, (255, 255, 255, 255))
    faded = Image.blend(white, base, opacity)
    faded.convert('RGB').save(out_path)
    print('underlay  : %s  (%d%%)' % (os.path.basename(out_path), int(opacity * 100)))


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit('usage: rk-part.py prep|cut|underlay ...')
    mode = sys.argv[1]
    if mode == 'prep':
        prep(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5],
             int(sys.argv[6]) if len(sys.argv) > 6 else 24)
    elif mode == 'cut':
        cut(sys.argv[2], sys.argv[3], sys.argv[4])
    elif mode == 'underlay':
        underlay(sys.argv[2], sys.argv[3],
                 float(sys.argv[4]) if len(sys.argv) > 4 else 0.30)
    else:
        raise SystemExit('unknown mode: ' + mode)
