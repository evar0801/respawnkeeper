"""paint-signs.py - write readable text into the rail backdrop's two neon signs.

Run by build-belka.ps1 AFTER the first derive pass and BEFORE the second. It
edits the base frame (idle.0) of art/rail-bg.rkspr in place; the derive step
then turns the repainted slab back into the state light.

WHY THIS IS NOT DONE IN THE SOURCE ART, which is where belka-rail's hand-painted
frame lives. Measured 2026-09-13: feeding art/rail-bg.png (the importer's own
36-colour output) back through rk-import-art.ps1 -Colors 36 comes back with
THIRTY-FOUR distinct colours, not 36 - with no edits at all, as a control. The
palette letter each colour gets is assigned in sorted order, so losing two
colours renumbers the legend, and build-belka.ps1's $signMap names those letters
by hand ('9=*,8=*,...'). A hand-painted PNG would therefore light up whatever
happened to land on '9' - the duvet, say - instead of the sign. So the text goes
into the .rkspr, which is the artefact the panel actually reads.

Nothing here is hardcoded to today's palette: the slab colour, the stroke colour
and the little sign's mark colour are all read back out of the file, so this
still does the right thing after a re-import that renumbers everything.

  python paint-signs.py [path/to/rail-bg.rkspr]
"""
import collections
import io
import os
import re
import sys

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
SPR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'art', 'rail-bg.rkspr')

# The same two rectangles build-belka.ps1 passes as $signBox. Kept in step with
# it by hand, which is survivable because the boxes describe the PICTURE and the
# picture only changes when somebody replaces the art.
RIGHT = (190, 292, 38, 82)
LEFT = (46, 96, 62, 82)

# WHERE THE LETTERS GO, as x0,x1,y0,y1. Measured once off the unpainted art
# (2026-09-13) and written down rather than re-derived, because the measurement
# only holds while the art holds - and a measurement taken from the PAINTED file
# gives a different answer, which is how the first version of this script talked
# itself down to an 8px font on its second run.
#
# The big sign is drawn in perspective: over its 24 usable rows the left edge
# walks from x199 to x195 and the right edge from x278 to x271. These are the
# INSCRIBED rectangle - the part that is inside the slab on EVERY row - so no
# character can be sliced by an edge that has already moved in. Replace the art
# and both of these have to be measured again.
RIGHT_FIELD = (199, 271, 50, 73)      # y range, and the edges at its top row
LEFT_FIELD = (50, 76, 67, 76)         # 27 x 10
PAD_X, PAD_Y = 1, 1                   # one pixel of air inside the frame


def edge_left(y):
    """The sign's own left edge on row y: 199 at the top, 195 at the bottom."""
    span = RIGHT_FIELD[3] - RIGHT_FIELD[2]
    return 199 - int(round((y - RIGHT_FIELD[2]) * 4.0 / span))


def edge_right(y):
    """...and the right edge: 278 down to 271."""
    span = RIGHT_FIELD[3] - RIGHT_FIELD[2]
    return 278 - int(round((y - RIGHT_FIELD[2]) * 7.0 / span))

RIGHT_TEXT = '怠惰ニ伏ス'
# The left-hand sign is 27x10. No real font reaches down there, so it gets a
# 3x5 pixel alphabet - six characters is 24 columns, which is why it fits.
LEFT_TEXT = 'RBELKA'         # R = the radical sign, then BELKA
FONT = 'C:/Windows/Fonts/YuGothB.ttc'

F35 = {
    'B': ['##.', '#.#', '##.', '#.#', '##.'],
    'E': ['###', '#..', '##.', '#..', '###'],
    'L': ['#..', '#..', '#..', '#..', '###'],
    'K': ['#.#', '#.#', '##.', '#.#', '#.#'],
    'A': ['.#.', '#.#', '###', '#.#', '#.#'],
    'R': ['..###', '..#..', '#.#..', '#.#..', '.#...'],   # the radical sign
}


def load(path):
    """-> (palette, {frame: [rows]}, lines, {frame: [line index per row]})"""
    lines = io.open(path, encoding='utf-8').read().split('\n')
    pal, frames, where = {}, {}, {}
    cur, mode = None, None
    for i, line in enumerate(lines):
        if line.startswith('#') or (mode is None and not line.strip()):
            continue
        if line.startswith('@palette'):
            mode = 'pal'
            continue
        m = re.match(r'^@frame\s+(\S+)(?:\s+from\s+(\S+))?\s*$', line)
        if m:
            cur, base = m.group(1), m.group(2)
            frames[cur] = list(frames[base]) if base else []
            where[cur] = list(where.get(base, [])) if base else []
            mode = 'delta' if base else 'full'
            continue
        if line.startswith('@'):
            mode = None
            continue
        if mode == 'pal':
            mm = re.match(r'^(\S+)\s*=\s*(#\S+)\s*$', line)
            if mm:
                pal[mm.group(1)] = mm.group(2)
        elif mode == 'full':
            # A blank line is not row zero of anything. rk-derive.ps1 leaves one
            # behind each time it rewrites the file, and counting it as a row
            # would shift every row index below it by one.
            if not line.strip():
                continue
            frames[cur].append(line)
            where[cur].append(i)
        elif mode == 'delta':
            mm = re.match(r'^(\d+)\s*=\s*(.*)$', line)
            if mm:
                frames[cur][int(mm.group(1))] = mm.group(2)
    return pal, frames, lines, where


