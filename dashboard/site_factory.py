# -*- coding: utf-8 -*-
"""Atelier de sites : fabrication déterministe d'un site statique multi-pages (docs/AUTONOMY-ENGINE.md, section 8).

Ce module ne dépend d'aucun modèle ni d'aucun réseau : il prépare le dossier `workspace/site/` (site_scaffold), assemble `site/dist/`
(site_build), produit le zip et le guide de mise en ligne (site_package) et prépare les brouillons WordPress à faire valider. Les contrôles
automatiques sont dans site_checks.py ; ce module les enregistre comme type de contrôle « site_check » auprès du moteur.

Organisation :
  site/site.json                       marque, langues, pages, coordonnées (ou « [À COMPLÉTER : …] »), hôtes externes autorisés, déclarations du client
  site/src/_partials/header.html       footer.html   nav.<lang>.html (facultatif)
  site/src/pages/<lang>/<slug>.html    corps de page ; 1re ligne facultative <!--meta {"title","description","path","alternates","og","noindex"} -->
  site/src/assets/**                   style.css, site.js (facultatif), img/, fonts/
  site/dist/                           produit par build() UNIQUEMENT ; l'aperçu, les contrôles et le zip lisent dist/
  site/build.json                      résumé de la dernière construction (empreinte de src/, pages, poids)

Déterminisme : deux constructions du même src/ donnent des octets identiques (aucune date, ordre trié, zip à horodatage fixe).
"""
import hashlib
import html
import io
import json
import os
import posixpath
import re
import secrets
import shutil
import struct
import zipfile
import zlib

import project_paths as pp
import site_css as css

ROOT = os.environ.get("BK_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE_DIR = "site"
TEMPLATES_REL = ("core", "projects", "site", "templates")
GUIDE_REL = ("core", "projects", "site", "SITE-GUIDE.md")
PROFILES = ("vitrine", "landing", "blog")
LANGS = ("fr", "en", "de", "it")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,47}\Z")
KEY_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}\Z")
TOKEN_RE = re.compile(r"\{\{\s*([a-z][a-z0-9_.:-]{0,60})\s*\}\}")
INCLUDE_RE = re.compile(r"<!--\s*@include\s+([a-z][a-z0-9_-]{0,31})\s*-->")
META_RE = re.compile(r"\A\s*<!--\s*meta\s+(\{.*?\})\s*-->\s*", re.DOTALL)
PLACEHOLDER = "[À COMPLÉTER : {}]"
ASSET_EXT = frozenset("css js svg png jpg jpeg webp gif ico woff2 txt json webmanifest xml".split())
MAX_PAGES = 60
MAX_DIST_BYTES = 25 * 1024 * 1024
MAX_SRC_FILE = 5 * 1024 * 1024
ZIP_MAX_BYTES = 25 * 1024 * 1024
ZIP_DATE = (2020, 1, 1, 0, 0, 0)
PLACEHOLDER_DOMAIN = "https://votre-domaine.example"

STRINGS = {
    "fr": {"skip": "Aller au contenu", "nav": "Navigation principale", "lang": "Langue", "contact": "Contact", "info": "Informations",
           "notfound_title": "Page introuvable", "notfound_text": "Cette page n'existe pas ou a été déplacée.", "home_link": "Retour à l'accueil",
           "lang_name": "Français"},
    "en": {"skip": "Skip to content", "nav": "Main navigation", "lang": "Language", "contact": "Contact", "info": "Information",
           "notfound_title": "Page not found", "notfound_text": "This page does not exist or has moved.", "home_link": "Back to the home page",
           "lang_name": "English"},
    "de": {"skip": "Zum Inhalt springen", "nav": "Hauptnavigation", "lang": "Sprache", "contact": "Kontakt", "info": "Informationen",
           "notfound_title": "Seite nicht gefunden", "notfound_text": "Diese Seite existiert nicht oder wurde verschoben.", "home_link": "Zur Startseite",
           "lang_name": "Deutsch"},
    "it": {"skip": "Vai al contenuto", "nav": "Navigazione principale", "lang": "Lingua", "contact": "Contatto", "info": "Informazioni",
           "notfound_title": "Pagina non trovata", "notfound_text": "Questa pagina non esiste o è stata spostata.", "home_link": "Torna alla home",
           "lang_name": "Italiano"},
}

# Champs de site.json qui, absents, deviennent « [À COMPLÉTER : …] » (et une ligne de needsFromClient) : jamais une valeur inventée.
FACT_LABELS = {
    "contact.email": "adresse e-mail de contact", "contact.phone": "numéro de téléphone", "contact.address": "adresse postale",
    "contact.hours": "horaires d'ouverture", "legal.company": "raison sociale", "legal.address": "adresse du siège",
    "legal.uid": "numéro IDE de l'entreprise", "legal.responsible": "responsable de la publication", "legal.host": "hébergeur du site",
    "legal.retention": "durée de conservation des messages",
}

FONT_STACKS = {
    "system": ('system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif', None),
    "humanist": ('Seravek, "Gill Sans Nova", Ubuntu, Calibri, "DejaVu Sans", source-sans-pro, sans-serif', None),
    "geometric": ('Avenir, Montserrat, Corbel, "URW Gothic", source-sans-pro, sans-serif', None),
    "serif": ('system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif',
              'Charter, "Bitstream Charter", "Sitka Text", Cambria, Georgia, serif'),
    "classic": ('Charter, "Bitstream Charter", "Sitka Text", Cambria, Georgia, serif', 'Charter, "Bitstream Charter", "Sitka Text", Cambria, Georgia, serif'),
}

ICONS = {
    "check": '<path d="M20 6 9 17l-5-5"/>',
    "phone": '<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.4 1.8.7 2.7a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.7.7a2 2 0 0 1 1.7 2z"/>',
    "mail": '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 6-10 7L2 6"/>',
    "map": '<path d="M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 0 1 16 0z"/><circle cx="12" cy="10" r="3"/>',
    "clock": '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
    "heart": '<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1-1.1a5.5 5.5 0 0 0-7.8 7.8l1 1.1L12 21l7.8-7.5 1-1.1a5.5 5.5 0 0 0 0-7.8z"/>',
    "leaf": '<path d="M11 20A7 7 0 0 1 9.8 6.1C15.5 5 17 4.5 19 2c1 2 2 4.2 2 8 0 5.5-4.8 10-10 10z"/><path d="M2 21c0-3 1.9-5.4 5.1-6"/>',
    "tool": '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.8-3.8a6 6 0 0 1-7.9 7.9l-6.9 6.9a2.1 2.1 0 0 1-3-3l6.9-6.9a6 6 0 0 1 7.9-7.9z"/>',
    "users": '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.9M16 3.1a4 4 0 0 1 0 7.8"/>',
    "calendar": '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
    "shield": '<path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>',
    "spark": '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M5.6 18.4l2.8-2.8M15.6 8.4l2.8-2.8"/>',
}


class SiteError(Exception):
    """Erreur de l'atelier : code stable + message français (transmis tel quel au Worker)."""

    def __init__(self, code, detail):
        super().__init__(detail)
        self.code = code
        self.detail = detail


# ------------------------------------------------------------------ utilitaires
def _read(path, limit=MAX_SRC_FILE):
    with open(path, "rb") as f:
        raw = f.read(limit + 1)
    if len(raw) > limit:
        raise SiteError("TOO_LARGE", f"Fichier trop gros : {os.path.basename(path)}.")
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def _write(full, text_or_bytes):
    data = text_or_bytes.encode("utf-8") if isinstance(text_or_bytes, str) else text_or_bytes
    pp.atomic_write_bytes(full, data)
    return len(data)


def _esc(value):
    """Échappement HTML (texte et attributs entre guillemets doubles) ; l'apostrophe reste lisible."""
    return html.escape(str(value), quote=False).replace('"', "&quot;")


def _get(d, dotted):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def _is_placeholder(v):
    """Vrai si la valeur manque (absente, vide, non textuelle) ou est un « [À COMPLÉTER : …] »."""
    if v is None or not isinstance(v, (str, int, float)) or isinstance(v, bool):
        return True
    return "[À COMPLÉTER" in str(v) or not str(v).strip()


