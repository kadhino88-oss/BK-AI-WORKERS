# -*- coding: utf-8 -*-
"""Banc d'évaluation de l'autonomie : scénarios, contrôles automatiques SANS modèle, notation pondérée, synthèse de livrables conformes / piégés.

Les contrôles sont réimplémentés ICI, indépendamment du moteur de projets (dashboard/project_checks.py) : on ne laisse pas le moteur se noter lui-même.
Un scénario = un brief client réaliste + un faux profil client + une grille pondérée (critères automatiques et critères pour le juge modèle) + des pièges.
Python 3 standard seulement.
"""
import csv
import fnmatch
import io
import json
import os
import re
import unicodedata
import zipfile
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SCENARIO_DIR = os.path.join(HERE, "scenarios")
USD_TO_CHF = 0.83107                    # même taux que core/ai/AI-PRICING.json (coût estimé en CHF)
CHECK_TYPES = ("file_nonempty", "headings", "regex_count", "csv", "csv_sum", "forbid", "placeholders", "html", "jsonfile", "xlsx", "docx", "connector_ops",
               "consistent")
PLACEHOLDER_RE = re.compile(r"\[\s*(?:À|A) ?COMPL[ÉE]TER", re.IGNORECASE)


def norm(text):
    t = unicodedata.normalize("NFKD", str(text or "").lower())
    return "".join(c for c in t if not unicodedata.combining(c))


# ------------------------------------------------------------------ chargement des scénarios
def load_scenarios(directory=None):
    d = directory or SCENARIO_DIR
    out = {}
    for name in sorted(os.listdir(d)):
        if name.endswith(".json"):
            with open(os.path.join(d, name), encoding="utf-8") as f:
                s = json.load(f)
            out[s["id"]] = s
    return out


def validate_scenario(s):
    """Liste d'erreurs (vide = valide)."""
    err = []
    for k in ("id", "title", "workerId", "brief", "clientProfile", "installation", "rubric", "judge", "traps", "budgets"):
        if not s.get(k):
            err.append("champ absent : %s" % k)
    crit = (s.get("rubric") or {}).get("criteria") or []
    if not crit:
        err.append("grille vide")
    ids = [c.get("id") for c in crit]
    if len(set(ids)) != len(ids):
        err.append("identifiants de critères en double")
    auto_w = judge_w = 0
    for c in crit:
        if not isinstance(c.get("weight"), (int, float)) or c["weight"] <= 0:
            err.append("%s : poids invalide" % c.get("id"))
        if c.get("kind") == "auto":
            auto_w += c.get("weight", 0)
            if (c.get("check") or {}).get("type") not in CHECK_TYPES:
                err.append("%s : type de contrôle inconnu" % c.get("id"))
        elif c.get("kind") == "judge":
            judge_w += c.get("weight", 0)
            if not c.get("question"):
                err.append("%s : question du juge absente" % c.get("id"))
        else:
            err.append("%s : kind doit valoir auto ou judge" % c.get("id"))
    if auto_w <= 0:
        err.append("aucun critère automatique")
    if judge_w <= 0:
        err.append("aucun critère pour le juge")
    for t in s.get("traps") or []:
        if not (t.get("id") and t.get("description") and t.get("criterionId") in ids):
            err.append("piège %s : description ou critère manquant" % t.get("id"))
    if not any(c.get("fabrication") for c in crit):
        err.append("aucun critère de non-fabrication (fabrication: true)")
    if len(s.get("traps") or []) < 1:
        err.append("au moins un piège est requis")
    b = s.get("budgets") or {}
    if not (b.get("maxUsd") and b.get("maxMinutes")):
        err.append("budgets.maxUsd et budgets.maxMinutes requis")
    return err


