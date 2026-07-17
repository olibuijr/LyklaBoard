#!/usr/bin/env python3
"""
compose.py — Stage C of the v2 screenshot pipeline.

Reads store/screenshots/copy.md FRESH on every run (the owner edits it), lays
the brand gradient behind the Blender phone render, draws a soft drop shadow,
overlays the caption typography (matched to store/screenshots/build/generate.py:
same palette, same sizes, same tight tracking), and writes
  store/screenshots/v2/export/{en-US,is-IS}/0N_name.png   at exactly 1260x2736
plus a 6-up en-US contact sheet at store/screenshots/v2/contact-sheet.png.

No uploading. Pure Pillow; no browser.
"""

import re
import sys
import pathlib
from PIL import Image, ImageDraw, ImageFont

HERE = pathlib.Path(__file__).parent
COPY = HERE.parent / "copy.md"
RENDERS = HERE / "blender"
EXPORT = HERE / "export"

W, H = 1260, 2736

# Palette — from store/screenshots/build/generate.py (site tokens). The v2
# stage is DARK: the brand ink tones (INK / the terminal bar #2a2926) become
# the backdrop, the cream tones become the type.
BG = (0xFA, 0xF9, 0xF6)          # cream — title text on the dark stage
BG_RAISED = (0xF1, 0xEF, 0xE9)
INK = (0x1C, 0x1B, 0x1A)         # backdrop base
INK_RAISED = (0x2A, 0x29, 0x26)  # backdrop radial center (generate.py term bar)
INK_SOFT = (0x55, 0x52, 0x4D)
TYPE_SOFT = (0xB5, 0xB1, 0xAA)   # subtitle on dark
CODE_BG = (0x33, 0x31, 0x2E)
CODE_FG = (0xE8, 0xE5, 0xE0)     # generate.py term-body text

SLUGS = {1: "hero", 2: "accents", 3: "blend", 4: "bin",
         5: "dictionary", 6: "privacy"}
LOCALES = {"is": "is-IS", "en": "en-US"}

SF = "/System/Library/Fonts/SFNS.ttf"
SF_MONO = "/System/Library/Fonts/SFNSMono.ttf"


def font(size, weight=400, mono=False):
    path = SF_MONO if mono else SF
    f = ImageFont.truetype(path, size)
    try:
        if mono:
            # SFNSMono axes: [YAXS, Weight]
            f.set_variation_by_axes([294, weight])
        else:
            # SFNS axes: [Width, Optical Size, GRAD, Weight]
            optical = max(17, min(96, size * 0.55))
            f.set_variation_by_axes([100, optical, 400, weight])
    except Exception:
        pass
    return f


# ------------------------------------------------------------- copy.md -------
def parse_copy():
    """{shot: {locale: {"title": [lines], "sub": str, "meta": str|None}}}"""
    text = COPY.read_text(encoding="utf-8")
    shots = {}
    current = None
    for line in text.splitlines():
        m = re.match(r"^##\s+(\d+)\s", line)
        if m:
            current = int(m.group(1))
            shots[current] = {"is-IS": {}, "en-US": {}}
            continue
        if current is None:
            continue
        m = re.match(r"^-\s+(Title|Sub|Meta|Pitch)\s+\((is|en)\):\s+(.*)$",
                     line)
        if m:
            kind, loc, val = m.group(1).lower(), LOCALES[m.group(2)], m.group(3)
            if kind == "title":
                shots[current][loc]["title"] = [
                    s.strip() for s in val.split(" / ")]
            else:
                shots[current][loc][kind] = val.strip()
    return shots


# ------------------------------------------------------------ drawing --------