def site_paths(workspace):
    base = pp.resolve(workspace, SITE_DIR, kind="dir")
    return {"base": base, "json": os.path.join(base, "site.json"), "src": os.path.join(base, "src"), "dist": os.path.join(base, "dist"),
            "pages": os.path.join(base, "src", "pages"), "partials": os.path.join(base, "src", "_partials"),
            "assets": os.path.join(base, "src", "assets"), "build": os.path.join(base, "build.json")}


def load_site(workspace):
    p = site_paths(workspace)
    if not os.path.isfile(p["json"]):
        raise SiteError("SITE_MISSING", "site/site.json est absent : lancez d'abord site_scaffold.")
    try:
        site = json.loads(_read(p["json"], 512 * 1024))
    except ValueError as e:
        raise SiteError("SITE_INVALID", f"site/site.json n'est pas un JSON valide ({e}).")
    if not isinstance(site, dict):
        raise SiteError("SITE_INVALID", "site/site.json doit être un objet JSON.")
    return normalise_site(site)


def normalise_site(site):
    """Valeurs par défaut sûres, sans jamais inventer de fait (un fait absent devient « [À COMPLÉTER : …] » au rendu)."""
    s = dict(site)
    langs = [l for l in (s.get("languages") or []) if isinstance(l, str) and l in LANGS]
    s["languages"] = langs or ["fr"]
    if s.get("defaultLanguage") not in s["languages"]:
        s["defaultLanguage"] = s["languages"][0]
    s["profile"] = s.get("profile") if s.get("profile") in PROFILES else "vitrine"
    s["name"] = str(s.get("name") or PLACEHOLDER.format("nom de l'entreprise"))[:120]
    s["slug"] = s.get("slug") if isinstance(s.get("slug"), str) and SLUG_RE.match(s.get("slug")) else (_slugify(s["name"]) or "site")
    base = s.get("baseUrl")
    s["baseUrl"] = base.strip().rstrip("/") if isinstance(base, str) and re.match(r"^https?://[A-Za-z0-9.-]+(?::\d+)?(/[A-Za-z0-9._~/-]*)?\Z", base.strip()) else ""
    pages = []
    seen = set()
    for pg in s.get("pages") or []:
        if not isinstance(pg, dict) or not KEY_RE.match(str(pg.get("key") or "")) or pg["key"] in seen:
            continue
        seen.add(pg["key"])
        slug = pg.get("slug")
        if isinstance(slug, str):
            slug = {l: slug for l in s["languages"]}
        slug = {l: v for l, v in (slug or {}).items() if l in s["languages"] and isinstance(v, str) and SLUG_RE.match(v)}
        title = pg.get("title")
        if isinstance(title, str):
            title = {l: title for l in s["languages"]}
        pages.append({"key": pg["key"], "slug": slug, "title": {l: str(v)[:80] for l, v in (title or {}).items() if isinstance(v, (str, int))},
                      "nav": pg.get("nav") is not False and not pg.get("footer"), "footer": bool(pg.get("footer")),
                      "ogType": pg.get("ogType") if pg.get("ogType") in ("website", "article") else "website"})
    s["pages"] = pages[:MAX_PAGES]
    for k in ("allowedExternalHosts", "claimsProvidedByClient", "needsFromClient"):
        s[k] = [x for x in (s.get(k) or []) if isinstance(x, (str, dict))][:100]
    for k in ("brand", "contact", "legal", "hosting", "strings"):
        s[k] = s.get(k) if isinstance(s.get(k), dict) else {}
    return s


def _slugify(text):
    t = str(text or "").lower()
    for a, b in (("àâä", "a"), ("éèêë", "e"), ("îï", "i"), ("ôö", "o"), ("ùûü", "u"), ("ç", "c"), ("œ", "oe"), ("æ", "ae")):
        for ch in a:
            t = t.replace(ch, b)
    t = re.sub(r"[^a-z0-9]+", "-", t).strip("-")
    return t[:40].strip("-")


def page_url(site, page, lang):
    """URL racine d'une page (« / », « /services/ », « /en/about/ »)."""
    slug = (page.get("slug") or {}).get(lang) or page["key"]
    prefix = "" if lang == site["defaultLanguage"] else "/" + lang
    if slug == "index":
        return prefix + "/"
    return f"{prefix}/{slug}/"


def url_to_dist_rel(url):
    rel = url.lstrip("/")
    return (rel + "index.html") if (rel == "" or rel.endswith("/")) else rel


def _rel_prefix(dist_rel):
    depth = dist_rel.count("/")
    return "../" * depth if depth else "./"


# ------------------------------------------------------------------ couleurs et jetons de conception
def palette(brand):
    """Variables CSS à partir des couleurs de marque, contrastes AA garantis (>= 4,5:1) pour texte/fond et texte sur couleur principale."""
    colors = brand.get("colors") if isinstance(brand.get("colors"), dict) else {}

    def col(name, default):
        c = css.parse_color(colors.get(name)) if isinstance(colors.get(name), str) else None
        return c or default

    bg = col("bg", (255, 255, 255))
    text = col("text", (31, 41, 55))
    primary = col("primary", (29, 78, 137))
    accent = col("accent", (180, 83, 9))
    dark_bg = css.luminance(bg) < 0.4
    text = css.ensure_contrast(text, bg, 7.0)
    on_primary = css.best_on(primary)
    if css.contrast(on_primary, primary) < 4.5:
        primary = css.ensure_contrast(primary, on_primary, 4.5)
    primary_strong = css.mix(primary, (0, 0, 0) if not dark_bg else (255, 255, 255), 0.18)
    if css.contrast(on_primary, primary_strong) < 4.5:
        primary_strong = primary
    surface = css.mix(bg, primary, 0.05)
    text = css.ensure_contrast(text, surface, 7.0)
    muted = css.ensure_contrast(css.mix(text, bg, 0.35), surface, 4.6)
    link = css.ensure_contrast(primary, bg, 4.6)
    link = css.ensure_contrast(link, surface, 4.6)
    accent_text = css.ensure_contrast(accent, bg, 4.6)
    border = css.mix(bg, text, 0.16)
    border_strong = css.mix(bg, text, 0.45)
    footer_bg = css.mix(text, (0, 0, 0), 0.25) if not dark_bg else css.mix(bg, (255, 255, 255), 0.06)
    on_footer = css.best_on(footer_bg, light=(255, 255, 255), dark=(17, 24, 39))
    hero_bg = css.mix(bg, accent, 0.06)
    hero_bg = hero_bg if css.contrast(text, hero_bg) >= 7 and css.contrast(muted, hero_bg) >= 4.5 else surface
    font = brand.get("font") if brand.get("font") in FONT_STACKS else "system"
    body_font, heading_font = FONT_STACKS[font]
    radius = brand.get("radius") if isinstance(brand.get("radius"), str) and re.match(r"^\d{1,2}(px|rem)\Z", brand.get("radius")) else "10px"
    hx = css.to_hex
    lines = [
        ":root {",
        f"  --bg: {hx(bg)};", f"  --surface: {hx(surface)};", f"  --hero-bg: {hx(hero_bg)};",
        f"  --text: {hx(text)};", f"  --heading: {hx(text)};", f"  --muted: {hx(muted)};",
        f"  --primary: {hx(primary)};", f"  --primary-strong: {hx(primary_strong)};", f"  --on-primary: {hx(on_primary)};",
        f"  --accent: {hx(accent)};", f"  --accent-text: {hx(accent_text)};", f"  --link: {hx(link)};",
        f"  --border: {hx(border)};", f"  --border-strong: {hx(border_strong)};", f"  --focus: {hx(accent_text)};",
        f"  --footer-bg: {hx(footer_bg)};", f"  --on-footer: {hx(on_footer)};",
        f"  --font-body: {body_font};", f"  --font-heading: {heading_font or 'var(--font-body)'};",
        f"  --radius: {radius};", "  --max-width: 72rem;",
        "  --space-1: 0.25rem; --space-2: 0.5rem; --space-3: 1rem; --space-4: 1.5rem;",
        "  --space-5: 2rem; --space-6: 3rem; --space-7: 4.5rem; --space-8: 6rem;",
        "  --step--1: clamp(0.83rem, 0.8rem + 0.15vw, 0.9rem);",
        "  --step-0: clamp(1rem, 0.96rem + 0.2vw, 1.125rem);",
        "  --step-1: clamp(1.2rem, 1.12rem + 0.4vw, 1.4rem);",
        "  --step-2: clamp(1.44rem, 1.3rem + 0.7vw, 1.75rem);",
        "  --step-3: clamp(1.73rem, 1.5rem + 1.1vw, 2.2rem);",
        "  --step-4: clamp(2.07rem, 1.7rem + 1.8vw, 2.8rem);",
        "  --step-5: clamp(2.3rem, 1.8rem + 2.6vw, 3.5rem);",
        "}",
    ]
    return "\n".join(lines), {"bg": hx(bg), "text": hx(text), "primary": hx(primary), "onPrimary": hx(on_primary), "accent": hx(accent),
                               "surface": hx(surface), "link": hx(link)}