def commonest(seq):
    return collections.Counter(seq).most_common(1)[0][0]


def luminance(hexcolour):
    """WCAG relative luminance of '#rrggbb'."""
    ch = [int(hexcolour[i:i + 2], 16) / 255.0 for i in (1, 3, 5)]
    ch = [(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4) for v in ch]
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]


def main():
    pal, frames, lines, where = load(SPR)
    if 'lit.0' not in frames:
        raise SystemExit('rail-bg.rkspr has no lit.0 yet - run the derive step first')
    lit, idle = frames['lit.0'], frames['idle.0']
    rows = [list(r) for r in idle]

    # ---- what to wipe: whatever the slab has ENCLOSED ----------------------
    # RUN THIS TWICE AND IT MUST DO THE SAME THING. The first version found the
    # field by run length - "the first stretch of lit cells from the left is the
    # frame" - which is true of the generated scribble and false the moment the
    # field is mostly bare slab with thin strokes on it. Re-running it therefore
    # measured a 44x15 field instead of 85x27 and set the text at 8px.
    #
    # A cell is inside the sign if it has lit slab somewhere to its left AND
    # somewhere to its right on the same row. That is true of the old scribble
    # and of the text this script writes, and false of the wall outside the
    # slab, whatever state the file is in when it is read.
    x0, x1, y0, y1 = RIGHT
    enclosed = []
    for y in range(y0, y1 + 1):
        row = lit[y]
        xs = [x for x in range(x0, x1 + 1) if row[x] == '*']
        if len(xs) < 2:
            continue
        for x in range(xs[0] + 1, xs[-1]):
            if row[x] not in '*+':
                enclosed.append((x, y))
    if not enclosed:
        raise SystemExit('nothing is enclosed by the big sign - has the art changed?')

    slab = commonest([idle[y][x] for y in range(y0, y1 + 1)
                      for x in range(x0, x1 + 1) if lit[y][x] == '*'])

    # THE STROKE IS THE DARKEST COLOUR THE PALETTE HAS, not the one the
    # generated scribble happened to use.
    #
    # The scribble was drawn in #A119A0, a magenta. Against the cyan slab of a
    # running server that is 4.44:1 and reads fine - and against the MAGENTA
    # slab of a stopped one it is 1.63:1. So the first version of this script
    # wrote a sign saying "lying down in idleness" that was legible only while
    # nothing was idle. Measured with the darkest entry (#030408) instead:
    # run 13.70:1, care 12.75:1, halt 6.08:1, stopped 5.04:1 - every state
    # above AA. Picked by luminance rather than hardcoded, so a re-import that
    # renumbers the palette still gets the darkest one.
    #
    # "Not mapped" matters: a colour that build-belka.ps1's $signMap turns into
    # * or + is part of the LIGHT, and painting letters in it would make them
    # vanish rather than cut out. The mapped set is read back out of the file
    # instead of copied from that script, so the two cannot drift.
    mapped = set()
    for bx0, bx1, by0, by1 in (RIGHT, LEFT):
        for yy in range(by0, by1 + 1):
            for xx in range(bx0, bx1 + 1):
                if lit[yy][xx] in '*+':
                    mapped.add(idle[yy][xx])
    usable = [k for k in pal if k not in mapped]
    if not usable:
        raise SystemExit('every palette entry is part of the sign light - nothing to draw letters in')
    stroke = min(usable, key=lambda k: luminance(pal[k]))
    brightest = max(mapped, key=lambda k: luminance(pal[k]))
    print('big sign  : %d enclosed cells, slab=%s %s, stroke=%s %s'
          % (len(enclosed), slab, pal[slab], stroke, pal[stroke]))

    # ---- clear the old scribble WITHOUT flattening the sign -----------------
    # The first version filled the whole field with one colour and the result
    # was, in Eva's words, dasai: the slab has a gradient across it, and wiping
    # it to a single palette entry turned a lit sign into a flat rectangle with
    # a font on it. Each old pixel takes the colour of the nearest lit pixel on
    # its own row instead, so the shading survives the edit.
    encset = set(enclosed)
    for (x, y) in enclosed:
        pick = None
        for step in range(1, (x1 - x0) + 1):
            for xx in (x - step, x + step):
                if x0 <= xx <= x1 and (xx, y) not in encset and lit[y][xx] == '*':
                    pick = idle[y][xx]
                    break
            if pick:
                break
        rows[y][x] = pick if pick else slab

    # ---- the letters: TALL, and leaning with the sign -----------------------
    # Eva: "make it tall, fit it in, mind the perspective; a bit of crushing is
    # fine." Both are measured off the art rather than eyeballed:
    #   TALL - the field is 24 rows and five SQUARE glyphs only used 14 of them.
    #          Rendered at the field's full height and squeezed to width, which
    #          is what a condensed sign face is, and it thickens the horizontal
    #          strokes that were disappearing at 14px.
    #   LEAN - the slab is a parallelogram: over its 24 usable rows the left
    #          edge walks 199 -> 195 and the right 278 -> 271. Text set square
    #          in the bounding box either sat off-centre or lost its last glyph
    #          to an edge that had already moved in. Each row starts from the
    #          sign's own left edge, so the line leans with it.
    ty0, ty1 = RIGHT_FIELD[2] + PAD_Y, RIGHT_FIELD[3] - PAD_Y
    th = ty1 - ty0 + 1
    avail = min(edge_right(y) - edge_left(y) + 1 for y in range(ty0, ty1 + 1)) - 2 * PAD_X
    gw = avail // len(RIGHT_TEXT)
    if gw < 8:
        raise SystemExit('only %d columns per character - has the art changed?' % gw)
    font = ImageFont.truetype(FONT, th)
    strip = Image.new('L', (th * len(RIGHT_TEXT), th), 0)
    d = ImageDraw.Draw(strip)
    for i, ch in enumerate(RIGHT_TEXT):
        bb = font.getbbox(ch)
        gwid, ghei = bb[2] - bb[0], bb[3] - bb[1]
        d.text((i * th + (th - gwid) // 2 - bb[0], (th - ghei) // 2 - bb[1]), ch, fill=255, font=font)
    # A neon cut-out has no antialiasing, so the mask is taken to 1 bit rather
    # than dithered into palette entries that are not there.
    strip = strip.resize((gw * len(RIGHT_TEXT), th), Image.LANCZOS).point(
        lambda v: 255 if v >= 110 else 0)
    mk = strip.load()
    sw, sh = strip.size

    painted = 0
    for j in range(sh):
        y = ty0 + j
        room = edge_right(y) - edge_left(y) + 1 - 2 * PAD_X
        left = edge_left(y) + PAD_X + (room - sw) // 2
        for i in range(sw):
            if mk[i, j]:
                x = left + i
                if edge_left(y) <= x <= edge_right(y):
                    rows[y][x] = stroke
                    painted += 1
    print('            "%s" at %dx%d per character, %d stroke pixels'
          % (RIGHT_TEXT, gw, th, painted))

    # ---- the little sign ----------------------------------------------------
    lx0, lx1, ly0, ly1 = LEFT
    marks = [(x, y) for y in range(ly0, ly1 + 1) for x in range(lx0, lx1 + 1)
             if lit[y][x] in '*+']
    if not marks:
        raise SystemExit('no marks found inside the little sign - has the art changed?')
    mark = commonest([idle[y][x] for x, y in marks])
    mx0, mx1, my0, my1 = LEFT_FIELD
    ground = commonest([idle[y][x] for y in range(my0, my1 + 1)
                        for x in range(mx0, mx1 + 1) if lit[y][x] not in '*+'])
    lw = sum(len(F35[c][0]) for c in LEFT_TEXT) + len(LEFT_TEXT) - 1
    box_w, box_h = mx1 - mx0 + 1, my1 - my0 + 1
    print('little sign: %dx%d, mark=%s %s, ground=%s %s, text needs %dx5'
          % (box_w, box_h, mark, pal[mark], ground, pal[ground], lw))
    if lw > box_w or 5 > box_h:
        raise SystemExit('the little sign cannot hold %s' % LEFT_TEXT)

    for y in range(my0, my1 + 1):
        for x in range(mx0, mx1 + 1):
            rows[y][x] = ground
    ox = mx0 + (box_w - lw) // 2
    oy = my0 + (box_h - 5) // 2
    for c in LEFT_TEXT:
        g = F35[c]
        for j, gr in enumerate(g):
            for i, on in enumerate(gr):
                if on == '#':
                    rows[oy + j][ox + i] = mark
        ox += len(g[0]) + 1

    # ---- write idle.0 back --------------------------------------------------
    # Only the rows that changed, and only in the base frame. lit.0 / lit.1 are
    # regenerated from this by the derive step that runs next.
    touched = sorted(set(y for _, y in enclosed)
                    | set(range(RIGHT_FIELD[2], RIGHT_FIELD[3] + 1))
                    | set(range(LEFT_FIELD[2], LEFT_FIELD[3] + 1)))
    out = list(lines)
    for y in touched:
        out[where['idle.0'][y]] = ''.join(rows[y])
    data = '\n'.join(out).encode('utf-8')
    tmp = SPR + '.tmpwrite'
    with open(tmp, 'wb') as fh:
        fh.write(data)
    os.replace(tmp, SPR)
    print('wrote %d rows of idle.0 in %s' % (len(touched), SPR))


if __name__ == '__main__':
    main()
