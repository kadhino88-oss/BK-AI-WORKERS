# -*- coding: utf-8 -*-
"""Lecteur HTML tolérant de l'atelier de sites (docs/AUTONOMY-ENGINE.md, section 8.4). Bibliothèque standard seulement.

Ce n'est PAS le validateur W3C (indisponible hors ligne) : c'est un lecteur qui construit un arbre léger, signale ce qu'un navigateur
répare en silence mais qui trahit une page mal écrite (balise non fermée, mal imbriquée, `id` en double, attribut sans guillemets,
attribut répété) et expose ce dont les contrôles ont besoin (titre, méta, liens, images, titres, formulaires, textes visibles).
"""
import re
from html.parser import HTMLParser

VOID = frozenset("area base br col embed hr img input link meta param source track wbr".split())
RAW_TEXT = frozenset(("script", "style"))
# Fin de balise facultative en HTML : jamais un défaut.
OPTIONAL_END = frozenset("p li dt dd tr td th thead tbody tfoot option optgroup colgroup caption head body html rp rt".split())
BLOCKS_CLOSING_P = frozenset(("address article aside blockquote details div dl fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hgroup hr main nav ol p pre "
                              "section table ul").split())
CLOSED_BY = {
    "p": BLOCKS_CLOSING_P,
    "li": frozenset(("li",)),
    "dt": frozenset(("dt", "dd")),
    "dd": frozenset(("dt", "dd")),
    "tr": frozenset(("tr", "tbody", "tfoot", "thead")),
    "td": frozenset(("td", "th", "tr", "tbody", "tfoot", "thead")),
    "th": frozenset(("td", "th", "tr", "tbody", "tfoot", "thead")),
    "thead": frozenset(("tbody", "tfoot")),
    "tbody": frozenset(("tbody", "tfoot")),
    "option": frozenset(("option", "optgroup")),
    "optgroup": frozenset(("optgroup",)),
    "head": frozenset(("body",)),
}
FOREIGN = frozenset(("svg", "math"))
_ATTR_RE = re.compile(r"""\s+([^\s"'<>/=]+)(?:\s*=\s*(?:"[^"]*"|'[^']*'|([^\s"'=<>`]+)))?""")
_SCRIPT_TYPES_DATA = ("application/ld+json", "application/json", "importmap", "speculationrules", "text/template", "text/x-template")


