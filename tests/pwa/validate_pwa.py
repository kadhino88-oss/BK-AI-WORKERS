"""Validateur de l'application installable (PWA) : manifeste, icones, pages, service worker.

Sans dependance (bibliotheque standard seulement : les PNG sont lus avec zlib).
Verifie, sur les fichiers du depot :
  - manifeste : champs obligatoires, id/start_url/scope coherents, display, couleurs, icones
    (fichier present, taille REELLE = taille declaree, type, "purpose" valide, pas de
    "any maskable", icone maskable sans transparence et marque dans la zone de securite),
    raccourcis (url dans le scope, icones presentes), categories ;
  - coherence avec le site : theme_color = <meta theme-color> d'index.html, background_color =
    --bg de style.css, <link rel=manifest>, apple-touch-icon PNG 180x180 SANS transparence
    (iOS remplit la transparence en noir), aucune apple-touch-icon SVG ;
  - service worker : ecouteur fetch, fichiers du precache presents, aucune liste de cache
    "cache-d'abord", page de secours /offline.html ;
  - page hors connexion et page "supprimer mon compte" : autonomes (aucune ressource
    externe), chaque texte visible a sa traduction anglaise dans i18n-en-pwa.js.

Usage : python tests/pwa/validate_pwa.py            (code de sortie 1 si un controle echoue)
Utilisable en bibliotheque : run(repo) -> liste de (nom, ok, detail) ; png_info(bytes)."""
import json
import os
import re
import struct
import sys
import zlib
from html.parser import HTMLParser

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
VALID_PURPOSES = {"any", "maskable", "monochrome"}


# ---------------------------------------------------------------- PNG (stdlib)

