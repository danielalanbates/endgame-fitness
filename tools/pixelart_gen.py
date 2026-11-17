#!/usr/bin/env python3
"""
Endgame Fitness — pixel art sprite generator.

Draws cute chibi / side-view RPG sprites on a 32x32 grid from explicit
per-sprite shape programs + limited palettes, auto-adds a 1px dark outline,
then upscales 8x with NEAREST to 256x256 transparent PNGs.

No external art assets, no image APIs. Pillow only.

    python3 tools/pixelart_gen.py [--out DIR]
"""

import argparse
import json
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow required:  python3 -m pip install pillow")

S = 32          # sprite grid
SCALE = 8       # upscale factor -> 256x256
MIN_PIXELS = 200

# ---------------------------------------------------------------- canvas ----

class Canvas:
    """32x32 indexed canvas. Colours are (r,g,b) tuples; None = transparent."""

    def __init__(self, size=S):
        self.size = size
        self.px = [[None] * size for _ in range(size)]

    def set(self, x, y, c):
        if c is None:
            return
        if 0 <= x < self.size and 0 <= y < self.size:
            self.px[y][x] = c

    def get(self, x, y):
        if 0 <= x < self.size and 0 <= y < self.size:
            return self.px[y][x]
        return None

    # --- primitives ---------------------------------------------------

    def rect(self, x0, y0, x1, y1, c):
        for y in range(min(y0, y1), max(y0, y1) + 1):
            for x in range(min(x0, x1), max(x0, x1) + 1):
                self.set(x, y, c)

    def hline(self, x0, x1, y, c):
        self.rect(x0, y, x1, y, c)

    def vline(self, x, y0, y1, c):
        self.rect(x, y0, x, y1, c)

    def ellipse(self, cx, cy, rx, ry, c, fill=True):
        rx = max(rx, 0.5)
        ry = max(ry, 0.5)
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
                if fill:
                    if d <= 1.0:
                        self.set(x, y, c)
                else:
                    if 0.55 <= d <= 1.0:
                        self.set(x, y, c)

    def line(self, x0, y0, x1, y1, c, w=1):
        dx, dy = abs(x1 - x0), abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx - dy
        x, y = x0, y0
        while True:
            if w == 1:
                self.set(x, y, c)
            else:
                r = w // 2
                self.rect(x - r, y - r, x - r + w - 1, y - r + w - 1, c)
            if x == x1 and y == y1:
                break
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x += sx
            if e2 < dx:
                err += dx
                y += sy

    def tri(self, p0, p1, p2, c):
        xs = [p0[0], p1[0], p2[0]]
        ys = [p0[1], p1[1], p2[1]]
        for y in range(min(ys), max(ys) + 1):
            for x in range(min(xs), max(xs) + 1):
                if _in_tri((x, y), p0, p1, p2):
                    self.set(x, y, c)

    def poly(self, pts, c):
        """Scanline fill of an arbitrary polygon."""
        ys = [p[1] for p in pts]
        for y in range(min(ys), max(ys) + 1):
            xs = []
            n = len(pts)
            for i in range(n):
                (x0, y0), (x1, y1) = pts[i], pts[(i + 1) % n]
                if y0 == y1:
                    continue
                if min(y0, y1) <= y < max(y0, y1):
                    xs.append(x0 + (y - y0) * (x1 - x0) / (y1 - y0))
            xs.sort()
            for i in range(0, len(xs) - 1, 2):
                for x in range(int(round(xs[i])), int(round(xs[i + 1])) + 1):
                    self.set(x, y, c)

    # --- post-processing ----------------------------------------------

    def outline(self, c=(26, 20, 34)):
        """Add a 1px dark border around every opaque cluster."""
        add = []
        for y in range(self.size):
            for x in range(self.size):
                if self.px[y][x] is not None:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    if self.get(x + dx, y + dy) is not None:
                        add.append((x, y))
                        break
        for x, y in add:
            self.set(x, y, c)

    def shade(self, c_from, c_to):
        """Darken the bottom-most pixel of each column of colour c_from."""
        for x in range(self.size):
            col = [y for y in range(self.size) if self.px[y][x] == c_from]
            if col:
                self.px[max(col)][x] = c_to

    def count(self):
        return sum(1 for row in self.px for p in row if p is not None)

    def to_image(self):
        img = Image.new("RGBA", (self.size, self.size), (0, 0, 0, 0))
        px = img.load()
        for y in range(self.size):
            for x in range(self.size):
                c = self.px[y][x]
                if c is not None:
                    px[x, y] = (c[0], c[1], c[2], 255)
        return img.resize((self.size * SCALE, self.size * SCALE), Image.NEAREST)


def _sign(p, a, b):
    return (p[0] - b[0]) * (a[1] - b[1]) - (a[0] - b[0]) * (p[1] - b[1])


def _in_tri(p, a, b, c):
    d1, d2, d3 = _sign(p, a, b), _sign(p, b, c), _sign(p, c, a)
    neg = (d1 < 0) or (d2 < 0) or (d3 < 0)
    pos = (d1 > 0) or (d2 > 0) or (d3 > 0)
    return not (neg and pos)


# ---------------------------------------------------------------- palette ---

DARK = (26, 20, 34)
WHITE = (245, 245, 250)
EYE = (30, 28, 46)

SKIN = (255, 214, 175)
SKIN_S = (222, 165, 128)
GREEN = (122, 186, 76)
GREEN_S = (86, 140, 52)
GREY = (176, 184, 196)
GREY_S = (120, 130, 146)
STEEL = (206, 214, 226)
GOLD = (247, 199, 74)
GOLD_S = (196, 146, 34)
BROWN = (140, 96, 58)
BROWN_S = (98, 64, 36)
RED = (214, 76, 68)
BLUE = (86, 140, 226)
CYAN = (140, 214, 236)
PURPLE = (146, 96, 200)
BONE = (232, 228, 208)
BONE_S = (186, 180, 156)


# ------------------------------------------------------- shared body parts ---

