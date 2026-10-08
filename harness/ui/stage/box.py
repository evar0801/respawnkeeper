"""Crop an exact box out of a PNG, enlarged, with a 10px grid drawn on it so the
row/column numbers can be read straight off the picture.
Usage: box.py <in> <out> <x0> <y0> <x1> <y1> [scale]"""
import sys
from PIL import Image, ImageDraw

src, dst = sys.argv[1], sys.argv[2]
x0, y0, x1, y1 = (int(v) for v in sys.argv[3:7])
s = int(sys.argv[7]) if len(sys.argv) > 7 else 8

im = Image.open(src).convert('RGBA').crop((x0, y0, x1, y1))
im = im.resize((im.width * s, im.height * s), Image.NEAREST)
d = ImageDraw.Draw(im)
for x in range(x0 - x0 % 10, x1, 10):
    px = (x - x0) * s
    d.line([(px, 0), (px, im.height)], fill=(255, 0, 255, 160))
    d.text((px + 2, 2), str(x), fill=(255, 0, 255, 255))
for y in range(y0 - y0 % 10, y1, 10):
    py = (y - y0) * s
    d.line([(0, py), (im.width, py)], fill=(255, 255, 0, 160))
    d.text((2, py + 2), str(y), fill=(255, 255, 0, 255))
im.save(dst)
print('%s  box x%d..%d y%d..%d -> %dx%d' % (dst, x0, x1, y0, y1, im.width, im.height))
