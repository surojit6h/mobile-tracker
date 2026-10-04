"""
Generates the app launcher icon (a location pin on a blue rounded field)
as a 1024x1024 PNG. flutter_launcher_icons uses this as its source image
and produces all the Android icon sizes from it.

Run:  python app/tool/make_icon.py
Needs Pillow:  pip install pillow
"""

from PIL import Image, ImageDraw
import math
import os

SIZE = 1024
BG = (59, 130, 246)        # app blue (#3B82F6)
BG_DARK = (37, 99, 235)    # slightly darker for depth
PIN = (255, 255, 255)      # white pin
PIN_HOLE = (59, 130, 246)  # hole matches bg

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "assets")
OUT = os.path.join(OUT_DIR, "icon.png")


def rounded_background(img):
    draw = ImageDraw.Draw(img)
    radius = int(SIZE * 0.22)
    # vertical gradient-ish by drawing two rounded rects
    draw.rounded_rectangle([0, 0, SIZE, SIZE], radius=radius, fill=BG_DARK)
    draw.rounded_rectangle([0, 0, SIZE, int(SIZE * 0.92)], radius=radius, fill=BG)


def draw_pin(img):
    draw = ImageDraw.Draw(img)
    cx = SIZE / 2
    # Teardrop pin: a circle on top + a triangle tip at the bottom.
    head_cy = SIZE * 0.40
    head_r = SIZE * 0.20
    tip_y = SIZE * 0.78

    # Circle (head)
    draw.ellipse(
        [cx - head_r, head_cy - head_r, cx + head_r, head_cy + head_r],
        fill=PIN,
    )

    # Triangle (tip) blending into the circle bottom.
    spread = head_r * 0.92
    draw.polygon(
        [
            (cx - spread, head_cy + head_r * 0.35),
            (cx + spread, head_cy + head_r * 0.35),
            (cx, tip_y),
        ],
        fill=PIN,
    )

    # Inner hole in the pin head.
    hole_r = head_r * 0.42
    draw.ellipse(
        [cx - hole_r, head_cy - hole_r, cx + hole_r, head_cy + hole_r],
        fill=PIN_HOLE,
    )


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded_background(img)
    draw_pin(img)
    img.save(OUT)
    print("Wrote", os.path.abspath(OUT))


if __name__ == "__main__":
    main()