def chibi_body(cv, robe, robe_s, skin=SKIN, hood=None, head_cx=15, head_cy=11,
               head_r=6, body_top=17, body_bot=28):
    """Big head + small side-facing body. Returns head centre."""
    # body / robe: trapezoid widening to the ground
    cv.poly([(head_cx - 3, body_top), (head_cx + 4, body_top),
             (head_cx + 6, body_bot), (head_cx - 6, body_bot)], robe)
    cv.hline(head_cx - 6, head_cx + 6, body_bot, robe_s)
    cv.hline(head_cx - 5, head_cx + 5, body_bot - 1, robe_s)
    # head
    cv.ellipse(head_cx, head_cy, head_r, head_r - 1, skin)
    if hood:
        # hood covers the top/back of the head, face left-facing stays open
        for y in range(head_cy - head_r, head_cy + 1):
            for x in range(head_cx - head_r, head_cx + head_r + 1):
                if cv.get(x, y) == skin and (x > head_cx - 2 or y < head_cy - 3):
                    cv.set(x, y, hood)
    return head_cx, head_cy


def face_left(cv, cx, cy, eye=EYE, blush=None):
    """Side-view face looking left: one big eye + mouth."""
    cv.rect(cx - 4, cy - 1, cx - 3, cy, eye)
    cv.set(cx - 4, cy - 1, WHITE)
    cv.set(cx - 3, cy + 2, (200, 120, 110))
    if blush:
        cv.set(cx - 5, cy + 1, blush)


def staff(cv, x, top, bot, shaft, orb, orb2=None):
    cv.vline(x, top + 3, bot, shaft)
    cv.ellipse(x, top + 1, 2.2, 2.2, orb)
    if orb2:
        cv.set(x - 1, top, orb2)


# ---------------------------------------------------------------- sprites ---
# Each function draws one sprite. Distinct geometry per sprite (no recolours).

SPRITES = []


def sprite(name, category, desc):
    def deco(fn):
        SPRITES.append({"fn": fn, "name": name, "category": category,
                        "description": desc})
        return fn
    return deco


# ---- WIZARDS ----------------------------------------------------------------

@sprite("fire_wizard", "wizards", "Chibi fire mage in a red robe with a flame-tipped staff")
def _(cv):
    R, RS = (198, 66, 52), (146, 40, 34)
    chibi_body(cv, R, RS, hood=(226, 112, 60))
    # pointed wizard hat
    cv.tri((15, -1), (8, 7), (22, 7), R)
    cv.hline(7, 23, 7, RS)
    cv.hline(7, 23, 8, RS)
    face_left(cv, 15, 12, blush=(240, 150, 140))
    # beard
    cv.poly([(11, 14), (15, 14), (14, 19), (11, 18)], (250, 240, 230))
    staff(cv, 24, 6, 28, BROWN, (255, 168, 44), (255, 226, 120))
    cv.set(24, 4, (255, 236, 160))
    cv.set(23, 5, (255, 120, 40))


@sprite("ice_wizard", "wizards", "Blue-robed ice mage with crystal shards orbiting a frost staff")
def _(cv):
    B, BS = (92, 148, 214), (56, 100, 160)
    chibi_body(cv, B, BS, hood=(150, 206, 236))
    cv.tri((16, 0), (9, 8), (23, 8), B)
    cv.hline(8, 24, 8, BS)
    face_left(cv, 15, 12)
    # frost shards on the hat
    cv.set(14, 3, CYAN); cv.set(17, 5, CYAN); cv.set(12, 6, WHITE)
    # staff: crystal cluster instead of an orb
    cv.vline(24, 12, 28, (120, 150, 180))
    cv.tri((24, 6), (21, 12), (27, 12), CYAN)
    cv.tri((24, 8), (22, 12), (26, 12), WHITE)
    cv.set(20, 14, CYAN); cv.set(28, 16, CYAN)


@sprite("storm_wizard", "wizards", "Purple storm sorcerer hurling a forked lightning bolt")
def _(cv):
    P, PS = (128, 88, 190), (86, 56, 134)
    chibi_body(cv, P, PS, hood=(170, 140, 226))
    # wide brimmed hat, bent tip
    cv.poly([(16, 1), (10, 8), (22, 8)], P)
    cv.hline(6, 25, 8, PS)
    cv.hline(6, 25, 9, PS)
    cv.set(17, 0, GOLD)
    face_left(cv, 15, 13)
    # lightning bolt in front (no staff)
    cv.poly([(8, 12), (5, 19), (8, 19), (5, 27)], GOLD)
    cv.poly([(8, 13), (6, 18), (8, 18), (6, 25)], (255, 244, 180))
    cv.set(4, 15, GOLD); cv.set(3, 22, GOLD)


@sprite("necro_wizard", "wizards", "Hollow-hooded necromancer with a skull staff and green soul wisps")
def _(cv):
    K, KS = (58, 54, 76), (36, 33, 50)
    # no skin: an empty hood
    cv.poly([(12, 15), (19, 15), (22, 28), (9, 28)], K)
    cv.hline(9, 22, 28, KS)
    cv.ellipse(15, 10, 7, 7, K)
    cv.ellipse(15, 11, 4.5, 5, (14, 12, 20))     # void inside the hood
    cv.set(12, 11, (128, 240, 140)); cv.set(13, 11, (128, 240, 140))
    cv.set(12, 12, (60, 170, 80))
    cv.poly([(15, 2), (8, 10), (22, 10)], KS)
    # skull staff
    cv.vline(25, 10, 28, (72, 60, 50))
    cv.ellipse(25, 8, 2.5, 2.5, BONE)
    cv.set(24, 8, DARK); cv.set(26, 8, DARK)
    cv.set(25, 10, BONE_S)
    # soul wisps
    cv.set(6, 14, (128, 240, 140)); cv.set(7, 18, (90, 200, 110))
    cv.set(5, 21, (128, 240, 140))


# ---- KNIGHTS ----------------------------------------------------------------

@sprite("paladin", "knights", "Gleaming chibi paladin with a winged helm and holy sword")
def _(cv):
    chibi_body(cv, STEEL, GREY_S)
    cv.rect(13, 18, 17, 27, (232, 200, 96))
    cv.vline(15, 19, 26, (255, 250, 220))
    cv.ellipse(15, 11, 6, 6, SKIN)
    cv.ellipse(15, 9, 6.2, 4.5, STEEL)
    cv.hline(9, 21, 11, GREY_S)
    cv.set(11, 13, WHITE); cv.set(12, 13, EYE)
    cv.set(12, 16, (200, 120, 110))
    cv.poly([(9, 6), (3, 3), (4, 9), (9, 9)], WHITE)
    cv.poly([(21, 6), (27, 3), (26, 9), (21, 9)], WHITE)
    cv.set(15, 4, GOLD); cv.set(15, 5, GOLD)
    cv.rect(23, 6, 24, 18, STEEL)
    cv.vline(23, 6, 18, WHITE)
    cv.tri((22, 4), (25, 4), (23, 1), STEEL)
    cv.hline(20, 27, 19, GOLD)
    cv.rect(23, 20, 24, 23, BROWN)
    cv.set(23, 24, GOLD)


