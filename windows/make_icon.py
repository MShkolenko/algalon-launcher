#!/usr/bin/env python3
"""Draw the launcher icon (operator's choice 2026-10-10: variant 2, the spiked frame) into algalon.ico.

WoW-style badge without Blizzard's mark: beveled gold ring with eight gold spikes, a blue-green globe, a two-level
gold letter A (Algalon). Drawn once at 1024 px and downscaled, so every size is antialiased.
"""
from PIL import Image, ImageDraw

S = 1024 / 110          # design is in 110-unit coordinates
OUT = __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0]


def P(*pts):
    return [(x * S, y * S) for x, y in pts]


def quad(p0, p1, p2, n=24):
    return [((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t * t * p2[0],
             (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t * t * p2[1]) for t in (i / n for i in range(n + 1))]


def circle(d, r, fill):
    d.ellipse([(55 - r) * S, (55 - r) * S, (55 + r) * S, (55 + r) * S], fill=fill)


img = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

gold = "#c99528"
for tri in [((55, 0), (60, 10), (50, 10)), ((55, 110), (60, 100), (50, 100)), ((0, 55), (10, 50), (10, 60)),
            ((110, 55), (100, 50), (100, 60)), ((16, 16), (26, 20), (20, 26)), ((94, 16), (90, 26), (84, 20)),
            ((16, 94), (20, 84), (26, 90)), ((94, 94), (84, 90), (90, 84))]:
    d.polygon(P(*tri), fill=gold)

for r, c in [(47, "#3a2508"), (44, gold), (41, "#f0cd62"), (38, "#a8761c"), (35, "#1a1208"), (32, "#1f6fb0")]:
    circle(d, r, c)

# lower green land of the globe: two quadratic curves (25,61)->(85,61) under the equator
land = quad((25, 61), (55, 86), (85, 61)) + quad((85, 61), (85, 87), (55, 87))[1:] + quad((55, 87), (25, 87), (25, 61))[1:]
d.polygon(P(*land), fill="#2c8a55")
d.ellipse([(48 - 14) * S, (41 - 8) * S, (48 + 14) * S, (41 + 8) * S], fill="#5fb3ea")

d.polygon(P((55, 25), (78, 82), (66, 82), (61, 69), (49, 69), (44, 82), (32, 82)), fill="#5a3a08")
d.polygon(P((55, 30), (74, 79), (67, 79), (62, 66), (48, 66), (43, 79), (36, 79)), fill="#f4c94a")
d.polygon(P((55, 46), (59, 59), (51, 59)), fill="#1f6fb0")

big = img.resize((256, 256), Image.LANCZOS)
big.save(f"{OUT}/algalon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
big.save(f"{OUT}/algalon-icon-256.png")
print("wrote algalon.ico and algalon-icon-256.png")