def draw_wrapped(draw, text, fnt, fill, y, max_w, line_h, tracking=0,
                 mono_spans=None):
    """Center-draw `text` wrapped to max_w. Returns next y. `text` may carry
    `code` spans (backticks) rendered in mono with a soft chip behind."""
    # Tokenize into (word, is_code) preserving order.
    tokens = []
    for part in re.split(r"(`[^`]+`)", text):
        if not part:
            continue
        if part.startswith("`"):
            tokens.append((part[1:-1], True, False))
        else:
            for w in part.split(" "):
                if not w:
                    continue
                # Punctuation-only fragments (e.g. the "." after a code chip)
                # glue to the previous token instead of wrapping alone.
                if re.fullmatch(r"[.,;:!?…]+", w) and tokens:
                    if tokens[-1][1]:          # after a code chip: glue token
                        tokens.append((w, False, True))
                    else:
                        tokens[-1] = (tokens[-1][0] + w, False, tokens[-1][2])
                else:
                    tokens.append((w, False, False))
    mono_f = font(int(fnt.size * 0.86), 500, mono=True)

    def width(tok, code):
        f = mono_f if code else fnt
        return draw.textlength(tok, font=f) + (18 if code else 0)

    space_w = draw.textlength(" ", font=fnt)
    lines, cur, cur_w = [], [], 0.0
    for tok, code, glue in tokens:
        w_tok = width(tok, code)
        add = w_tok if (not cur or glue) else space_w + w_tok
        if cur and not glue and cur_w + add > max_w:
            lines.append(cur)
            cur, cur_w = [(tok, code, glue)], w_tok
        else:
            cur.append((tok, code, glue))
            cur_w += add
    if cur:
        lines.append(cur)

    for line in lines:
        total = (sum(width(t, c) for t, c, _ in line)
                 + space_w * sum(1 for i, (_, _, g) in enumerate(line)
                                 if i > 0 and not g))
        x = (W - total) / 2
        for i, (tok, code, glue) in enumerate(line):
            if i > 0 and not glue:
                x += space_w
            if code:
                w_tok = draw.textlength(tok, font=mono_f)
                pad = 9
                draw.rounded_rectangle(
                    [x, y + fnt.size * 0.02, x + w_tok + 2 * pad,
                     y + fnt.size * 1.12],
                    radius=12, fill=CODE_BG)
                draw.text((x + pad, y + fnt.size * 0.08), tok,
                          font=mono_f, fill=CODE_FG)
                x += w_tok + 2 * pad
            else:
                draw.text((x, y), tok, font=fnt, fill=fill)
                x += draw.textlength(tok, font=fnt)
        y += line_h
    return y


def draw_title(draw, lines, y):
    # generate.py: 112px, weight 700, letter-spacing -3px, line-height 1.02
    f = font(112, 700)
    for line in lines:
        # letter-spacing -3px: draw per-char
        widths = [draw.textlength(c, font=f) for c in line]
        total = sum(widths) - 3 * (len(line) - 1)
        x = (W - total) / 2
        for c, w_c in zip(line, widths):
            draw.text((x, y), c, font=f, fill=BG)
            x += w_c - 3
        y += int(112 * 1.02) + 8
    return y


def compose_shot(shot, loc, content, out_path):
    # The render is opaque: the device sits in a physically lit dark studio
    # (real backdrop, real contact shadow) — no synthetic gradient/shadow.
    render = RENDERS / f"render-{shot:02d}.png"
    canvas = (Image.open(render).convert("RGBA")
              .resize((W, H), Image.LANCZOS))

    draw = ImageDraw.Draw(canvas)
    y = 150
    y = draw_title(draw, content["title"], y)
    y += 26  # margin-top 34 minus title bottom padding
    sub_f = font(46, 450)
    y = draw_wrapped(draw, content["sub"], sub_f, TYPE_SOFT, y,
                     max_w=W - 2 * 96, line_h=int(46 * 1.32))
    # Hero meta chips dropped: the caption sub already carries that line
    # (owner: don't double-stack sub + meta).

    out_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(out_path, "PNG")
    print("wrote", out_path)


def contact_sheet(paths, out):
    thumb_w = 420
    thumb_h = round(thumb_w * H / W)
    sheet = Image.new("RGB", (thumb_w * len(paths) + 20 * (len(paths) + 1),
                              thumb_h + 40), (30, 29, 28))
    x = 20
    for p in paths:
        im = Image.open(p).resize((thumb_w, thumb_h), Image.LANCZOS)
        sheet.paste(im, (x, 20))
        x += thumb_w + 20
    sheet.save(out, "PNG")
    print("wrote", out)


def main():
    shots = parse_copy()
    made = {}
    for shot, slug in SLUGS.items():
        for loc in ("en-US", "is-IS"):
            content = shots.get(shot, {}).get(loc)
            if not content or "title" not in content:
                print(f"copy.md missing shot {shot} {loc} — skipped",
                      file=sys.stderr)
                continue
            render = RENDERS / f"render-{shot:02d}.png"
            if not render.exists():
                print(f"missing {render} — run render-all.sh", file=sys.stderr)
                continue
            out = EXPORT / loc / f"{shot:02d}_{slug}.png"
            compose_shot(shot, loc, content, out)
            made.setdefault(loc, []).append(out)
    if len(made.get("en-US", [])) == len(SLUGS):
        contact_sheet(made["en-US"], HERE / "contact-sheet.png")


main()