@sprite("dark_knight", "knights", "Black-armoured dark knight with horned helm and a jagged greatsword")
def _(cv):
    K, KS = (68, 62, 88), (40, 36, 56)
    chibi_body(cv, K, KS)
    cv.rect(12, 18, 18, 27, KS)
    cv.ellipse(15, 11, 6, 6, K)
    cv.rect(9, 11, 12, 12, (214, 60, 60))       # glowing red slit
    cv.tri((10, 6), (6, 1), (12, 7), KS)        # horns
    cv.tri((20, 6), (24, 1), (18, 7), KS)
    # jagged greatsword, point-down
    cv.poly([(24, 4), (26, 8), (26, 22), (24, 26), (22, 22), (22, 8)], (120, 60, 120))
    cv.vline(24, 6, 22, (188, 120, 200))
    cv.hline(21, 27, 5, (90, 80, 110))
    cv.set(22, 12, DARK); cv.set(26, 17, DARK)  # notches


@sprite("shield_bearer", "knights", "Stout shield-bearer crouched behind a huge kite shield")
def _(cv):
    chibi_body(cv, (150, 158, 176), GREY_S, body_top=18, body_bot=28)
    cv.ellipse(16, 12, 5.5, 5.5, SKIN)
    face_left(cv, 16, 13)
    cv.ellipse(16, 8, 6, 3, (110, 120, 140))    # flat-top helm
    cv.hline(10, 22, 10, GREY_S)
    # huge kite shield dominating the left
    cv.poly([(3, 9), (12, 9), (12, 22), (7, 28), (3, 22)], (196, 70, 62))
    cv.poly([(5, 11), (10, 11), (10, 21), (7, 25), (5, 21)], (232, 220, 200))
    cv.poly([(6, 12), (9, 12), (9, 20), (7, 23), (6, 20)], (196, 70, 62))
    cv.vline(12, 9, 22, GOLD)


@sprite("lancer", "knights", "Blue lancer leaning forward behind a long diagonal lance")
def _(cv):
    chibi_body(cv, (78, 110, 190), (48, 72, 138))
    cv.ellipse(15, 11, 6, 5.5, SKIN)
    cv.ellipse(15, 8, 6.2, 3.5, (200, 210, 230))
    cv.hline(9, 21, 10, (150, 162, 190))
    cv.set(11, 12, WHITE); cv.set(12, 12, EYE)
    cv.set(12, 15, (200, 120, 110))
    cv.poly([(16, 4), (23, 1), (20, 8)], RED)
    cv.line(3, 28, 27, 6, (176, 140, 96), w=3)
    cv.poly([(29, 2), (23, 6), (26, 9)], STEEL)
    cv.ellipse(19, 14, 3, 3, (200, 210, 230))
    cv.hline(2, 6, 28, GOLD)


# ---- GOBLINS ----------------------------------------------------------------

@sprite("goblin_grunt", "goblins", "Hunched green goblin grunt with a rusty dagger and loincloth")
def _(cv):
    cv.poly([(12, 17), (20, 17), (22, 27), (10, 27)], GREEN)
    cv.hline(10, 22, 27, GREEN_S)
    cv.rect(12, 22, 20, 25, BROWN)              # loincloth
    cv.ellipse(15, 11, 6, 5.5, GREEN)
    cv.tri((8, 8), (1, 6), (8, 14), GREEN)      # big pointy ear
    cv.set(4, 9, GREEN_S)
    cv.set(11, 10, WHITE); cv.set(12, 10, EYE)
    cv.set(14, 10, WHITE); cv.set(15, 10, EYE)
    cv.hline(11, 15, 14, (60, 100, 40))         # grin
    cv.set(12, 13, WHITE); cv.set(14, 13, WHITE)  # tusks
    cv.line(23, 20, 26, 13, (170, 120, 90))     # rusty dagger
    cv.line(24, 20, 27, 13, GREY)
    cv.hline(22, 26, 20, BROWN_S)


@sprite("goblin_shaman", "goblins", "Goblin shaman in a bone mask waving a totem rattle")
def _(cv):
    cv.poly([(11, 16), (20, 16), (23, 28), (8, 28)], (150, 110, 70))  # hide robe
    cv.hline(8, 23, 28, BROWN_S)
    for x in (10, 14, 18, 22):
        cv.set(x, 27, BONE)
    cv.ellipse(15, 10, 6, 5.5, GREEN)
    cv.tri((8, 7), (2, 4), (8, 12), GREEN)
    cv.tri((22, 7), (28, 4), (22, 12), GREEN)   # two ears, upright
    cv.poly([(10, 7), (18, 7), (18, 14), (10, 14)], BONE)   # bone mask
    cv.set(12, 10, (214, 60, 60)); cv.set(16, 10, (214, 60, 60))
    cv.hline(11, 17, 13, BONE_S)
    cv.vline(25, 14, 26, BROWN)                 # totem rattle
    cv.ellipse(25, 12, 2.5, 3, BONE)
    cv.set(24, 12, DARK); cv.set(26, 12, DARK)
    cv.set(23, 17, (214, 60, 60)); cv.set(27, 18, (86, 140, 226))


@sprite("goblin_archer", "goblins", "Lean goblin archer drawing a bent shortbow")
def _(cv):
    cv.poly([(14, 17), (21, 17), (23, 27), (12, 27)], GREEN)
    cv.hline(12, 23, 27, GREEN_S)
    cv.rect(14, 18, 21, 21, (110, 84, 60))      # leather jerkin
    cv.ellipse(17, 11, 5.5, 5, GREEN)
    cv.tri((11, 8), (5, 5), (11, 13), GREEN)
    cv.rect(12, 9, 15, 11, (80, 60, 44))        # blindfold-style headband
    cv.set(13, 10, (255, 220, 90))
    # bow arc on the left + drawn arrow
    for y in range(4, 25):
        dx = int(3.2 * (1 - ((y - 14) / 10.5) ** 2))
        cv.set(6 - dx, y, BROWN)
    cv.line(6, 4, 6, 24, (230, 226, 210))       # string
    cv.hline(3, 14, 14, (176, 140, 96))         # arrow shaft
    cv.tri((1, 14), (4, 12), (4, 16), GREY)
    cv.set(14, 13, RED); cv.set(14, 15, RED)


