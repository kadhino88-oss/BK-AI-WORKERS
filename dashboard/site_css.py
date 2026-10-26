# -*- coding: utf-8 -*-
"""Lecture minimale du CSS pour les contrôles de l'atelier de sites : règles (avec leur contexte @media), variables, couleurs, contraste WCAG.
Bibliothèque standard seulement. Ce n'est pas un analyseur CSS complet : il suffit à lire le CSS que l'atelier génère et celui qu'un Worker écrit
dans le même style (variables sur :root, règles simples, @media)."""
import re

_NAMED = {
    "white": (255, 255, 255), "black": (0, 0, 0), "transparent": None, "red": (255, 0, 0), "gray": (128, 128, 128), "grey": (128, 128, 128),
    "silver": (192, 192, 192), "navy": (0, 0, 128), "blue": (0, 0, 255), "green": (0, 128, 0), "teal": (0, 128, 128), "orange": (255, 165, 0),
}
_COMMENT = re.compile(r"/\*.*?\*/", re.S)
_AT_STATEMENT = re.compile(r"@(?:import|charset|namespace)\b[^;{]*;", re.I)
_VAR_DECL = re.compile(r"(--[A-Za-z0-9_-]+)\s*:\s*([^;{}]+?)\s*(?:;|$)")


def strip_comments(css):
    return _COMMENT.sub("", css or "")


def import_urls(css):
    """URL des @import du CSS (avec ou sans url())."""
    out = []
    for m in re.finditer(r"@import\s+(?:url\(\s*)?['\"]?([^'\")\s;]+)", strip_comments(css), re.I):
        out.append(m.group(1))
    return out


def rules(css):
    """[(sélecteur ou @règle, corps, contexte @media)] — les @media / @supports / @layer sont aplatis ; @font-face et @keyframes restent des règles."""
    css = _AT_STATEMENT.sub("", strip_comments(css))
    return list(_walk(css, ""))


def _walk(css, ctx, depth=0):
    i, n = 0, len(css)
    while i < n and depth < 6:
        j = css.find("{", i)
        if j < 0:
            break
        sel = css[i:j].strip()
        level, k = 1, j + 1
        while k < n and level:
            c = css[k]
            if c == "{":
                level += 1
            elif c == "}":
                level -= 1
            k += 1
        body = css[j + 1:k - 1]
        low = sel.lower()
        if low.startswith(("@media", "@supports", "@layer", "@container")):
            yield from _walk(body, (ctx + " " + sel).strip(), depth + 1)
        else:
            yield (sel, body, ctx)
        i = k


def variables(css):
    """{contexte: {--nom: valeur}} ; le contexte est « » pour :root / html, ou le texte du @media (ex. « @media (prefers-color-scheme: dark) »)."""
    out = {}
    for sel, body, ctx in rules(css):
        if sel.startswith("@"):
            continue
        parts = [s.strip().lower() for s in sel.split(",")]
        if not any(p in (":root", "html", "body", ":root:not([data-theme=\"light\"])", ":root[data-theme=\"dark\"]", "[data-theme=\"dark\"]") or p.startswith(":root") for p in parts):
            continue
        for m in _VAR_DECL.finditer(body):
            out.setdefault(ctx, {})[m.group(1)] = m.group(2).strip()
    return out


def resolve_var(value, vars_, depth=0):
    if depth > 5 or not isinstance(value, str):
        return value
    m = re.match(r"^var\(\s*(--[A-Za-z0-9_-]+)\s*(?:,\s*([^)]+))?\)$", value.strip())
    if m:
        if m.group(1) in vars_:
            return resolve_var(vars_[m.group(1)], vars_, depth + 1)
        return m.group(2).strip() if m.group(2) else None
    return value


def parse_color(value, vars_=None):
    """(r, g, b) 0-255 ou None (couleur absente, transparente ou non comprise)."""
    if value is None:
        return None
    v = resolve_var(value, vars_ or {})
    if not isinstance(v, str):
        return None
    v = v.strip().lower()
    if v in _NAMED:
        return _NAMED[v]
    m = re.match(r"^#([0-9a-f]{3,8})$", v)
    if m:
        h = m.group(1)
        if len(h) in (3, 4):
            h = "".join(c * 2 for c in h)
        if len(h) in (6, 8):
            return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
        return None
    m = re.match(r"^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)", v)
    if m:
        return tuple(max(0, min(255, int(round(float(x))))) for x in m.groups())
    m = re.match(r"^hsla?\(\s*([\d.]+)(?:deg)?[\s,]+([\d.]+)%[\s,]+([\d.]+)%", v)
    if m:
        return hsl_to_rgb(float(m.group(1)), float(m.group(2)) / 100.0, float(m.group(3)) / 100.0)
    return None


def hsl_to_rgb(h, s, l):
    h = (h % 360) / 360.0
    if s == 0:
        r = g = b = l
    else:
        q = l * (1 + s) if l < 0.5 else l + s - l * s
        p = 2 * l - q

        def f(t):
            t %= 1.0
            if t < 1 / 6:
                return p + (q - p) * 6 * t
            if t < 1 / 2:
                return q
            if t < 2 / 3:
                return p + (q - p) * (2 / 3 - t) * 6
            return p

        r, g, b = f(h + 1 / 3), f(h), f(h - 1 / 3)
    return (int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))


def luminance(rgb):
    def ch(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = rgb
    return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b)


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def to_hex(rgb):
    return "#%02x%02x%02x" % tuple(rgb)


def mix(a, b, t):
    """Mélange linéaire a -> b (t 0..1)."""
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def best_on(bg, light=(255, 255, 255), dark=(17, 24, 39)):
    """Couleur de texte (blanc ou quasi noir) au meilleur contraste sur `bg`."""
    return light if contrast(light, bg) >= contrast(dark, bg) else dark


def ensure_contrast(fg, bg, minimum=4.5, toward=None):
    """Éclaircit ou assombrit `fg` jusqu'à atteindre `minimum` sur `bg` (au plus 40 pas) ; renvoie la couleur ajustée."""
    if contrast(fg, bg) >= minimum:
        return fg
    target = toward or ((0, 0, 0) if contrast((0, 0, 0), bg) >= contrast((255, 255, 255), bg) else (255, 255, 255))
    cur = fg
    for i in range(1, 41):
        cur = mix(fg, target, i / 40.0)
        if contrast(cur, bg) >= minimum:
            return cur
    return cur
