"""Tests de dashboard/file_preview.py (apercu des fichiers produits par les Workers).
Lancer : python tests/file-preview/test_file_preview.py   (bibliotheque standard uniquement)
"""
import io
import os
import sys
import tempfile
import time
import unittest
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "dashboard"))
import file_preview as fp  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")
CT = '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'
MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG = "http://schemas.openxmlformats.org/package/2006/relationships"


def make_xlsx(path, sheets, extra_workbook_prefix=""):
    """sheets : liste de (nom, xml_sheetData). Cree un classeur minimal, sans valeurs en cache pour les formules."""
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CT)
        wb = extra_workbook_prefix + '<workbook xmlns="%s" xmlns:r="%s"><sheets>' % (MAIN, REL)
        rels = '<Relationships xmlns="%s">' % PKG
        for i, (name, data) in enumerate(sheets, 1):
            wb += '<sheet name="%s" sheetId="%d" r:id="rId%d"/>' % (name, i, i)
            rels += '<Relationship Id="rId%d" Type="x" Target="worksheets/sheet%d.xml"/>' % (i, i)
            z.writestr("xl/worksheets/sheet%d.xml" % i, '<worksheet xmlns="%s"><sheetData>%s</sheetData></worksheet>' % (MAIN, data))
        z.writestr("xl/workbook.xml", wb + "</sheets></workbook>")
        z.writestr("xl/_rels/workbook.xml.rels", rels + "</Relationships>")


def num(ref, v):
    return '<c r="%s"><v>%s</v></c>' % (ref, v)


def fml(ref, f):
    return '<c r="%s"><f>%s</f></c>' % (ref, f)


def txt(ref, s):
    return '<c r="%s" t="inlineStr"><is><t>%s</t></is></c>' % (ref, s)


def row(n, *cells):
    return '<row r="%d">%s</row>' % (n, "".join(cells))


class XlsxTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def p(self, name="t.xlsx"):
        return os.path.join(self.tmp, name)

    def one(self, rows_xml):
        make_xlsx(self.p(), [("Feuille1", rows_xml)])
        return fp.build_preview(self.p(), "t.xlsx")["sheets"][0]

    def test_real_worker_file_values_are_computed(self):
        r = fp.build_preview(os.path.join(FIXTURES, "real-worker-generated.xlsx"), "devis.xlsx")
        self.assertEqual(r["kind"], "table")
        devis = r["sheets"][0]
        self.assertEqual(devis["name"], "Devis")
        self.assertEqual(devis["rows"][0], ["Produit", "Prix HT (CHF)", "TVA 8.1 %", "Prix TTC"])
        self.assertEqual(devis["rows"][1][3], "107.019")
        self.assertEqual(devis["rows"][4][1], "699")               # =SUM(B2:B4)
        self.assertEqual(devis["computedCells"], devis["formulaCells"])
        self.assertEqual(len(r["sheets"]), 2)
        self.assertEqual(r["sheets"][1]["rows"][3][1], "VRAI")

    def test_arithmetic_functions_and_precedence(self):
        s = self.one(row(1, num("A1", 2), num("B1", 3), num("C1", 4),
                         fml("D1", "A1+B1*C1"), fml("E1", "(A1+B1)*C1"), fml("F1", "-A1^2"), fml("G1", "A1^B1"), fml("H1", "B1*8.1%"),
                         fml("I1", "AVERAGE(A1:C1)"), fml("J1", "MAX(A1:C1)-MIN(A1:C1)"), fml("K1", "COUNT(A1:C1)"), fml("L1", "ABS(A1-C1)")))
        self.assertEqual(s["rows"][0][3:], ["14", "20", "4", "8", "0.243", "3", "2", "3", "2"])

    def test_round_half_away_from_zero(self):
        s = self.one(row(1, fml("A1", "ROUND(2.5,0)"), fml("B1", "ROUND(0.125,2)"), fml("C1", "ROUND(-2.5,0)"), fml("D1", "ROUND(1234.5,-2)")))
        self.assertEqual(s["rows"][0], ["3", "0.13", "-3", "1200"])

    def test_formula_chain_uses_other_formulas(self):
        s = self.one(row(1, num("A1", 10), fml("B1", "A1*2"), fml("C1", "B1+A1"), fml("D1", "SUM(A1:C1)")))
        self.assertEqual(s["rows"][0], ["10", "20", "30", "60"])

    def test_unsupported_stays_as_formula(self):
        s = self.one(row(1, num("A1", 1), txt("B1", "abc"),
                         fml("C1", "A1/0"), fml("D1", "Autre!A1+1"), fml("E1", "B1+1"), fml("F1", "VLOOKUP(A1,A1:B1,2,0)"), fml("G1", "IF(A1>0,1,2)")))
        self.assertEqual(s["rows"][0][2:], ["=A1/0", "=Autre!A1+1", "=B1+1", "=VLOOKUP(A1,A1:B1,2,0)", "=IF(A1>0,1,2)"])
        self.assertEqual(s["computedCells"], 0)

    def test_cycle_does_not_hang(self):
        s = self.one(row(1, fml("A1", "B1+1"), fml("B1", "A1+1"), num("C1", 5), fml("D1", "C1+1")))
        self.assertEqual(s["rows"][0], ["=B1+1", "=A1+1", "5", "6"])

    def test_deep_chain_and_huge_range_are_bounded(self):
        rows = "".join(row(i, fml("A%d" % i, "A%d+1" % (i + 1) if i < 3000 else "1")) for i in range(1, 3001))
        t0 = time.time()
        s = self.one(rows)
        self.assertEqual(s["kind"] if "kind" in s else "ok", "ok")
        self.assertLess(time.time() - t0, 10)
        t0 = time.time()
        s = self.one(row(1, fml("A1", "SUM(A2:ZZ99999)"), num("B2", 1)))
        self.assertEqual(s["rows"][0][0], "=SUM(A2:ZZ99999)")      # plage geante : refusee, pas parcourue
        self.assertLess(time.time() - t0, 3)

    def test_power_guards(self):
        s = self.one(row(1, fml("A1", "(-8)^0.5"), fml("B1", "10^400"), fml("C1", "2^10")))
        self.assertEqual(s["rows"][0], ["=(-8)^0.5", "=10^400", "1024"])

    def test_cached_values_win_over_formulas(self):
        s = self.one(row(1, '<c r="A1"><f>1+1</f><v>42</v></c>'))
        self.assertEqual(s["rows"][0], ["42"])

    def test_truncation_flagged(self):
        rows = "".join(row(i, num("A%d" % i, i)) for i in range(1, fp.MAX_ROWS + 50))
        s = self.one(rows)
        self.assertTrue(s["truncated"])
        self.assertLessEqual(len(s["rows"]), fp.MAX_ROWS)

    def test_truncated_sheet_does_not_compute(self):
        wide = "".join(num("%s1" % c, 1) for c in "ABC") + fml("D1", "SUM(A1:C1)")
        s = self.one(row(1, wide, '<c r="AZ1"><v>9</v></c>'))       # colonne AZ > MAX_COLS : feuille tronquee
        self.assertTrue(s["truncated"])
        self.assertEqual(s["rows"][0][3], "=SUM(A1:C1)")


class SecurityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(self._restore, dict(zm=fp.MAX_ZIP_MEMBERS, zu=fp.MAX_ZIP_UNCOMPRESSED))

    @staticmethod
    def _restore(saved):
        fp.MAX_ZIP_MEMBERS, fp.MAX_ZIP_UNCOMPRESSED = saved["zm"], saved["zu"]

    def p(self, name):
        return os.path.join(self.tmp, name)

    def test_doctype_and_entities_are_rejected(self):
        bomb = '<?xml version="1.0"?><!DOCTYPE lolz [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;">]>'
        make_xlsx(self.p("a.xlsx"), [("S", row(1, num("A1", 1)))], extra_workbook_prefix=bomb)
        with self.assertRaises(fp.PreviewError):
            fp.build_preview(self.p("a.xlsx"), "a.xlsx")
        with zipfile.ZipFile(self.p("b.docx"), "w") as z:
            z.writestr("word/document.xml", bomb + '<w:document xmlns:w="x"><w:body/></w:document>')
        with self.assertRaises(fp.PreviewError):
            fp.build_preview(self.p("b.docx"), "b.docx")
        with zipfile.ZipFile(self.p("c.pptx"), "w") as z:
            z.writestr("ppt/slides/slide1.xml", bomb + "<p/>")
        with self.assertRaises(fp.PreviewError):
            fp.build_preview(self.p("c.pptx"), "c.pptx")

    def test_zip_member_cap(self):
        make_xlsx(self.p("a.xlsx"), [("S", row(1, num("A1", 1)))])
        fp.MAX_ZIP_MEMBERS = 2
        with self.assertRaises(fp.PreviewError):
            fp.build_preview(self.p("a.xlsx"), "a.xlsx")

    def test_zip_uncompressed_cap(self):
        make_xlsx(self.p("a.xlsx"), [("S", row(1, num("A1", 1)))])
        fp.MAX_ZIP_UNCOMPRESSED = 100
        with self.assertRaises(fp.PreviewError):
            fp.build_preview(self.p("a.xlsx"), "a.xlsx")

    def test_corrupt_and_wrong_type_files(self):
        for name, payload in (("x.xlsx", b"ceci n'est pas un zip"), ("x.docx", b"PK\x03\x04garbage"), ("x.pptx", b"")):
            with open(self.p(name), "wb") as f:
                f.write(payload)
            with self.assertRaises(fp.PreviewError):
                fp.build_preview(self.p(name), name)
        with zipfile.ZipFile(self.p("empty.xlsx"), "w") as z:
            z.writestr("hello.txt", "x")
        with self.assertRaises(fp.PreviewError):
            fp.build_preview(self.p("empty.xlsx"), "empty.xlsx")

    def test_oversized_xml_member_refused(self):
        with zipfile.ZipFile(self.p("big.docx"), "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("word/document.xml", b"<a>" + b"x" * (fp.MAX_XML_BYTES + 10) + b"</a>")
        with self.assertRaises(fp.PreviewError):
            fp.build_preview(self.p("big.docx"), "big.docx")

    def test_inline_types_are_a_strict_allowlist(self):
        self.assertEqual(fp.inline_content_type("a.PDF"), "application/pdf")
        self.assertEqual(fp.inline_content_type("a.png"), "image/png")
        for bad in ("a.svg", "a.html", "a.htm", "a.xml", "a.js", "a.txt", "a.xlsx", "noext", ""):
            self.assertIsNone(fp.inline_content_type(bad), bad)


class OtherFormatsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def p(self, name):
        return os.path.join(self.tmp, name)

    def test_real_docx(self):
        r = fp.build_preview(os.path.join(FIXTURES, "real-worker-generated.docx"), "x.docx")
        self.assertEqual(r["kind"], "document")
        types = [b["type"] for b in r["blocks"]]
        self.assertIn("h", types)
        self.assertIn("p", types)
        self.assertIn("table", types)

    def test_docx_script_text_is_data_not_markup(self):
        body = ('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>'
                '&lt;script&gt;alert(1)&lt;/script&gt;</w:t></w:r></w:p></w:body></w:document>')
        with zipfile.ZipFile(self.p("s.docx"), "w") as z:
            z.writestr("word/document.xml", body)
        r = fp.build_preview(self.p("s.docx"), "s.docx")
        self.assertEqual(r["blocks"][0]["text"], "<script>alert(1)</script>")       # texte brut : c'est le navigateur (textContent) qui l'echappe

    def test_real_pptx(self):
        r = fp.build_preview(os.path.join(FIXTURES, "real-worker-generated.pptx"), "x.pptx")
        self.assertEqual(r["kind"], "slides")
        self.assertGreaterEqual(len(r["slides"]), 1)
        self.assertTrue(r["slides"][0]["lines"])

    def test_csv_semicolon_and_truncation(self):
        with open(self.p("a.csv"), "w", encoding="utf-8") as f:
            f.write("Produit;Prix\nCafé;3,5\n" + "".join("x;%d\n" % i for i in range(400)))
        r = fp.build_preview(self.p("a.csv"), "a.csv")
        s = r["sheets"][0]
        self.assertEqual(s["rows"][1], ["Café", "3,5"])
        self.assertTrue(s["truncated"])
        self.assertLessEqual(len(s["rows"]), fp.MAX_ROWS)

    def test_csv_cp1252(self):
        with open(self.p("b.csv"), "wb") as f:
            f.write("Prénom,Ville\nÉlodie,Genève\n".encode("cp1252"))
        r = fp.build_preview(self.p("b.csv"), "b.csv")
        self.assertEqual(r["sheets"][0]["rows"][1], ["Élodie", "Genève"])

    def test_text_truncation(self):
        with open(self.p("a.txt"), "w", encoding="utf-8") as f:
            f.write("a" * (fp.MAX_TEXT_CHARS + 500))
        r = fp.build_preview(self.p("a.txt"), "a.txt")
        self.assertEqual(r["kind"], "text")
        self.assertTrue(r["truncated"])
        self.assertEqual(len(r["text"]), fp.MAX_TEXT_CHARS)

    def test_pdf_image_and_unknown_kinds(self):
        for name, kind in (("a.pdf", "pdf"), ("a.png", "image"), ("a.JPG", "image"), ("a.webp", "image"), ("a.bin", "none"), ("a.svg", "none"), ("a.html", "none")):
            with open(self.p(name), "wb") as f:
                f.write(b"x")
            self.assertEqual(fp.build_preview(self.p(name), name)["kind"], kind, name)


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=1).result
    sys.exit(0 if result.wasSuccessful() else 1)