def _brand_hex(site):
    _css, vals = palette(site.get("brand") or {})
    return vals


def brand_mark_svg(site, size=32):
    v = _brand_hex(site)
    initial = (str((site.get("brand") or {}).get("initial") or site.get("name") or "?").strip()[:1] or "?").upper()
    if initial == "[":
        initial = "•"
    return (f'<svg class="brand__mark" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32" width="{size}" height="{size}" aria-hidden="true" focusable="false">'
            f'<rect width="32" height="32" rx="8" fill="{v["primary"]}"/>'
            f'<text x="16" y="21.5" text-anchor="middle" font-family="system-ui, sans-serif" font-size="16" font-weight="700" fill="{v["onPrimary"]}">{_esc(initial)}</text></svg>')


def favicon_svg(site):
    return brand_mark_svg(site, 32).replace(' class="brand__mark"', "").replace(' aria-hidden="true" focusable="false"', "") + "\n"


def illustration_svg(site):
    """Illustration abstraite (formes de la marque) : aucune image externe, aucune photo inventée ; décorative (aria-hidden)."""
    v = _brand_hex(site)
    seed = int(hashlib.sha256(str(site.get("name")).encode("utf-8")).hexdigest()[:6], 16)
    r1, r2 = 60 + seed % 30, 40 + (seed >> 5) % 25
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 320" width="400" height="320" aria-hidden="true" focusable="false">'
            f'<rect x="20" y="30" width="300" height="240" rx="28" fill="{v["surface"]}"/>'
            f'<circle cx="290" cy="{90 + seed % 40}" r="{r1}" fill="{v["accent"]}" opacity="0.85"/>'
            f'<rect x="70" y="150" width="210" height="120" rx="20" fill="{v["primary"]}"/>'
            f'<circle cx="{110 + seed % 50}" cy="110" r="{r2}" fill="{v["primary"]}" opacity="0.35"/>'
            f'<path d="M90 230h120M90 205h170" stroke="{v["onPrimary"]}" stroke-width="10" stroke-linecap="round" opacity="0.9"/></svg>')