class Element:
    __slots__ = ("tag", "attrs", "line", "parent", "children", "content", "raw")

    def __init__(self, tag, attrs, line, parent):
        self.tag = tag
        self.attrs = attrs
        self.line = line
        self.parent = parent
        self.children = []
        self.content = []     # texte et enfants dans l'ordre du document (str | Element)
        self.raw = ""         # contenu brut d'un <script> ou d'un <style>

    def get(self, name, default=None):
        v = self.attrs.get(name)
        return default if v is None else v

    def has(self, name):
        return name in self.attrs

    def classes(self):
        return (self.attrs.get("class") or "").split()

    def inner_text(self):
        parts = []
        self._collect(parts)
        return re.sub(r"\s+", " ", "".join(parts)).strip()

    def _collect(self, parts):
        if self.tag in RAW_TEXT or self.tag == "template":
            return
        for c in self.content:
            if isinstance(c, str):
                parts.append(c)
            else:
                if c.tag in ("br", "p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "section", "tr"):
                    parts.append(" ")
                c._collect(parts)
                if c.tag in ("p", "div", "li", "h1", "h2", "h3", "h4", "h5", "h6", "section", "tr"):
                    parts.append(" ")

    def ancestors(self):
        p = self.parent
        while p is not None:
            yield p
            p = p.parent

    def descendants(self):
        for c in self.children:
            yield c
            yield from c.descendants()


class Document:
    def __init__(self):
        self.root = Element("#document", {}, 0, None)
        self.elements = []
        self.errors = []          # [(ligne, message)]
        self.doctype = None       # texte de <!doctype ...>
        self.doctype_first = False
        self.ids = {}             # id -> [lignes]
        self.comments = []

    def by_tag(self, *tags):
        want = set(tags)
        return [e for e in self.elements if e.tag in want]

    def first(self, tag):
        for e in self.elements:
            if e.tag == tag:
                return e
        return None

    def visible_text(self):
        body = self.first("body") or self.root
        return body.inner_text()


class _Builder(HTMLParser):
    def __init__(self, doc):
        super().__init__(convert_charrefs=True)
        self.doc = doc
        self.stack = [doc.root]
        self.seen_content = False
        self._pending_raw = None

    # -- utilitaires
    def _line(self):
        return self.getpos()[0]

    def _top(self):
        return self.stack[-1]

    def _in_foreign(self):
        return any(e.tag in FOREIGN for e in self.stack)

    def _close_implicit(self, new_tag):
        while True:
            top = self._top()
            closers = CLOSED_BY.get(top.tag)
            if top is not self.doc.root and closers and new_tag in closers:
                self.stack.pop()
            else:
                break

    # -- événements
    def handle_decl(self, decl):
        if decl.lower().startswith("doctype"):
            self.doc.doctype = decl.strip()
            self.doc.doctype_first = not self.seen_content

    def handle_comment(self, data):
        self.doc.comments.append((self._line(), data))

    def handle_starttag(self, tag, attrs, selfclosing=False):
        self.seen_content = True
        line = self._line()
        d = {}
        raw = self.get_starttag_text() or ""
        names = [m.group(1).lower() for m in _ATTR_RE.finditer(raw[len(tag) + 1:])]
        for m in _ATTR_RE.finditer(raw[len(tag) + 1:]):
            if m.group(2) is not None:
                self.doc.errors.append((line, f"attribut sans guillemets dans <{tag}> : {m.group(1)}={m.group(2)[:30]}"))
        seen = set()
        for n in names:
            if n in seen and n not in ("class",):
                self.doc.errors.append((line, f"attribut « {n} » répété dans <{tag}>"))
            seen.add(n)
        for k, v in attrs:
            d[k.lower()] = v if v is not None else ""
        self._close_implicit(tag)
        el = Element(tag, d, line, self._top())
        self._top().children.append(el)
        self._top().content.append(el)
        self.doc.elements.append(el)
        if "id" in d and d["id"]:
            self.doc.ids.setdefault(d["id"], []).append(line)
        if tag in VOID:
            return
        if selfclosing and self._in_foreign():
            return
        if selfclosing and tag not in FOREIGN:
            self.doc.errors.append((line, f"<{tag}/> : une balise non vide ne se ferme pas ainsi en HTML"))
        self.stack.append(el)
        if tag in RAW_TEXT:
            self._pending_raw = el

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs, selfclosing=True)

    def handle_endtag(self, tag):
        line = self._line()
        if tag in VOID:
            if tag == "br":
                return
            self.doc.errors.append((line, f"</{tag}> : une balise vide n'a pas de balise fermante"))
            return
        idx = None
        for i in range(len(self.stack) - 1, 0, -1):
            if self.stack[i].tag == tag:
                idx = i
                break
        if idx is None:
            if tag not in ("p", "br"):
                self.doc.errors.append((line, f"</{tag}> sans balise ouvrante"))
            return
        for el in reversed(self.stack[idx + 1:]):
            if el.tag not in OPTIONAL_END:
                self.doc.errors.append((el.line, f"<{el.tag}> ouverte ligne {el.line} n'est pas fermée avant </{tag}> (ligne {line})"))
        del self.stack[idx:]
        if self._pending_raw is not None and self._pending_raw.tag == tag:
            self._pending_raw = None

    def handle_data(self, data):
        if not data:
            return
        top = self._top()
        if self._pending_raw is not None and top is self._pending_raw:
            top.raw += data
            return
        if not data.strip() and top is self.doc.root:
            return
        if top is not self.doc.root:
            top.content.append(data)
        if data.strip():
            self.seen_content = True

    def close(self):
        super().close()
        for el in self.stack[1:]:
            if el.tag not in OPTIONAL_END:
                self.doc.errors.append((el.line, f"<{el.tag}> ouverte ligne {el.line} n'est jamais fermée"))


