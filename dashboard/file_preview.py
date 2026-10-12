"""Apercu des fichiers produits par les Workers (2026-10-12), avant de les telecharger.

Demande de Kader : "je ne vois pas le fichier a telecharger et au moins il faut avoir un apercu avant de pouvoir telecharger".
Lecture SEULE, bibliotheque standard uniquement (aucun Office, aucune commande externe), bornee en taille et en temps :
  - .xlsx / .xlsm : feuilles (5 max), 200 lignes x 30 colonnes, valeur en cache sinon la formule ("=SOMME(...)")
  - .docx        : titres, paragraphes et tableaux (400 blocs max)
  - .pptx        : texte de chaque diapositive (60 max)
  - .csv / .tsv  : tableau (200 x 30)
  - .txt .md .json : debut du texte
  - .pdf / images (png, jpg, gif, webp) : le navigateur les affiche lui-meme (route ?inline=1 du serveur)
Les fichiers sont ecrits par un modele : on les traite comme NON FIABLES (archives plafonnees, XML avec DOCTYPE/ENTITY refuse pour eviter
les attaques par expansion d'entites, aucune execution, aucun lien suivi, tout le texte est ensuite echappe par le navigateur).
"""
import csv
import io
import math
import os
import re
import zipfile
import xml.etree.ElementTree as ET
from decimal import Decimal, ROUND_HALF_UP

MAX_ZIP_MEMBERS = 500
MAX_ZIP_UNCOMPRESSED = 80 * 1024 * 1024
MAX_XML_BYTES = 12 * 1024 * 1024
MAX_SHEETS = 5
MAX_ROWS = 200
MAX_COLS = 30
MAX_CELLS = 5000
MAX_BLOCKS = 400
MAX_TEXT_CHARS = 30000
MAX_SLIDES = 60
INLINE_TYPES = {".pdf": "application/pdf", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}

NS_MAIN = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
NS_REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
NS_PKG_REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"
NS_W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
NS_A = "{http://schemas.openxmlformats.org/drawingml/2006/main}"


class PreviewError(Exception):
    pass


def inline_content_type(filename):
    return INLINE_TYPES.get(os.path.splitext(filename or "")[1].lower())


def _open_zip(path):
    try:
        z = zipfile.ZipFile(path)
    except (zipfile.BadZipFile, OSError):
        raise PreviewError("Fichier illisible ou abime.")
    infos = z.infolist()
    if len(infos) > MAX_ZIP_MEMBERS or sum(i.file_size for i in infos) > MAX_ZIP_UNCOMPRESSED:
        z.close()
        raise PreviewError("Fichier trop volumineux pour l'apercu.")
    return z


def _read_xml(z, name):
    try:
        info = z.getinfo(name)
    except KeyError:
        return None
    if info.file_size > MAX_XML_BYTES:
        raise PreviewError("Contenu trop volumineux pour l'apercu.")
    data = z.read(name)
    head = data[:4096].upper()
    if b"<!DOCTYPE" in head or b"<!ENTITY" in data[:65536].upper():      # expansion d'entites : jamais traitee
        raise PreviewError("Contenu non pris en charge.")
    try:
        return ET.fromstring(data)
    except ET.ParseError:
        raise PreviewError("Contenu illisible.")


def _col_index(ref):
    letters = re.match(r"[A-Z]+", ref or "")
    n = 0
    for ch in (letters.group(0) if letters else "A"):
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def _fmt_number(text):
    try:
        f = float(text)
    except (TypeError, ValueError):
        return text
    if f == int(f) and abs(f) < 1e15:
        return str(int(f))
    return ("%.10g" % f)


def _shared_strings(z):
    root = _read_xml(z, "xl/sharedStrings.xml")
    out = []
    if root is None:
        return out
    for si in root.findall(NS_MAIN + "si"):
        out.append("".join(t.text or "" for t in si.iter(NS_MAIN + "t")))
    return out


# ----------------------------------------------------------------------------------------------------------------------------
# Calcul des formules courantes pour l'apercu : un fichier genere par du code n'a PAS de valeur en cache (openpyxl n'en ecrit pas) et
# Excel ne les calcule qu'a l'ouverture ; sans cela l'apercu d'un devis afficherait "=B2*0.081" partout. Evaluateur minimal et SUR
# (analyse syntaxique, aucun eval) : nombres, references de la MEME feuille, + - * / ^, parentheses, SUM / AVERAGE / MIN / MAX / COUNT /
# ROUND / ABS. Tout le reste (autres feuilles, autres fonctions, texte, erreurs) reste affiche comme formule.
MAX_FORMULA_CHARS = 500
MAX_RANGE_CELLS = 20000
_TOKEN_RE = re.compile(r"\s*(?:(\d+(?:\.\d+)?(?:[eE][+-]?\d+)?%?)|(\$?[A-Za-z]{1,3}\$?\d+(?::\$?[A-Za-z]{1,3}\$?\d+)?)|([A-Za-z][A-Za-z0-9.]*)\(|([-+*/^(),]))")