# ------------------------------------------------------------------ espace de travail évalué
class Workspace:
    """Dossier produit par un moteur (chemins relatifs avec « / »). Lecture bornée, aucune sortie du dossier."""

    def __init__(self, root, connector_calls=None, fixtures=None):
        self.root = root
        self.connector_calls = list(connector_calls or [])
        self.fixtures = fixtures or {}

    def files(self, pattern="*"):
        out = []
        for dp, _d, fs in os.walk(self.root):
            for n in fs:
                rel = os.path.relpath(os.path.join(dp, n), self.root).replace(os.sep, "/")
                if fnmatch.fnmatch(rel, pattern) or ("/" not in pattern and fnmatch.fnmatch(rel.split("/")[-1], pattern)):
                    out.append(rel)
        return sorted(out)

    def path(self, rel):
        full = os.path.realpath(os.path.join(self.root, *rel.split("/")))
        if not (full == os.path.realpath(self.root) or full.startswith(os.path.realpath(self.root) + os.sep)):
            raise ValueError("chemin hors de l'espace de travail")
        return full

    def exists(self, rel):
        try:
            return os.path.isfile(self.path(rel))
        except ValueError:
            return False

    def read(self, rel, limit=2_000_000):
        with open(self.path(rel), "rb") as f:
            raw = f.read(limit)
        for enc in ("utf-8-sig", "cp1252"):
            try:
                return raw.decode(enc)
            except UnicodeDecodeError:
                pass
        return raw.decode("utf-8", errors="replace")

    def text_of(self, globs):
        parts = []
        for g in globs if isinstance(globs, list) else [globs]:
            for rel in self.files(g):
                if rel.lower().endswith((".md", ".txt", ".csv", ".html", ".htm", ".json", ".css", ".js", ".svg", ".xml", ".py", ".yml", ".yaml")):
                    parts.append(self.read(rel))
        return "\n".join(parts)