def parse(text):
    """Document HTML analysé (jamais d'exception : le texte brut est toujours lisible)."""
    doc = Document()
    b = _Builder(doc)
    try:
        b.feed(text or "")
        b.close()
    except Exception as e:  # noqa: BLE001 - HTMLParser ne lève presque rien, mais un page piégée ne doit jamais faire tomber le contrôle
        doc.errors.append((0, f"analyse interrompue : {type(e).__name__}"))
    for ident, lines in doc.ids.items():
        if len(lines) > 1:
            doc.errors.append((lines[1], f"id « {ident} » en double (lignes {', '.join(str(x) for x in lines[:4])})"))
    return doc


# ------------------------------------------------------------------ extraction commune aux contrôles
def meta_content(doc, key, attr="name"):
    for e in doc.by_tag("meta"):
        if (e.get(attr) or "").lower() == key.lower() and e.has("content"):
            return e.get("content")
    return None


def link_rels(doc):
    """[(rel (minuscule, jeu), href, élément)] pour chaque <link>."""
    out = []
    for e in doc.by_tag("link"):
        rel = set((e.get("rel") or "").lower().split())
        out.append((rel, e.get("href"), e))
    return out


def srcset_urls(value):
    urls = []
    for part in (value or "").split(","):
        part = part.strip()
        if part:
            urls.append(part.split()[0])
    return urls


def resource_refs(doc):
    """[(url, élément, attribut, genre)] de TOUTES les références chargées ou suivies par la page.
    genre : link | script | style | img | media | frame | form | object | a | meta."""
    out = []
    for e in doc.elements:
        t = e.tag
        if t == "a" and e.get("href") is not None:
            out.append((e.get("href"), e, "href", "a"))
        elif t == "area" and e.get("href") is not None:
            out.append((e.get("href"), e, "href", "a"))
        elif t == "link" and e.get("href") is not None:
            rel = set((e.get("rel") or "").lower().split())
            kind = "style" if "stylesheet" in rel else "link"
            out.append((e.get("href"), e, "href", kind))
        elif t == "script" and e.get("src") is not None:
            out.append((e.get("src"), e, "src", "script"))
        elif t == "img":
            if e.get("src") is not None:
                out.append((e.get("src"), e, "src", "img"))
            for u in srcset_urls(e.get("srcset")):
                out.append((u, e, "srcset", "img"))
        elif t == "source":
            if e.get("src") is not None:
                out.append((e.get("src"), e, "src", "media"))
            for u in srcset_urls(e.get("srcset")):
                out.append((u, e, "srcset", "media"))
        elif t in ("video", "audio", "track") and e.get("src") is not None:
            out.append((e.get("src"), e, "src", "media"))
        elif t in ("iframe", "frame") and e.get("src") is not None:
            out.append((e.get("src"), e, "src", "frame"))
        elif t in ("embed", "object"):
            u = e.get("src") if t == "embed" else e.get("data")
            if u is not None:
                out.append((u, e, "src", "object"))
        elif t == "form" and e.get("action") is not None:
            out.append((e.get("action"), e, "action", "form"))
        elif t == "meta":
            prop = (e.get("property") or e.get("name") or "").lower()
            if prop in ("og:image", "twitter:image", "og:url", "og:video", "og:audio") and e.has("content"):
                out.append((e.get("content"), e, "content", "meta"))
    return out


def is_external(url):
    u = (url or "").strip().lower()
    return u.startswith(("http://", "https://", "//"))


def host_of(url):
    u = (url or "").strip()
    if u.startswith("//"):
        u = "https:" + u
    m = re.match(r"^[a-z][a-z0-9+.-]*://([^/?#:@]*@)?([^/?#:]+)", u, re.IGNORECASE)
    return m.group(2).lower() if m else None