def icon_svg(name):
    body = ICONS.get(name, ICONS["check"])
    return (f'<svg class="card__icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="40" height="40" fill="none" stroke="currentColor" '
            f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">{body}</svg>')


def og_png(site, width=1200, height=630):
    """Image de partage 1200×630 (PNG produit sans bibliothèque) : fond de la marque, bande et pastille de couleur. Un og.png fourni dans
    src/assets/img/ (photo du client, visuel du bac à sable) la remplace."""
    v = _brand_hex(site)

    def rgb(h):
        return bytes(int(h[i:i + 2], 16) for i in (1, 3, 5))

    bg, pr, ac = rgb(v["surface"]), rgb(v["primary"]), rgb(v["accent"])
    rows = []
    for y in range(height):
        if 470 <= y < 630:
            row = pr * width
        elif 120 <= y < 360:
            row = bg * 120 + ac * 240 + bg * (width - 360)
        else:
            row = bg * width
        rows.append(b"\x00" + row)
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(t, data):
        return struct.pack(">I", len(data)) + t + data + struct.pack(">I", zlib.crc32(t + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b""))


# ------------------------------------------------------------------ gabarits du kit
def templates_dir(root=None):
    return os.path.join(root or ROOT, *TEMPLATES_REL)


def load_profile(profile, root=None):
    path = os.path.join(templates_dir(root), profile if profile in PROFILES else "vitrine", "profile.json")
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def load_sections(lang, root=None):
    d = os.path.join(templates_dir(root), "_kit", "sections")
    path = os.path.join(d, f"{lang}.html")
    if not os.path.isfile(path):
        path = os.path.join(d, "en.html")
    text = _read(path)
    out = {}
    for m in re.finditer(r"<!-- section:([a-z-]+) -->[ \t]*\r?\n(.*?)(?=<!-- section:|\Z)", text.replace("\r\n", "\n"), re.DOTALL):
        out[m.group(1)] = m.group(2).strip() + "\n"
    return out


def guide_text(root=None):
    try:
        return _read(os.path.join(root or ROOT, *GUIDE_REL), 200 * 1024)
    except (OSError, SiteError):
        return ""


# ------------------------------------------------------------------ site_scaffold
def scaffold(workspace, inp, root=None):
    """Crée site.json, les parties communes, la feuille de style (variables de la marque) et un squelette par page et par langue.
    Le squelette ne contient AUCUN fait inventé : « [À RÉDIGER : …] » (texte que le Worker écrit) et « [À COMPLÉTER : …] » (fait que seul
    le client peut donner). Refuse d'écraser un site existant sans force:true."""
    root = root or ROOT
    p = site_paths(workspace)
    if os.path.exists(p["json"]) and inp.get("force") is not True:
        raise SiteError("EXISTS", "Un site existe déjà dans site/ : modifiez ses fichiers, ou relancez site_scaffold avec force:true pour TOUT recréer (les pages écrites seraient perdues).")
    profile = inp.get("profile") if inp.get("profile") in PROFILES else "vitrine"
    langs = [l for l in (inp.get("languages") or ["fr"]) if isinstance(l, str) and l in LANGS]
    langs = list(dict.fromkeys(langs)) or ["fr"]
    brand = inp.get("brand") if isinstance(inp.get("brand"), dict) else {}
    prof = load_profile(profile, root)
    pages = prof["pages"]
    if isinstance(inp.get("pages"), list) and inp["pages"]:
        by_key = {pg["key"]: pg for pg in pages}
        chosen = []
        for item in inp["pages"][:MAX_PAGES]:
            if not isinstance(item, dict):
                continue
            key = str(item.get("key") or item.get("slug") or "")
            key = _slugify(key)[:32] or None
            if key in ("index", "accueil"):
                key = "home"
            if not key or not KEY_RE.match(key):
                continue
            base = dict(by_key.get(key) or {"key": key, "slug": {l: (item.get("slug") if isinstance(item.get("slug"), str) and SLUG_RE.match(item.get("slug")) else key) for l in langs},
                                            "title": {}, "nav": True, "sections": ["page-title", "text", "cta"]})
            if isinstance(item.get("title"), (str, dict)):
                t = item["title"]
                base["title"] = {l: t for l in langs} if isinstance(t, str) else {**base.get("title", {}), **t}
            if isinstance(item.get("sections"), list):
                base["sections"] = [s for s in item["sections"] if isinstance(s, str)][:12]
            if "nav" in item:
                base["nav"] = bool(item["nav"])
            chosen.append(base)
        keys = {c["key"] for c in chosen}
        if "home" not in keys:
            chosen.insert(0, dict(by_key.get("home")))
        for must in ("legal", "privacy"):
            if must not in keys and must in by_key:
                chosen.append(dict(by_key[must]))
        pages = chosen
    name = str(brand.get("name") or inp.get("name") or "").strip()[:120]
    contact = inp.get("contact") if isinstance(inp.get("contact"), dict) else {}
    legal = inp.get("legal") if isinstance(inp.get("legal"), dict) else {}
    site = {
        "schema": "BK-SITE-V1", "profile": profile, "name": name or PLACEHOLDER.format("nom de l'entreprise"), "slug": _slugify(name) or "site",
        "tagline": str(brand.get("tagline") or "")[:160], "tone": str(brand.get("tone") or "")[:160],
        "languages": langs, "defaultLanguage": langs[0], "baseUrl": str(inp.get("baseUrl") or ""),
        "brand": {"colors": brand.get("colors") if isinstance(brand.get("colors"), dict) else {}, "font": brand.get("font") if brand.get("font") in FONT_STACKS else "system",
                  "radius": brand.get("radius") if isinstance(brand.get("radius"), str) else "10px"},
        "contact": {k: str(contact[k])[:200] for k in ("email", "phone", "address", "hours") if isinstance(contact.get(k), str) and contact.get(k).strip()},
        "legal": {k: str(legal[k])[:300] for k in ("company", "address", "uid", "responsible", "host", "retention") if isinstance(legal.get(k), str) and legal.get(k).strip()},
        "pages": [{k: pg[k] for k in ("key", "slug", "title", "nav", "footer", "ogType") if k in pg} for pg in pages],
        "allowedExternalHosts": [], "claimsProvidedByClient": [], "storageDeclared": False,
        "hosting": {"host": str((inp.get("hosting") or {}).get("host") or "") if isinstance(inp.get("hosting"), dict) else "",
                    "domain": str((inp.get("hosting") or {}).get("domain") or "") if isinstance(inp.get("hosting"), dict) else ""},
        "needsFromClient": [],
    }
    norm = normalise_site(site)
    needs = []
    for dotted, label in FACT_LABELS.items():
        if _is_placeholder(_get(norm, dotted)):
            needs.append(label)
    if not name:
        needs.insert(0, "nom de l'entreprise")
    if not norm["baseUrl"]:
        needs.append("adresse du site (nom de domaine)")
    if any("pricing" in (pg.get("sections") or []) for pg in pages):
        needs.append("prix de la formule")
    site["needsFromClient"] = list(dict.fromkeys(needs))
    written = []
    if inp.get("force") is True and os.path.isdir(p["src"]):
        _safe_rmtree(p["src"], p["base"])
    os.makedirs(p["base"], exist_ok=True)
    _write(p["json"], json.dumps(site, ensure_ascii=False, indent=2) + "\n")
    written.append("site/site.json")
    kit = os.path.join(templates_dir(root), "_kit")
    tokens_css, colors = palette(site["brand"])
    style = _read(os.path.join(kit, "style.css")).replace("/* @tokens */", tokens_css)
    _write(os.path.join(p["assets"], "style.css"), style)
    written.append("site/src/assets/style.css")
    for part in ("header", "footer"):
        _write(os.path.join(p["partials"], f"{part}.html"), _read(os.path.join(kit, "_partials", f"{part}.html")))
        written.append(f"site/src/_partials/{part}.html")
    for lang in langs:
        sections = load_sections(lang, root)
        for pg in pages:
            slug = (pg.get("slug") or {}).get(lang) or pg["key"]
            body = "".join(sections.get(s, "") for s in (pg.get("sections") or ["page-title", "text"]))
            title = (pg.get("title") or {}).get(lang) or pg["key"]
            meta = {"title": "", "description": ""}
            head = f"<!--meta {json.dumps(meta, ensure_ascii=False)} -->\n<!-- Page « {title} » : remplacez chaque [À RÉDIGER] / [TO WRITE] par le vrai texte ; title 30-60 caractères, description 70-160. -->\n"
            rel = f"site/src/pages/{lang}/{slug}.html"
            _write(pp.resolve(workspace, rel, kind="file"), head + body)
            written.append(rel)
    guide = guide_text(root)
    if guide:
        _write(pp.resolve(workspace, "notes/site-guide.md", kind="file"), guide)
        written.append("notes/site-guide.md")
    return {"profile": profile, "languages": langs, "pages": [{"key": pg["key"], "slug": pg.get("slug"), "url": {l: page_url(norm, {"key": pg["key"], "slug": pg.get("slug") or {}}, l) for l in langs}} for pg in pages],
            "files": written, "colors": colors, "needsFromClient": site["needsFromClient"]}


def _safe_rmtree(target, must_be_under):
    real_t = os.path.realpath(target)
    real_b = os.path.realpath(must_be_under)
    if not real_t.startswith(real_b + os.sep) or pp._is_link_or_reparse(target):
        raise SiteError("PATH_INVALID", "Suppression refusée hors du dossier du site.")
    shutil.rmtree(real_t)


# ------------------------------------------------------------------ rendu d'une page
def _fact(site, dotted):
    v = _get(site, dotted)
    if _is_placeholder(v):
        return None
    return str(v)


def _token_value(site, lang, token, ctx):
    """Valeur HTML d'un jeton {{…}} (déjà échappée)."""
    s = STRINGS.get(lang, STRINGS["en"])
    if token.startswith("t:"):
        key = token[2:]
        custom = (site.get("strings") or {}).get(lang) if isinstance((site.get("strings") or {}).get(lang), dict) else {}
        return _esc(custom.get(key) or s.get(key) or "")
    if token.startswith("page:"):
        key = token[5:]
        pg = ctx["pages_by_key"].get(key)
        if pg is None:
            pg = ctx["pages_by_key"].get("contact") if key == "services" else None
        if pg is None:
            pg = ctx["pages_by_key"].get("home")
            if key in ("contact", "services"):
                return page_url(site, pg, lang) + ("#contact" if key == "contact" else "")
        return page_url(site, pg, lang) if pg else "/"
    if token.startswith("icon:"):
        return icon_svg(token[5:])
    if token == "home":
        return page_url(site, ctx["pages_by_key"]["home"], lang) if "home" in ctx["pages_by_key"] else "/"
    if token == "nav":
        return ctx["nav"]
    if token == "lang_switch":
        return ctx["lang_switch"]
    if token == "footer_links":
        return ctx["footer_links"]
    if token == "brand_mark":
        return brand_mark_svg(site)
    if token == "illustration":
        return illustration_svg(site)
    if token == "site.name":
        return _esc(site["name"])
    if token == "site.tagline":
        return _esc(site.get("tagline") or "")
    if token == "contact.email_link":
        e = _fact(site, "contact.email")
        return f'<a href="mailto:{_esc(e)}">{_esc(e)}</a>' if e else _esc(PLACEHOLDER.format(FACT_LABELS["contact.email"]))
    if token == "contact.phone_link":
        t = _fact(site, "contact.phone")
        if not t:
            return _esc(PLACEHOLDER.format(FACT_LABELS["contact.phone"]))
        tel = re.sub(r"[^0-9+]", "", t)
        return f'<a href="tel:{_esc(tel)}">{_esc(t)}</a>'
    if token == "contact.mailto":
        e = _fact(site, "contact.email")
        return f"mailto:{_esc(e)}" if e else ""
    if token in FACT_LABELS:
        v = _fact(site, token)
        if token == "legal.host" and not v and (site.get("hosting") or {}).get("host"):
            v = str(site["hosting"]["host"])
        if token == "legal.company" and not v and not _is_placeholder(site.get("name")):
            v = site["name"]
        if token == "legal.address" and not v:
            v = _fact(site, "contact.address")
        return _esc(v) if v else _esc(PLACEHOLDER.format(FACT_LABELS[token]))
    ctx["unknown"].add(token)
    return ""


def render_tokens(text, site, lang, ctx):
    return TOKEN_RE.sub(lambda m: _token_value(site, lang, m.group(1), ctx), text)


def _nav_html(site, lang, current_key, pages):
    items = []
    for pg in pages:
        if not pg.get("nav") or lang not in (pg.get("slug") or {lang: 1}):
            continue
        title = (pg.get("title") or {}).get(lang) or pg["key"]
        cur = ' aria-current="page"' if pg["key"] == current_key else ""
        items.append(f'<li><a href="{page_url(site, pg, lang)}"{cur}>{_esc(title)}</a></li>')
    return "<ul>" + "".join(items) + "</ul>"


def _footer_links(site, lang, pages):
    items = []
    for pg in pages:
        if pg.get("footer"):
            title = (pg.get("title") or {}).get(lang) or pg["key"]
            items.append(f'<li><a href="{page_url(site, pg, lang)}">{_esc(title)}</a></li>')
    return "<ul>" + "".join(items) + "</ul>"


def _lang_switch(site, lang, page, available):
    if len(site["languages"]) < 2:
        return ""
    s = STRINGS.get(lang, STRINGS["en"])
    items = []
    for l in site["languages"]:
        if l == lang:
            continue
        target = available.get(l)
        if target is None:
            continue
        name = STRINGS.get(l, STRINGS["en"])["lang_name"]
        items.append(f'<li><a href="{target}" hreflang="{l}" lang="{l}">{_esc(name)}</a></li>')
    if not items:
        return ""
    return f'<ul class="lang-switch" aria-label="{_esc(s["lang"])}">' + "".join(items) + "</ul>"


def split_meta(text):
    """(meta dict, corps) d'un fichier source de page. Une première ligne <!--meta {...} --> invalide est ignorée (signalée)."""
    m = META_RE.match(text)
    if not m:
        return {}, text, None
    try:
        meta = json.loads(m.group(1))
        if not isinstance(meta, dict):
            raise ValueError
    except ValueError:
        return {}, text[m.end():], "ligne <!--meta …--> illisible (JSON invalide) : ignorée"
    return meta, text[m.end():], None


def _strip_document(body):
    """Si le Worker a écrit un document complet, ne garde que le contenu de <body> (les balises de tête sont produites par la construction)."""
    note = None
    if re.search(r"<html[\s>]|<!doctype", body, re.IGNORECASE):
        note = "document HTML complet réduit au contenu de <body> (la tête est produite par site_build)"
        m = re.search(r"<body[^>]*>(.*)</body>", body, re.IGNORECASE | re.DOTALL)
        body = m.group(1) if m else re.sub(r"<!doctype[^>]*>|</?html[^>]*>|<head>.*?</head>", "", body, flags=re.IGNORECASE | re.DOTALL)
    return body, note


def _abs(site, url):
    return (site["baseUrl"] or PLACEHOLDER_DOMAIN) + url


def _json_ld(site, lang, url):
    """Données structurées : uniquement des valeurs de site.json (le contrôle seo.jsonld le vérifie). Aucune note ni avis."""
    data = {"@context": "https://schema.org", "@type": str((site.get("brand") or {}).get("schemaType") or "Organization"),
            "name": site["name"], "url": _abs(site, url)}
    if not re.match(r"^[A-Za-z]{2,40}\Z", data["@type"]):
        data["@type"] = "Organization"
    for key, dotted in (("email", "contact.email"), ("telephone", "contact.phone"), ("address", "contact.address")):
        v = _fact(site, dotted)
        if v:
            data[key] = v
    if _is_placeholder(site["name"]):
        return ""
    return '<script type="application/ld+json">' + json.dumps(data, ensure_ascii=False, sort_keys=True).replace("</", "<\\/") + "</script>"


_ATTR_URL_RE = re.compile(r'(\s(?:href|src|action|poster|data-src)\s*=\s*)(["\'])(/(?!/)[^"\']*)\2', re.IGNORECASE)
_SRCSET_RE = re.compile(r'(\ssrcset\s*=\s*)(["\'])([^"\']*)\2', re.IGNORECASE)
_CSS_URL_RE = re.compile(r'url\(\s*(["\']?)(/(?!/)[^"\')]*)\1\s*\)')


def relativize(html_text, dist_rel):
    """Liens internes « /chemin » -> chemins relatifs à la page : le site marche à la racine d'un domaine, dans un sous-dossier, dans
    l'aperçu à jeton et ouvert depuis le zip. (canonical, hreflang et og:url restent absolus : ils ne passent pas par ici.)"""
    prefix = _rel_prefix(dist_rel)

    def one(url):
        if url.startswith("/"):
            return prefix + url.lstrip("/") if url != "/" else prefix
        return url

    out = _ATTR_URL_RE.sub(lambda m: m.group(1) + m.group(2) + one(m.group(3)) + m.group(2), html_text)
    out = _SRCSET_RE.sub(lambda m: m.group(1) + m.group(2) + ", ".join(
        " ".join([one(part.strip().split(" ")[0])] + part.strip().split(" ")[1:]) for part in m.group(3).split(",") if part.strip()) + m.group(2), out)
    out = _CSS_URL_RE.sub(lambda m: f"url({m.group(1)}{one(m.group(2))}{m.group(1)})", out)
    return out


def render_site(workspace, root=None, relative=True):
    """Assemble toutes les pages en mémoire : {dist_rel: bytes} + liste des pages + avertissements. N'écrit rien."""
    root = root or ROOT
    p = site_paths(workspace)
    site = load_site(workspace)
    pages = site["pages"]
    if not pages:
        raise SiteError("SITE_INVALID", "site.json ne déclare aucune page (champ pages).")
    pages_by_key = {pg["key"]: pg for pg in pages}
    warnings = []
    out = {}
    page_rows = []
    partials = {}
    if os.path.isdir(p["partials"]):
        for fn in sorted(os.listdir(p["partials"])):
            m = re.match(r"^([a-z][a-z0-9_.-]{0,31})\.html\Z", fn)
            full = os.path.join(p["partials"], fn)
            if m and os.path.isfile(full) and not pp._is_link_or_reparse(full):
                partials[m.group(1)] = _read(full)
    # pages présentes par langue (fichier source existant)
    sources = {}
    for lang in site["languages"]:
        for pg in pages:
            slug = (pg.get("slug") or {}).get(lang) or pg["key"]
            full = os.path.join(p["pages"], lang, f"{slug}.html")
            if os.path.isfile(full) and not pp._is_link_or_reparse(full):
                sources[(pg["key"], lang)] = full
            elif lang == site["defaultLanguage"]:
                warnings.append(f"page « {pg['key']} » ({lang}) déclarée dans site.json mais absente : src/pages/{lang}/{slug}.html")
    extra = []
    if os.path.isdir(p["pages"]):
        for lang in sorted(os.listdir(p["pages"])):
            d = os.path.join(p["pages"], lang)
            if lang not in site["languages"] or not os.path.isdir(d):
                continue
            known = {(pg.get("slug") or {}).get(lang) or pg["key"] for pg in pages}
            for fn in sorted(os.listdir(d)):
                if fn.endswith(".html") and fn[:-5] not in known and fn != "404.html":
                    extra.append(f"src/pages/{lang}/{fn}")
    if extra:
        warnings.append("fichier(s) de page non déclaré(s) dans site.json › pages, donc ignoré(s) : " + ", ".join(extra[:6]))
    if len(sources) > MAX_PAGES:
        raise SiteError("TOO_LARGE", f"{len(sources)} pages : au plus {MAX_PAGES}.")
    has_js = os.path.isfile(os.path.join(p["assets"], "site.js"))
    has_og = os.path.isfile(os.path.join(p["assets"], "img", "og.png"))
    has_favicon = os.path.isfile(os.path.join(p["assets"], "favicon.svg"))
    for (key, lang), full in sorted(sources.items(), key=lambda kv: (kv[0][1] != site["defaultLanguage"], kv[0][1], [pg["key"] for pg in pages].index(kv[0][0]))):
        pg = pages_by_key[key]
        meta, body, meta_note = split_meta(_read(full))
        if meta_note:
            warnings.append(f"{lang}/{key} : {meta_note}")
        body, doc_note = _strip_document(body)
        if doc_note:
            warnings.append(f"{lang}/{key} : {doc_note}")
        url = meta.get("path") if isinstance(meta.get("path"), str) and re.match(r"^/[a-z0-9/_-]{0,120}\Z", meta.get("path") or "") else page_url(site, pg, lang)
        if not url.endswith("/") and not url.endswith(".html"):
            url += "/"
        dist_rel = url_to_dist_rel(url)
        available = {l: page_url(site, pg, l) for l in site["languages"] if (key, l) in sources}
        alternates = meta.get("alternates") if isinstance(meta.get("alternates"), dict) else {}
        for l, u in alternates.items():
            if l in site["languages"] and isinstance(u, str) and u.startswith("/"):
                available[l] = u
        ctx = {"pages_by_key": pages_by_key, "unknown": set(), "nav": "", "lang_switch": "", "footer_links": ""}
        nav_custom = partials.get(f"nav.{lang}")
        ctx["nav"] = render_tokens(nav_custom, site, lang, dict(ctx, nav="")) if nav_custom else _nav_html(site, lang, key, pages)
        ctx["lang_switch"] = _lang_switch(site, lang, pg, available)
        ctx["footer_links"] = _footer_links(site, lang, pages)
        body = INCLUDE_RE.sub(lambda m: partials.get(m.group(1), ""), body)
        body = re.sub(r"<!--(?!\[if).*?-->\s*", "", body, flags=re.DOTALL)        # commentaires de travail : jamais publiés
        main_html = render_tokens(body, site, lang, ctx).strip()
        if ctx["unknown"]:
            warnings.append(f"{lang}/{key} : jeton(s) inconnu(s) ignoré(s) : " + ", ".join(sorted("{{" + t + "}}" for t in ctx["unknown"])[:5]))
        header = render_tokens(partials.get("header", ""), site, lang, ctx)
        footer = render_tokens(partials.get("footer", ""), site, lang, ctx)
        s = STRINGS.get(lang, STRINGS["en"])
        title = str(meta.get("title") or "").strip()
        page_title = (pg.get("title") or {}).get(lang) or key
        if not title:
            title = f"{site['name']} — {site.get('tagline')}" if key == "home" and site.get("tagline") else f"{page_title} | {site['name']}"
        desc = str(meta.get("description") or "").strip()
        og = meta.get("og") if isinstance(meta.get("og"), dict) else {}
        og_image = og.get("image") if isinstance(og.get("image"), str) and og.get("image").startswith("/") else "/assets/img/og.png"
        og_type = og.get("type") if og.get("type") in ("website", "article") else pg.get("ogType", "website")
        noindex = meta.get("noindex") is True
        head = ['<meta charset="utf-8">', '<meta name="viewport" content="width=device-width, initial-scale=1">',
                f"<title>{_esc(title)}</title>"]
        if desc:
            head.append(f'<meta name="description" content="{_esc(desc)}">')
        if noindex:
            head.append('<meta name="robots" content="noindex">')
        head.append(f'<link rel="canonical" href="{_esc(_abs(site, url))}">')
        if len(available) > 1:
            for l in site["languages"]:
                if l in available:
                    head.append(f'<link rel="alternate" hreflang="{l}" href="{_esc(_abs(site, available[l]))}">')
            if site["defaultLanguage"] in available:
                head.append(f'<link rel="alternate" hreflang="x-default" href="{_esc(_abs(site, available[site["defaultLanguage"]]))}">')
        head += [f'<meta property="og:type" content="{og_type}">', f'<meta property="og:title" content="{_esc(title)}">']
        if desc:
            head.append(f'<meta property="og:description" content="{_esc(desc)}">')
        head += [f'<meta property="og:url" content="{_esc(_abs(site, url))}">', f'<meta property="og:image" content="{_esc(_abs(site, og_image))}">',
                 f'<meta property="og:site_name" content="{_esc(site["name"])}">', '<meta name="twitter:card" content="summary_large_image">',
                 '<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">', '<link rel="stylesheet" href="/assets/style.css">',
                 f'<meta name="theme-color" content="{_brand_hex(site)["primary"]}">']
        if key == "home":
            ld = _json_ld(site, lang, url)
            if ld:
                head.append(ld)
        if has_js:
            head.append('<script src="/assets/site.js" defer></script>')
        if "<main" in main_html.lower():
            main_block = main_html
            if 'id="main"' not in main_html:
                main_block = re.sub(r"<main(\s|>)", r'<main id="main"\1', main_html, count=1, flags=re.IGNORECASE)
        else:
            main_block = f'<main id="main">\n{main_html}\n</main>'
        doc = (f'<!doctype html>\n<html lang="{lang}">\n<head>\n' + "\n".join(head) + "\n</head>\n<body>\n"
               f'<a class="skip-link" href="#main">{_esc(s["skip"])}</a>\n' + header.strip() + "\n" + main_block + "\n" + footer.strip() + "\n</body>\n</html>\n")
        if relative:
            # les URL absolues (https://) de la tête ne commencent pas par « / » : relativize ne les touche pas
            doc = relativize(doc, dist_rel)
        if dist_rel in out:
            warnings.append(f"{lang}/{key} : adresse {url} déjà utilisée par une autre page : page ignorée")
            continue
        out[dist_rel] = doc.encode("utf-8")
        page_rows.append({"key": key, "lang": lang, "url": url, "path": dist_rel, "title": title, "description": desc, "noindex": noindex,
                          "bytes": len(out[dist_rel]), "main": main_html if not relative else None, "nav": bool(pg.get("nav"))})
    # 404 (liens absolus : un hébergeur la sert à n'importe quelle profondeur)
    lang = site["defaultLanguage"]
    s = STRINGS.get(lang, STRINGS["en"])
    nf_src = os.path.join(p["pages"], lang, "404.html")
    ctx = {"pages_by_key": pages_by_key, "unknown": set(), "nav": _nav_html(site, lang, None, pages), "lang_switch": "", "footer_links": _footer_links(site, lang, pages)}
    if os.path.isfile(nf_src) and not pp._is_link_or_reparse(nf_src):
        _m, nf_body, _n = split_meta(_read(nf_src))
        nf_body = render_tokens(_strip_document(nf_body)[0], site, lang, ctx)
    else:
        home = page_url(site, pages_by_key["home"], lang) if "home" in pages_by_key else "/"
        nf_body = (f'<section class="section"><div class="container prose"><h1>{_esc(s["notfound_title"])}</h1><p>{_esc(s["notfound_text"])}</p>'
                   f'<p><a class="btn" href="{home}">{_esc(s["home_link"])}</a></p></div></section>')
    nf = (f'<!doctype html>\n<html lang="{lang}">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n'
          f'<title>{_esc(s["notfound_title"])} | {_esc(site["name"])}</title>\n<meta name="description" content="{_esc(s["notfound_text"] + " " + s["home_link"] + " : " + site["name"] + ".")}">\n'
          '<meta name="robots" content="noindex">\n'
          '<link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">\n<link rel="stylesheet" href="/assets/style.css">\n</head>\n<body>\n'
          f'<a class="skip-link" href="#main">{_esc(s["skip"])}</a>\n' + render_tokens(partials.get("header", ""), site, lang, ctx).strip() + "\n"
          f'<main id="main">\n{nf_body}\n</main>\n' + render_tokens(partials.get("footer", ""), site, lang, ctx).strip() + "\n</body>\n</html>\n")
    out["404.html"] = nf.encode("utf-8")
    # ressources
    assets = {}
    if os.path.isdir(p["assets"]):
        for dirpath, dirnames, filenames in os.walk(p["assets"], followlinks=False):
            dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and not pp._is_link_or_reparse(os.path.join(dirpath, d)))
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                if fn.startswith(".") or pp._is_link_or_reparse(full) or pp.ext_of(fn) not in ASSET_EXT:
                    continue
                rel = "assets/" + pp.rel_of(p["assets"], full)
                with open(full, "rb") as f:
                    data = f.read(MAX_SRC_FILE + 1)
                if len(data) > MAX_SRC_FILE:
                    warnings.append(f"{rel} : plus de 5 Mo, ignoré")
                    continue
                if rel.endswith(".css") and relative:
                    data = _CSS_URL_RE.sub(lambda m, r=rel: f"url({m.group(1)}{_rel_prefix(r)}{m.group(2).lstrip('/')}{m.group(1)})", data.decode("utf-8", "replace")).encode("utf-8")
                assets[rel] = data
    if not has_favicon:
        assets["assets/favicon.svg"] = favicon_svg(site).encode("utf-8")
    if not has_og:
        assets["assets/img/og.png"] = og_png(site)
    out.update(assets)
    # sitemap, robots
    base = site["baseUrl"] or PLACEHOLDER_DOMAIN
    locs = sorted({_abs(site, r["url"]) for r in page_rows if not r["noindex"]})
    out["sitemap.xml"] = ('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
                          + "".join(f"  <url><loc>{_esc(u)}</loc></url>\n" for u in locs) + "</urlset>\n").encode("utf-8")
    out["robots.txt"] = f"User-agent: *\nAllow: /\n\nSitemap: {base}/sitemap.xml\n".encode("utf-8")
    if not site["baseUrl"]:
        warnings.append(f"baseUrl absent de site.json : adresses provisoires {PLACEHOLDER_DOMAIN} dans canonical, hreflang, og:url et sitemap (à remplacer avant la mise en ligne)")
    return site, out, page_rows, warnings