def png_info(data, decode=True):
    """-> dict(width, height, bit_depth, color_type, interlace, has_alpha, min_alpha, pixels)
    `pixels` = fonction (x, y) -> (r, g, b, a) quand decode=True et le format est 8 bits non entrelace."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("pas un PNG")
    pos, idat, chunks = 8, [], {}
    while pos < len(data):
        length, ctype = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if ctype == b"IDAT":
            idat.append(body)
        else:
            chunks.setdefault(ctype, body)
        if ctype == b"IEND":
            break
    width, height, depth, ctype_, _, _, interlace = struct.unpack(">IIBBBBB", chunks[b"IHDR"])
    info = {"width": width, "height": height, "bit_depth": depth, "color_type": ctype_, "interlace": interlace,
            "has_trns_chunk": b"tRNS" in chunks, "min_alpha": None, "pixels": None}
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype_)
    info["has_alpha"] = ctype_ in (4, 6) or b"tRNS" in chunks
    if not decode or depth != 8 or interlace != 0 or channels is None:
        return info
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    rows, prev = [], bytearray(stride)
    p = 0
    for _ in range(height):
        ft = raw[p]
        line = bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if ft == 1:
                line[i] = (line[i] + a) & 255
            elif ft == 2:
                line[i] = (line[i] + b) & 255
            elif ft == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 255
            elif ft == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        rows.append(line)
        prev = line
    palette = chunks.get(b"PLTE")
    trns = chunks.get(b"tRNS")

    def pixel(x, y):
        row = rows[y]
        if ctype_ == 6:
            o = x * 4
            return row[o], row[o + 1], row[o + 2], row[o + 3]
        if ctype_ == 2:
            o = x * 3
            return row[o], row[o + 1], row[o + 2], 255
        if ctype_ == 4:
            return row[x * 2], row[x * 2], row[x * 2], row[x * 2 + 1]
        if ctype_ == 0:
            return row[x], row[x], row[x], 255
        idx = row[x]
        a = trns[idx] if trns and idx < len(trns) else 255
        return palette[idx * 3], palette[idx * 3 + 1], palette[idx * 3 + 2], a

    info["pixels"] = pixel
    if ctype_ == 6:
        info["min_alpha"] = min(min(r[3::4]) for r in rows)
    elif ctype_ == 4:
        info["min_alpha"] = min(min(r[1::2]) for r in rows)
    elif ctype_ == 3 and trns:
        info["min_alpha"] = min(trns)
    else:
        info["min_alpha"] = 255
    return info


def opaque(info):
    return info["min_alpha"] == 255


def mark_inside_safe_zone(info, white_min=235):
    """Les pixels blancs (la marque "BK") d'une icone maskable doivent tenir dans le cercle
    central de diametre 80 % (zone de securite du W3C) : un masque Android arrondi ou circulaire
    ne doit jamais rogner la marque. -> (ok, pire_distance_relative)"""
    w, h, px = info["width"], info["height"], info["pixels"]
    cx, cy, limit = (w - 1) / 2, (h - 1) / 2, 0.4 * w
    worst = 0.0
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b, a = px(x, y)
            if r >= white_min and g >= white_min and b >= white_min and a > 200:
                d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
                worst = max(worst, d / limit)
    return worst <= 1.0, worst


# ---------------------------------------------------------------- HTML helpers

class _Collector(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tags, self.texts, self._skip, self._noi18n = [], [], 0, 0
        self.stack = []

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        self.tags.append((tag, d))
        if tag in ("script", "style", "title"):   # <title> : traduit via window.BK_EN_HEAD
            self._skip += 1
        if tag not in ("meta", "link", "img", "br", "input", "hr"):
            self.stack.append((tag, "data-no-i18n" in d))
            if "data-no-i18n" in d:
                self._noi18n += 1

    def handle_endtag(self, tag):
        if tag in ("script", "style", "title"):
            self._skip = max(0, self._skip - 1)
        while self.stack:
            t, noi = self.stack.pop()
            if noi:
                self._noi18n -= 1
            if t == tag:
                break

    def handle_data(self, data):
        if self._skip or self._noi18n:
            return
        t = " ".join(data.split())
        if t:
            self.texts.append(t)


def parse_html(text):
    c = _Collector()
    c.feed(text)
    return c


def read_file(path):
    with open(path, "rb") as f:
        return f.read()


def read(repo, *parts):
    with open(os.path.join(repo, *parts), "rb") as f:
        return f.read()


def read_text(repo, *parts):
    return read(repo, *parts).decode("utf-8")


def load_dictionary(repo):
    """Cles du dictionnaire FR->EN de i18n-en-pwa.js (litteraux "cle": "valeur")."""
    src = read_text(repo, "dashboard", "i18n-en-pwa.js")
    return dict(re.findall(r'"((?:[^"\\]|\\.)*)"\s*:\s*\n?\s*"((?:[^"\\]|\\.)*)"', src))


# ---------------------------------------------------------------- controles

def run(repo=REPO):
    results = []

    def check(name, cond, detail=""):
        results.append((name, bool(cond), detail))
        return bool(cond)

    dash = os.path.join(repo, "dashboard")
    try:
        manifest = json.loads(read_text(repo, "dashboard", "manifest.json"))
    except Exception as e:  # noqa: BLE001
        check("manifest.json est un JSON valide", False, str(e))
        return results
    check("manifest.json est un JSON valide", True)

    # --- champs d'identite
    for key in ("name", "short_name", "start_url", "scope", "display", "icons", "id", "background_color", "theme_color", "lang"):
        check(f"manifest: champ '{key}' present", manifest.get(key) not in (None, "", []))
    check("manifest: display = standalone (ou fullscreen/minimal-ui)", manifest.get("display") in ("standalone", "fullscreen", "minimal-ui"))
    check("manifest: short_name <= 15 caracteres (etiquette sous l'icone)", len(manifest.get("short_name", "")) <= 15, manifest.get("short_name"))
    check("manifest: scope et start_url relatifs a la racine", str(manifest.get("scope", "")).startswith("/") and str(manifest.get("start_url", "")).startswith("/"))
    start_path = re.split(r"[?#]", manifest.get("start_url", ""))[0]
    check("manifest: start_url dans le scope", start_path.startswith(manifest.get("scope", "/")))
    check("manifest: id relatif a la racine, stable", str(manifest.get("id", "")).startswith("/"))
    check("manifest: orientation non verrouillee en portrait (tablettes, fenetres)", manifest.get("orientation", "any") in ("any", "natural"), manifest.get("orientation"))
    check("manifest: couleurs au format #rrggbb", all(HEX_RE.match(str(manifest.get(k, ""))) for k in ("theme_color", "background_color")))
    check("manifest: categories connues", set(manifest.get("categories", [])) <= {"business", "productivity", "utilities", "education", "finance", "social", "shopping", "news", "lifestyle", "health", "entertainment", "games", "music", "navigation", "photo", "security", "sports", "travel", "weather", "books", "food", "kids", "medical", "personalization", "politics"} and manifest.get("categories"))

    # --- icones
    icons = manifest.get("icons", [])
    have = {"any192": False, "any512": False, "mask512": False}
    for ic in icons:
        src = ic.get("src", "")
        label = f"icone {src} ({ic.get('purpose', 'any')} {ic.get('sizes')})"
        path = os.path.join(dash, *src.lstrip("/").split("/"))
        if not check(f"{label}: fichier present", os.path.isfile(path)):
            continue
        data = read_file(path)
        try:
            info = png_info(data)
        except Exception as e:  # noqa: BLE001
            check(f"{label}: PNG lisible", False, str(e))
            continue
        declared = ic.get("sizes", "")
        check(f"{label}: taille reelle = taille declaree", declared == f"{info['width']}x{info['height']}", f"reel {info['width']}x{info['height']}")
        check(f"{label}: carree", info["width"] == info["height"])
        check(f"{label}: type image/png", ic.get("type") == "image/png")
        purposes = set(str(ic.get("purpose", "any")).split())
        check(f"{label}: purpose valide", purposes <= VALID_PURPOSES)
        check(f"{label}: pas de 'any maskable' combine (rendu degrade sur Android)", len(purposes) == 1)
        if "maskable" in purposes:
            check(f"{label}: sans aucune transparence (pleine page)", opaque(info), f"alpha min {info['min_alpha']}")
            if info["pixels"]:
                ok, worst = mark_inside_safe_zone(info)
                check(f"{label}: marque dans la zone de securite (cercle 80 %)", ok, f"{worst:.2f} du rayon autorise")
            if info["width"] >= 512:
                have["mask512"] = True
        if "any" in purposes and info["width"] == 192:
            have["any192"] = True
        if "any" in purposes and info["width"] == 512:
            have["any512"] = True
    check("manifest: icone 192 'any' presente", have["any192"])
    check("manifest: icone 512 'any' presente", have["any512"])
    check("manifest: icone 512 'maskable' presente", have["mask512"])

    # --- raccourcis
    shortcuts = manifest.get("shortcuts", [])
    check("manifest: au moins 2 raccourcis (nouvelle mission, automatisations)", len(shortcuts) >= 2)
    for sc in shortcuts:
        label = f"raccourci '{sc.get('name')}'"
        check(f"{label}: name + url", bool(sc.get("name")) and bool(sc.get("url")))
        u = str(sc.get("url", ""))
        check(f"{label}: url dans le scope", u.startswith(manifest.get("scope", "/")) and not u.startswith("//") and "://" not in u)
        for ic in sc.get("icons", []):
            check(f"{label}: icone {ic.get('src')} presente", os.path.isfile(os.path.join(dash, *ic.get("src", "").lstrip("/").split("/"))))
    sc_names = {re.search(r"shortcut=([a-z-]+)", s.get("url", "")).group(1) for s in shortcuts if re.search(r"shortcut=([a-z-]+)", s.get("url", ""))}
    install_js = read_text(repo, "dashboard", "pwa-install.js")
    for name in sc_names:
        check(f"raccourci '{name}' gere par pwa-install.js", f'"{name}"' in install_js)

    # --- coherence avec le site
    index = parse_html(read_text(repo, "dashboard", "index.html"))
    metas = {d.get("name"): d.get("content") for t, d in index.tags if t == "meta" and d.get("name")}
    links = [d for t, d in index.tags if t == "link"]
    check("index.html: <meta theme-color> = theme_color du manifeste", (metas.get("theme-color") or "").lower() == manifest.get("theme_color", "").lower(), metas.get("theme-color"))
    css = read_text(repo, "dashboard", "style.css")
    m = re.search(r":root\s*\{[^}]*--bg:\s*(#[0-9a-fA-F]{6})", css)
    check("style.css: --bg = background_color du manifeste (pas de flash au demarrage)", bool(m) and m.group(1).lower() == manifest.get("background_color", "").lower(), m and m.group(1))
    check("index.html: <link rel=manifest href=/manifest.json>", any(l.get("rel") == "manifest" and l.get("href") == "/manifest.json" for l in links))
    touch = [l for l in links if l.get("rel") == "apple-touch-icon"]
    check("index.html: au moins une apple-touch-icon", bool(touch))
    check("index.html: apple-touch-icon toujours en PNG (iOS ignore le SVG)", all(str(l.get("href", "")).endswith(".png") for l in touch), [l.get("href") for l in touch])
    for l in touch:
        p = os.path.join(dash, *l.get("href", "").lstrip("/").split("/"))
        if l.get("href", "").endswith(".png") and os.path.isfile(p):
            info = png_info(read_file(p))
            check(f"apple-touch-icon {l['href']}: 180x180", (info["width"], info["height"]) == (180, 180), f"{info['width']}x{info['height']}")
            check(f"apple-touch-icon {l['href']}: sans transparence (sinon coins noirs sur iOS)", opaque(info), f"alpha min {info['min_alpha']}")
    # Toutes les pages publiques (HTML statiques + gabarit de seo_pages.py), pas seulement l'accueil.
    svg_touch = []
    for fn in sorted(os.listdir(dash)):
        if fn.endswith((".html", ".py")):
            for tag in re.findall(r"<link\b[^>]*apple-touch-icon[^>]*>", read_text(repo, "dashboard", fn)):
                href = re.search(r'href="([^"]+)"', tag)
                if not href or not href.group(1).endswith(".png"):
                    svg_touch.append(fn + " -> " + (href.group(1) if href else "?"))
    check("toutes les pages publiques: apple-touch-icon en PNG (iOS ignore le SVG)", not svg_touch, svg_touch)
    check("index.html: meta viewport", "viewport" in metas)
    check("index.html: meta apple-mobile-web-app-title", bool(metas.get("apple-mobile-web-app-title")))
    check("index.html: meta mobile-web-app-capable", metas.get("mobile-web-app-capable") == "yes")
    scripts = [d.get("src") for t, d in index.tags if t == "script" and d.get("src")]
    check("index.html: charge /i18n-en-pwa.js avant /i18n.js", "/i18n-en-pwa.js" in scripts and "/i18n.js" in scripts and scripts.index("/i18n-en-pwa.js") < scripts.index("/i18n.js"))
    check("index.html: charge /pwa-install.js apres /app.js", "/pwa-install.js" in scripts and scripts.index("/pwa-install.js") > scripts.index("/app.js"))
    check("index.html: charge /pwa-install.css", any(l.get("href") == "/pwa-install.css" for l in links))
    check("index.html: lien 'Installer l'application' cache par defaut", any(d.get("id") == "footer-install-app" and "hidden" in d for t, d in index.tags))
    check("index.html: lang = lang du manifeste", any(t == "html" and d.get("lang") == manifest.get("lang") for t, d in index.tags))

    # --- service worker
    sw = read_text(repo, "dashboard", "service-worker.js")
    check("service-worker.js: ecouteur 'fetch'", "addEventListener(\"fetch\"" in sw)
    check("service-worker.js: install + activate", "addEventListener(\"install\"" in sw and "addEventListener(\"activate\"" in sw)
    check("service-worker.js: aucune strategie cache-d'abord (regle anti JS perime)", "caches.match(event.request).then(cached => cached ||" not in sw and "cacheFirst" not in sw)
    check("service-worker.js: /api/ jamais intercepte", '"/api/"' in sw)
    pre = []
    for name in ("PRECACHE_REQUIRED", "PRECACHE_OPTIONAL"):
        mm = re.search(name + r"\s*=\s*\[(.*?)\]", sw, re.S)
        pre += re.findall(r'"(/[^"]*)"', mm.group(1)) if mm else []
    check("service-worker.js: precache declare", bool(pre))
    offline_const = re.search(r'OFFLINE_URL\s*=\s*"(/[^"]+)"', sw)
    check("service-worker.js: OFFLINE_URL = /offline.html", bool(offline_const) and offline_const.group(1) == "/offline.html")
    for u in pre:
        if u == "/":
            continue
        check(f"service-worker.js: fichier du precache {u} existe", os.path.isfile(os.path.join(dash, *u.lstrip("/").split("/"))))
    check("service-worker.js: /offline.html dans le precache obligatoire", "/offline.html" in re.search(r"PRECACHE_REQUIRED\s*=\s*\[(.*?)\]", sw, re.S).group(1) or "OFFLINE_URL" in re.search(r"PRECACHE_REQUIRED\s*=\s*\[(.*?)\]", sw, re.S).group(1))

    # --- pages autonomes et traductions
    dictionary = load_dictionary(repo)
    check("i18n-en-pwa.js: dictionnaire non vide", len(dictionary) >= 30, len(dictionary))
    for page in ("offline.html", "suppression-compte.html"):
        html = read_text(repo, "dashboard", page)
        p = parse_html(html)
        external = [d.get("src") or d.get("href") for t, d in p.tags
                    if (d.get("src") or d.get("href")) and re.match(r"^(https?:)?//", d.get("src") or d.get("href") or "")
                    and d.get("rel") not in ("canonical",)]
        if page == "offline.html":
            check(f"{page}: aucune ressource externe (affichee sans reseau)", not external, external)
        check(f"{page}: <html lang>, viewport, titre", any(t == "html" and d.get("lang") for t, d in p.tags) and any(t == "meta" and d.get("name") == "viewport" for t, d in p.tags) and "<title>" in html)
        check(f"{page}: charge i18n-en-pwa.js puis i18n.js", html.find("/i18n-en-pwa.js") != -1 and html.find("/i18n-en-pwa.js") < html.find("/i18n.js"))
        check(f"{page}: fournit window.BK_EN_HEAD (titre anglais)", "window.BK_EN_HEAD" in html)
        missing = [t for t in p.texts if t not in dictionary and not re.match(r"^[©\W\d]+$", t) and "BK-AI-WORKERS" != t and not t.startswith("©")
                   and "@" not in t and t != "bk-ai-workers.com"]
        check(f"{page}: chaque texte visible a sa traduction anglaise", not missing, missing)
    # chaque phrase de l'invitation a installer existe dans le dictionnaire
    for key in ("Installer l'application", "Comment faire ?", "Compris", "Fermer", "Installer"):
        check(f"pwa-install.js / dictionnaire: \"{key}\"", key in dictionary and key in install_js)
    return results


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    results = run(REPO)
    failures = 0
    for name, ok, detail in results:
        print(("  PASS  " if ok else "  FAIL  ") + name + (f"  [{detail}]" if detail not in ("", None) and not ok else ""))
        failures += 0 if ok else 1
    print(f"\n{len(results) - failures}/{len(results)} controles passes")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