class _FormulaError(Exception):
    pass


def _cell_key(ref):
    m = re.match(r"\$?([A-Za-z]{1,3})\$?(\d+)$", ref)
    if not m:
        raise _FormulaError("ref")
    return (int(m.group(2)) - 1, _col_index(m.group(1).upper()))


class _Evaluator:
    def __init__(self, values, formulas):
        self.values, self.formulas, self.cache, self.stack = values, formulas, {}, set()
        self.toks, self.i = [], 0

    def cell(self, key):
        if key in self.cache:
            return self.cache[key]
        if key in self.formulas:
            if key in self.stack:
                raise _FormulaError("cycle")
            self.stack.add(key)
            try:
                v = self.run(self.formulas[key])
            finally:
                self.stack.discard(key)
            self.cache[key] = v
            return v
        raw = self.values.get(key)
        if raw is None or raw == "":
            return 0.0
        try:
            v = float(raw)
        except (TypeError, ValueError):
            raise _FormulaError("text")
        if not math.isfinite(v):
            raise _FormulaError("nan")
        return v

    def numbers_in(self, ref):
        a, _, b = ref.partition(":")
        k1, k2 = _cell_key(a), _cell_key(b or a)
        r_lo, r_hi, c_lo, c_hi = min(k1[0], k2[0]), max(k1[0], k2[0]), min(k1[1], k2[1]), max(k1[1], k2[1])
        if (r_hi - r_lo + 1) * (c_hi - c_lo + 1) > MAX_RANGE_CELLS:
            raise _FormulaError("range")
        out = []
        for r in range(r_lo, r_hi + 1):
            for c in range(c_lo, c_hi + 1):
                if (r, c) in self.formulas:
                    out.append(self.cell((r, c)))
                elif self.values.get((r, c)) not in (None, ""):
                    try:
                        out.append(float(self.values[(r, c)]))
                    except (TypeError, ValueError):
                        pass                          # texte dans une plage : ignore, comme Excel pour SUM / AVERAGE / MIN / MAX
        return out

    def run(self, formula):
        text = formula.lstrip("=").strip()
        if len(text) > MAX_FORMULA_CHARS or "!" in text or '"' in text or "'" in text:
            raise _FormulaError("unsupported")
        toks, pos = [], 0
        while pos < len(text):
            m = _TOKEN_RE.match(text, pos)
            if not m:
                raise _FormulaError("syntax")
            pos = m.end()
            num, ref, fn, op = m.groups()
            toks.append(("num", num) if num else ("ref", ref) if ref else ("fn", fn.upper()) if fn else ("op", op))
        saved = (self.toks, self.i)                   # evaluation imbriquee (une formule qui reference une autre) : on restaure l'etat
        self.toks, self.i = toks, 0
        try:
            v = self.expr()
            if self.i != len(self.toks):
                raise _FormulaError("syntax")
        finally:
            self.toks, self.i = saved
        if not math.isfinite(v):
            raise _FormulaError("nan")
        return v

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def eat(self, op=None):
        t = self.peek()
        if op and t != ("op", op):
            raise _FormulaError("syntax")
        self.i += 1
        return t

    def expr(self):
        v = self.term()
        while self.peek() in (("op", "+"), ("op", "-")):
            o = self.eat()[1]
            r = self.term()
            v = v + r if o == "+" else v - r
        return v

    def term(self):
        v = self.power()
        while self.peek() in (("op", "*"), ("op", "/")):
            o = self.eat()[1]
            r = self.power()
            if o == "/" and r == 0:
                raise _FormulaError("div0")
            v = v * r if o == "*" else v / r
        return v

    def power(self):
        v = self.unary()
        if self.peek() == ("op", "^"):
            self.eat()
            e = self.unary()
            if abs(e) > 50 or abs(v) > 1e9 or (v < 0 and e != int(e)):
                raise _FormulaError("pow")
            v = v ** e
        return v

    def unary(self):
        if self.peek() in (("op", "-"), ("op", "+")):
            s = -1.0 if self.eat()[1] == "-" else 1.0
            return s * self.unary()
        return self.primary()

    def primary(self):
        kind, val = self.peek()
        if kind == "num":
            self.eat()
            return float(val[:-1]) / 100.0 if val.endswith("%") else float(val)
        if kind == "ref":
            self.eat()
            if ":" in val:
                raise _FormulaError("range")
            return self.cell(_cell_key(val))
        if kind == "op" and val == "(":
            self.eat()
            v = self.expr()
            self.eat(")")
            return v
        if kind == "fn":
            self.eat()
            args = []
            while True:
                if self.peek() == ("op", ")"):
                    self.eat()
                    break
                t = self.peek()
                if t[0] == "ref" and ":" in t[1]:
                    self.eat()
                    args.extend(self.numbers_in(t[1]))
                else:
                    args.append(self.expr())
                if self.peek() == ("op", ","):
                    self.eat()
                elif self.peek() != ("op", ")"):
                    raise _FormulaError("syntax")
            if val == "SUM":
                return float(sum(args))
            if val == "AVERAGE" and args:
                return sum(args) / len(args)
            if val == "MIN" and args:
                return min(args)
            if val == "MAX" and args:
                return max(args)
            if val == "COUNT":
                return float(len(args))
            if val == "ABS" and len(args) == 1:
                return abs(args[0])
            if val == "ROUND" and len(args) in (1, 2):
                d = int(args[1]) if len(args) == 2 else 0
                if abs(d) > 15 or not math.isfinite(args[0]):
                    raise _FormulaError("round")
                q = Decimal(1).scaleb(-d)             # arrondi "demi vers l'exterieur" comme Excel (round() de Python est bancaire)
                return float(Decimal(repr(args[0])).quantize(q, rounding=ROUND_HALF_UP))
            raise _FormulaError("fn")
        raise _FormulaError("syntax")