@sprite("goblin_king", "goblins", "Fat goblin king on a gold crown with a jewelled sceptre")
def _(cv):
    cv.ellipse(15, 22, 9, 6, GREEN)             # round belly
    cv.hline(7, 23, 27, GREEN_S)
    cv.rect(10, 20, 20, 23, (150, 50, 60))      # royal sash
    cv.ellipse(15, 11, 6.5, 6, GREEN)
    cv.tri((7, 8), (2, 6), (8, 13), GREEN)
    cv.poly([(9, 5), (10, 1), (13, 4), (15, 0), (17, 4), (20, 1), (21, 5)], GOLD)
    cv.hline(9, 21, 5, GOLD_S)
    cv.set(15, 3, RED)
    cv.set(11, 11, WHITE); cv.set(12, 11, EYE)
    cv.set(16, 11, WHITE); cv.set(17, 11, EYE)
    cv.hline(11, 18, 15, (60, 100, 40))
    cv.set(11, 14, WHITE); cv.set(18, 14, WHITE)
    cv.vline(26, 14, 27, GOLD_S)                # sceptre
    cv.ellipse(26, 12, 2.5, 2.5, (214, 76, 140))


# ---- MONSTERS ---------------------------------------------------------------

@sprite("gargoyle", "monsters", "Stone gargoyle perched with folded bat wings and horns")
def _(cv):
    G, GS = (132, 138, 150), (92, 98, 112)
    cv.poly([(11, 16), (20, 16), (22, 26), (9, 26)], G)
    cv.hline(9, 22, 26, GS)
    cv.rect(9, 26, 12, 27, GS); cv.rect(19, 26, 22, 27, GS)   # clawed feet
    cv.ellipse(15, 10, 6, 5.5, G)
    cv.tri((10, 5), (7, 0), (13, 6), GS)        # horns
    cv.tri((20, 5), (23, 0), (17, 6), GS)
    cv.set(11, 10, (255, 190, 60)); cv.set(12, 10, (255, 120, 30))
    cv.set(17, 10, (255, 190, 60))
    cv.hline(12, 18, 13, (50, 50, 60))
    # folded scalloped wings
    cv.poly([(6, 10), (10, 14), (10, 24), (2, 20)], GS)
    cv.poly([(24, 10), (20, 14), (20, 24), (28, 20)], GS)
    cv.line(6, 11, 4, 19, G); cv.line(24, 11, 26, 19, G)


@sprite("slime", "monsters", "Glossy green blob slime with a wobbling flat base and shine spot")
def _(cv):
    G, GS = (108, 208, 120), (62, 158, 82)
    cv.ellipse(15, 19, 11, 9, G)
    cv.rect(4, 19, 26, 26, G)
    cv.ellipse(15, 11, 5, 4, G)
    cv.hline(4, 26, 26, GS)
    cv.hline(5, 25, 25, GS)
    cv.set(3, 25, GS); cv.set(27, 25, GS)
    cv.ellipse(10, 13, 2.5, 3, (190, 246, 200))
    cv.set(9, 11, WHITE)
    cv.set(11, 19, EYE); cv.set(12, 19, EYE)
    cv.set(11, 18, EYE); cv.set(12, 18, EYE)
    cv.set(19, 19, EYE); cv.set(20, 19, EYE)
    cv.set(19, 18, EYE); cv.set(20, 18, EYE)
    cv.hline(14, 17, 22, (40, 110, 60))
    cv.set(13, 23, (255, 170, 170)); cv.set(14, 23, (255, 170, 170))
    cv.set(20, 23, (255, 170, 170)); cv.set(21, 23, (255, 170, 170))


@sprite("bat", "monsters", "Purple cave bat mid-flap with wide membrane wings and fangs")
def _(cv):
    P = (128, 96, 176)
    cv.ellipse(15, 16, 4, 4.5, P)
    cv.tri((12, 11), (10, 6), (15, 12), P)      # ears
    cv.tri((18, 11), (20, 6), (15, 12), P)
    cv.set(12, 15, (255, 220, 90)); cv.set(13, 15, EYE)
    cv.set(17, 15, (255, 220, 90)); cv.set(18, 15, EYE)
    cv.set(14, 19, WHITE); cv.set(16, 19, WHITE)
    # scalloped wings
    cv.poly([(11, 14), (2, 9), (0, 17), (5, 16), (4, 22), (11, 19)], (96, 70, 140))
    cv.poly([(19, 14), (28, 9), (30, 17), (25, 16), (26, 22), (19, 19)], (96, 70, 140))
    cv.line(11, 15, 3, 11, P); cv.line(19, 15, 27, 11, P)
    cv.line(11, 17, 5, 19, P); cv.line(19, 17, 25, 19, P)


@sprite("skeleton", "monsters", "Grinning skeleton warrior with visible ribcage and a bone club")
def _(cv):
    cv.ellipse(14, 9, 5.5, 5, BONE)
    cv.rect(9, 11, 11, 13, EYE)                 # eye socket (side view)
    cv.set(9, 13, DARK)
    cv.hline(10, 17, 14, BONE_S)
    for x in (11, 13, 15):
        cv.vline(x, 13, 14, DARK)               # teeth gaps
    cv.vline(14, 15, 17, BONE)                  # spine
    cv.vline(14, 18, 24, BONE_S)
    for y in (18, 20, 22):                      # ribs
        cv.hline(10, 18, y, BONE)
        cv.set(10, y + 1, BONE_S); cv.set(18, y + 1, BONE_S)
    cv.rect(11, 25, 13, 28, BONE)               # legs
    cv.rect(16, 25, 18, 28, BONE)
    cv.line(22, 22, 25, 14, BONE)               # bone club
    cv.ellipse(25, 12, 2.2, 2.2, BONE)
    cv.ellipse(22, 23, 2, 2, BONE_S)


