# -*- coding: utf-8 -*-
"""Contrôles typés (dashboard/project_checks.py) et vérification (dashboard/projects_verify.py) : détection de défauts semés, preuves résolues par
le moteur, aucun PASS sans preuve, définition de « terminé », rapport final. Aucun modèle, aucun réseau.

    python tests/projects/test_verify.py"""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import project_checks as pc  # noqa: E402
import projects_verify as pv  # noqa: E402

FIXTURES = os.path.join(REPO, "tests", "file-preview", "fixtures")


class Base(unittest.TestCase):
    def setUp(self):
        self.proj = tempfile.mkdtemp(prefix="bkver-")
        self.addCleanup(shutil.rmtree, self.proj, True)
        self.ws = os.path.join(self.proj, "workspace")
        os.makedirs(self.ws)

    def put(self, rel, content):
        full = os.path.join(self.ws, *rel.split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as f:
            f.write(content if isinstance(content, bytes) else content.encode("utf-8"))

    def run_check(self, check, out_dir=None):
        return pc.run_check(pc.CheckCtx(self.ws, self.proj), check, out_dir=out_dir)

    def rules(self, res):
        return {f["rule"] for f in res["findings"] if f["severity"] == "error"}


class TypedChecks(Base):
    def test_file_exists(self):
        self.put("site/index.html", "<h1>x</h1>")
        self.put("site/empty.html", b"")
        self.assertTrue(self.run_check({"type": "file_exists", "path": "site/index.html"})["ok"])
        self.assertIn("file.missing", self.rules(self.run_check({"type": "file_exists", "path": "site/absent.html"})))
        self.assertIn("file.too_small", self.rules(self.run_check({"type": "file_exists", "path": "site/empty.html"})))
        self.assertIn("file.too_small", self.rules(self.run_check({"type": "file_exists", "path": "site/index.html", "minBytes": 1000})))
        for hostile in ("../state.json", "/etc/passwd", "site/../../x", "a\\b", ""):
            r = self.run_check({"type": "file_exists", "path": hostile})
            self.assertFalse(r["ok"], hostile)

    def test_results_are_written_and_reloadable_but_ids_are_validated(self):
        self.put("a.md", "x")
        out = os.path.join(self.proj, "verification", "1", "checks")
        r = self.run_check({"type": "file_exists", "path": "a.md"}, out_dir=out)
        self.assertTrue(r["id"].startswith("CHK-"))
        self.assertEqual(pc.load_check(out, r["id"])["ok"], True)
        self.assertEqual(r["inputs"][0]["path"], "a.md")
        self.assertEqual(len(r["inputs"][0]["sha256"]), 64)
        for bad in ("../x", "CHK-ZZZZZZZZ", "CHK-1234", None, 12, "chk-00000000"):
            self.assertIsNone(pc.load_check(out, bad))

    def test_unknown_type_and_garbage_never_raise(self):
        for check in ({"type": "telepathy"}, {}, None, {"type": 12}, {"type": "csv_check", "path": "a.md", "columns": 5}):
            r = self.run_check(check)
            self.assertFalse(r["ok"], check)

    def test_file_contains_and_the_regex_guard(self):
        self.put("site/index.html", "<title>Cabinet de physiothérapie</title> 021 555 12 34")
        ok = self.run_check({"type": "file_contains", "path": "site/index.html", "mustContain": ["cabinet", "re:\\d{3} \\d{3} \\d{2} \\d{2}"], "mustNotContain": ["lorem ipsum"]})
        self.assertTrue(ok["ok"], ok["findings"])
        self.assertIn("content.missing", self.rules(self.run_check({"type": "file_contains", "path": "site/index.html", "mustContain": ["ostéopathe"]})))
        self.assertIn("content.forbidden", self.rules(self.run_check({"type": "file_contains", "path": "site/index.html", "mustNotContain": ["Cabinet"]})))
        self.assertIn("check.empty", self.rules(self.run_check({"type": "file_contains", "path": "site/index.html"})))
        self.put("big.txt", "a" * 100000 + "!")
        t0 = time.time()
        r = self.run_check({"type": "file_contains", "path": "big.txt", "mustContain": ["re:(a+)+$"]})            # retour catastrophique : refuse, ne bloque pas
        self.assertLess(time.time() - t0, 3)
        self.assertFalse(r["ok"])
        t0 = time.time()
        r = self.run_check({"type": "count_matches", "path": "big.txt", "regex": "(a+)+$"})
        self.assertLess(time.time() - t0, 3)
        self.assertIn("check.invalid", self.rules(r))
        r = self.run_check({"type": "json_schema", "path": "big.txt", "schema": {}})
        self.assertFalse(r["ok"])

    def test_json_schema_pattern_is_guarded_too(self):
        self.put("d.json", json.dumps({"email": "a" * 5000 + "!"}))
        t0 = time.time()
        r = self.run_check({"type": "json_schema", "path": "d.json", "schema": {"type": "object", "properties": {"email": {"type": "string", "pattern": "(a+)+$"}}}})
        self.assertLess(time.time() - t0, 3)
        self.assertFalse(r["ok"])

    def test_count_matches(self):
        self.put("posts.md", "## Jour 1\n## Jour 2\n## Jour 3\n")
        self.assertTrue(self.run_check({"type": "count_matches", "path": "posts.md", "regex": "^## Jour \\d+", "min": 3})["ok"])
        self.assertIn("count.too_low", self.rules(self.run_check({"type": "count_matches", "path": "posts.md", "regex": "^## Jour \\d+", "min": 30})))
        self.assertIn("check.invalid", self.rules(self.run_check({"type": "count_matches", "path": "posts.md", "regex": "("})))

    def test_csv_check(self):
        self.put("prospects.csv", "nom,email,source_url\nAcme,a@acme.ch,https://acme.ch\nBeta,b@beta.ch,https://beta.ch\nGamma,,https://g.ch\nBeta,b2@beta.ch,\n")
        ok = self.run_check({"type": "csv_check", "path": "prospects.csv", "columns": ["nom", "email", "source_url"], "minRows": 4, "unique": "nom"})
        self.assertIn("csv.duplicates", self.rules(ok))                                                      # « Beta » deux fois
        ok = self.run_check({"type": "csv_check", "path": "prospects.csv", "columns": ["nom", "email"], "minRows": 4})
        self.assertTrue(ok["ok"], ok["findings"])
        self.assertIn("csv.empty_cells", self.rules(self.run_check({"type": "csv_check", "path": "prospects.csv", "noEmpty": ["source_url"]})))
        self.assertIn("csv.column_missing", self.rules(self.run_check({"type": "csv_check", "path": "prospects.csv", "columns": ["telephone"]})))
        self.assertIn("csv.too_few_rows", self.rules(self.run_check({"type": "csv_check", "path": "prospects.csv", "minRows": 30})))
        self.put("fr.csv", "nom;ville\nAcme;Lausanne\n")                                                       # séparateur point-virgule
        self.assertTrue(self.run_check({"type": "csv_check", "path": "fr.csv", "columns": ["nom", "ville"], "minRows": 1})["ok"])

    def test_xlsx_check_demands_living_formulas_and_no_error_values(self):
        import shutil as sh
        sh.copy2(os.path.join(FIXTURES, "real-worker-generated.xlsx"), os.path.join(self.ws, "devis.xlsx"))
        ok = self.run_check({"type": "xlsx_check", "path": "devis.xlsx", "sheets": ["Devis"], "minFormulas": 3})
        self.assertTrue(ok["ok"], ok["findings"])
        self.assertIn("xlsx.sheet_missing", self.rules(self.run_check({"type": "xlsx_check", "path": "devis.xlsx", "sheets": ["Bilan"]})))
        self.assertIn("xlsx.hardcoded_values", self.rules(self.run_check({"type": "xlsx_check", "path": "devis.xlsx", "minFormulas": 500})))
        self.put("faux.xlsx", b"ceci n'est pas un classeur")
        self.assertIn("xlsx.unreadable", self.rules(self.run_check({"type": "xlsx_check", "path": "faux.xlsx"})))
        self.put("devis.csv", "a,b")
        self.assertFalse(self.run_check({"type": "xlsx_check", "path": "devis.csv"})["ok"])                    # mauvaise extension

    def test_docx_check(self):
        import shutil as sh
        sh.copy2(os.path.join(FIXTURES, "real-worker-generated.docx"), os.path.join(self.ws, "rapport.docx"))
        r = self.run_check({"type": "docx_check", "path": "rapport.docx", "minWords": 5})
        self.assertTrue(r["ok"], r["findings"])
        self.assertIn("docx.too_short", self.rules(self.run_check({"type": "docx_check", "path": "rapport.docx", "minWords": 100000})))
        self.assertIn("docx.heading_missing", self.rules(self.run_check({"type": "docx_check", "path": "rapport.docx", "headings": ["Section inexistante xyz"]})))
        self.put("faux.docx", b"PK mais pas un docx")
        self.assertIn("docx.unreadable", self.rules(self.run_check({"type": "docx_check", "path": "faux.docx"})))

    def test_json_schema(self):
        self.put("d.json", json.dumps({"name": "Acme", "items": [{"price": 5}, {"price": -1}]}))
        schema = {"type": "object", "required": ["name", "items"], "properties": {"name": {"type": "string", "minLength": 2},
                                                                                    "items": {"type": "array", "minItems": 1, "items": {"type": "object", "properties": {"price": {"type": "number", "minimum": 0}}}}}}
        r = self.run_check({"type": "json_schema", "path": "d.json", "schema": schema})
        self.assertIn("json.schema", self.rules(r))
        self.assertTrue(any("minimum" in f["detail"] for f in r["findings"]))
        self.put("d2.json", json.dumps({"name": "Acme", "items": [{"price": 5}]}))
        self.assertTrue(self.run_check({"type": "json_schema", "path": "d2.json", "schema": schema})["ok"])
        self.put("d3.json", "{pas du json")
        self.assertIn("json.invalid", self.rules(self.run_check({"type": "json_schema", "path": "d3.json", "schema": schema})))

    def test_approval_executed_counts_only_executed_items(self):
        with open(os.path.join(self.proj, "approvals.json"), "w", encoding="utf-8") as f:
            json.dump({"items": [{"id": "APR-00000001", "status": "EXECUTED", "connectorId": "wordpress", "operation": "CREATE_DRAFT", "kind": "connector_action"},
                                 {"id": "APR-00000002", "status": "PENDING", "connectorId": "wordpress", "operation": "CREATE_DRAFT", "kind": "connector_action"}]}, f)
        self.assertTrue(self.run_check({"type": "approval_executed", "kind": "wordpress", "minCount": 1})["ok"])
        self.assertTrue(self.run_check({"type": "approval_executed", "kind": "wordpress:CREATE_DRAFT"})["ok"])
        self.assertIn("approval.not_executed", self.rules(self.run_check({"type": "approval_executed", "kind": "wordpress", "minCount": 2})))
        self.assertIn("approval.not_executed", self.rules(self.run_check({"type": "approval_executed", "kind": "slack"})))

    def test_seeded_defects_are_all_detected_and_the_good_files_pass(self):
        """Banc de défauts semés (4.7) : chaque défaut doit être détecté (aucun faux PASS), chaque fichier sain doit passer (aucun faux FAIL)."""
        import shutil as sh
        sh.copy2(os.path.join(FIXTURES, "real-worker-generated.xlsx"), os.path.join(self.ws, "devis.xlsx"))
        self.put("ok/index.html", "<html><title>Cabinet</title><p>Bienvenue</p></html>")
        self.put("ok/prospects.csv", "nom,email,source_url\nA,a@a.ch,https://a.ch\nB,b@b.ch,https://b.ch\n")
        self.put("ok/data.json", json.dumps({"name": "Acme", "n": 3}))
        self.put("ok/cal.md", "## J1\n## J2\n## J3\n")
        good = [{"type": "file_exists", "path": "ok/index.html"}, {"type": "file_contains", "path": "ok/index.html", "mustContain": ["Bienvenue"], "mustNotContain": ["lorem"]},
                {"type": "csv_check", "path": "ok/prospects.csv", "columns": ["nom", "email", "source_url"], "minRows": 2, "unique": "nom", "noEmpty": ["source_url"]},
                {"type": "json_schema", "path": "ok/data.json", "schema": {"type": "object", "required": ["name"]}},
                {"type": "count_matches", "path": "ok/cal.md", "regex": "^## J\\d", "min": 3}, {"type": "xlsx_check", "path": "devis.xlsx", "minFormulas": 3}]
        for c in good:
            r = self.run_check(c)
            self.assertTrue(r["ok"], (c, r["findings"]))
        self.put("bad/empty.html", b"")
        self.put("bad/lorem.html", "<p>Lorem ipsum dolor sit amet</p>")
        self.put("bad/p.csv", "nom,email\nA,\nA,\n")
        self.put("bad/d.json", "{}")
        self.put("bad/cal.md", "## J1\n")
        defects = [{"type": "file_exists", "path": "bad/absent.html"}, {"type": "file_exists", "path": "bad/empty.html"},
                   {"type": "file_contains", "path": "bad/lorem.html", "mustNotContain": ["lorem ipsum"]}, {"type": "file_contains", "path": "bad/lorem.html", "mustContain": ["Contact"]},
                   {"type": "csv_check", "path": "bad/p.csv", "columns": ["source_url"]}, {"type": "csv_check", "path": "bad/p.csv", "unique": "nom"},
                   {"type": "csv_check", "path": "bad/p.csv", "noEmpty": ["email"]}, {"type": "csv_check", "path": "bad/p.csv", "minRows": 30},
                   {"type": "json_schema", "path": "bad/d.json", "schema": {"type": "object", "required": ["name"]}},
                   {"type": "count_matches", "path": "bad/cal.md", "regex": "^## J\\d", "min": 30}, {"type": "xlsx_check", "path": "devis.xlsx", "minFormulas": 900},
                   {"type": "xlsx_check", "path": "devis.xlsx", "sheets": ["Absente"]}, {"type": "file_exists", "path": "../hors.html"},
                   {"type": "approval_executed", "kind": "gmail"}, {"type": "docx_check", "path": "bad/absent.docx"}, {"type": "no_such_check"}]
        missed = [c for c in defects if self.run_check(c)["ok"]]
        self.assertEqual(missed, [], "défauts non détectés")


class Evidence(Base):
    def setUp(self):
        super().setUp()
        self.put("site/index.html", "<h1>Cabinet</h1>\n<p>Ouvert du lundi au vendredi</p>\n<p>Tél. 021 555 12 34</p>")
        self.put("site/empty.html", b"")
        self.round = 1
        self.checks_dir = os.path.join(pv.round_dir(self.proj, 1), "checks")
        self.ok_chk = pc.run_check(pc.CheckCtx(self.ws, self.proj), {"type": "file_exists", "path": "site/index.html"}, out_dir=self.checks_dir)
        self.bad_chk = pc.run_check(pc.CheckCtx(self.ws, self.proj), {"type": "file_exists", "path": "site/absent.html"}, out_dir=self.checks_dir)

    def resolve(self, verdict, evidence, approvals=None, step_dirs=None):
        return pv.resolve_evidence(self.proj, self.round, verdict, evidence, approvals or [], step_dirs)

    def test_file_evidence(self):
        valid, bad = self.resolve("PASS", [{"type": "file", "ref": "site/index.html"}])
        self.assertEqual(valid[0]["type"], "file")
        self.assertEqual(len(valid[0]["sha256"]), 64)
        for ref in ("site/empty.html", "site/absent.html", "../x", ""):
            valid, bad = self.resolve("PASS", [{"type": "file", "ref": ref}])
            self.assertEqual(valid, [], ref)
            self.assertTrue(bad, ref)

    def test_check_evidence_must_exist_in_this_round_and_agree_with_the_verdict(self):
        self.assertEqual(self.resolve("PASS", [{"type": "check", "ref": self.ok_chk["id"]}])[0][0]["ok"], True)
        self.assertEqual(self.resolve("PASS", [{"type": "check", "ref": self.bad_chk["id"]}])[0], [])           # un échec n'appuie pas un PASS
        self.assertEqual(self.resolve("FAIL", [{"type": "check", "ref": self.ok_chk["id"]}])[0], [])            # un succès n'appuie pas un FAIL
        self.assertEqual(self.resolve("FAIL", [{"type": "check", "ref": self.bad_chk["id"]}])[0][0]["ok"], False)
        self.assertEqual(self.resolve("PASS", [{"type": "check", "ref": "CHK-deadbeef"}])[0], [])
        self.round = 2                                                                                         # un contrôle d'un AUTRE tour ne compte pas
        self.assertEqual(self.resolve("PASS", [{"type": "check", "ref": self.ok_chk["id"]}])[0], [])

    def test_excerpt_evidence_must_literally_occur(self):
        v, b = self.resolve("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": "Ouvert du lundi au vendredi"}])
        self.assertEqual(len(v), 1)
        v, b = self.resolve("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": "Ouvert   du lundi\n au vendredi"}])
        self.assertEqual(len(v), 1)                                                                            # espaces normalisés
        self.assertEqual(self.resolve("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": "Ouvert le samedi"}])[0], [])
        self.assertEqual(self.resolve("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": "x" * 301}])[0], [])
        self.assertEqual(self.resolve("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": ""}])[0], [])
        self.assertEqual(self.resolve("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": "Tél. 021", "lines": [1, 2]}])[0], [])   # hors des lignes citées
        self.assertEqual(len(self.resolve("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": "Tél. 021", "lines": [3, 3]}])[0]), 1)

    def test_fetch_and_approval_evidence(self):
        step_dir = os.path.join(self.proj, "steps", "VER1", "1")
        os.makedirs(os.path.join(step_dir, "fetches"))
        with open(os.path.join(step_dir, "fetches", "FET-0a1b2c3d.json"), "w", encoding="utf-8") as f:
            json.dump({"id": "FET-0a1b2c3d", "path": "site/dist/index.html", "status": 200, "title": "Cabinet"}, f)
        with open(os.path.join(step_dir, "fetches", "FET-00000404.json"), "w", encoding="utf-8") as f:
            json.dump({"id": "FET-00000404", "status": 404}, f)
        self.assertEqual(len(self.resolve("PASS", [{"type": "fetch", "ref": "FET-0a1b2c3d"}], step_dirs=[step_dir])[0]), 1)
        self.assertEqual(self.resolve("PASS", [{"type": "fetch", "ref": "FET-00000404"}], step_dirs=[step_dir])[0], [])
        self.assertEqual(self.resolve("PASS", [{"type": "fetch", "ref": "../../x"}], step_dirs=[step_dir])[0], [])
        approvals = [{"id": "APR-00000001", "status": "EXECUTED"}, {"id": "APR-00000002", "status": "PENDING"}]
        self.assertEqual(len(self.resolve("PASS", [{"type": "approval", "ref": "APR-00000001"}], approvals)[0]), 1)
        self.assertEqual(self.resolve("PASS", [{"type": "approval", "ref": "APR-00000002"}], approvals)[0], [])
        self.assertEqual(self.resolve("PASS", [{"type": "magic", "ref": "x"}])[0], [])
        self.assertEqual(self.resolve("PASS", "not a list")[0], [])


