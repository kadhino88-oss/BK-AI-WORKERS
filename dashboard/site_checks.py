# -*- coding: utf-8 -*-
"""Contrôles automatiques d'un site (docs/AUTONOMY-ENGINE.md, section 8.4). Hors ligne, bibliothèque standard, sans modèle, jamais de requête sortante
(les liens externes sont listés, jamais suivis). Chaque règle a un identifiant, une gravité (error bloque DONE ; warn est signalé ; info informe)
et des seuils réglables dans core/projects/site/site-checks.json.

Entrée : le dossier `site/dist/` produit par site_build (et `site/site.json`, `site/build.json`). Sortie : des constats dans un accumulateur
`project_checks.Res` ; le moteur en fait le résultat CHK-xxxxxxxx.
"""
import json
import os
import posixpath
import re
import time
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urldefrag, urlsplit

import project_paths as pp
import site_css as css
import site_html as H

ROOT = os.environ.get("BK_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_REL = ("core", "projects", "site", "site-checks.json")
MAX_PER_RULE_FILE = 3
SEV_ORDER = {"error": 0, "warn": 1, "info": 2}
FR_WORDS = frozenset("le la les des une un du de pour avec nous vous votre vos notre nos est sont dans sur par au aux et ou qui que ce cette ces plus pas ne".split())
EN_WORDS = frozenset("the of and to in is are for with our your you we on by at this that these from or not as be it its".split())
_CONFIG_CACHE = {}


# ------------------------------------------------------------------ configuration
def load_config(root=None):
    root = root or ROOT
    path = os.path.join(root, *CONFIG_REL)
    try:
        mt = os.path.getmtime(path)
    except OSError:
        mt = 0
    hit = _CONFIG_CACHE.get(root)
    if hit and hit[0] == mt:
        return hit[1]
    try:
        with open(path, encoding="utf-8-sig") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        cfg = {"default": {}, "profiles": {}, "families": [], "alwaysRun": []}
    _CONFIG_CACHE[root] = (mt, cfg)
    return cfg


def profile_config(cfg, profile):
    base = json.loads(json.dumps(cfg.get("default") or {}))
    over = (cfg.get("profiles") or {}).get(profile if profile in (cfg.get("profiles") or {}) else "vitrine") or {}
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            base[k].update(v)
        else:
            base[k] = v
    return base


# ------------------------------------------------------------------ modèle du site chargé depuis le disque
class Page:
    def __init__(self, rel, full, text):
        self.rel = rel                       # « en/care/index.html » (relatif à dist/)
        self.full = full
        self.text = text
        self.bytes = len(text.encode("utf-8", "replace"))
        self.doc = H.parse(text)
        self.url = "/" + rel[:-len("index.html")] if rel.endswith("index.html") else "/" + rel
        self.is_404 = rel == "404.html"
        robots = (H.meta_content(self.doc, "robots") or "").lower()
        self.noindex = "noindex" in robots
        html = self.doc.first("html")
        self.lang = (html.get("lang") if html else None) or ""


class SiteModel:
    def __init__(self, workspace, site_rel="site", root=None):
        self.workspace = workspace
        self.site_dir = os.path.join(workspace, *site_rel.split("/"))
        self.dist = os.path.join(self.site_dir, "dist")
        self.root = root or ROOT
        self.site = None
        self.site_error = None
        self.build = None
        self.pages = []
        self.files = {}          # rel -> taille (tous les fichiers de dist)
        self.texts = {}          # rel -> texte (css, js, xml, txt, svg, json)
        self.page_by_url = {}
        self.total_bytes = 0
        self.dist_exists = os.path.isdir(self.dist)
        self._load()

    def _load(self):
        sj = os.path.join(self.site_dir, "site.json")
        try:
            with open(sj, encoding="utf-8-sig") as f:
                self.site = json.load(f)
            if not isinstance(self.site, dict):
                self.site, self.site_error = None, "site.json n'est pas un objet JSON."
        except OSError:
            self.site_error = "site/site.json est absent : lancez site_scaffold."
        except ValueError as e:
            self.site_error = f"site/site.json n'est pas un JSON valide ({e})."
        try:
            with open(os.path.join(self.site_dir, "build.json"), encoding="utf-8-sig") as f:
                self.build = json.load(f)
        except (OSError, ValueError):
            self.build = None
        if not self.dist_exists:
            return
        for dirpath, dirnames, filenames in os.walk(self.dist, followlinks=False):
            dirnames[:] = sorted(d for d in dirnames if not pp._is_link_or_reparse(os.path.join(dirpath, d)))
            for fn in sorted(filenames):
                full = os.path.join(dirpath, fn)
                if pp._is_link_or_reparse(full):
                    continue
                rel = pp.rel_of(self.dist, full)
                try:
                    size = os.path.getsize(full)
                except OSError:
                    continue
                self.files[rel] = size
                self.total_bytes += size
                ext = pp.ext_of(rel)
                if ext in ("html", "htm") and len(self.pages) < 400:
                    text = _read_text(full)
                    self.pages.append(Page(rel, full, text))
                elif ext in ("css", "js", "mjs", "xml", "txt", "svg", "json", "webmanifest") and size <= 2 * 1024 * 1024:
                    self.texts[rel] = _read_text(full)
        self.pages.sort(key=lambda p: p.rel)
        for p in self.pages:
            self.page_by_url[p.url] = p

    @property
    def languages(self):
        langs = (self.site or {}).get("languages")
        return [l for l in langs if isinstance(l, str)] if isinstance(langs, list) and langs else []

    @property
    def default_language(self):
        d = (self.site or {}).get("defaultLanguage")
        return d if isinstance(d, str) and d else (self.languages[0] if self.languages else "fr")

    @property
    def base_url(self):
        b = (self.site or {}).get("baseUrl")
        return b.strip().rstrip("/") if isinstance(b, str) and b.strip().startswith(("http://", "https://")) else ""

    def expected_lang(self, page):
        first = page.rel.split("/", 1)[0]
        if "/" in page.rel and first in self.languages and first != self.default_language:
            return first
        return self.default_language

    def resolve(self, page, href):
        """Chemin de fichier de dist (relatif) visé par `href` depuis `page`, ou None s'il n'existe pas. href interne seulement."""
        h = urldefrag(href.strip())[0]
        h = h.split("?", 1)[0]
        if not h:
            return page.rel
        h = unquote(h)
        if h.startswith("/"):
            target = h
        else:
            target = posixpath.normpath(posixpath.join(posixpath.dirname("/" + page.rel), h))
            if h.endswith("/") and not target.endswith("/"):
                target += "/"
        target = posixpath.normpath(target) + ("/" if target.endswith("/") and target != "/" else "")
        if target.startswith("/.."):
            return None
        rel = target.lstrip("/")
        if rel == "" or rel.endswith("/"):
            rel += "index.html"
        if rel in self.files:
            return rel
        if rel + "/index.html" in self.files:
            return rel + "/index.html"
        return None


def _read_text(full):
    try:
        with open(full, "rb") as f:
            raw = f.read(2 * 1024 * 1024 + 1)
    except OSError:
        return ""
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


# ------------------------------------------------------------------ accumulateur de constats
class Reporter:
    """Enveloppe de project_checks.Res : plafonne les répétitions (3 constats par règle et par fichier, puis « … N autres ») et calcule le score."""

    def __init__(self, res):
        self.res = res
        self.counts = {}
        self.extra = {}

    def ok(self, n=1):
        for _ in range(n):
            self.res.ok()

    def fail(self, rule, detail, file=None, severity="error"):
        key = (rule, file, severity)
        c = self.counts.get(key, 0) + 1
        self.counts[key] = c
        if c > MAX_PER_RULE_FILE:
            self.extra[key] = c - MAX_PER_RULE_FILE
            self.res.total += 1
            if severity != "error":
                self.res.passed += 1
            return
        self.res.fail(rule, detail, file=file, severity=severity)

    def info(self, rule, detail, file=None):
        self.res.info(rule, detail, file=file)

    def finish(self):
        for (rule, file, severity), n in self.extra.items():
            self.res.findings.append({"rule": rule, "severity": severity, "file": file, "detail": f"… et {n} autre(s) constat(s) du même type."})
        self.res.findings.sort(key=lambda f: SEV_ORDER.get(f["severity"], 3))


# ------------------------------------------------------------------ outils communs
def _want(rule, families, always):
    return rule in always or rule.split(".", 1)[0] in families


def _sev(value, default="warn"):
    return value if value in ("error", "warn", "info") else (None if value == "off" else default)


def _indexable(p):
    return not p.is_404 and not p.noindex


def _page_js(m, page):
    """Textes JavaScript visibles par une page : scripts en ligne (hors données) + fichiers locaux référencés."""
    chunks = []
    for s in page.doc.by_tag("script"):
        typ = (s.get("type") or "").lower()
        if typ in H._SCRIPT_TYPES_DATA:
            continue
        if s.get("src"):
            if not H.is_external(s.get("src")):
                rel = m.resolve(page, s.get("src"))
                if rel and rel in m.texts:
                    chunks.append((rel, m.texts[rel]))
        elif s.raw.strip():
            chunks.append((page.rel + " (script en ligne)", s.raw))
    return chunks


def _own_js(m):
    return {rel: t for rel, t in m.texts.items() if rel.endswith((".js", ".mjs"))}


def _own_css(m):
    return {rel: t for rel, t in m.texts.items() if rel.endswith(".css")}


def _all_css_text(m):
    parts = list(_own_css(m).values())
    for p in m.pages:
        for s in p.doc.by_tag("style"):
            parts.append(s.raw)
    return "\n".join(parts)


def _placeholder_domain(cfg):
    return cfg.get("placeholderDomain") or "votre-domaine.example"


# ------------------------------------------------------------------ html
def rule_html(m, rp, pc, want):
    for p in m.pages:
        d = p.doc
        if want("html.parse"):
            if d.errors:
                for line, msg in d.errors[:6]:
                    rp.fail("html.parse", f"ligne {line} : {msg}", file=p.rel)
            else:
                rp.ok()
        if want("html.doctype"):
            if d.doctype and d.doctype.lower().replace(" ", "") == "doctypehtml" and d.doctype_first:
                rp.ok()
            else:
                rp.fail("html.doctype", "<!doctype html> absent, mal écrit ou pas en première ligne.", file=p.rel)
        html = d.first("html")
        if want("html.lang"):
            lang = html.get("lang") if html else None
            if lang and re.match(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*\Z", lang):
                rp.ok()
            else:
                rp.fail("html.lang", "Attribut lang absent ou invalide sur <html> (ex. lang=\"fr\").", file=p.rel)
        if want("html.charset"):
            cs = None
            for e in d.by_tag("meta"):
                if e.has("charset"):
                    cs = e.get("charset")
                elif (e.get("http-equiv") or "").lower() == "content-type" and "charset=" in (e.get("content") or "").lower():
                    cs = (e.get("content") or "").lower().split("charset=")[-1]
            if cs and cs.strip().lower() in ("utf-8", "utf8"):
                rp.ok()
            else:
                rp.fail("html.charset", "<meta charset=\"utf-8\"> absent (ou autre que UTF-8).", file=p.rel)
        if want("html.viewport"):
            vp = H.meta_content(d, "viewport")
            if vp and "width=device-width" in vp.replace(" ", "").lower():
                low = vp.replace(" ", "").lower()
                if "user-scalable=no" in low or "maximum-scale=1" in low:
                    rp.fail("html.viewport", "Le zoom est interdit (user-scalable=no / maximum-scale=1) : c'est un défaut d'accessibilité.", file=p.rel, severity="warn")
                else:
                    rp.ok()
            else:
                rp.fail("html.viewport", "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"> absent : la page ne s'adapte pas au mobile.", file=p.rel)


# ------------------------------------------------------------------ meta
def _len_check(rp, rule, label, value, bounds, file):
    n = len(value)
    mn, mx, hmn, hmx = bounds["min"], bounds["max"], bounds["hardMin"], bounds["hardMax"]
    if n < hmn or n > hmx:
        rp.fail(rule, f"{label} de {n} caractères : hors de la plage tolérée ({hmn} à {hmx} ; idéal {mn} à {mx}).", file=file)
    elif n < mn or n > mx:
        rp.fail(rule, f"{label} de {n} caractères : idéal {mn} à {mx}.", file=file, severity="warn")
    else:
        rp.ok()


def rule_meta(m, rp, pc, want, cfg):
    seen_titles = {}
    seen_desc = {}
    base = m.base_url
    for p in m.pages:
        d = p.doc
        title = d.first("title")
        ttext = title.inner_text() if title else ""
        if want("meta.title"):
            if not ttext:
                rp.fail("meta.title", "<title> absent ou vide.", file=p.rel)
            else:
                _len_check(rp, "meta.title", "Titre", ttext, pc["title"], p.rel)
        desc = H.meta_content(d, "description")
        if want("meta.description"):
            if not desc or not desc.strip():
                rp.fail("meta.description", "<meta name=\"description\"> absente ou vide.", file=p.rel)
            else:
                _len_check(rp, "meta.description", "Description", desc.strip(), pc["description"], p.rel)
        if _indexable(p):
            if ttext:
                seen_titles.setdefault(ttext.strip().lower(), []).append(p.rel)
            if desc and desc.strip():
                seen_desc.setdefault(desc.strip().lower(), []).append(p.rel)
        rels = H.link_rels(d)
        if want("meta.canonical") and _indexable(p):
            can = [href for rel, href, _e in rels if "canonical" in rel]
            sev = "error" if pc.get("requireCanonical", True) else "warn"
            if not can:
                rp.fail("meta.canonical", "<link rel=\"canonical\"> absent.", file=p.rel, severity=sev)
            elif not can[0] or not re.match(r"^https?://", can[0]):
                rp.fail("meta.canonical", f"canonical doit être une adresse absolue (https://…), trouvé « {str(can[0])[:80]} ».", file=p.rel, severity=sev)
            elif base and can[0].rstrip("/") != (base + p.url).rstrip("/"):
                rp.fail("meta.canonical", f"canonical « {can[0][:90]} » ne correspond pas à l'adresse attendue « {base + p.url} ».", file=p.rel, severity="warn")
            else:
                rp.ok()
        if want("meta.og") and _indexable(p):
            need = ["og:title", "og:description", "og:type", "og:url", "og:image"]
            have = {(e.get("property") or "").lower() for e in d.by_tag("meta") if e.has("content") and e.get("content").strip()}
            missing = [k for k in need if k not in have]
            if missing:
                rp.fail("meta.og", "Balises Open Graph manquantes : " + ", ".join(missing) + ".", file=p.rel)
            else:
                rp.ok()
        if want("meta.twitter") and _indexable(p):
            have = {(e.get("name") or "").lower() for e in d.by_tag("meta") if e.has("content")}
            if "twitter:card" in have:
                rp.ok()
            else:
                rp.fail("meta.twitter", "<meta name=\"twitter:card\"> absente.", file=p.rel)
        if want("meta.favicon"):
            if any(("icon" in rel) for rel, _h, _e in rels):
                rp.ok()
            else:
                rp.fail("meta.favicon", "Aucune icône de site (<link rel=\"icon\">).", file=p.rel, severity="warn")
    if want("seo.titles_unique"):
        dup = False
        for t, files in seen_titles.items():
            if len(files) > 1:
                dup = True
                rp.fail("seo.titles_unique", f"Titre identique sur {len(files)} pages : {', '.join(files[:4])} (« {t[:60]} »).", file=files[1])
        if seen_titles and not dup:
            rp.ok()
    if want("meta.description"):
        for t, files in seen_desc.items():
            if len(files) > 1:
                rp.fail("meta.description", f"Description identique sur {len(files)} pages : {', '.join(files[:4])}.", file=files[1], severity="warn")


# ------------------------------------------------------------------ liens
_CONTACT_MAIL = re.compile(r"^[^@\s,;<>]+@[^@\s,;<>]+\.[A-Za-z]{2,}\Z")
_CONTACT_TEL = re.compile(r"^\+?[0-9][0-9\s().\-]{5,}\Z")


def rule_links(m, rp, pc, want):
    anchors_cache = {}

    def anchors_of(page):
        if page.rel not in anchors_cache:
            a = set(page.doc.ids)
            for e in page.doc.by_tag("a"):
                if e.get("name"):
                    a.add(e.get("name"))
            anchors_cache[page.rel] = a
        return anchors_cache[page.rel]

    by_rel = {p.rel: p for p in m.pages}
    external_hosts = {}
    for p in m.pages:
        for url, el, attr, kind in H.resource_refs(p.doc):
            u = (url or "").strip()
            low = u.lower()
            if kind == "form":
                continue
            if low.startswith("mailto:"):
                if want("links.contact"):
                    addrs = [a for a in unquote(u[7:].split("?", 1)[0]).split(",") if a.strip()]
                    if addrs and all(_CONTACT_MAIL.match(a.strip()) for a in addrs):
                        rp.ok()
                    else:
                        rp.fail("links.contact", f"Lien mailto mal formé : « {u[:80]} ».", file=p.rel)
                continue
            if low.startswith("tel:"):
                if want("links.contact"):
                    if _CONTACT_TEL.match(unquote(u[4:]).strip()):
                        rp.ok()
                    else:
                        rp.fail("links.contact", f"Lien tel mal formé : « {u[:60]} » (attendu : tel:+41791234567).", file=p.rel)
                continue
            if low.startswith(("sms:", "data:", "blob:")):
                continue
            if low.startswith("javascript:"):
                if want("links.internal"):
                    rp.fail("links.internal", f"Lien « javascript: » à la ligne {el.line} : interdit (bloqué par la politique de sécurité de l'aperçu).", file=p.rel)
                continue
            if H.is_external(u):
                if kind == "a" and want("links.external"):
                    host = H.host_of(u) or "?"
                    external_hosts.setdefault(host, set()).add(p.rel)
                    if (el.get("target") or "").lower() == "_blank":
                        rel_attr = set((el.get("rel") or "").lower().split())
                        if not ({"noopener", "noreferrer"} <= rel_attr or "noreferrer" in rel_attr):
                            rp.fail("links.external", f"Lien externe « {host} » en target=_blank sans rel=\"noopener noreferrer\" (ligne {el.line}).", file=p.rel, severity="warn")
                    if low.startswith("http://"):
                        rp.fail("links.external", f"Lien externe non sécurisé (http://) vers {host} (ligne {el.line}).", file=p.rel, severity="warn")
                continue
            if not u:
                if kind == "a" and want("links.internal"):
                    rp.fail("links.internal", f"Lien vide (href=\"\") ligne {el.line}.", file=p.rel, severity="warn")
                continue
            if not want("links.internal") and not want("links.anchor"):
                continue
            frag = urldefrag(u)[1]
            target_rel = m.resolve(p, u)
            if target_rel is None:
                if want("links.internal"):
                    rp.fail("links.internal", f"Lien interne introuvable : « {u[:90]} » (ligne {el.line}).", file=p.rel)
                continue
            if want("links.internal"):
                rp.ok()
            if frag and want("links.anchor") and kind == "a" and frag.lower() != "top":
                tp = by_rel.get(target_rel)
                if tp is not None:
                    if unquote(frag) in anchors_of(tp):
                        rp.ok()
                    else:
                        rp.fail("links.anchor", f"Ancre « #{frag[:40]} » introuvable dans {target_rel} (lien ligne {el.line}).", file=p.rel)
    if want("links.external") and external_hosts:
        hosts = sorted(external_hosts)
        rp.info("links.external", f"{len(hosts)} site(s) externe(s) cité(s), non suivis par le contrôle : " + ", ".join(hosts[:10]) + (" …" if len(hosts) > 10 else ""))


# ------------------------------------------------------------------ images
def rule_img(m, rp, pc, want):
    max_kb = pc["perf"]["imgKb"]
    for p in m.pages:
        imgs = p.doc.by_tag("img")
        for i, img in enumerate(imgs):
            if want("img.alt"):
                if not img.has("alt"):
                    rp.fail("img.alt", f"<img src=\"{(img.get('src') or '')[:60]}\"> sans attribut alt (ligne {img.line}) ; alt=\"\" si l'image est décorative.", file=p.rel)
                else:
                    alt = img.get("alt") or ""
                    if re.search(r"\.(png|jpe?g|webp|gif|svg)\b|^(image|img|photo|picture)[\s_-]*\d*$", alt.strip(), re.I):
                        rp.fail("img.alt", f"alt « {alt[:50]} » ressemble à un nom de fichier (ligne {img.line}).", file=p.rel, severity="warn")
                    else:
                        rp.ok()
            if want("img.dims") and not img.get("src", "").startswith("data:"):
                if img.get("width") and img.get("height"):
                    rp.ok()
                else:
                    rp.fail("img.dims", f"<img> sans width et height (ligne {img.line}) : la page « saute » au chargement.", file=p.rel, severity="warn")
            sev = _sev(pc.get("requireLazy"), "warn")
            if want("img.lazy") and sev and i > 0:
                if (img.get("loading") or "").lower() == "lazy":
                    rp.ok()
                else:
                    rp.fail("img.lazy", f"<img> sans loading=\"lazy\" (ligne {img.line}).", file=p.rel, severity=sev)
    if want("img.size"):
        for rel, size in sorted(m.files.items()):
            if pp.ext_of(rel) in ("png", "jpg", "jpeg", "webp", "gif", "svg", "ico"):
                if size > max_kb * 1024:
                    rp.fail("img.size", f"Image de {size // 1024} Ko (maximum {max_kb} Ko) : compressez-la (WebP, dimensions réduites).", file=rel)
                else:
                    rp.ok()


# ------------------------------------------------------------------ accessibilité
_GENERIC_LINK = re.compile(r"^(cliquez ici|cliquer ici|ici|en savoir plus|lire la suite|lire plus|plus|voir plus|click here|here|read more|more|learn more|lien|link)\Z", re.I)
_INPUT_NO_LABEL = ("hidden", "submit", "button", "reset", "image")


def _has_name(el):
    if el.get("aria-label") or el.get("aria-labelledby") or el.get("title"):
        return True
    if el.inner_text().strip():
        return True
    for d in el.descendants():
        if d.tag == "img" and (d.get("alt") or "").strip():
            return True
        if d.tag in ("svg",) and (d.get("aria-label") or any(x.tag == "title" for x in d.descendants())):
            return True
        if d.get("aria-label"):
            return True
    return False


def rule_a11y_html(m, rp, pc, want):
    skip_sev = _sev(pc.get("requireSkipLink"), "warn")
    for p in m.pages:
        d = p.doc
        heads = [e for e in d.elements if e.tag in ("h1", "h2", "h3", "h4", "h5", "h6")]
        if want("a11y.h1"):
            h1s = [e for e in heads if e.tag == "h1"]
            if len(h1s) == 1:
                rp.ok()
            elif not h1s:
                rp.fail("a11y.h1", "Aucun <h1> : chaque page a un titre principal.", file=p.rel)
            else:
                rp.fail("a11y.h1", f"{len(h1s)} balises <h1> : une seule par page.", file=p.rel)
        if want("a11y.heading_order") and heads:
            prev, bad = 0, None
            for e in heads:
                lvl = int(e.tag[1])
                if prev and lvl > prev + 1:
                    bad = (e, prev)
                    break
                prev = lvl
            if bad:
                rp.fail("a11y.heading_order", f"Niveau de titre sauté : <{bad[0].tag}> après <h{bad[1]}> (ligne {bad[0].line}).", file=p.rel, severity="warn")
            else:
                rp.ok()
        if want("a11y.landmarks"):
            def has_lm(tag, role):
                return any(e.tag == tag or (e.get("role") or "").lower() == role for e in d.elements)

            mains = [e for e in d.elements if e.tag == "main" or (e.get("role") or "").lower() == "main"]
            if len(mains) != 1:
                rp.fail("a11y.landmarks", f"{len(mains)} zone(s) <main> (une seule attendue).", file=p.rel)
            else:
                rp.ok()
            for tag, role, label in (("header", "banner", "<header>"), ("nav", "navigation", "<nav>"), ("footer", "contentinfo", "<footer>")):
                if not has_lm(tag, role):
                    rp.fail("a11y.landmarks", f"Zone {label} absente.", file=p.rel, severity="warn")
        if want("a11y.form_labels"):
            label_for = {l.get("for") for l in d.by_tag("label") if l.get("for")}
            for inp in d.by_tag("input", "select", "textarea"):
                if inp.tag == "input" and (inp.get("type") or "text").lower() in _INPUT_NO_LABEL:
                    continue
                named = (inp.get("id") and inp.get("id") in label_for) or inp.get("aria-label") or inp.get("aria-labelledby") or inp.get("title") \
                    or any(a.tag == "label" for a in inp.ancestors())
                if named:
                    rp.ok()
                else:
                    rp.fail("a11y.form_labels", f"Champ <{inp.tag}> sans étiquette (ligne {inp.line}) : ajoutez un <label for=…>.", file=p.rel)
        if want("a11y.link_text"):
            for a in d.by_tag("a"):
                if not a.has("href"):
                    continue
                txt = a.inner_text().strip()
                if not _has_name(a):
                    rp.fail("a11y.link_text", f"Lien sans texte ni nom accessible (ligne {a.line}).", file=p.rel)
                elif _GENERIC_LINK.match(txt) and not a.get("aria-label") and not a.get("title"):
                    rp.fail("a11y.link_text", f"Texte de lien peu explicite « {txt[:30]} » (ligne {a.line}).", file=p.rel, severity="warn")
                else:
                    rp.ok()
        if want("a11y.button_name"):
            for b in d.by_tag("button"):
                if _has_name(b):
                    rp.ok()
                else:
                    rp.fail("a11y.button_name", f"Bouton sans nom accessible (ligne {b.line}).", file=p.rel)
            for b in d.by_tag("input"):
                if (b.get("type") or "").lower() in ("button", "submit", "reset") and not (b.get("value") or b.get("aria-label") or b.get("title")) \
                        and (b.get("type") or "").lower() == "button":
                    rp.fail("a11y.button_name", f"<input type=\"button\"> sans value (ligne {b.line}).", file=p.rel)
        if want("a11y.skip_link") and skip_sev and not p.is_404:
            first = next((a for a in d.by_tag("a") if a.has("href")), None)
            hrefs = (first.get("href") or "") if first else ""
            if first and hrefs.startswith("#") and len(hrefs) > 1 and hrefs[1:] in d.ids:
                rp.ok()
            else:
                rp.fail("a11y.skip_link", "Pas de lien d'évitement « Aller au contenu » en premier dans la page.", file=p.rel, severity=skip_sev)


def rule_a11y_css(m, rp, pc, want):
    sheets = _own_css(m)
    inline = [s.raw for p in m.pages for s in p.doc.by_tag("style")]
    all_css = "\n".join(list(sheets.values()) + inline)
    if want("a11y.contrast"):
        found_any = False
        for rel, text in list(sheets.items()) + [("<style>", "\n".join(inline))]:
            if not text.strip():
                continue
            vmap = css.variables(text)
            if not vmap:
                continue
            light = dict(vmap.get("", {}))
            blocks = [("", light)]
            for ctx, v in vmap.items():
                if ctx and "dark" in ctx.lower():
                    merged = dict(light)
                    merged.update(v)
                    blocks.append((ctx, merged))
            for ctx, vs in blocks:
                pairs = []
                for fg, bg in (("--text", "--bg"), ("--on-primary", "--primary"), ("--on-accent", "--accent"), ("--muted", "--bg"), ("--text-muted", "--bg"),
                               ("--text", "--surface"), ("--muted", "--surface"), ("--link", "--bg"), ("--on-dark", "--dark"), ("--text", "--bg-alt"),
                               ("--primary", "--bg"), ("--text", "--bg-soft"), ("--text-muted", "--bg-soft"), ("--on-surface", "--surface")):
                    if fg in vs and bg in vs:
                        pairs.append((fg, bg))
                for fg, bg in pairs:
                    a, b = css.parse_color(vs[fg], vs), css.parse_color(vs[bg], vs)
                    if a is None or b is None:
                        continue
                    found_any = True
                    ratio = css.contrast(a, b)
                    where = f" (thème sombre)" if ctx else ""
                    if ratio + 1e-9 < pc["contrast"]["normal"]:
                        rp.fail("a11y.contrast", f"Contraste {ratio:.1f}:1 entre {fg} ({css.to_hex(a)}) et {bg} ({css.to_hex(b)}){where} : minimum {pc['contrast']['normal']}:1.", file=rel)
                    else:
                        rp.ok()
        if not found_any:
            rp.info("a11y.contrast", "Contraste non vérifiable automatiquement (variables --text/--bg, --on-primary/--primary absentes) : le contrôleur le lit à la main.")
    if want("a11y.focus"):
        bad = re.search(r"outline\s*:\s*(?:none|0)\b", all_css) is not None
        good = re.search(r":focus-visible[^{}]*\{[^{}]*(?:outline|box-shadow|border)", all_css) is not None or \
            re.search(r":focus[^{}]*\{[^{}]*(?:outline\s*:\s*(?!none|0)|box-shadow)", all_css) is not None
        if bad and not good:
            rp.fail("a11y.focus", "outline:none sans style de focus de remplacement (:focus-visible) : le clavier ne voit plus où il est.", file="assets/style.css")
        elif all_css.strip():
            rp.ok()
    sev = _sev(pc.get("requireReducedMotion"), "warn")
    if want("a11y.reduced_motion") and sev and all_css.strip():
        animated = re.search(r"\banimation\s*:|\banimation-name\s*:|\btransition\s*:|scroll-behavior\s*:\s*smooth", all_css) is not None
        if animated and not re.search(r"prefers-reduced-motion", all_css):
            rp.fail("a11y.reduced_motion", "Animations ou transitions sans @media (prefers-reduced-motion: reduce).", file="assets/style.css", severity=sev)
        else:
            rp.ok()


# ------------------------------------------------------------------ poids
def rule_perf(m, rp, pc, want):
    pf = pc["perf"]
    if want("perf.page_weight"):
        for p in m.pages:
            if p.bytes > pf["htmlKb"] * 1024:
                rp.fail("perf.page_weight", f"HTML de {p.bytes // 1024} Ko (maximum {pf['htmlKb']} Ko).", file=p.rel)
            else:
                rp.ok()
            total = p.bytes
            seen = set()
            for url, el, attr, kind in H.resource_refs(p.doc):
                if kind in ("a", "form", "meta") or H.is_external(url or ""):
                    continue
                rel = m.resolve(p, url or "") if url else None
                if rel and rel not in seen and rel != p.rel:
                    seen.add(rel)
                    total += m.files.get(rel, 0)
            if total > pf["pageKb"] * 1024:
                rp.fail("perf.page_weight", f"Page complète de {total // 1024} Ko avec ses ressources (maximum {pf['pageKb']} Ko).", file=p.rel)
            else:
                rp.ok()
        for rel, size in sorted(m.files.items()):
            ext = pp.ext_of(rel)
            if ext == "css" and size > pf["cssKb"] * 1024:
                rp.fail("perf.page_weight", f"Feuille de style de {size // 1024} Ko (maximum {pf['cssKb']} Ko).", file=rel)
            elif ext in ("js", "mjs") and size > pf["jsKb"] * 1024:
                rp.fail("perf.page_weight", f"Script de {size // 1024} Ko (maximum {pf['jsKb']} Ko).", file=rel)
    if want("perf.total"):
        if m.total_bytes > pf["totalMb"] * 1024 * 1024:
            rp.fail("perf.total", f"Le site pèse {m.total_bytes // (1024 * 1024)} Mo (maximum {pf['totalMb']} Mo).")
        else:
            rp.ok()


# ------------------------------------------------------------------ vie privée
def _allowed_hosts(m):
    hosts = (m.site or {}).get("allowedExternalHosts")
    return {h.lower() for h in hosts if isinstance(h, str)} if isinstance(hosts, list) else set()


def _host_matches(host, listed):
    host = (host or "").lower()
    for h in listed:
        h = h.lower()
        if host == h or host.endswith("." + h):
            return True
    return False


def _tracker_hit(text, cfg):
    low = text.lower()
    for h in cfg.get("trackerHosts") or []:
        if h in low:
            return h
    for pat in cfg.get("trackerPatterns") or []:
        if re.search(pat, text):
            return pat
    return None


def rule_privacy(m, rp, pc, want, cfg):
    allowed = _allowed_hosts(m)
    neutral = set(cfg.get("neutralHosts") or [])
    declared_storage = bool((m.site or {}).get("storageDeclared"))
    placeholder = _placeholder_domain(cfg)
    sources = []        # (fichier, texte à fouiller pour les traceurs)
    for p in m.pages:
        sources.append((p.rel, p.text))
    for rel, t in m.texts.items():
        if rel.endswith((".js", ".mjs", ".css", ".html", ".svg")):
            sources.append((rel, t))
    if want("privacy.trackers"):
        hit_any = False
        for rel, text in sources:
            if pp.ext_of(rel) == "css" and "url(" not in text:
                continue
            hit = _tracker_hit(text, cfg)
            if hit:
                hit_any = True
                rp.fail("privacy.trackers", f"Traceur ou statistique tiers détecté (« {hit[:40]} ») : interdit par défaut (vie privée, nLPD/RGPD).", file=rel)
        if not hit_any:
            rp.ok()
    if want("privacy.external"):
        ok_all = True
        for p in m.pages:
            for url, el, attr, kind in H.resource_refs(p.doc):
                if kind in ("a", "form") or not H.is_external(url or ""):
                    continue
                host = H.host_of(url)
                if kind == "meta" and host and placeholder in host:
                    continue
                if host and (_host_matches(host, allowed) or host in neutral):
                    continue
                ok_all = False
                if host and ("fonts.googleapis.com" in host or "fonts.gstatic.com" in host):
                    rp.fail("privacy.external", f"Google Fonts (ligne {el.line}) : refusé, la police part de chez Google. Hébergez un fichier .woff2 dans assets/fonts/ ou utilisez les polices du système.", file=p.rel)
                else:
                    rp.fail("privacy.external", f"Ressource externe chargée depuis « {host} » (ligne {el.line}) : le site doit être autonome (ajoutez l'hôte à allowedExternalHosts seulement si le client le demande).", file=p.rel)
        for rel, text in _own_css(m).items():
            for u in css.import_urls(text) + re.findall(r"url\(\s*['\"]?((?:https?:)?//[^'\")\s]+)", text, re.I):
                if H.is_external(u):
                    host = H.host_of(u)
                    if host and not (_host_matches(host, allowed) or host in neutral):
                        ok_all = False
                        rp.fail("privacy.external", f"Le CSS charge une ressource externe depuis « {host} ».", file=rel)
        for p in m.pages:
            for s in p.doc.by_tag("style"):
                for u in re.findall(r"url\(\s*['\"]?((?:https?:)?//[^'\")\s]+)", s.raw, re.I) + css.import_urls(s.raw):
                    host = H.host_of(u)
                    if host and not (_host_matches(host, allowed) or host in neutral):
                        ok_all = False
                        rp.fail("privacy.external", f"Le CSS en ligne charge une ressource externe depuis « {host} ».", file=p.rel)
        if ok_all:
            rp.ok()
    js_all = []
    for p in m.pages:
        js_all.extend(_page_js(m, p))
    seen_js = {r for r, _t in js_all}
    for rel, t in _own_js(m).items():
        if rel not in seen_js:
            js_all.append((rel, t))
    if want("privacy.storage"):
        bad = False
        for rel, text in js_all:
            for pat in cfg.get("storagePatterns") or []:
                if re.search(pat, text):
                    if not declared_storage:
                        bad = True
                        rp.fail("privacy.storage", f"Le script utilise un stockage navigateur (« {pat.replace(chr(92), '')[:30]} ») : cookies et stockage exigent un bandeau de consentement ; déclarez storageDeclared dans site.json seulement si le client le demande.", file=rel)
                    break
        if not bad:
            rp.ok()
    if want("privacy.network"):
        bad = False
        for rel, text in js_all:
            for pat in cfg.get("networkPatterns") or []:
                if re.search(pat, text):
                    bad = True
                    rp.fail("privacy.network", "Le script fait des appels réseau (fetch / XMLHttpRequest…) : inutile pour un site de présentation et bloqué dans l'aperçu.", file=rel, severity="warn")
                    break
            for pat in cfg.get("dynamicCodePatterns") or []:
                if re.search(pat, text):
                    bad = True
                    rp.fail("privacy.network", "Le script exécute du code construit à la volée (eval, new Function, document.write) : à supprimer.", file=rel)
                    break
        if not bad:
            rp.ok()
    if want("privacy.forms"):
        for p in m.pages:
            for f in p.doc.by_tag("form"):
                action = (f.get("action") or "").strip()
                if not action:
                    rp.fail("privacy.forms", f"Formulaire sans destination (ligne {f.line}) : prévoyez action=\"mailto:…\" et dites-le au visiteur.", file=p.rel, severity="warn")
                elif H.is_external(action):
                    rp.fail("privacy.forms", f"Le formulaire envoie ses données à « {H.host_of(action)} » (ligne {f.line}) : à déclarer dans la politique de confidentialité.", file=p.rel, severity="warn")
                else:
                    rp.ok()


# ------------------------------------------------------------------ langues
def _word_ratio(text, words):
    toks = re.findall(r"[a-zàâçéèêëîïôûùüÿœ']+", text.lower())
    toks = [t.split("'")[-1] for t in toks]
    if len(toks) < 40:
        return 0.0
    return sum(1 for t in toks if t in words) / len(toks)


def rule_i18n(m, rp, pc, want):
    langs = m.languages
    pages = [p for p in m.pages if not p.is_404]
    if want("i18n.lang"):
        for p in m.pages:
            exp = m.expected_lang(p)
            got = (p.lang or "").lower()
            if got.split("-")[0] == exp.lower():
                rp.ok()
            else:
                rp.fail("i18n.lang", f"lang=\"{p.lang}\" alors que la page est en « {exp} ».", file=p.rel)
    if len(langs) < 2:
        return
    alt_of = {}
    for p in pages:
        alts = {}
        for rel, href, _e in H.link_rels(p.doc):
            if "alternate" in rel and _e.get("hreflang"):
                alts[_e.get("hreflang").lower()] = href
        alt_of[p.rel] = alts
    def target_rel(p, href):
        if not href:
            return None
        if H.is_external(href):
            path = urlsplit(href).path or "/"
            rel = path.lstrip("/")
            if rel == "" or rel.endswith("/"):
                rel += "index.html"
            return rel if rel in m.files else (rel + "/index.html" if rel + "/index.html" in m.files else None)
        return m.resolve(p, href)

    if want("i18n.parity"):
        if not pc.get("requireParity", True):
            rp.info("i18n.parity", "Parité des langues non exigée pour ce profil.")
        else:
            for p in pages:
                lang = m.expected_lang(p)
                if not _indexable(p):
                    continue
                for other in langs:
                    if other == lang:
                        continue
                    href = alt_of[p.rel].get(other.lower())
                    t = target_rel(p, href)
                    if not href or t is None:
                        rp.fail("i18n.parity", f"La page « {p.url} » ({lang}) n'a pas d'équivalent en « {other} ».", file=p.rel)
                    else:
                        rp.ok()
            counts = {}
            for p in pages:
                counts.setdefault(m.expected_lang(p), 0)
                counts[m.expected_lang(p)] += 1
            if len(set(counts.values())) > 1:
                rp.fail("i18n.parity", "Nombre de pages différent selon la langue : " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) + ".")
            # texte resté dans l'autre langue
            for p in pages:
                lang = m.expected_lang(p)
                text = p.doc.visible_text()
                if lang == "en" and _word_ratio(text, FR_WORDS) > 0.12 and _word_ratio(text, FR_WORDS) > _word_ratio(text, EN_WORDS):
                    rp.fail("i18n.parity", "Cette page « en » semble contenir du texte français (traduction manquante ?).", file=p.rel, severity="warn")
                if lang == "fr" and _word_ratio(text, EN_WORDS) > 0.12 and _word_ratio(text, EN_WORDS) > _word_ratio(text, FR_WORDS):
                    rp.fail("i18n.parity", "Cette page « fr » semble contenir du texte anglais (traduction manquante ?).", file=p.rel, severity="warn")
    if want("i18n.hreflang"):
        for p in pages:
            if not _indexable(p):
                continue
            alts = alt_of[p.rel]
            if not alts:
                rp.fail("i18n.hreflang", "Aucune balise hreflang alors que le site est multilingue.", file=p.rel)
                continue
            for lg, href in alts.items():
                if lg == "x-default":
                    continue
                t = target_rel(p, href)
                if t is None:
                    rp.fail("i18n.hreflang", f"hreflang=\"{lg}\" pointe vers une page introuvable (« {str(href)[:70]} »).", file=p.rel)
                    continue
                back = alt_of.get(t, {})
                mylang = m.expected_lang(p).lower()
                back_t = target_rel(next((q for q in pages if q.rel == t), p), back.get(mylang)) if back.get(mylang) else None
                if back_t == p.rel or lg == mylang and t == p.rel:
                    rp.ok()
                else:
                    rp.fail("i18n.hreflang", f"hreflang non réciproque : {p.url} -> {lg}, mais l'autre page ne renvoie pas vers « {mylang} ».", file=p.rel)
            if "x-default" not in alts:
                rp.fail("i18n.hreflang", "hreflang=\"x-default\" absent.", file=p.rel, severity="warn")


# ------------------------------------------------------------------ SEO
def _ld_blocks(p):
    out = []
    for s in p.doc.by_tag("script"):
        if (s.get("type") or "").lower() == "application/ld+json":
            out.append(s)
    return out


def _leaf_strings(obj, out):
    if isinstance(obj, dict):
        for v in obj.values():
            _leaf_strings(v, out)
    elif isinstance(obj, list):
        for v in obj:
            _leaf_strings(v, out)
    elif isinstance(obj, str):
        out.append(obj)


def rule_seo(m, rp, pc, want, cfg):
    pages = [p for p in m.pages if not p.is_404]
    if want("seo.sitemap"):
        sm = m.texts.get("sitemap.xml")
        if sm is None:
            rp.fail("seo.sitemap", "sitemap.xml absent de dist/ (site_build le génère).")
        else:
            try:
                root = ET.fromstring(sm)
                locs = {(e.text or "").strip().rstrip("/") for e in root.iter() if e.tag.endswith("}loc") or e.tag == "loc"}
                base = m.base_url or ("https://" + _placeholder_domain(cfg))
                missing = [p.url for p in pages if _indexable(p) and (base + p.url).rstrip("/") not in locs]
                if missing:
                    rp.fail("seo.sitemap", f"{len(missing)} page(s) absente(s) du sitemap : {', '.join(missing[:4])}.")
                else:
                    rp.ok()
            except ET.ParseError:
                rp.fail("seo.sitemap", "sitemap.xml n'est pas un XML valide.")
        if "robots.txt" not in m.texts:
            rp.fail("seo.sitemap", "robots.txt absent de dist/.", severity="warn")
    if want("seo.orphans") and pc.get("requireOrphanCheck", True) and pages:
        start = next((p for p in pages if p.url == "/"), pages[0])
        seen = {start.rel}
        queue = [start]
        by_rel = {p.rel: p for p in m.pages}
        while queue:
            cur = queue.pop()
            for url, el, attr, kind in H.resource_refs(cur.doc):
                if kind != "a" or not url or H.is_external(url):
                    continue
                t = m.resolve(cur, url)
                if t and t in by_rel and t not in seen:
                    seen.add(t)
                    queue.append(by_rel[t])
        # une langue entière peut n'être atteignable que par le sélecteur de langue : on le suit comme un lien (il est un <a>)
        for p in pages:
            if p.noindex:
                continue
            if p.rel in seen:
                rp.ok()
            else:
                rp.fail("seo.orphans", f"La page « {p.url} » n'est liée depuis aucune autre page.", file=p.rel)
    if want("seo.jsonld"):
        allowed = []
        _leaf_strings(m.site or {}, allowed)
        allowed_low = {a.strip().lower() for a in allowed if isinstance(a, str)}
        base = m.base_url
        for p in pages:
            for s in _ld_blocks(p):
                try:
                    data = json.loads(s.raw)
                except ValueError:
                    rp.fail("seo.jsonld", f"JSON-LD invalide (ligne {s.line}).", file=p.rel)
                    continue
                leaves = []
                _leaf_strings(data, leaves)
                bad = []
                for v in leaves:
                    vv = v.strip().lower()
                    if not vv or vv.startswith(("http://schema.org", "https://schema.org")) or vv in allowed_low:
                        continue
                    if base and vv.startswith(base.lower()):
                        continue
                    if vv in ("localbusiness", "organization", "website", "webpage", "postaladdress", "person", "professionalservice", "store", "restaurant", "medicalbusiness") \
                            or re.match(r"^[a-z]+$", vv) and len(vv) < 30 and vv[:1].isupper() is False and v[:1].isupper():
                        continue
                    bad.append(v)
                if bad:
                    rp.fail("seo.jsonld", f"JSON-LD : valeur(s) absente(s) de site.json (inventées ?) : {', '.join(repr(b[:40]) for b in bad[:3])}.", file=p.rel)
                else:
                    rp.ok()


# ------------------------------------------------------------------ contenu
def _claim_allowed(site, kind, matched):
    given = (site or {}).get("claimsProvidedByClient")
    if not isinstance(given, list):
        return False
    low = matched.lower()
    for g in given:
        if not isinstance(g, str) or not g.strip():
            continue
        gl = g.strip().lower()
        if gl == kind or gl in low or (len(low) > 3 and low in gl):
            return True
    return False


def rule_content(m, rp, pc, want, cfg):
    site = m.site or {}
    ph_re = re.compile(cfg.get("placeholderRe") or r"\[À COMPLÉTER\s*:[^\]]{0,200}\]")
    declared = " ".join(str(x).lower() for x in (site.get("needsFromClient") or []) if isinstance(x, (str, int, float)))
    labels_all = {}
    for p in m.pages:
        texts = [p.doc.visible_text()]
        for e in p.doc.elements:
            for k in ("alt", "title", "content", "placeholder", "aria-label"):
                v = e.get(k)
                if isinstance(v, str) and "COMPLÉTER" in v:
                    texts.append(v)
        for t in texts:
            for mm in ph_re.finditer(t):
                lab = re.sub(r"\s+", " ", mm.group(0)[len("[À COMPLÉTER"):].strip(" :]")).strip()
                labels_all.setdefault(lab, set()).add(p.rel)
    if want("content.placeholders"):
        if labels_all:
            rp.info("content.placeholders", f"{len(labels_all)} champ(s) « À COMPLÉTER » restent à renseigner par le client : " + " ; ".join(sorted(labels_all)[:8]) + (" …" if len(labels_all) > 8 else ""))
            for lab, files in sorted(labels_all.items()):
                l = lab.lower()
                if l and not any(l in declared or (len(w) > 3 and w in l) for w in declared.split()):
                    rp.fail("content.placeholders", f"« À COMPLÉTER : {lab[:60]} » n'est pas déclaré dans needsFromClient (site.json) : le client ne sera pas prévenu.", file=sorted(files)[0], severity="warn")
        else:
            rp.ok()
    if want("content.filler"):
        pat = re.compile(r"lorem ipsum|dolor sit amet|consectetur adipiscing|texte (?:à|a) remplacer|your text here|insérez votre texte|\bTODO\b|\bTBD\b|\bXXX+\b|coming soon", re.I)
        for p in m.pages:
            mm = pat.search(p.doc.visible_text())
            if mm:
                rp.fail("content.filler", f"Texte de remplissage visible : « {mm.group(0)[:30]} ».", file=p.rel)
            else:
                rp.ok()
    if want("content.fake_contact"):
        fake_mail = re.compile(r"[\w.+-]+@(?:example\.(?:com|org|net|ch|fr)|test\.com|domain\.com|domaine\.(?:com|ch|fr)|votre[-_]?(?:site|domaine|entreprise)\.[a-z]+|yourdomain\.[a-z]+|email\.com|mail\.com|monsite\.[a-z]+)\b", re.I)
        fake_tel = re.compile(r"(?:\b0?1[\s.-]?23[\s.-]?45[\s.-]?67[\s.-]?89\b|\b0{4,}\b|\b(?:12345678|123[\s.-]?456[\s.-]?7890)\b|\+\d{2}[\s.-]?0{2}[\s.-]?0{3}|\bxx[\s.-]?xx[\s.-]?xx\b|\+?\d{2}\s?79\s?123\s?45\s?67\b|\+41\s?21\s?123\s?45\s?67)", re.I)
        for p in m.pages:
            blob = p.doc.visible_text() + " " + " ".join((e.get("href") or "") for e in p.doc.by_tag("a"))
            mm = fake_mail.search(blob) or fake_tel.search(blob)
            if mm:
                rp.fail("content.fake_contact", f"Coordonnées factices : « {mm.group(0)[:40]} ». Utilisez la valeur donnée par le client ou « [À COMPLÉTER : …] ».", file=p.rel)
            else:
                rp.ok()
    if want("claims.unverified"):
        found = False
        for p in m.pages:
            blobs = [("texte", p.doc.visible_text())]
            for e in p.doc.elements:
                for k in ("alt", "title", "content", "aria-label"):
                    v = e.get(k)
                    if isinstance(v, str) and len(v) > 3 and not (e.tag == "meta" and (e.get("name") or "").lower() in ("viewport", "robots", "theme-color")):
                        blobs.append((f"{e.tag}[{k}]", v))
            for s in _ld_blocks(p):
                blobs.append(("JSON-LD", s.raw))
            for src, text in blobs:
                for cp in cfg.get("claimPatterns") or []:
                    mm = re.search(cp["re"], text, re.I)
                    if mm and not _claim_allowed(site, cp.get("kind", ""), mm.group(0)):
                        found = True
                        rp.fail("claims.unverified", f"Affirmation non vérifiée ({cp['label']}) : « {mm.group(0).strip()[:60]} ». Aucun chiffre, avis, note ni certification n'est inventé : le client doit les fournir (site.json › claimsProvidedByClient) ou retirez la phrase.", file=p.rel)
                for cp in cfg.get("softClaimPatterns") or []:
                    mm = re.search(cp["re"], text, re.I)
                    if mm and not _claim_allowed(site, cp.get("kind", ""), mm.group(0)):
                        rp.fail("claims.unverified", f"Affirmation à confirmer par le client ({cp['label']}) : « {mm.group(0).strip()[:60]} ».", file=p.rel, severity="warn")
            hints = [h.lower() for h in cfg.get("testimonialClassHints") or []]
            for e in p.doc.elements:
                cls = " ".join(e.classes()).lower() + " " + (e.get("id") or "").lower()
                is_quote = e.tag == "blockquote" and not _all_placeholders(e.inner_text(), ph_re)
                is_hint = any(h in cls for h in hints) and not _all_placeholders(e.inner_text(), ph_re) and e.inner_text().strip()
                if (is_quote or is_hint) and not _claim_allowed(site, "testimonials", e.inner_text()[:80]):
                    found = True
                    rp.fail("claims.unverified", f"Témoignage ou citation présenté comme venant d'un client (ligne {e.line}) : aucun avis n'est inventé. Retirez-le ou faites-le fournir par le client (claimsProvidedByClient: [\"testimonials\"]).", file=p.rel)
                    break
            for h in p.doc.by_tag("h2", "h3"):
                if re.search(r"\b(?:nos clients|nos références|ils nous font confiance|references|our clients|trusted by)\b", h.inner_text(), re.I) \
                        and not _claim_allowed(site, "client_logos", h.inner_text()):
                    sec = next((a for a in h.ancestors() if a.tag in ("section", "div", "article")), None)
                    if sec is not None and (any(d.tag == "img" for d in sec.descendants()) or "COMPLÉTER" not in sec.inner_text()):
                        found = True
                        rp.fail("claims.unverified", f"Section « {h.inner_text()[:40]} » (clients ou références) : aucun logo ni nom de client n'est inventé ; à fournir par le client (claimsProvidedByClient: [\"client_logos\"]).", file=p.rel)
        if not found:
            rp.ok()
    if want("abuse.credential_form"):
        bad = False
        names = [re.compile(rf"(?:^|[-_ ]){n}(?:$|[-_ ])", re.I) for n in cfg.get("credentialFieldNames") or []]
        for p in m.pages:
            for inp in p.doc.by_tag("input", "textarea"):
                typ = (inp.get("type") or "text").lower()
                ident = " ".join([inp.get("name") or "", inp.get("id") or "", inp.get("autocomplete") or ""])
                if typ == "password" or (inp.get("autocomplete") or "").lower().startswith(("cc-", "current-password", "new-password")) or any(r.search(ident) for r in names):
                    bad = True
                    rp.fail("abuse.credential_form", f"Champ de mot de passe ou de carte bancaire (ligne {inp.line}) : un site de présentation n'en collecte jamais.", file=p.rel)
        if not bad:
            rp.ok()


def _all_placeholders(text, ph_re):
    rest = ph_re.sub("", text)
    return not re.search(r"[A-Za-zÀ-ÿ]{4,}", rest)


# ------------------------------------------------------------------ build frais ?
def rule_build(m, rp, pc, cfg):
    """Règles toujours exécutées : le dist/ existe, correspond à src/, le site.json se lit."""
    if m.site_error:
        rp.fail("site.config", m.site_error)
    if not m.dist_exists or not m.pages:
        rp.fail("build.missing", "Aucun site construit : lancez site_build (il assemble site/dist/ depuis site/src/).")
        return False
    return True


def run_checks(workspace, check, res, root=None, site_rel="site"):
    """Point d'entrée : exécute les contrôles demandés par `check` ({profile, must[], path}) et les range dans `res` (project_checks.Res)."""
    started = time.time()
    root = root or ROOT
    cfg = load_config(root)
    profile = check.get("profile") if isinstance(check.get("profile"), str) else "vitrine"
    pc = profile_config(cfg, profile)
    path = check.get("path") if isinstance(check.get("path"), str) and check.get("path").strip() else site_rel + "/"
    site_rel = path.strip("/") or "site"
    try:
        pp.split_rel(site_rel, allow_empty=False)
    except pp.PathError:
        res.fail("check.invalid", "path invalide pour site_check.")
        return
    m = SiteModel(workspace, site_rel, root)
    rp = Reporter(res)
    must = check.get("must")
    fams = set(f for f in must if isinstance(f, str)) if isinstance(must, list) and must else set(cfg.get("families") or [])
    always = set(cfg.get("alwaysRun") or [])
    want = lambda rule: _want(rule, fams, always)  # noqa: E731
    if not rule_build(m, rp, pc, cfg):
        rp.finish()
        return
    # dist/ à jour ?
    try:
        import site_factory
        if m.build and m.build.get("srcDigest") and site_factory.src_digest(m.site_dir) != m.build.get("srcDigest"):
            rp.fail("build.stale", "site/src ou site.json ont changé depuis le dernier site_build : relancez site_build, sinon l'aperçu, le zip et ce contrôle portent sur une ancienne version.")
    except Exception:  # noqa: BLE001
        pass
    if len(m.pages) > int(pc.get("maxPages") or 60):
        rp.fail("perf.total", f"{len(m.pages)} pages : au plus {pc.get('maxPages')} pour ce profil.")
    if not m.base_url:
        rp.fail("build.baseurl", f"Adresse du site non renseignée (site.json › baseUrl) : canonical, hreflang, og:url et sitemap utilisent l'adresse provisoire {_placeholder_domain(cfg)}. À remplacer avant la mise en ligne.", severity="warn")
    rule_html(m, rp, pc, want)
    rule_meta(m, rp, pc, want, cfg)
    rule_links(m, rp, pc, want)
    rule_img(m, rp, pc, want)
    rule_a11y_html(m, rp, pc, want)
    rule_a11y_css(m, rp, pc, want)
    rule_perf(m, rp, pc, want)
    rule_privacy(m, rp, pc, want, cfg)
    rule_i18n(m, rp, pc, want)
    rule_seo(m, rp, pc, want, cfg)
    rule_content(m, rp, pc, want, cfg)
    rp.finish()
    for p in m.pages[:30]:
        res.note_input("site/dist/" + p.rel, p.full)
    if os.path.isfile(os.path.join(m.site_dir, "site.json")):
        res.note_input(site_rel + "/site.json", os.path.join(m.site_dir, "site.json"))
    return time.time() - started