def _evaluate_formulas(values, formulas):
    """{(ligne, colonne): valeur} pour les formules que l'evaluateur sait resoudre ; les autres sont absentes (affichees telles quelles)."""
    ev, done = _Evaluator(values, formulas), {}
    for key in list(formulas):
        try:
            done[key] = ev.cell(key)
        except (_FormulaError, OverflowError, ZeroDivisionError, ValueError, ArithmeticError, RecursionError):
            continue
    return done


def preview_xlsx(path):
    z = _open_zip(path)
    try:
        wb = _read_xml(z, "xl/workbook.xml")
        if wb is None:
            raise PreviewError("Classeur illisible.")
        rels = _read_xml(z, "xl/_rels/workbook.xml.rels")
        targets = {}
        if rels is not None:
            for r in rels.findall(NS_PKG_REL + "Relationship"):
                targets[r.get("Id")] = r.get("Target") or ""
        shared = _shared_strings(z)
        sheets = []
        sheets_el = wb.find(NS_MAIN + "sheets")
        for sh in (sheets_el if sheets_el is not None else []):
            if len(sheets) >= MAX_SHEETS:
                break
            target = targets.get(sh.get(NS_REL + "id"), "")
            target = target.lstrip("/")
            member = target if target.startswith("xl/") else "xl/" + target
            root = _read_xml(z, member)
            if root is None:
                continue
            rows, formula_cells, cells, truncated = [], 0, 0, False
            values, formulas, shown = {}, {}, []                   # valeurs brutes, formules sans valeur en cache, cellules a remplacer par leur resultat
            data = root.find(NS_MAIN + "sheetData")
            for row in (data if data is not None else []):
                if len(rows) >= MAX_ROWS or cells >= MAX_CELLS:
                    truncated = True
                    break
                r_idx = int(row.get("r") or (len(rows) + 1)) - 1
                while len(rows) < r_idx and len(rows) < MAX_ROWS:       # lignes vides entre deux lignes remplies
                    rows.append([])
                line = []
                for c in row.findall(NS_MAIN + "c"):
                    ci = _col_index(c.get("r"))
                    if ci >= MAX_COLS:
                        truncated = True
                        continue
                    while len(line) < ci:
                        line.append("")
                    t = c.get("t")
                    v = c.find(NS_MAIN + "v")
                    f = c.find(NS_MAIN + "f")
                    value = ""
                    if t == "s" and v is not None and (v.text or "").isdigit() and int(v.text) < len(shared):
                        value = shared[int(v.text)]
                    elif t == "inlineStr":
                        value = "".join(x.text or "" for x in c.iter(NS_MAIN + "t"))
                    elif t == "b" and v is not None:
                        value = "VRAI" if (v.text or "") == "1" else "FAUX"
                    elif v is not None and v.text is not None:
                        value = v.text if t in ("str", "e") else _fmt_number(v.text)
                    elif f is not None and (f.text or "").strip():
                        value = "=" + f.text.strip()                       # formule sans valeur en cache (cas courant des fichiers generes par code)
                        formulas[(r_idx, ci)] = value
                    if f is not None:
                        formula_cells += 1
                    if (r_idx, ci) not in formulas:
                        values[(r_idx, ci)] = value
                    shown.append((r_idx, ci, len(rows)))
                    line.append(value[:500])
                    cells += 1
                rows.append(line)
            computed = {} if (truncated or not formulas) else _evaluate_formulas(values, formulas)   # feuille tronquee : references hors cadre, on ne calcule pas
            for (r_idx, ci, ri) in shown:
                if (r_idx, ci) in computed and ri < len(rows) and ci < len(rows[ri]):
                    rows[ri][ci] = _fmt_number(repr(computed[(r_idx, ci)]))
            while rows and not any(rows[-1]):
                rows.pop()
            sheets.append({"name": (sh.get("name") or "Feuille")[:80], "rows": rows, "truncated": truncated,
                           "formulaCells": formula_cells, "computedCells": len(computed)})
        if not sheets:
            raise PreviewError("Aucune feuille lisible.")
        return {"kind": "table", "sheets": sheets}
    finally:
        z.close()