@sprite("zombie", "monsters", "Lurching green zombie with arms out, stitches and a lolling tongue")
def _(cv):
    Z, ZS = (128, 168, 108), (88, 124, 74)
    cv.poly([(13, 17), (20, 17), (22, 28), (11, 28)], (108, 96, 130))
    cv.hline(11, 22, 28, (74, 66, 96))
    cv.set(14, 24, ZS); cv.set(19, 22, ZS)
    cv.ellipse(16, 10, 6.5, 6, Z)
    cv.poly([(10, 5), (22, 4), (22, 8), (10, 9)], (74, 96, 60))
    cv.set(12, 11, WHITE); cv.set(13, 11, EYE)
    cv.set(18, 10, WHITE); cv.set(18, 11, EYE)
    cv.hline(12, 19, 15, (60, 50, 60))
    cv.set(15, 16, (214, 100, 120)); cv.set(15, 17, (214, 100, 120))
    cv.set(14, 7, DARK); cv.set(17, 6, DARK); cv.set(20, 12, DARK)
    cv.rect(4, 16, 13, 18, Z); cv.hline(4, 13, 19, ZS)
    cv.rect(2, 15, 5, 19, Z)
    cv.set(2, 14, ZS); cv.set(4, 14, ZS)
    cv.rect(20, 17, 27, 19, Z); cv.hline(20, 27, 20, ZS)
    cv.rect(26, 16, 29, 20, Z)


@sprite("dragon_whelp", "monsters", "Baby red dragon whelp with stubby wings, snout and tail")
def _(cv):
    D, DS = (208, 78, 66), (156, 46, 44)
    cv.ellipse(16, 20, 7, 6, D)                 # body
    cv.hline(9, 23, 25, DS)
    cv.ellipse(11, 22, 5, 3.5, (250, 200, 150))  # pale belly
    cv.ellipse(13, 10, 6, 5, D)                 # head
    cv.poly([(8, 9), (2, 11), (8, 14)], D)      # snout
    cv.set(3, 10, (255, 200, 120))              # smoke puff
    cv.set(10, 9, (255, 230, 120)); cv.set(11, 9, EYE)
    cv.tri((15, 5), (17, 1), (12, 6), DS)       # horn
    cv.poly([(18, 12), (27, 8), (28, 20), (19, 18)], (240, 150, 120))  # wing
    cv.line(19, 13, 27, 10, DS); cv.line(19, 15, 28, 15, DS)
    cv.line(22, 24, 29, 27, D)                  # tail
    cv.tri((28, 24), (31, 27), (28, 30), DS)
    cv.rect(11, 25, 13, 27, DS); cv.rect(18, 25, 20, 27, DS)


@sprite("wolf", "monsters", "Grey dire wolf in profile, snarling with a bushy raised tail")
def _(cv):
    W, WS = (140, 146, 160), (96, 102, 118)
    cv.ellipse(17, 17, 9, 6, W)
    cv.hline(9, 26, 21, WS)
    cv.ellipse(9, 12, 5.5, 4.5, W)
    cv.rect(9, 14, 14, 18, W)
    cv.poly([(2, 12), (7, 10), (7, 15)], W)
    cv.set(2, 12, DARK); cv.set(3, 12, DARK)
    cv.set(6, 11, (255, 200, 60)); cv.set(7, 11, EYE)
    cv.set(4, 14, WHITE); cv.set(6, 14, WHITE)
    cv.poly([(9, 8), (7, 3), (13, 9)], W)
    cv.poly([(13, 8), (16, 4), (11, 9)], WS)
    cv.rect(11, 20, 14, 27, W); cv.rect(21, 20, 24, 27, W)
    cv.rect(15, 21, 18, 27, WS)
    cv.hline(10, 15, 27, WS); cv.hline(20, 25, 27, WS)
    cv.poly([(25, 15), (31, 6), (30, 17), (24, 20)], WS)
    cv.hline(12, 23, 12, WS)


@sprite("spider", "monsters", "Fat black spider with eight jointed legs and red eyes")
def _(cv):
    B, BS = (58, 52, 74), (34, 30, 46)
    cv.ellipse(19, 17, 8, 7, B)                 # abdomen
    cv.ellipse(19, 15, 4, 3, BS)
    cv.set(17, 14, (214, 60, 60)); cv.set(21, 18, (214, 60, 60))
    cv.ellipse(9, 18, 4.5, 4, B)                # cephalothorax
    for ey in (16, 18):
        cv.set(6, ey, (232, 70, 70)); cv.set(8, ey, (232, 70, 70))
    cv.set(4, 17, BS); cv.set(4, 20, BS)        # fangs
    # four jointed legs per side, mirrored above/below
    for i, (ax, ay) in enumerate([(11, 12), (15, 11), (20, 11), (24, 12)]):
        cv.line(ax, 15, ax - 2 + i, ay, BS)
        cv.line(ax - 2 + i, ay, ax - 5 + 2 * i, ay - 5, BS)
    for i, (ax, ay) in enumerate([(11, 24), (15, 25), (20, 25), (24, 24)]):
        cv.line(ax, 20, ax - 2 + i, ay, BS)
        cv.line(ax - 2 + i, ay, ax - 5 + 2 * i, ay + 4, BS)


@sprite("minotaur", "monsters", "Hulking minotaur with a bull head, nose ring and battleaxe")
def _(cv):
    F, FS = (150, 96, 62), (108, 66, 42)
    cv.poly([(8, 15), (22, 15), (24, 28), (7, 28)], F)
    cv.hline(7, 24, 28, FS)
    cv.ellipse(15, 20, 5, 4.5, (196, 150, 110))
    cv.rect(12, 13, 18, 16, FS)
    cv.ellipse(14, 9, 6.5, 5.5, F)
    cv.poly([(6, 8), (10, 7), (10, 13), (6, 12)], (200, 168, 130))
    cv.set(7, 10, DARK); cv.set(7, 11, DARK)
    cv.set(10, 8, (232, 70, 70)); cv.set(11, 8, EYE)
    cv.poly([(9, 4), (3, 1), (10, 6)], BONE)
    cv.poly([(18, 4), (25, 1), (17, 6)], BONE)
    cv.rect(4, 16, 8, 23, F); cv.rect(22, 16, 26, 23, F)
    cv.vline(28, 8, 26, BROWN); cv.vline(27, 8, 26, BROWN_S)
    cv.poly([(24, 6), (31, 5), (31, 14), (24, 13)], GREY)
    cv.line(25, 8, 25, 12, STEEL)


