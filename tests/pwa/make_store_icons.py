"""Regenere les icones "pleine page" a partir de la marque (degrade or + "BK") : apple-touch-icon
(180 px, OPAQUE), icone App Store (1024 px, sans transparence) et icone Google Play (512 px).
Pourquoi : iOS remplit en NOIR les zones transparentes d'une apple-touch-icon, et l'App Store
refuse une icone 1024 avec transparence. Les icones "any" du manifeste gardent leurs coins arrondis.

Usage (necessite Pillow, pas utilise par les tests) :
    python tests/pwa/make_store_icons.py            # ecrit dashboard/icons/apple-touch-icon.png + docs/store-assets/
    python tests/pwa/make_store_icons.py --check     # compare le rendu a icon-512.png (ecart moyen) sans rien ecrire
Police : Segoe UI Bold (celle des icones d'origine) ; sur une machine sans cette police, passer --font <fichier.ttf>."""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICONS = os.path.join(REPO, "dashboard", "icons")
ASSETS = os.path.join(REPO, "docs", "store-assets")
GOLD_LIGHT = (0xC9, 0x97, 0x3A)   # --gold-light (style.css)
GOLD = (0xA5, 0x76, 0x1F)         # --gold
# Mesures prises sur dashboard/icons/icon-512.png : corps de police 216/512, base de ligne 330/512.
FONT_FRAC = 216 / 512
BASELINE_FRAC = 330 / 512


def gradient(n):
    x = np.linspace(0, 1, n)
    gx, gy = np.meshgrid(x, x)
    t = ((gx + gy) / 2)[..., None]           # diagonale 135 deg, comme favicon.svg
    c0, c1 = np.array(GOLD_LIGHT), np.array(GOLD)
    return Image.fromarray((c0 * (1 - t) + c1 * t).round().astype("uint8"), "RGB")


def render(n, font_path):
    img = gradient(n)
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(font_path, int(round(n * FONT_FRAC)))
    d.text((n / 2, n * BASELINE_FRAC), "BK", font=font, fill=(255, 255, 255), anchor="ms")
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--font", default="C:/Windows/Fonts/segoeuib.ttf")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if not os.path.isfile(args.font):
        sys.exit("police introuvable : " + args.font + " (utiliser --font)")
    master = render(1024, args.font)
    if args.check:
        ref = np.array(Image.open(os.path.join(ICONS, "icon-512.png")).convert("RGBA"))
        inside = ref[..., 3] > 250
        cand = np.array(master.resize((512, 512), Image.LANCZOS))
        diff = np.abs(cand.astype(int) - ref[..., :3].astype(int))[inside].mean()
        print("ecart moyen vs icon-512.png (0-255) :", round(float(diff), 2))
        return
    os.makedirs(ASSETS, exist_ok=True)
    master.resize((180, 180), Image.LANCZOS).save(os.path.join(ICONS, "apple-touch-icon.png"), optimize=True)
    master.save(os.path.join(ASSETS, "ios-app-icon-1024.png"), optimize=True)
    master.resize((512, 512), Image.LANCZOS).convert("RGBA").save(os.path.join(ASSETS, "play-store-icon-512.png"), optimize=True)
    print("ecrit : dashboard/icons/apple-touch-icon.png, docs/store-assets/ios-app-icon-1024.png, docs/store-assets/play-store-icon-512.png")


if __name__ == "__main__":
    main()