def src_fingerprint(workspace):
    """Empreinte de site.json + src/ (détecte un dist/ périmé)."""
    p = site_paths(workspace)
    h = hashlib.sha256()
    files = []
    if os.path.isfile(p["json"]):
        files.append(("site.json", p["json"]))
    if os.path.isdir(p["src"]):
        for dirpath, dirnames, filenames in os.walk(p["src"], followlinks=False):
            dirnames[:] = sorted(d for d in dirnames if not pp._is_link_or_reparse(os.path.join(dirpath, d)))
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                if not fn.startswith(".") and not pp._is_link_or_reparse(full):
                    files.append(("src/" + pp.rel_of(p["src"], full), full))
    for rel, full in sorted(files):
        h.update(rel.encode("utf-8") + b"\0")
        try:
            h.update(pp.sha256_file(full).encode("ascii"))
        except OSError:
            continue
    return h.hexdigest()


# ------------------------------------------------------------------ site_build
def build(workspace, root=None, capacity_bytes=None):
    """Construit site/dist/ (remplacement complet et atomique : dossier temporaire puis renommage). Renvoie les pages, les poids et les
    avertissements. Déterministe : deux constructions du même src/ donnent les mêmes octets."""
    p = site_paths(workspace)
    site, files, rows, warnings = render_site(workspace, root, relative=True)
    total = sum(len(b) for b in files.values())
    if total > MAX_DIST_BYTES:
        raise SiteError("TOO_LARGE", f"Le site construit pèserait {total // (1024 * 1024)} Mo (maximum {MAX_DIST_BYTES // (1024 * 1024)} Mo).")
    if capacity_bytes is not None:
        _f, used = pp.usage(workspace)
        old = sum(sz for _r, sz, _m in pp.walk_files(p["dist"])) if os.path.isdir(p["dist"]) else 0
        if used - old + total > capacity_bytes:
            raise SiteError("WORKSPACE_FULL", "Espace de travail plein : le site construit ne tient pas (supprimez des fichiers inutiles).")
    tmp = os.path.join(p["base"], "dist.tmp-" + secrets.token_hex(4))
    try:
        for rel in sorted(files):
            full = os.path.join(tmp, *rel.split("/"))
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(files[rel])
        if os.path.lexists(p["dist"]):
            if pp._is_link_or_reparse(p["dist"]) or not os.path.isdir(p["dist"]):
                raise SiteError("PATH_INVALID", "site/dist n'est pas un dossier ordinaire.")
            _safe_rmtree(p["dist"], p["base"])
        os.replace(tmp, p["dist"])
    finally:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
    info = {"schema": "BK-SITE-BUILD-V1", "srcSha256": src_fingerprint(workspace), "languages": site["languages"],
            "pages": [{k: r[k] for k in ("key", "lang", "url", "path", "title", "bytes", "noindex")} for r in rows],
            "files": len(files), "totalBytes": total, "warnings": warnings[:40]}
    _write(p["build"], json.dumps(info, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return info


# ------------------------------------------------------------------ export zip et guide de mise en ligne
def _zip_bytes(entries):
    """Zip reproductible : noms triés, horodatage fixe, droits fixes, compression deflate."""
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for name in sorted(entries):
            zi = zipfile.ZipInfo(name, date_time=ZIP_DATE)
            zi.compress_type = zipfile.ZIP_DEFLATED
            zi.external_attr = 0o644 << 16
            zi.create_system = 3
            z.writestr(zi, entries[name])
    return buf.getvalue()


def _dir_entries(base, prefix, skip_dirs=()):
    out = {}
    if not os.path.isdir(base):
        return out
    for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in skip_dirs and not pp._is_link_or_reparse(os.path.join(dirpath, d)))
        for fn in sorted(filenames):
            full = os.path.join(dirpath, fn)
            if fn.startswith(".") or pp._is_link_or_reparse(full):
                continue
            with open(full, "rb") as f:
                out[prefix + pp.rel_of(base, full)] = f.read()
    return out


def export_zip(workspace, scope="dist", root=None):
    """Octets du zip : dist/ + MISE-EN-LIGNE.md (+ src/ et site.json si scope=source). SiteError si rien n'est construit ou si c'est trop gros."""
    p = site_paths(workspace)
    if not os.path.isdir(p["dist"]):
        raise SiteError("BUILD_MISSING", "Le site n'est pas encore construit (site_build).")
    site = load_site(workspace)
    entries = _dir_entries(p["dist"], "site/")
    entries["MISE-EN-LIGNE.md"] = publish_guide(site, workspace, root).encode("utf-8")
    if scope == "source":
        entries.update(_dir_entries(p["src"], "source/src/"))
        with open(p["json"], "rb") as f:
            entries["source/site.json"] = f.read()
    if sum(len(v) for v in entries.values()) > ZIP_MAX_BYTES:
        raise SiteError("TOO_LARGE", "Export trop volumineux (25 Mo au plus).")
    data = _zip_bytes(entries)
    if len(data) > ZIP_MAX_BYTES:
        raise SiteError("TOO_LARGE", "Export trop volumineux (25 Mo au plus).")
    return data


HOST_GUIDES = {
    "infomaniak": ("Infomaniak (hébergement Web)", "Manager Infomaniak › Hébergement › Gestionnaire de fichiers (ou FTP/SFTP) : déposez le CONTENU du dossier `site/` dans le dossier `web/` du site.",
                   "Le certificat SSL Let's Encrypt s'active dans Manager › Hébergement › votre site › Certificats SSL."),
    "hostpoint": ("Hostpoint", "Hostpoint Control Panel › Sites web › FTP : déposez le CONTENU du dossier `site/` dans le dossier `www/` (ou le dossier du domaine).",
                  "Le certificat SSL gratuit s'active dans Control Panel › Sites web › SSL."),
    "ovh": ("OVHcloud (hébergement Web)", "Espace client OVHcloud › Hébergements › FTP-SSH : déposez le CONTENU du dossier `site/` dans le dossier `www/`.",
            "Le certificat SSL s'active dans l'onglet « Informations générales » de l'hébergement."),
    "netlify": ("Netlify", "app.netlify.com › Add new site › Deploy manually : glissez-déposez le dossier `site/` entier dans la zone prévue.",
                "Netlify fournit le certificat HTTPS automatiquement une fois le domaine vérifié."),
    "cloudflare-pages": ("Cloudflare Pages", "dash.cloudflare.com › Workers & Pages › Create › Pages › Upload assets : déposez le dossier `site/`.",
                         "Cloudflare fournit le certificat HTTPS automatiquement."),
    "github-pages": ("GitHub Pages", "Créez un dépôt, déposez le CONTENU du dossier `site/` à la racine, puis Settings › Pages › Deploy from a branch (main, /root).",
                     "Cochez « Enforce HTTPS » dans Settings › Pages une fois le domaine vérifié."),
}


def publish_guide(site, workspace=None, root=None):
    """MISE-EN-LIGNE.md : guide de mise en ligne manuelle pour l'hébergeur indiqué par le client. Aucun enregistrement DNS n'est inventé :
    sans domaine fourni, ils restent à compléter ; les valeurs exactes viennent de l'hébergeur."""
    hosting = site.get("hosting") or {}
    host_key = str(hosting.get("host") or "").strip().lower().replace(" ", "-")
    domain = str(hosting.get("domain") or "").strip().lower()
    if not re.match(r"^[a-z0-9.-]{3,100}\.[a-z]{2,24}\Z", domain or ""):
        domain = ""
    if not domain and site.get("baseUrl"):
        domain = re.sub(r"^https?://", "", site["baseUrl"]).split("/")[0]
    label, upload, tls = HOST_GUIDES.get(host_key, ("votre hébergeur", "Déposez le CONTENU du dossier `site/` à la racine publique de votre hébergement (souvent `www/`, `web/`, `public_html/` ou `htdocs/`), par le gestionnaire de fichiers ou par SFTP.",
                                                    "Activez le certificat HTTPS (souvent gratuit, Let's Encrypt) dans l'interface de l'hébergeur."))
    needs = [str(x) for x in (site.get("needsFromClient") or []) if isinstance(x, str)]
    pending = []
    if workspace:
        try:
            p = site_paths(workspace)
            ph = re.compile(r"\[À COMPLÉTER\s*:\s*([^\]]{1,200})\]")
            for dirpath, _d, filenames in os.walk(p["dist"], followlinks=False):
                for fn in sorted(filenames):
                    if fn.endswith(".html"):
                        for m in ph.finditer(_read(os.path.join(dirpath, fn))):
                            pending.append(m.group(1).strip())
        except (SiteError, OSError, pp.PathError):
            pass
    pending = sorted(set(pending))
    dom = domain or "[À COMPLÉTER : votre nom de domaine]"
    lines = [f"# Mettre en ligne le site « {site['name']} »", "",
             "Ce dossier contient un site statique complet (HTML, CSS, images) : aucun serveur d'application, aucune base de données, aucun cookie, aucun outil de mesure d'audience. "
             "Rien n'a été publié : c'est vous qui le mettez en ligne, quand tout est relu.", "",
             "## 1. Avant la mise en ligne (à cocher)", ""]
    for item in pending or []:
        lines.append(f"- [ ] Renseigner : {item}")
    for item in needs:
        if item not in pending:
            lines.append(f"- [ ] Fournir : {item}")
    lines += ["- [ ] Relire chaque page (textes, prix, horaires, coordonnées) dans l'aperçu privé.",
              "- [ ] Faire relire les mentions légales et la politique de confidentialité (nLPD / RGPD) par un juriste ou par Clara.",
              "- [ ] Vérifier que chaque affirmation (diplômes, labels, chiffres) est exacte et prouvable : le site n'en contient aucune qui n'ait été fournie par vous.",
              "- [ ] Si l'adresse définitive du site change, la mettre dans site.json (baseUrl) et reconstruire : les liens canoniques, le plan du site et les aperçus de partage l'utilisent.", "",
              f"## 2. Déposer les fichiers ({label})", "", upload, "",
              "Le fichier `404.html` sert de page « introuvable » : la plupart des hébergeurs l'utilisent automatiquement ; sinon, indiquez-le comme page d'erreur 404 dans leur interface.", "",
              "## 3. Nom de domaine et DNS", ""]
    if domain:
        lines += [f"Domaine : **{domain}**. Dans l'interface de votre registraire (là où le domaine a été acheté), faites pointer le domaine vers l'hébergement :", "",
                  "| Type | Nom | Valeur |", "|---|---|---|",
                  f"| A | {domain}. | adresse IP indiquée par {label} [À COMPLÉTER : IP fournie par l'hébergeur] |",
                  f"| CNAME | www.{domain}. | {domain}. (ou la cible indiquée par {label}) |", "",
                  "Les valeurs exactes viennent TOUJOURS de l'hébergeur (page « Domaines » ou « DNS ») : ne copiez pas une valeur trouvée ailleurs. La propagation prend de quelques minutes à 48 heures."]
    else:
        lines += [f"Domaine : {dom}. Une fois le domaine choisi, l'hébergeur indique les enregistrements DNS exacts (en général un `A` pour le domaine et un `CNAME` pour `www`). "
                  "Aucune valeur n'est inventée ici."]
    lines += ["", "## 4. Certificat HTTPS", "", tls, "",
              "## 5. Après la mise en ligne", "",
              f"- Ouvrir https://{domain or 'votre-domaine'}/ sur ordinateur et téléphone, tester chaque lien et le bouton de contact.",
              f"- Déclarer le site dans Google Search Console et soumettre `https://{domain or 'votre-domaine'}/sitemap.xml` ; Seoya peut ensuite suivre l'indexation.",
              "- Garder une copie de ce zip : il permet de remettre le site en ligne à l'identique.", "",
              "## WordPress, Webflow, Shopify, WooCommerce", "",
              "- **WordPress** : si votre WordPress est connecté à BK-AI-WORKERS, chaque page peut être déposée comme **brouillon de page** après votre validation (rien n'est publié : vous publiez vous-même dans WordPress). "
              "Ajoutez le contenu de `site/assets/style.css` dans Apparence › Personnaliser › CSS additionnel. Les images (fichiers .png/.webp) se téléversent à la main dans Médias ; les illustrations SVG du kit sont intégrées dans le texte des pages.",
              "- **Webflow** : l'API disponible ne permet pas de créer des pages statiques ; recréez les pages dans le Designer à partir de l'aperçu, ou importez le contenu à la main.",
              "- **Shopify / WooCommerce** : ce sont des boutiques ; un site de présentation statique ne s'y dépose pas. Gardez la boutique et liez-la depuis le site.", ""]
    return "\n".join(lines)


def package(workspace, root=None):
    """deliverables/site-<slug>.zip + deliverables/MISE-EN-LIGNE.md (écrits par le chemin sûr). Renvoie les chemins et tailles."""
    site = load_site(workspace)
    data = export_zip(workspace, "dist", root)
    zrel = f"deliverables/site-{site['slug']}.zip"
    grel = "deliverables/MISE-EN-LIGNE.md"
    _write(pp.resolve(workspace, zrel, kind="file"), data)
    guide = publish_guide(site, workspace, root)
    _write(pp.resolve(workspace, grel, kind="file"), guide)
    return {"zip": zrel, "zipBytes": len(data), "guide": grel, "guideBytes": len(guide.encode("utf-8")),
            "zipSha256": hashlib.sha256(data).hexdigest()}


# ------------------------------------------------------------------ préparation de la publication WordPress (brouillons de pages)
WP_CONTENT_MAX = 7000        # les paramètres d'un article d'approbation sont plafonnés à 8 Ko : au-delà, action manuelle guidée


def wordpress_pages(workspace, languages=None, root=None):
    """Pages prêtes à devenir des BROUILLONS WordPress : titre, slug, contenu de <main> avec liens « /slug/ » (permaliens WordPress).
    Renvoie [{key, lang, slug, title, content, bytes, fits}] ; fits=False si le contenu dépasse le plafond d'un article d'approbation."""
    site, _files, rows, _w = render_site(workspace, root, relative=False)
    langs = [l for l in (languages or [site["defaultLanguage"]]) if l in site["languages"]]
    by_key = {pg["key"]: pg for pg in site["pages"]}
    out = []
    for r in rows:
        if r["lang"] not in langs:
            continue
        content = re.sub(r"\n\s+", "\n", r["main"] or "").strip()
        content = re.sub(r"<!--(?!\s*wp:).*?-->", "", content, flags=re.DOTALL)
        slug = ((by_key.get(r["key"]) or {}).get("slug") or {}).get(r["lang"]) or r["key"]
        title = ((by_key.get(r["key"]) or {}).get("title") or {}).get(r["lang"]) or r["title"]
        block = "<!-- wp:html -->\n" + content + "\n<!-- /wp:html -->"
        n = len(block.encode("utf-8"))
        out.append({"key": r["key"], "lang": r["lang"], "slug": "accueil" if slug == "index" and r["lang"] == "fr" else ("home" if slug == "index" else slug),
                    "title": title, "content": block, "bytes": n, "fits": n <= WP_CONTENT_MAX})
    return out


# ------------------------------------------------------------------ type de contrôle « site_check » (moteur)
def _site_check(ctx, check, res):
    import site_checks
    site_checks.run_checks(ctx.workspace, check, res)


def register_checks():
    try:
        import project_checks
    except ImportError:  # pragma: no cover
        return False
    project_checks.register_check("site_check", _site_check)
    return True


register_checks()