class Verdicts(Evidence):
    def plan(self):
        return {"goal": "Site", "criteria": [
            {"id": "C1", "text": "La page d'accueil existe", "kind": "auto", "check": {"type": "file_exists", "path": "site/index.html"}},
            {"id": "C2", "text": "Le ton est professionnel", "kind": "rubric", "rubric": "Aucune faute"},
            {"id": "C3", "text": "Les horaires sont affichés", "kind": "rubric", "rubric": "horaires"}],
            "steps": [{"id": "S1", "worker": "lucas", "criteriaIds": ["C1"]}, {"id": "S2", "worker": "emma", "criteriaIds": ["C2", "C3"]}]}

    def verdicts(self, report, autos=None):
        plan = self.plan()
        autos = autos if autos is not None else pv.run_auto_checks(self.proj, plan, 1)
        out = pv.resolve_verification(plan, report, autos, self.proj, 1, [])
        return {c["id"]: c for c in out["criteria"]}, out

    def file_ev(self):
        return [{"type": "file", "ref": "site/index.html"}]

    def test_a_pass_without_a_valid_proof_is_downgraded_to_unverifiable(self):
        rep = {"criteria": [{"id": "C2", "verdict": "PASS", "note": "ok", "evidence": []}, {"id": "C3", "verdict": "PASS", "note": "ok",
                                                                                              "evidence": [{"type": "file", "ref": "site/absent.html"}]}], "overall": "PASS"}
        v, out = self.verdicts(rep)
        self.assertEqual(v["C2"]["verdict"], "UNVERIFIABLE")
        self.assertEqual(v["C3"]["verdict"], "UNVERIFIABLE")
        self.assertIn("rétrogradé", v["C2"]["note"])
        self.assertEqual(out["overall"], "UNVERIFIABLE")

    def test_a_pass_with_a_valid_proof_counts_and_the_overall_follows(self):
        rep = {"criteria": [{"id": "C2", "verdict": "PASS", "evidence": self.file_ev()},
                            {"id": "C3", "verdict": "PASS", "evidence": [{"type": "excerpt", "ref": "site/index.html", "quote": "Ouvert du lundi au vendredi"}]}], "overall": "PASS"}
        v, out = self.verdicts(rep)
        self.assertEqual({k: x["verdict"] for k, x in v.items()}, {"C1": "PASS", "C2": "PASS", "C3": "PASS"})
        self.assertEqual(out["overall"], "PASS")
        self.assertTrue(all(x["evidence"] for x in v.values()))

    def test_an_auto_criterion_is_pass_only_if_its_typed_check_is_ok(self):
        os.remove(os.path.join(self.ws, "site", "index.html"))
        rep = {"criteria": [{"id": "C1", "verdict": "PASS", "evidence": [{"type": "check", "ref": self.ok_chk["id"]}]}], "overall": "PASS"}
        v, out = self.verdicts(rep)
        self.assertEqual(v["C1"]["verdict"], "FAIL")                                                          # le vérificateur ne peut pas passer outre
        self.assertEqual(out["overall"], "FAIL")
        self.assertTrue(v["C1"]["fixHint"])

    def test_the_verifier_can_refute_a_criterion_the_typed_check_accepts(self):
        rep = {"criteria": [{"id": "C1", "verdict": "FAIL", "note": "La page est vide de sens", "evidence": self.file_ev(), "fixHint": "Réécrire"}], "overall": "FAIL"}
        v, out = self.verdicts(rep)
        self.assertEqual(v["C1"]["verdict"], "FAIL")

    def test_without_a_verifier_only_typed_checks_count(self):
        v, out = self.verdicts(None)
        self.assertEqual(v["C1"]["verdict"], "PASS")
        self.assertEqual((v["C2"]["verdict"], v["C3"]["verdict"]), ("UNVERIFIABLE", "UNVERIFIABLE"))
        self.assertEqual(out["overall"], "UNVERIFIABLE")
        self.assertFalse(out["verifierRan"])

    def test_a_missing_verdict_is_never_a_pass(self):
        v, out = self.verdicts({"criteria": [{"id": "C2", "verdict": "PASS", "evidence": self.file_ev()}], "overall": "PASS"})
        self.assertEqual(v["C3"]["verdict"], "UNVERIFIABLE")

    def test_fix_steps_go_to_the_worker_who_owns_the_failing_criterion(self):
        plan = self.plan()
        ver = {"criteria": [{"id": "C1", "verdict": "FAIL", "note": "absent", "fixHint": "Créer l'accueil", "evidence": []},
                            {"id": "C3", "verdict": "FAIL", "note": "horaires absents", "fixHint": "Ajouter les horaires", "evidence": []},
                            {"id": "C2", "verdict": "PASS", "evidence": []}]}
        steps = {"S1": {"status": "DONE"}, "S2": {"status": "DONE"}}
        fixes = pv.plan_fix_steps(plan, steps, ver, 1, "chloe")
        self.assertEqual(sorted(f["worker"] for f in fixes), ["emma", "lucas"])
        by = {f["worker"]: f for f in fixes}
        self.assertEqual(by["lucas"]["criteriaIds"], ["C1"])
        self.assertEqual(by["emma"]["criteriaIds"], ["C3"])
        self.assertIn("Ajouter les horaires", by["emma"]["goal"])
        self.assertTrue(all(f["kind"] == "fix" and f["id"].startswith("FIX1-") for f in fixes))