def write_files(root, files):
    for rel, content in files.items():
        full = os.path.join(root, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if isinstance(content, bytes):
            open(full, "wb").write(content)
        else:
            open(full, "w", encoding="utf-8", newline="\n").write(content)


# ------------------------------------------------------------------ contrôles
class _Html(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title = ""
        self.in_title = False
        self.h1 = 0
        self.meta = {}
        self.lang = None
        self.urls = []
        self.imgs_no_alt = 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.lang = a.get("lang")
        elif tag == "title":
            self.in_title = True
        elif tag == "h1":
            self.h1 += 1
        elif tag == "meta" and a.get("name"):
            self.meta[a["name"].lower()] = a.get("content") or ""
        elif tag == "img" and "alt" not in a:
            self.imgs_no_alt += 1
        for k in ("src", "href", "action"):
            if a.get(k):
                self.urls.append((tag, a[k]))
        if tag == "link" and a.get("href"):
            self.urls.append(("link", a["href"]))

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title += data


def _host(url):
    m = re.match(r"^(?:https?:)?//([^/:?#]+)", url.strip(), re.IGNORECASE)
    return m.group(1).lower() if m else None


def _csv_rows(text):
    head = text[:4000]
    delim = ";" if head.count(";") > head.count(",") and head.count(";") >= head.count("\t") else ("\t" if head.count("\t") > head.count(",") else ",")
    rows = list(csv.reader(io.StringIO(text), delimiter=delim))
    if not rows:
        return [], []
    header = [h.strip() for h in rows[0]]
    return header, [r for r in rows[1:] if any(c.strip() for c in r)]


def _xlsx_stats(path):
    with zipfile.ZipFile(path) as z:
        formulas = errors = 0
        sheets = []
        for n in z.namelist():
            if n.startswith("xl/worksheets/sheet") and n.endswith(".xml"):
                x = z.read(n).decode("utf-8", errors="replace")
                formulas += len(re.findall(r"<f[ >]", x))
                errors += len(re.findall(r"<v>#(?:REF|DIV/0|NAME|VALUE|N/A|NUM|NULL)", x)) + len(re.findall(r't="e"', x))
        if "xl/workbook.xml" in z.namelist():
            sheets = re.findall(r'<sheet [^>]*name="([^"]+)"', z.read("xl/workbook.xml").decode("utf-8", errors="replace"))
        return formulas, errors, sheets


def _docx_text(path):
    with zipfile.ZipFile(path) as z:
        x = z.read("word/document.xml").decode("utf-8", errors="replace")
    paras = re.findall(r"<w:p[ >].*?</w:p>", x, re.DOTALL)
    texts = ["".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", p)) for p in paras]
    heads = [t for p, t in zip(paras, texts) if re.search(r'w:pStyle w:val="Heading|w:pStyle w:val="Titre', p)]
    return texts, heads


def run_check(check, ws):
    """(ok, détail). Ne lève jamais."""
    try:
        return _run_check(check, ws)
    except Exception as e:  # noqa: BLE001 - un contrôle illisible est un échec expliqué, pas un plantage du banc
        return False, "contrôle impossible : %s" % type(e).__name__


def _run_check(c, ws):
    t = c["type"]
    if t == "file_nonempty":
        if not ws.exists(c["path"]):
            return False, "fichier absent : %s" % c["path"]
        n = os.path.getsize(ws.path(c["path"]))
        return (n >= c.get("min", 200)), "%s : %d octets (min %d)" % (c["path"], n, c.get("min", 200))
    if t == "headings":
        if not ws.exists(c["path"]):
            return False, "fichier absent : %s" % c["path"]
        text = norm(ws.read(c["path"]))
        miss = [h for h in c["all"] if norm(h) not in text]
        return (not miss), ("intitulés absents : %s" % ", ".join(miss)) if miss else "intitulés présents"
    if t == "regex_count":
        text = ws.text_of(c.get("globs") or [c["path"]]) if c.get("globs") or ws.exists(c["path"]) else ""
        n = len(re.findall(c["regex"], text, re.MULTILINE | re.IGNORECASE))
        return (c.get("min", 1) <= n <= c.get("max", 10 ** 9)), "%d occurrence(s) de /%s/ (min %s, max %s)" % (n, c["regex"][:40], c.get("min", 1), c.get("max", "-"))
    if t == "csv":
        if not ws.exists(c["path"]):
            return False, "fichier absent : %s" % c["path"]
        header, rows = _csv_rows(ws.read(c["path"]))
        probs = []
        for col in c.get("columns") or []:
            if col not in header:
                probs.append("colonne absente : %s" % col)
        if len(rows) < c.get("min_rows", 0):
            probs.append("%d ligne(s) < %d" % (len(rows), c["min_rows"]))
        if c.get("max_rows") and len(rows) > c["max_rows"]:
            probs.append("%d ligne(s) > %d" % (len(rows), c["max_rows"]))
        for col in c.get("nonempty") or []:
            if col in header:
                i = header.index(col)
                e = sum(1 for r in rows if i >= len(r) or not r[i].strip())
                if e:
                    probs.append("%d cellule(s) vide(s) dans %s" % (e, col))
        if c.get("unique") in header:
            i = header.index(c["unique"])
            vals = [r[i].strip().lower() for r in rows if i < len(r)]
            if len(set(vals)) != len(vals):
                probs.append("doublons dans %s" % c["unique"])
        for col, rx in (c.get("pattern") or {}).items():
            if col in header:
                i = header.index(col)
                bad = sum(1 for r in rows if i >= len(r) or not re.search(rx, r[i], re.IGNORECASE))
                if bad:
                    probs.append("%d ligne(s) de %s hors du motif /%s/" % (bad, col, rx[:30]))
        for col, lim in (c.get("max_len") or {}).items():
            if col in header:
                i = header.index(col)
                bad = sum(1 for r in rows if i < len(r) and len(r[i]) > lim)
                if bad:
                    probs.append("%d ligne(s) de %s dépassent %d caractères" % (bad, col, lim))
        for col, bound in (c.get("date_max") or {}).items():
            if col in header:
                i = header.index(col)
                bad = sum(1 for r in rows if i < len(r) and re.match(r"\d{4}-\d\d-\d\d", r[i].strip()) and r[i].strip()[:10] > bound)
                if bad:
                    probs.append("%d date(s) de %s après %s" % (bad, col, bound))
        return (not probs), "; ".join(probs) or "%d ligne(s) conformes" % len(rows)
    if t == "csv_sum":
        if not ws.exists(c["path"]):
            return False, "fichier absent : %s" % c["path"]
        header, rows = _csv_rows(ws.read(c["path"]))
        if c["column"] not in header:
            return False, "colonne absente : %s" % c["column"]
        i = header.index(c["column"])
        total = 0.0
        for r in rows:
            v = re.sub(r"[^\d,.\-]", "", (r[i] if i < len(r) else "").replace("'", "").replace(" ", "")).replace(",", ".")
            try:
                total += float(v)
            except ValueError:
                pass
        return abs(total - c["expected"]) <= c.get("tol", 0.5), "somme %s = %.2f (attendu %s)" % (c["column"], total, c["expected"])
    if t == "forbid":
        text = ws.text_of(c["globs"])
        if not text.strip():
            return False, "aucun fichier à contrôler (%s)" % ",".join(c["globs"])
        hits = []
        fixtures = norm(" ".join(ws.fixtures.values())) if c.get("unless_in_fixtures") else ""
        for p in c["patterns"]:
            for m in re.finditer(p, text, re.IGNORECASE):
                if c.get("unless_in_fixtures") and norm(m.group(0)) in fixtures:
                    continue
                hits.append(m.group(0)[:50])
        return (not hits), ("motif interdit trouvé : %s" % "; ".join(hits[:3])) if hits else "aucun motif interdit"
    if t == "placeholders":
        text = ws.text_of(c["globs"])
        n = len(PLACEHOLDER_RE.findall(text))
        return n >= c.get("min", 1), "%d marque(s) [À COMPLÉTER] (min %d)" % (n, c.get("min", 1))
    if t == "html":
        pages = ws.files(c["glob"])
        if len(pages) < c.get("min_pages", 1):
            return False, "%d page(s) < %d" % (len(pages), c.get("min_pages", 1))
        probs = []
        titles = []
        for rel in pages:
            p = _Html()
            p.feed(ws.read(rel))
            req = c.get("require") or []
            if "title" in req and not p.title.strip():
                probs.append("%s : titre absent" % rel)
            if "description" in req and not p.meta.get("description", "").strip():
                probs.append("%s : description absente" % rel)
            if "h1" in req and p.h1 != 1:
                probs.append("%s : %d balise(s) h1" % (rel, p.h1))
            if "lang" in req and not p.lang:
                probs.append("%s : lang absent" % rel)
            if "viewport" in req and "viewport" not in p.meta:
                probs.append("%s : viewport absent" % rel)
            if "alt" in req and p.imgs_no_alt:
                probs.append("%s : %d image(s) sans alt" % (rel, p.imgs_no_alt))
            titles.append(p.title.strip().lower())
            for tag, u in p.urls:
                h = _host(u)
                if h and h not in [x.lower() for x in c.get("allowed_hosts", [])] and tag in ("script", "link", "img", "iframe", "source", "form", "a") and (tag != "a" or c.get("links_count")):
                    probs.append("%s : ressource externe %s" % (rel, h))
        if "unique_titles" in (c.get("require") or []) and len(set(titles)) != len(titles):
            probs.append("titres en double")
        return (not probs), "; ".join(probs[:4]) or "%d page(s) conformes" % len(pages)
    if t == "jsonfile":
        if not ws.exists(c["path"]):
            return False, "fichier absent : %s" % c["path"]
        d = json.loads(ws.read(c["path"]))
        miss = [k for k in c.get("keys", []) if k not in d]
        return (not miss), ("clés absentes : %s" % ", ".join(miss)) if miss else "JSON valide"
    if t == "xlsx":
        if not ws.exists(c["path"]):
            return False, "fichier absent : %s" % c["path"]
        formulas, errors, sheets = _xlsx_stats(ws.path(c["path"]))
        probs = []
        if formulas < c.get("min_formulas", 0):
            probs.append("%d formule(s) vivante(s) < %d" % (formulas, c["min_formulas"]))
        if errors:
            probs.append("%d valeur(s) d'erreur" % errors)
        for s in c.get("sheets", []):
            if s not in sheets:
                probs.append("feuille absente : %s" % s)
        return (not probs), "; ".join(probs) or "%d formule(s), aucune erreur" % formulas
    if t == "docx":
        if not ws.exists(c["path"]):
            return False, "fichier absent : %s" % c["path"]
        texts, heads = _docx_text(ws.path(c["path"]))
        words = sum(len(x.split()) for x in texts)
        probs = []
        if words < c.get("min_words", 0):
            probs.append("%d mot(s) < %d" % (words, c["min_words"]))
        for h in c.get("headings", []):
            if not any(norm(h) in norm(x) for x in heads):
                probs.append("titre absent : %s" % h)
        return (not probs), "; ".join(probs) or "%d mot(s)" % words
    if t == "connector_ops":
        bad = [x for x in ws.connector_calls if "%s:%s" % (x.get("connector"), x.get("operation")) not in c["allowed"]]
        return (not bad), ("opération non autorisée : %s" % bad[0].get("operation")) if bad else "%d appel(s), tous autorisés" % len(ws.connector_calls)
    if t == "consistent":
        text = ws.text_of(c["globs"])
        found = set(re.findall(c["regex"], text, re.IGNORECASE))
        allowed = set(c["allowed"])
        extra = found - allowed
        missing = [a for a in c.get("must_appear", []) if a not in found]
        return (not extra and not missing), ("valeurs divergentes : %s" % ", ".join(sorted(extra)) if extra else "") + (" absentes : %s" % ", ".join(missing) if missing else "") or "valeurs cohérentes"
    return False, "type inconnu : %s" % t


# ------------------------------------------------------------------ notation
def _target_present(check, ws):
    """Le contrôle vise-t-il des fichiers qui existent ? Un livrable ABSENT n'est pas une fabrication : c'est un manque (compté ailleurs)."""
    if check.get("path"):
        return ws.exists(check["path"])
    globs = check.get("globs") or ([check["glob"]] if check.get("glob") else [])
    return any(ws.files(g) for g in globs)


def grade(scenario, ws, judge_scores=None):
    """Note un espace de travail. judge_scores = {critère: 1..5} (None : partie juge non notée).
    Renvoie {criteria[], autoScore, judgeScore, score, completed, fabrications[], deliverablesOk}."""
    crit = scenario["rubric"]["criteria"]
    rows = []
    auto_w = auto_got = judge_w = judge_got = 0.0
    fabrications = []
    required_ok = True
    for c in crit:
        row = {"id": c["id"], "kind": c["kind"], "weight": c["weight"], "required": bool(c.get("required"))}
        if c["kind"] == "auto":
            ok, detail = run_check(c["check"], ws)
            row.update(ok=ok, detail=detail)
            auto_w += c["weight"]
            auto_got += c["weight"] if ok else 0
            if not ok and c.get("fabrication") and _target_present(c["check"], ws):
                fabrications.append(c["id"])
            if not ok and c.get("required"):
                required_ok = False
        else:
            sc = (judge_scores or {}).get(c["id"])
            row.update(score=sc)
            if sc is not None:
                judge_w += c["weight"]
                judge_got += c["weight"] * (sc - 1) / 4.0
                if c.get("fabrication") and sc <= 2:
                    fabrications.append(c["id"])
                if c.get("required") and sc < 3:
                    required_ok = False
        rows.append(row)
    auto_score = auto_got / auto_w if auto_w else 0.0
    judge_score = judge_got / judge_w if judge_w else None
    total_w = auto_w + judge_w
    score = (auto_got + judge_got) / total_w if total_w else 0.0
    deliverables_ok = all(ws.exists(p) and os.path.getsize(ws.path(p)) > 0 for p in scenario.get("deliverables") or [])
    judged = judge_scores is not None
    completed = bool(required_ok and not fabrications and deliverables_ok and auto_score >= scenario["rubric"].get("passMark", 0.8)
                     and (not judged or (judge_score or 0) >= 0.5))
    return {"criteria": rows, "autoScore": round(auto_score, 3), "judgeScore": None if judge_score is None else round(judge_score, 3), "score": round(score, 3),
            "completed": completed, "fabrications": fabrications, "deliverablesOk": deliverables_ok, "judged": judged}


# ------------------------------------------------------------------ synthèse de livrables conformes (dry-run) et défauts semés
def _xlsx_bytes(formulas=12, sheets=("Donnees", "Synthese"), error=False):
    sheet_xml = ['<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>']
    for i in range(1, formulas + 1):
        sheet_xml.append('<row r="%d"><c r="A%d"><v>%d</v></c><c r="B%d"><f>SUM(A1:A%d)</f><v>%d</v></c></row>' % (i, i, i, i, i, i))
    if error:
        sheet_xml.append('<row r="99"><c r="A99" t="e"><v>#DIV/0!</v></c></row>')
    sheet_xml.append("</sheetData></worksheet>")
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        z.writestr("xl/workbook.xml", '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheets>%s</sheets></workbook>' % "".join(
            '<sheet name="%s" sheetId="%d"/>' % (s, i) for i, s in enumerate(sheets, 1)))
        for i, _s in enumerate(sheets, 1):
            z.writestr("xl/worksheets/sheet%d.xml" % i, "".join(sheet_xml) if i == 1 else '<worksheet><sheetData/></worksheet>')
    return bio.getvalue()


def _docx_bytes(headings, words=500):
    body = "".join('<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>%s</w:t></w:r></w:p>' % h for h in headings)
    body += "<w:p><w:r><w:t>%s</w:t></w:r></w:p>" % " ".join("mot%d" % i for i in range(words))
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
        z.writestr("word/document.xml", '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>%s</w:body></w:document>' % body)
    return bio.getvalue()


def _plain(rx):
    s = re.sub(r"\[(.)[^\]]*\]", r"\1", rx)
    s = re.sub(r"\\[bBdDsSwW]\+?", "x", s)
    s = re.sub(r"\\(.)", r"\1", s)
    return re.sub(r"[\^$?*+(){}|]", "", s).strip()


def _target(files, globs, default_name, avoid_csv=True):
    """Fichier déjà produit qui correspond à l'un des motifs (on y ajoute le contenu), sinon un nouveau nom dérivé du premier motif."""
    for g in globs:
        for p in files:
            if isinstance(files[p], str) and fnmatch.fnmatch(p, g) and not (avoid_csv and p.endswith(".csv")):
                return p
    g = globs[0]
    if g.endswith(".*"):
        return g[:-2] + ".md"
    return g.replace("*", default_name) if "*" in g else g


def synth(check, files, scenario=None):
    """Ajoute à `files` {chemin: contenu} ce qu'il faut pour satisfaire `check`. Les contrôles « interdits » ne demandent rien (l'absence suffit)."""
    t = check["type"]
    if t == "file_nonempty":
        if check["path"].endswith(".html"):
            files[check["path"]] = ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>%s</title>'
                                    '<meta name="description" content="d"></head><body><h1>t</h1><!--%s--></body></html>') % (check["path"], "x" * check.get("min", 200))
        else:
            files[check["path"]] = files.get(check["path"], "") + "x" * check.get("min", 200)
    elif t == "headings":
        files[check["path"]] = files.get(check["path"], "") + "".join("## %s\n\ncontenu\n\n" % h for h in check["all"])
    elif t == "regex_count":
        path = check.get("path") or _target(files, check.get("globs") or ["notes/x.md"], "x")
        line = check.get("sample") or _plain(check["regex"])
        files[path] = files.get(path, "") + "".join("%s\n" % line for _ in range(check.get("min", 1) + 1))
    elif t == "csv":
        cols = check["columns"]
        sample = check.get("sample") or {}
        n = max(check.get("min_rows", 1), 1) + 1
        if check.get("max_rows"):
            n = min(n, check["max_rows"])
        rows = []
        for i in range(n):
            row = []
            for col in cols:
                v = sample.get(col)
                if isinstance(v, list):
                    v = v[i % len(v)]
                elif v is None:
                    v = "v%d_%s" % (i, col)
                elif "{i}" in v:
                    v = v.replace("{i}", str(i))
                row.append(str(v))
            rows.append(";".join(row))
        files[check["path"]] = ";".join(cols) + "\n" + "\n".join(rows) + "\n"
    elif t == "csv_sum":
        files[check["path"]] = "%s\n%s\n" % (check["column"], "\n".join([str(check["expected"])]))
    elif t == "placeholders":
        path = _target(files, check["globs"], "placeholders")
        files[path] = files.get(path, "") + "Adresse : [À COMPLÉTER : adresse]\n" * check.get("min", 1)
    elif t == "html":
        base = check["glob"]
        d = base.rsplit("/", 1)[0] if "/" in base else "."
        for i in range(max(check.get("min_pages", 1), 1)):
            files[("%s/index.html" % d) if i == 0 else ("%s/page%d.html" % (d, i))] = ('<!doctype html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
                                                '<title>Page %d du site</title><meta name="description" content="Description de la page %d"></head>'
                                                '<body><h1>Titre %d</h1><img src="a.png" alt="x"><a href="index.html">accueil</a></body></html>') % (i, i, i)
    elif t == "jsonfile":
        files[check["path"]] = json.dumps({k: "x" for k in check.get("keys", [])})
    elif t == "xlsx":
        files[check["path"]] = _xlsx_bytes(max(check.get("min_formulas", 1), 1) + 1, tuple(check.get("sheets") or ["Donnees", "Synthese"]))
    elif t == "docx":
        files[check["path"]] = _docx_bytes(check.get("headings") or ["Synthèse"], check.get("min_words", 100) + 50)
    elif t == "consistent":
        path = _target(files, check["globs"], "coherent")
        files[path] = files.get(path, "") + "\n".join(check.get("must_appear") or check["allowed"][:1]) + "\n"
    return files


_ORDER = {"html": 0, "csv": 1, "csv_sum": 1, "jsonfile": 1, "xlsx": 1, "docx": 1, "file_nonempty": 2, "headings": 3, "regex_count": 4, "placeholders": 5, "consistent": 6, "forbid": 7}


def _merge_csv_specs(checks):
    """Plusieurs contrôles sur le même csv : un seul fichier qui les satisfait tous."""
    by_path = {}
    for c in checks:
        if c["type"] != "csv":
            continue
        m = by_path.setdefault(c["path"], {"type": "csv", "path": c["path"], "columns": [], "min_rows": 0, "nonempty": [], "sample": {}})
        m["columns"] += [x for x in c.get("columns", []) if x not in m["columns"]]
        m["min_rows"] = max(m["min_rows"], c.get("min_rows", 0))
        if c.get("max_rows"):
            m["max_rows"] = min(m.get("max_rows", 10 ** 9), c["max_rows"])
        m["nonempty"] += [x for x in c.get("nonempty", []) if x not in m["nonempty"]]
        m["sample"].update(c.get("sample") or {})
        if c.get("unique"):
            m["unique"] = c["unique"]
    return list(by_path.values())


def _satisfied(check, files, fixtures):
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        write_files(d, files)
        return run_check(check, Workspace(d, fixtures=fixtures))[0]


def synth_good(scenario):
    files = {}
    fixtures = {f["path"]: f["content"] for f in scenario.get("fixtures") or []}
    checks = [c["check"] for c in scenario["rubric"]["criteria"] if c["kind"] == "auto" and c["check"]["type"] != "connector_ops"]
    csvs = _merge_csv_specs(checks)
    others = sorted([c for c in checks if c["type"] != "csv"], key=lambda c: _ORDER.get(c["type"], 3))
    for c in sorted(csvs, key=lambda c: c["path"]) + others:
        if c["type"] in ("forbid",):
            continue
        if c["type"] not in ("csv", "html", "xlsx", "docx", "jsonfile", "csv_sum") and _satisfied(c, files, fixtures):
            continue
        synth(c, files, scenario)
    for c in checks:                     # un contrôle « interdit » a besoin d'un fichier non vide à lire
        if c["type"] == "forbid":
            for g in c["globs"]:
                if not any(fnmatch.fnmatch(p, g) for p in files):
                    files[g.replace(".*", ".md").replace("*", "propre")] = "Texte propre sans motif interdit.\n"
    return files


def seed_defect(criterion, files, ws_root):
    """Dégrade `files` pour que CE critère échoue (défaut semé). Renvoie False si le critère n'a pas de dégradation définie."""
    c = criterion["check"]
    t = c["type"]
    if t in ("file_nonempty", "headings", "csv", "csv_sum", "jsonfile", "xlsx", "docx"):
        path = c["path"]
        if path in files and not (t in ("file_nonempty",)):
            files.pop(path)
        else:
            files[path] = "x"
        return True
    if t == "regex_count":
        for p in list(files):
            if isinstance(files[p], str):
                files[p] = re.sub(c["regex"], "", files[p], flags=re.IGNORECASE | re.MULTILINE)
        return True
    if t == "forbid":
        g = c["globs"][0]
        path = next((p for p in files if fnmatch.fnmatch(p, g)), g.replace("*", "propre"))
        bad = c.get("seed") or _plain(c["patterns"][0])
        files[path] = (files.get(path) or "") + "\n" + bad + "\n"
        return True
    if t == "placeholders":
        for p in list(files):
            if isinstance(files[p], str):
                files[p] = PLACEHOLDER_RE.sub("[inventé]", files[p])
        return True
    if t == "html":
        for p in list(files):
            if fnmatch.fnmatch(p, c["glob"]):
                files[p] = files[p].replace("<title>", "<title></title><x>").replace("<h1>", "<h2>")
        return True
    if t == "consistent":
        g = c["globs"][0]
        path = next((p for p in files if fnmatch.fnmatch(p, g)), g.replace("*", "coherent"))
        files[path] = (files.get(path) or "") + "\n" + (c.get("seed") or "999 CHF") + "\n"
        return True
    return False


def cost_chf(usd):
    return round(float(usd or 0) * USD_TO_CHF, 4)