def _w_text(el):
    parts = []
    for node in el.iter():
        if node.tag == NS_W + "t" and node.text:
            parts.append(node.text)
        elif node.tag in (NS_W + "tab",):
            parts.append("\t")
        elif node.tag in (NS_W + "br",):
            parts.append("\n")
    return "".join(parts)


def preview_docx(path):
    z = _open_zip(path)
    try:
        root = _read_xml(z, "word/document.xml")
        body = root.find(NS_W + "body") if root is not None else None
        if body is None:
            raise PreviewError("Document illisible.")
        blocks, chars = [], 0
        for child in body:
            if len(blocks) >= MAX_BLOCKS or chars >= MAX_TEXT_CHARS:
                break
            if child.tag == NS_W + "p":
                text = _w_text(child).strip()
                if not text:
                    continue
                style = child.find(NS_W + "pPr/" + NS_W + "pStyle")
                sval = (style.get(NS_W + "val") if style is not None else "") or ""
                kind = "h" if re.match(r"(?i)^(heading|titre|title)", sval) else "p"
                blocks.append({"type": kind, "text": text[:3000]})
                chars += len(text)
            elif child.tag == NS_W + "tbl":
                rows = []
                for tr in child.iter(NS_W + "tr"):
                    if len(rows) >= MAX_ROWS:
                        break
                    rows.append([_w_text(tc).strip()[:300] for tc in tr.findall(NS_W + "tc")][:MAX_COLS])
                if rows:
                    blocks.append({"type": "table", "rows": rows})
                    chars += sum(len(c) for r in rows for c in r)
        return {"kind": "document", "blocks": blocks, "truncated": len(blocks) >= MAX_BLOCKS or chars >= MAX_TEXT_CHARS}
    finally:
        z.close()


def preview_pptx(path):
    z = _open_zip(path)
    try:
        names = sorted((n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n)), key=lambda n: int(re.findall(r"\d+", n)[0]))
        slides = []
        for n in names[:MAX_SLIDES]:
            root = _read_xml(z, n)
            texts = []
            for p in (root.iter(NS_A + "p") if root is not None else []):
                line = "".join(t.text or "" for t in p.iter(NS_A + "t")).strip()
                if line:
                    texts.append(line[:500])
            slides.append({"n": len(slides) + 1, "lines": texts[:60]})
        if not slides:
            raise PreviewError("Aucune diapositive lisible.")
        return {"kind": "slides", "slides": slides, "truncated": len(names) > MAX_SLIDES}
    finally:
        z.close()


def _decode(raw):
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def preview_text(path, ext):
    with open(path, "rb") as f:
        raw = f.read(400000)
    text = _decode(raw)
    if ext in (".csv", ".tsv"):
        delim = "\t" if ext == ".tsv" else (";" if text[:2000].count(";") > text[:2000].count(",") else ",")
        rows = []
        for row in csv.reader(io.StringIO(text), delimiter=delim):
            rows.append([c[:500] for c in row[:MAX_COLS]])
            if len(rows) >= MAX_ROWS:
                break
        return {"kind": "table", "sheets": [{"name": "Données", "rows": rows, "truncated": len(rows) >= MAX_ROWS, "formulaCells": 0}]}
    return {"kind": "text", "text": text[:MAX_TEXT_CHARS], "truncated": len(text) > MAX_TEXT_CHARS}


def build_preview(path, filename):
    """Aperçu JSON d'un fichier de mission. Ne leve jamais autre chose que PreviewError."""
    ext = os.path.splitext(filename or "")[1].lower()
    try:
        if ext in (".xlsx", ".xlsm"):
            return preview_xlsx(path)
        if ext == ".docx":
            return preview_docx(path)
        if ext == ".pptx":
            return preview_pptx(path)
        if ext in (".csv", ".tsv", ".txt", ".md", ".json"):
            return preview_text(path, ext)
        if ext == ".pdf":
            return {"kind": "pdf"}
        if ext in INLINE_TYPES:
            return {"kind": "image"}
    except PreviewError:
        raise
    except Exception:
        raise PreviewError("Aperçu indisponible pour ce fichier.")
    return {"kind": "none"}