@sprite("imp", "monsters", "Tiny red imp with a forked tail, trident and cheeky grin")
def _(cv):
    R, RS = (220, 90, 76), (168, 56, 50)
    cv.ellipse(14, 20, 5, 5, R)
    cv.hline(9, 19, 24, RS)
    cv.ellipse(14, 11, 6, 5.5, R)               # oversized head
    cv.tri((9, 6), (6, 1), (12, 7), RS)         # horns
    cv.tri((19, 6), (22, 1), (16, 7), RS)
    cv.set(10, 11, (255, 240, 120)); cv.set(11, 11, EYE)
    cv.set(16, 11, (255, 240, 120)); cv.set(17, 11, EYE)
    cv.hline(10, 18, 15, (120, 30, 30))         # wide grin
    cv.set(11, 14, WHITE); cv.set(17, 14, WHITE)
    cv.poly([(19, 16), (25, 13), (26, 21), (19, 21)], RS)  # small wing
    cv.line(10, 23, 4, 26, R)                   # forked tail
    cv.set(3, 25, RS); cv.set(3, 27, RS)
    cv.vline(24, 6, 26, BROWN_S)                # trident
    cv.hline(22, 26, 7, GREY)
    cv.vline(22, 4, 7, GREY); cv.vline(26, 4, 7, GREY); cv.vline(24, 3, 7, GREY)
    cv.rect(11, 24, 13, 26, RS); cv.rect(16, 24, 18, 26, RS)


@sprite("golem", "monsters", "Blocky stone golem built from rough rectangular slabs with a glowing core")
def _(cv):
    S1, S2 = (128, 122, 112), (94, 88, 80)
    cv.rect(9, 12, 22, 24, S1)                  # slab torso
    cv.rect(9, 22, 22, 24, S2)
    cv.rect(11, 5, 20, 12, S1)                  # blocky head
    cv.hline(11, 20, 11, S2)
    cv.set(13, 8, (120, 220, 180)); cv.set(14, 8, (120, 220, 180))
    cv.set(17, 8, (120, 220, 180))
    cv.ellipse(15, 18, 2.5, 2.5, (120, 220, 180))   # glowing core
    cv.ellipse(15, 18, 1.2, 1.2, (220, 255, 240))
    cv.rect(4, 13, 8, 22, S2)                   # arms
    cv.rect(23, 13, 27, 22, S2)
    cv.rect(3, 21, 8, 25, S1); cv.rect(23, 21, 28, 25, S1)   # fists
    cv.rect(10, 25, 14, 28, S2); cv.rect(17, 25, 21, 28, S2)  # feet
    cv.set(12, 15, S2); cv.set(19, 20, S2)      # cracks
    cv.set(18, 14, S2)


