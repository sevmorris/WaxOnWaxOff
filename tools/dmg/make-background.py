#!/usr/bin/env python3
"""Generate the DMG installer window background (1x and 2x).

This is the source of truth for the installer art. There is no design-tool
document behind it — the geometry lives here so the offsets are reviewable and
cannot drift out of sync with a file nobody can find.

Layout constraints worth knowing before changing anything:

  * Finder's status bar and path bar are GLOBAL Finder view settings, not
    per-window. dmg-settings.py asks for them to be hidden and the .DS_Store
    carries that, but Finder shows them anyway on machines where the user has
    them enabled — they cost roughly 70 pt of window height. Everything must
    therefore sit inside the top ~300 pt; below that is liable to be clipped.
    An earlier layout put the caption at y 291-305 and it was cut off in the
    mounted window.

  * The arrow is centred on ARROW_XY, which must match the midpoint between the
    two icon slots in dmg-settings.py (currently x=270) and their vertical
    centre (y=150). If you move the icons there, move the arrow here.

Usage:
    python3 tools/dmg/make-background.py --app-name "MyApp" --slug myapp
"""
# Shared verbatim across the sibling app repos (DoublEnder, WaxOnWaxOff,
# ClipHack, FilmStrip). Keep the copies byte-identical: scripts/check-shared.sh
# compares them and a release preflight fails when they drift. Anything
# app-specific belongs in that repo's release.sh, not here.
import argparse
import os
from PIL import Image, ImageDraw, ImageFont

W, H = 540, 380                       # window content size, 1x

# ── Palette ──────────────────────────────────────────────────────────────────
GRAD_TOP    = (244, 246, 249)         # linear vertical gradient, uniform in x
GRAD_BOTTOM = (210, 215, 225)
INK         = (40, 45, 55)            # arrow fill and caption
EDGE        = (240, 242, 245)         # light outline that lifts the arrow off

# ── Layout (1x points) ───────────────────────────────────────────────────────
# Both sit high in the window deliberately; see the note about Finder chrome.
ARROW_XY      = (270.5, 150)          # matches the icon midpoint and height
ARROW_W       = 70                    # overall length, shaft tip to head tip
ARROW_SHAFT_H = 17
ARROW_HEAD_LEN = 31
ARROW_HEAD_H  = 55
CAPTION_XY    = (270, 258)            # centre; ~40 pt clear of the chrome cut
CAPTION_SIZE  = 17
# Eurostile is a licensed font and is not in the repo; it has to be installed
# locally. Checked in order, first hit wins.
FONT_CANDIDATES = ["~/Library/Fonts/Eurostile.otf",
                   "/Library/Fonts/Eurostile.otf"]


def caption_font(px: int) -> ImageFont.FreeTypeFont:
    for c in FONT_CANDIDATES:
        path = os.path.expanduser(c)
        if os.path.exists(path):
            return ImageFont.truetype(path, px)
    raise SystemExit(
        "Eurostile not found — install it, or add its path to FONT_CANDIDATES.\n"
        "Looked in: " + ", ".join(FONT_CANDIDATES))


def gradient(scale: int) -> Image.Image:
    img = Image.new("RGB", (W * scale, H * scale))
    d = ImageDraw.Draw(img)
    span = H * scale - 1
    for y in range(H * scale):
        t = y / span
        d.line([(0, y), (W * scale, y)],
               fill=tuple(round(GRAD_TOP[i] + (GRAD_BOTTOM[i] - GRAD_TOP[i]) * t)
                          for i in range(3)))
    return img


def arrow_points(scale: int):
    cx, cy = ARROW_XY[0] * scale, ARROW_XY[1] * scale
    half_w = ARROW_W * scale / 2
    sh = ARROW_SHAFT_H * scale / 2
    hh = ARROW_HEAD_H * scale / 2
    x_left, x_right = cx - half_w, cx + half_w
    x_head = x_right - ARROW_HEAD_LEN * scale
    return [(x_left, cy - sh), (x_head, cy - sh), (x_head, cy - hh),
            (x_right, cy), (x_head, cy + hh), (x_head, cy + sh), (x_left, cy + sh)]


def build(scale: int, app_name: str) -> Image.Image:
    img = gradient(scale)
    d = ImageDraw.Draw(img)
    pts = arrow_points(scale)
    d.polygon(pts, fill=INK, outline=EDGE, width=2 * scale)
    d.polygon(pts, fill=INK)          # refill so the stroke sits outside the ink

    text = f"Drag {app_name} to Applications"
    font = caption_font(CAPTION_SIZE * scale)
    tw = d.textlength(text, font=font)
    bbox = d.textbbox((0, 0), text, font=font)
    d.text((CAPTION_XY[0] * scale - tw / 2,
            CAPTION_XY[1] * scale - (bbox[1] + bbox[3]) / 2),
           text, font=font, fill=INK)
    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    # Required rather than defaulted: this file is shared verbatim, so it
    # cannot carry one app's name. The slug is the one in the committed
    # background's filename, which release.sh names when it is missing.
    ap.add_argument("--app-name", required=True)
    ap.add_argument("--slug", required=True)
    ap.add_argument("--out", default="tools/dmg")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    for scale, suffix in ((1, ""), (2, "@2x")):
        p = os.path.join(a.out, f"dmg-background-{a.slug}{suffix}.png")
        img = build(scale, a.app_name)
        img.save(p, optimize=True)
        print(f"{p}  {img.size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
