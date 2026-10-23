"""Draw the Striso Live mark (four keys on the ink plate, as in the web app's favicon) and write
the Windows .ico and the macOS app icon set. Needs Pillow. Run from the repository root:

    python tool/make_icons.py
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent.parent
INK = (21, 18, 31, 255)
HONEY = (244, 210, 122)
EMBER = (255, 138, 101)


def mark(size: int) -> Image.Image:
    s = 8  # supersample
    im = Image.new("RGBA", (size * s, size * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    k = size * s / 32
    d.rounded_rectangle([0, 0, size * s - 1, size * s - 1], radius=7 * k, fill=INK)

    def dot(x, y, r, col, a=1.0):
        layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).ellipse([(x - r) * k, (y - r) * k, (x + r) * k, (y + r) * k], fill=col + (round(255 * a),))
        im.alpha_composite(layer)

    dot(11, 12, 5, HONEY)
    dot(21, 9, 4, HONEY, 0.55)
    dot(21, 21, 5, EMBER)
    dot(11, 24, 3.5, HONEY, 0.4)
    return im.resize((size, size), Image.LANCZOS)


def main():
    big = mark(256)
    big.save(HERE / "windows" / "runner" / "resources" / "app_icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    iconset = HERE / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    contents = json.loads((iconset / "Contents.json").read_text())
    for img in contents["images"]:
        px = int(float(img["size"].split("x")[0]) * int(img["scale"].rstrip("x")))
        name = img.get("filename") or f"app_icon_{px}.png"
        mark(px).save(iconset / name)
    print("icons written")


if __name__ == "__main__":
    main()
