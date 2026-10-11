# -*- coding: utf-8 -*-
"""Garde-fou "zero mensonge" : echoue si la page Securite (ou Statut, ou security.txt) contient un mot de
certification / d'audit / de conformite qui n'est pas ADOSSE a un document du depot.

Regle : un bloc de texte (puce, ligne de tableau, paragraphe) qui contient un terme de certification
(SOC 2, ISO 27001, test d'intrusion, HIPAA, PCI DSS, "certifie", "audite"...) doit soit
  - etre une NEGATION ou un "non fait" ("aucun rapport SOC 2", "pas de test d'intrusion", "no SOC 2 report",
    "a decider", "identifie, non commence"...),
  - soit etre appuye par un document de preuve present dans le depot (voir EVIDENCE_FILES : un rapport SOC 2
    depose dans docs/evidence/ autoriserait la phrase positive correspondante).
Sinon : echec, avec le texte fautif. La verification porte sur la version francaise ET sur la version anglaise
(traduction appliquee noeud par noeud, comme le fait i18n.js dans le navigateur).

Usage : python tests/trust/check_certification_claims.py        (rend les pages et verifie ; code 1 si violation)
        python tests/trust/check_certification_claims.py page.html [autre.txt ...]
"""
import glob
import html as htmllib
import os
import re
import sys
from html.parser import HTMLParser

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# terme -> (motif, cle de preuve)
TERMS = [
    (r"\bsoc\s*[- ]?2\b", "soc2"),
    (r"\bsoc\s*[- ]?3\b", "soc2"),
    (r"\biso\s*/?\s*(?:iec\s*)?2700[1-9]\b", "iso27001"),
    (r"\bhipaa\b", "hipaa"),
    (r"\bpci[\s-]*dss\b", "pci"),
    (r"\bhds\b", "hds"),
    (r"\bpen[\s-]?test\w*", "pentest"),
    (r"\bpenetration[\s-]+test\w*", "pentest"),
    (r"\btests?\s+d['’]intrusion\b", "pentest"),
    (r"\bbug[\s-]*bounty\b", "pentest"),
    (r"\bcertifi(?:cation|cations|é|ée|és|ées|ed|ons)\b", "certification"),
    (r"\battest(?:ation|ations|ed|é|ée)\b", "certification"),
    (r"\b(?:audit[eé]e?s?|audited)\b", "certification"),
    (r"\b(?:gdpr|rgpd)[\s-]*(?:compliant|conforme)\b", "gdpr"),
    (r"\bconforme?s?\s+(?:au\s+)?(?:rgpd|gdpr|soc|iso)\b", "gdpr"),
    (r"\b(?:bank|military)[\s-]*grade\b", "grade"),
    (r"\bniveau\s+(?:bancaire|militaire)\b", "grade"),
    (r"\b(?:inviolable|unhackable|infaillible|100\s*%\s*(?:secure|s[ée]curis[ée]))\b", "absolute"),
]
EVIDENCE_FILES = {
    "soc2": ["docs/evidence/soc2-*.pdf", "docs/evidence/soc2-*.md"],
    "iso27001": ["docs/evidence/iso27001-*.pdf", "docs/evidence/iso-27001-*.pdf"],
    "pentest": ["docs/evidence/pentest-*.pdf", "docs/evidence/pentest-*.md"],
    "hipaa": ["docs/evidence/hipaa-*"], "pci": ["docs/evidence/pci-*"], "hds": ["docs/evidence/hds-*"],
    "certification": ["docs/evidence/certificat*", "docs/evidence/attestation*"],
    "gdpr": ["docs/evidence/dpa-signed-*", "docs/evidence/gdpr-*"],
    "grade": [], "absolute": [],
}
NEGATION = re.compile(
    r"\b(?:aucun\w*|pas|non|ni|sans|jamais|no|not|neither|nor|never|without|none)\b|\bn['’]|\bne\s|"
    r"\bà\s+décider\b|\bto\s+be\s+decided\b|\bidentifi\w+\b|\bidentified\b|\bdépend\w*\b|\bdepends\b|"
    r"\bnon\s+commenc\w+\b|\bnot\s+started\b|\bpas\s+encore\b|\bnot\s+yet\b", re.I)