@sprite("ghost", "monsters", "Translucent white ghost with a wavy tattered hem and hollow eyes")
def _(cv):
    G, GS = (226, 230, 245), (176, 184, 210)
    cv.ellipse(15, 12, 8, 8, G)
    cv.rect(7, 12, 23, 23, G)
    # wavy hem
    for x in range(7, 24):
        h = 23 + (2 if (x // 3) % 2 == 0 else 0) + ((x % 3 == 1) and 1 or 0)
        cv.vline(x, 23, h, G)
        cv.set(x, h, GS)
    cv.ellipse(12, 11, 1.8, 2.5, (70, 76, 110))
    cv.ellipse(18, 11, 1.8, 2.5, (70, 76, 110))
    cv.ellipse(15, 16, 2, 2.5, (70, 76, 110))   # open wail mouth
    cv.set(10, 7, WHITE); cv.set(11, 6, WHITE)  # highlight
    cv.hline(19, 22, 19, GS)


# ---- ITEMS ------------------------------------------------------------------

@sprite("sword", "items", "Straight steel longsword with a gold crossguard, point up")
def _(cv):
    cv.poly([(15, 1), (18, 6), (18, 19), (12, 19), (12, 6)], STEEL)
    cv.vline(15, 3, 19, WHITE)
    cv.vline(17, 7, 19, GREY_S)
    cv.hline(7, 23, 20, GOLD)
    cv.hline(8, 22, 21, GOLD_S)
    cv.rect(14, 22, 16, 27, BROWN)
    cv.hline(13, 17, 24, BROWN_S)
    cv.ellipse(15, 29, 2.5, 1.8, GOLD)


@sprite("axe", "items", "Heavy double-bearded battleaxe on a wrapped wooden haft")
def _(cv):
    cv.rect(14, 3, 17, 29, BROWN)
    cv.vline(17, 3, 29, BROWN_S)
    for y in (14, 17, 20):
        cv.hline(13, 18, y, (90, 60, 40))       # grip wrap
    cv.poly([(14, 4), (5, 6), (2, 12), (6, 17), (14, 15)], GREY)
    cv.poly([(13, 5), (7, 7), (5, 12), (8, 15), (13, 14)], STEEL)
    cv.poly([(17, 4), (26, 6), (29, 12), (25, 17), (17, 15)], GREY)
    cv.poly([(18, 5), (24, 7), (26, 12), (23, 15), (18, 14)], GREY_S)
    cv.set(15, 2, GOLD); cv.set(16, 2, GOLD)


@sprite("potion", "items", "Round red healing potion in a corked flask with a shine highlight")
def _(cv):
    cv.ellipse(15, 20, 8, 7.5, (72, 66, 96))    # glass
    cv.rect(12, 8, 18, 14, (72, 66, 96))        # neck
    cv.ellipse(15, 21, 6.5, 6, (214, 62, 74))   # liquid
    cv.hline(9, 21, 16, (240, 120, 120))        # liquid surface
    cv.ellipse(11, 18, 1.5, 2, (255, 200, 200))  # highlight
    cv.rect(11, 4, 19, 8, BROWN)                # cork
    cv.hline(11, 19, 4, BROWN_S)
    cv.hline(10, 20, 13, (110, 100, 140))       # collar
    cv.set(18, 24, (255, 160, 160))


@sprite("shield", "items", "Round wooden shield with iron rim, boss and cross bands")
def _(cv):
    cv.ellipse(15, 16, 12, 13, GREY_S)          # rim
    cv.ellipse(15, 16, 10.5, 11.5, (162, 112, 68))
    for x in range(4, 27, 4):                   # plank lines
        cv.vline(x, 5, 28, (128, 84, 50))
    cv.hline(4, 26, 10, (128, 84, 50))
    cv.hline(4, 26, 22, (128, 84, 50))
    cv.ellipse(15, 16, 4, 4, STEEL)             # boss
    cv.ellipse(15, 16, 2, 2, WHITE)
    for p in ((6, 8), (24, 8), (6, 24), (24, 24)):
        cv.set(p[0], p[1], STEEL)               # rivets


@sprite("chest", "items", "Wooden treasure chest with a domed lid, iron bands and gold lock")
def _(cv):
    cv.rect(4, 16, 27, 27, BROWN)               # base
    cv.hline(4, 27, 27, BROWN_S)
    cv.hline(4, 27, 26, BROWN_S)
    cv.poly([(4, 16), (6, 9), (25, 9), (27, 16)], (168, 116, 68))   # domed lid
    cv.hline(4, 27, 15, BROWN_S)
    cv.hline(4, 27, 16, (90, 58, 34))
    for x in (9, 22):                           # iron bands
        cv.vline(x, 10, 27, GREY_S)
        cv.vline(x + 1, 10, 27, GREY)
    cv.rect(14, 17, 17, 22, GOLD)               # lock plate
    cv.set(15, 19, DARK); cv.set(15, 20, DARK)
    cv.set(7, 11, (200, 150, 100))


@sprite("scroll", "items", "Rolled parchment scroll with wooden dowels and ink lines")
def _(cv):
    cv.rect(8, 6, 23, 26, (236, 222, 182))      # parchment
    cv.vline(8, 6, 26, (200, 182, 140))
    cv.vline(23, 6, 26, (200, 182, 140))
    for y in (11, 14, 17, 20):                  # ink lines
        cv.hline(11, 20, y, (110, 88, 68))
    cv.hline(11, 16, 23, (110, 88, 68))
    cv.rect(5, 3, 26, 6, BROWN)                 # top dowel
    cv.hline(5, 26, 6, BROWN_S)
    cv.rect(5, 26, 26, 29, BROWN)               # bottom dowel
    cv.hline(5, 26, 29, BROWN_S)
    cv.ellipse(4, 4, 1.5, 1.5, BROWN_S)
    cv.ellipse(27, 27, 1.5, 1.5, BROWN_S)


@sprite("gem", "items", "Faceted purple gemstone cut as a brilliant with light facets")
def _(cv):
    cv.poly([(15, 3), (26, 12), (15, 29), (4, 12)], (150, 84, 214))
    cv.poly([(15, 3), (26, 12), (15, 15), (4, 12)], (190, 140, 240))  # crown
    cv.line(15, 3, 15, 15, (226, 196, 255))
    cv.line(4, 12, 26, 12, (120, 60, 176))
    cv.poly([(9, 12), (15, 15), (15, 29)], (124, 66, 186))  # pavilion shadow
    cv.poly([(15, 5), (20, 11), (15, 13), (10, 11)], (232, 214, 255))
    cv.set(11, 9, WHITE); cv.set(12, 8, WHITE)


@sprite("coin", "items", "Stacked gold coins, the front one stamped with a star")
def _(cv):
    cv.ellipse(12, 24, 8, 4, GOLD_S)            # back coins in the stack
    cv.ellipse(12, 22, 8, 4, GOLD)
    cv.ellipse(18, 21, 8, 4, GOLD_S)
    cv.ellipse(18, 19, 8, 4, GOLD)
    cv.ellipse(15, 12, 9, 9, GOLD_S)            # face-on coin
    cv.ellipse(15, 12, 7.5, 7.5, GOLD)
    cv.ellipse(15, 12, 5.5, 5.5, (255, 226, 130))
    cv.poly([(15, 7), (17, 11), (21, 11), (18, 14),
             (19, 18), (15, 15), (11, 18), (12, 14), (9, 11), (13, 11)], GOLD_S)
    cv.set(11, 8, WHITE)


@sprite("bow", "items", "Recurve longbow strung taut with a nocked arrow")
def _(cv):
    for y in range(2, 30):                      # limb arc
        t = (y - 16) / 14.0
        dx = int(7 * (1 - t * t))
        cv.set(20 - dx, y, BROWN)
        cv.set(21 - dx, y, BROWN_S)
    cv.poly([(13, 2), (11, 5), (13, 7)], BROWN_S)     # recurve tips
    cv.poly([(13, 29), (11, 26), (13, 24)], BROWN_S)
    cv.line(13, 3, 13, 28, (232, 226, 206))     # string
    cv.rect(19, 13, 22, 19, (90, 58, 34))       # grip
    cv.hline(2, 20, 16, (176, 140, 96))         # arrow
    cv.tri((0, 16), (4, 13), (4, 19), GREY)
    cv.poly([(17, 16), (21, 13), (21, 19)], RED)      # fletching


@sprite("helm", "items", "Crested iron great helm seen in profile with a T visor")
def _(cv):
    cv.ellipse(15, 14, 10, 10, GREY)
    cv.rect(5, 14, 25, 24, GREY)
    cv.ellipse(15, 24, 10, 3.5, GREY)
    cv.ellipse(15, 13, 8.5, 8.5, STEEL)
    cv.rect(7, 13, 23, 22, STEEL)
    cv.ellipse(15, 22, 8.5, 3, STEEL)
    cv.hline(7, 23, 13, (40, 44, 60))
    cv.hline(7, 23, 14, (40, 44, 60))
    cv.rect(14, 15, 16, 21, (40, 44, 60))
    cv.hline(6, 24, 9, GREY_S)
    cv.hline(6, 24, 24, GREY_S)
    cv.poly([(12, 5), (15, 0), (18, 5), (15, 7)], RED)
    cv.set(9, 9, WHITE); cv.set(10, 8, WHITE)
    cv.set(8, 18, GREY_S); cv.set(22, 18, GREY_S)


@sprite("boots", "items", "Pair of brown leather travel boots with turned cuffs")
def _(cv):
    # back boot
    cv.poly([(16, 8), (24, 8), (24, 22), (29, 22), (29, 27), (16, 27)], BROWN_S)
    cv.hline(16, 29, 27, (70, 46, 26))
    cv.rect(15, 6, 25, 9, (110, 74, 44))        # cuff
    # front boot
    cv.poly([(4, 10), (13, 10), (13, 23), (19, 23), (19, 29), (4, 29)], BROWN)
    cv.hline(4, 19, 29, (70, 46, 26))
    cv.hline(4, 19, 28, (70, 46, 26))
    cv.rect(3, 8, 14, 11, (176, 130, 84))       # cuff
    cv.hline(3, 14, 11, BROWN_S)
    cv.hline(5, 12, 18, BROWN_S)                # laces / seam
    cv.set(6, 15, GOLD); cv.set(11, 15, GOLD)   # buckle studs


@sprite("ring", "items", "Gold band ring set with a glowing blue stone and side filigree")
def _(cv):
    cv.ellipse(15, 19, 10, 10, GOLD_S, fill=False)
    cv.ellipse(15, 19, 9, 9, GOLD, fill=False)
    cv.ellipse(15, 19, 8, 8, GOLD_S, fill=False)
    cv.ellipse(11, 15, 2, 2, (255, 238, 170))   # metal highlight
    # setting + stone at the top
    cv.poly([(10, 10), (20, 10), (18, 5), (12, 5)], GOLD)
    cv.ellipse(15, 6, 4.5, 4, (74, 150, 226))
    cv.ellipse(15, 6, 2.5, 2.2, (150, 210, 255))
    cv.set(14, 5, WHITE)
    cv.set(9, 11, GOLD_S); cv.set(21, 11, GOLD_S)   # filigree
    cv.set(7, 14, GOLD); cv.set(23, 14, GOLD)


@sprite("orc_berserker", "monsters", "Grey-green orc berserker mid-roar with a spiked pauldron and cleaver")
def _(cv):
    O, OS = (126, 150, 96), (88, 110, 66)
    cv.poly([(9, 15), (22, 15), (24, 27), (7, 27)], O)
    cv.hline(7, 24, 27, OS)
    cv.rect(11, 19, 20, 23, (110, 74, 44))
    cv.ellipse(15, 9, 6.5, 5.5, O)
    cv.set(11, 9, (255, 220, 90)); cv.set(12, 9, EYE)
    cv.set(17, 9, (255, 220, 90))
    cv.ellipse(15, 13, 4, 2.5, (70, 40, 40))
    cv.set(12, 12, WHITE); cv.set(18, 12, WHITE)
    cv.hline(9, 21, 4, (60, 48, 40))
    cv.ellipse(6, 16, 4, 3, GREY_S)
    cv.set(4, 13, GREY); cv.set(8, 13, GREY)
    cv.vline(26, 12, 26, BROWN)
    cv.poly([(22, 6), (30, 8), (29, 14), (22, 13)], GREY)
    cv.line(23, 8, 23, 12, STEEL)


@sprite("harpy", "monsters", "Winged harpy with feathered arms, talons and a plumed crest")
def _(cv):
    F, FS = (196, 148, 96), (150, 108, 66)
    cv.ellipse(15, 18, 5, 6, F)
    cv.hline(10, 20, 23, FS)
    cv.ellipse(15, 9, 5, 4.5, SKIN)
    cv.poly([(10, 9), (6, 10), (10, 12)], GOLD)
    cv.set(12, 8, EYE)
    cv.poly([(16, 4), (21, 1), (18, 7)], (214, 76, 68))
    cv.poly([(10, 12), (2, 6), (0, 18), (8, 20)], FS)
    cv.poly([(20, 12), (28, 6), (30, 18), (22, 20)], FS)
    cv.line(3, 9, 8, 16, F); cv.line(27, 9, 22, 16, F)
    cv.line(1, 15, 8, 18, F); cv.line(29, 15, 22, 18, F)
    cv.rect(12, 24, 13, 27, GOLD); cv.rect(17, 24, 18, 27, GOLD)
    cv.set(11, 28, GOLD_S); cv.set(19, 28, GOLD_S)


@sprite("mimic", "monsters", "Treasure chest mimic with a hinged jaw of teeth and a pink tongue")
def _(cv):
    cv.rect(4, 19, 27, 28, BROWN)
    cv.hline(4, 27, 28, BROWN_S)
    cv.poly([(3, 13), (6, 4), (26, 3), (28, 12)], (168, 116, 68))
    cv.hline(3, 28, 12, BROWN_S)
    cv.rect(3, 13, 28, 19, (86, 26, 36))
    cv.ellipse(16, 18, 7, 2.5, (226, 110, 130))
    for x in range(5, 27, 5):
        cv.tri((x, 13), (x + 3, 13), (x + 1, 17), WHITE)
    for x in range(7, 27, 5):
        cv.tri((x, 19), (x + 3, 19), (x + 1, 15), WHITE)
    cv.ellipse(9, 8, 2.5, 2.5, WHITE)
    cv.set(9, 8, EYE); cv.set(10, 8, EYE)
    cv.ellipse(21, 7, 2.5, 2.5, WHITE)
    cv.set(21, 7, EYE); cv.set(22, 7, EYE)
    cv.vline(10, 19, 28, GREY_S); cv.vline(22, 19, 28, GREY_S)
    cv.set(6, 22, GOLD_S); cv.set(25, 24, GOLD_S)


@sprite("wand", "items", "Slender wizard wand with a star tip and trailing sparkles")
def _(cv):
    cv.line(6, 27, 20, 9, BROWN)
    cv.line(7, 27, 21, 9, BROWN_S)
    for t in range(3):
        cv.set(8 + t * 4, 24 - t * 5, GOLD)
    cv.poly([(22, 2), (24, 8), (30, 8), (25, 12),
             (27, 18), (22, 14), (17, 18), (19, 12), (14, 8), (20, 8)], GOLD)
    cv.ellipse(22, 9, 2.5, 2.5, (255, 246, 190))
    cv.set(12, 14, (255, 236, 140)); cv.set(9, 19, (255, 236, 140))
    cv.set(14, 21, WHITE); cv.set(5, 23, WHITE)


# ---------------------------------------------------------------- driver ----

def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--out", default=os.path.join(
        here, "App", "Resources", "Assets", "PixelArt"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    manifest, failures = [], []
    for spec in SPRITES:
        cv = Canvas()
        spec["fn"](cv)
        cv.outline()
        n = cv.count()
        fname = f"{spec['category']}_{spec['name']}.png"
        path = os.path.join(args.out, fname)
        cv.to_image().save(path)
        if n <= MIN_PIXELS:
            failures.append((fname, n))
        manifest.append({
            "name": spec["name"],
            "category": spec["category"],
            "file": fname,
            "description": spec["description"],
            "pixels": n,
        })

    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump({"grid": S, "output": f"{S*SCALE}x{S*SCALE}",
                   "count": len(manifest), "sprites": manifest}, f, indent=2)

    print(f"wrote {len(manifest)} sprites -> {args.out}")
    assert not failures, f"sprites under {MIN_PIXELS} opaque px: {failures}"
    names = [s["name"] for s in manifest]
    assert len(names) == len(set(names)), "duplicate sprite names"
    print("OK: all sprites >", MIN_PIXELS, "opaque pixels")


if __name__ == "__main__":
    main()