class Done(Base):
    def setUp(self):
        super().setUp()
        self.put("site/index.html", "<p>ok</p>")
        self.plan = {"goal": "g", "criteria": [{"id": "C1", "text": "t1", "kind": "rubric"}, {"id": "C2", "text": "t2", "kind": "rubric"}],
                     "steps": [{"id": "S1", "worker": "lucas", "criteriaIds": ["C1", "C2"], "requiresApprovalsFrom": ["S1"]}]}
        self.ver = {"criteria": [{"id": "C1", "verdict": "PASS", "evidence": [{"type": "file", "ref": "site/index.html"}]},
                                 {"id": "C2", "verdict": "PASS", "evidence": [{"type": "file", "ref": "site/index.html"}]}]}
        self.dels = [{"path": "site/index.html", "title": "Accueil", "bytes": 9, "stepId": "S1"}]

    def problems(self, **kw):
        args = dict(plan=self.plan, verification=self.ver, deliverables=self.dels, approvals=[], workspace=self.ws, accepted_gaps=None, final_report_exists=True)
        args.update(kw)
        return pv.definition_of_done(**args)

    def test_done_only_with_every_criterion_proven(self):
        self.assertEqual(self.problems(), [])
        self.ver["criteria"][1]["verdict"] = "UNVERIFIABLE"
        self.assertTrue(any("C2" in p for p in self.problems()))
        self.ver["criteria"][1] = {"id": "C2", "verdict": "PASS", "evidence": []}
        self.assertTrue(any("sans preuve" in p for p in self.problems()))
        self.assertEqual(self.problems(accepted_gaps=["C2"]), [])                                           # lacune acceptée par le client
        self.assertTrue(self.problems(verification={"criteria": []}))
        self.assertTrue(self.problems(verification=None))

    def test_a_missing_or_empty_deliverable_blocks_done(self):
        self.put("site/index.html", b"")
        self.assertTrue(any("absent ou vide" in p for p in self.problems()))
        os.remove(os.path.join(self.ws, "site", "index.html"))
        self.assertTrue(any("absent ou vide" in p for p in self.problems()))
        self.assertTrue(any("absent ou vide" in p for p in self.problems(deliverables=[{"path": "../x.html"}])))

    def test_a_required_approval_still_pending_blocks_done_but_an_unrelated_one_does_not(self):
        pending = [{"id": "APR-00000001", "stepId": "S1", "status": "PENDING"}]
        self.assertTrue(any("en attente" in p for p in self.problems(approvals=pending)))
        self.assertEqual(self.problems(approvals=[{"id": "APR-00000002", "stepId": "S9", "status": "PENDING"}]), [])
        self.assertEqual(self.problems(approvals=[{"id": "APR-00000003", "stepId": "S1", "status": "EXECUTED"}]), [])

    def test_the_final_report_must_exist(self):
        self.assertIn("rapport final absent", self.problems(final_report_exists=False))

    def test_final_report_has_the_eight_parts_and_never_invents_a_pass(self):
        state = {"projectId": "PRJ-" + "A" * 32, "title": "Site", "status": "DONE", "budget": {"creditsCharged": 12, "creditsCap": 20}, "steps": {"S1": {"status": "DONE"}},
                 "activeSeconds": 600}
        self.ver["criteria"][1] = {"id": "C2", "verdict": "UNVERIFIABLE", "note": "pas de preuve", "evidence": []}
        rep = pv.build_final_report(state, self.plan, self.ver, self.dels, [], "Tout est prêt.", ["C2"], "2026-10-19T10:00:00Z")
        for n in range(1, 9):
            self.assertIn(f"## {n}.", rep)
        self.assertIn("accepté en l'état", rep)
        self.assertIn("C2 : UNVERIFIABLE", rep)
        self.assertIn("Message du Worker", rep)
        self.assertTrue(pv.message_claims_ok("C1 PASS, le reste est à relire", self.ver))
        self.assertFalse(pv.message_claims_ok("C2 : PASS, tout est vérifié", self.ver))                     # un PASS absent de verification.json est refusé
        self.assertFalse(pv.message_claims_ok("Le critère C9 est PASS", self.ver))

    def test_verification_files_roundtrip(self):
        self.assertEqual(pv.latest_round(self.proj), 0)
        pv.write_verification(self.proj, 1, {"round": 1, "overall": "FAIL", "criteria": []})
        pv.write_verification(self.proj, 2, {"round": 2, "overall": "PASS", "criteria": []})
        self.assertEqual(pv.latest_round(self.proj), 2)
        self.assertEqual(pv.read_verification(self.proj, 1)["overall"], "FAIL")
        self.assertIsNone(pv.read_verification(self.proj, 9))


if __name__ == "__main__":
    unittest.main(verbosity=2)