class _Blocks(HTMLParser):
    """Decoupe le HTML en blocs de texte : li, p, h1-h4, summary, et tr (cellules jointes)."""
    BLOCK = {"li", "p", "h1", "h2", "h3", "h4", "summary", "tr"}
    SKIP = {"script", "style", "noscript"}

    def __init__(self, translate=None):
        super().__init__(convert_charrefs=True)
        self.translate = translate
        self.blocks, self._stack, self._skip = [], [], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self._skip += 1
        if tag in self.BLOCK:
            self._stack.append([tag, []])

    def handle_endtag(self, tag):
        if tag in self.SKIP:
            self._skip = max(0, self._skip - 1)
        if tag in self.BLOCK:
            for i in range(len(self._stack) - 1, -1, -1):
                if self._stack[i][0] == tag:
                    _, parts = self._stack.pop(i)
                    text = " ".join(p for p in parts if p).strip()
                    if text:
                        self.blocks.append((tag, text))
                    break

    def handle_data(self, data):
        if self._skip or not self._stack:
            return
        norm = re.sub(r"\s+", " ", data).strip()
        if not norm:
            return
        if self.translate is not None:
            norm = self.translate.get(norm, norm)
        self._stack[-1][1].append(norm)            # un texte appartient a son bloc le plus proche


def blocks_of(html_text, translate=None):
    p = _Blocks(translate)
    p.feed(html_text)
    p.close()
    out = []
    for tag, text in p.blocks:
        if tag == "p":                                   # un paragraphe est examine phrase par phrase
            out.extend(s.strip() for s in re.split(r"(?<=[.;])\s+", text) if s.strip())
        else:                                            # puce / ligne de tableau : une seule unite (le statut est dans la cellule voisine)
            out.append(text)
    return out


def has_evidence(key, root=REPO):
    return any(glob.glob(os.path.join(root, pat)) for pat in EVIDENCE_FILES.get(key, []))


def check_blocks(blocks, root=REPO):
    """-> liste de (terme trouve, phrase fautive)."""
    bad = []
    for sentence in blocks:
        low = sentence.lower()
        for pattern, key in TERMS:
            m = re.search(pattern, low, re.I)
            if not m:
                continue
            if NEGATION.search(low):
                continue
            if has_evidence(key, root):
                continue
            bad.append((m.group(0), sentence))
    return bad


def check_html(html_text, translate=None, root=REPO):
    return check_blocks(blocks_of(html_text, translate), root)


def check_plain(text, root=REPO):
    return check_blocks([s.strip() for s in re.split(r"(?<=[.;\n])\s+", text) if s.strip()], root)


def load_translations(js_path):
    """Lit un fichier i18n-en*.js (paires "FR": "EN" au format JSON) sans Node."""
    import json
    with open(js_path, encoding="utf-8") as f:
        src = f.read()
    pair = re.compile(r'"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"')
    return {json.loads('"' + k + '"'): json.loads('"' + v + '"') for k, v in pair.findall(src)}


def render_pages():
    sys.path.insert(0, os.path.join(REPO, "dashboard"))
    import trust_pages
    payload = {"status": "unknown", "components": [], "days": [], "incidents": [], "uptime": {}, "measuredSinceUtc": None}
    return {"/securite.html": trust_pages.render_security_page(), "/status.html": trust_pages.render_status_page(payload),
            "/.well-known/security.txt": trust_pages.render_security_txt("https://bk-ai-workers.com")}


def main(argv):
    problems = []
    if argv:
        for path in argv:
            text = open(path, encoding="utf-8").read()
            found = check_html(text) if path.endswith((".html", ".htm")) else check_plain(text)
            problems += [(path, t, s) for t, s in found]
    else:
        pages = render_pages()
        en = load_translations(os.path.join(REPO, "dashboard", "i18n-en-trust.js"))
        for path, content in pages.items():
            if path.endswith(".txt"):
                problems += [(path, t, s) for t, s in check_plain(content)]
                continue
            problems += [(path + " [fr]", t, s) for t, s in check_html(content)]
            problems += [(path + " [en]", t, s) for t, s in check_html(content, en)]
    if problems:
        print("ECHEC : mot de certification non adosse a un document du depot (voir EVIDENCE_FILES) :")
        for where, term, sentence in problems:
            print(f"  - {where} : « {term} » dans : {sentence[:200]}")
        return 1
    print("OK : aucun mot de certification sans negation ni preuve dans les pages verifiees.")
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))
