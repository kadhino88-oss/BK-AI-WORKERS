# -*- coding: utf-8 -*-
"""Recettes (BK-RECIPE-V1) : intégrité, couverture des 17 Workers, choix, rendu, et critères automatiques exécutés pour de vrai.

Lancer : python tests/projects/test_recipes.py
"""
import json
import os
import re
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import recipes  # noqa: E402
import project_checks as pc  # noqa: E402
import projects_plan  # noqa: E402

projects_plan.register_check_type("site_check")      # enregistré par l'atelier de sites (ws/chantier-site) quand il est présent

WORKERS17 = ["alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya", "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis"]


def _load(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return json.load(f)


def _plain(pattern):
    """Texte lisible d'un motif accent-insensible produit par lib.tolerant (« [eéèêë] » -> « e »)."""
    s = pattern[3:] if pattern.startswith("re:") else pattern
    s = re.sub(r"\[(.)[^\]]*\]", r"\1", s)
    return re.sub(r"\\(.)", r"\1", s).lstrip("^")


def synth_workspace(root, recipe):
    """Fabrique des fichiers qui satisfont à la lettre chaque critère automatique de fichier (hors Office et site)."""
    made = 0
    for c in recipe["definitionOfDone"]:
        if c["kind"] != "auto":
            continue
        ck = c["check"]
        t = ck["type"]
        if t not in ("file_exists", "file_contains", "csv_check", "count_matches"):
            continue
        full = os.path.join(root, *ck["path"].split("/"))
        os.makedirs(os.path.dirname(full), exist_ok=True)
        if t == "file_exists":
            body = "x" * int(ck.get("minBytes", 1))
        elif t == "file_contains":
            body = "\n".join("## " + _plain(m) for m in ck.get("mustContain") or []) + "\n"
        elif t == "count_matches":
            body = "".join("%s %d\n" % (_plain(ck["regex"]), i) for i in range(int(ck.get("min", 1)) + 1))
        else:
            cols = ck["columns"]
            body = ";".join(cols) + "\n" + "".join(";".join("v%d_%s" % (i, col) for col in cols) + "\n" for i in range(max(int(ck.get("minRows", 1)), 1) + 1))
        mode = "a" if os.path.exists(full) else "w"
        with open(full, mode, encoding="utf-8") as f:
            f.write(body)
        made += 1
    return made


class RecipeIntegrity(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.all = recipes.load_all(REPO, refresh=True)
        cls.ops = recipes.operation_table(REPO)
        cls.schema = _load("core/projects/RECIPE-SCHEMA.json")
        cls.sources = recipes.source_ids(REPO)

    def setUp(self):
        # Les recettes de sites (lucas/site-vitrine-pro, chloe/lancement-offre) portent des criteres « site_check » : comme dans le serveur, l'atelier de sites
        # (dashboard/site_factory.py) enregistre ce type. Re-enregistre a chaque test : un autre test peut l'avoir retire (test_plan).
        import site_factory
        site_factory.register_checks()

    def test_count_and_every_worker_has_three(self):
        self.assertGreaterEqual(len(self.all), 51)
        for w in WORKERS17:
            self.assertGreaterEqual(len(recipes.list_for_worker(w)), 3, w)
        self.assertTrue(any(r["workerId"] == "chloe" for r in self.all.values()))

    def test_each_recipe_valid(self):
        for rid, r in self.all.items():
            with self.subTest(recipe=rid):
                self.assertEqual(pc.validate_schema(r, self.schema), [])
                self.assertEqual(recipes.validate(r, root=REPO, op_table=self.ops, sources=self.sources), [])

    def test_each_recipe_is_a_valid_plan(self):
        scope = {"chloe": True, "allowed": WORKERS17}
        for rid, r in self.all.items():
            with self.subTest(recipe=rid):
                plan = {"goal": r["title"], "recipeId": rid, "criteria": r["definitionOfDone"], "steps": r["steps"]}
                res = projects_plan.validate_plan(plan, scope, known_workers=set(WORKERS17) | {"chloe"})
                self.assertTrue(res.ok, res.messages())
                self.assertEqual(res.warnings, [], rid)      # aucun critère « auto » rétrogradé en grille

    def test_deliverables_have_a_producing_step_and_a_criterion(self):
        for rid, r in self.all.items():
            outs = {o for s in r["steps"] for o in s.get("expectedOutputs", [])}
            for d in r["deliverables"]:
                if d["path"].endswith((".zip", ".pdf")):
                    continue
                with self.subTest(recipe=rid, deliverable=d["path"]):
                    self.assertTrue(any(d["path"] == o or o.endswith("/") and d["path"].startswith(o) for o in outs) or any(
                        c.get("check", {}).get("path") == d["path"] for c in r["definitionOfDone"]), "livrable sans étape ni critère")

    def test_every_recipe_cites_known_sources_or_none(self):
        data = _load("core/projects/RECIPE-SOURCES.json")["sources"]
        for rid, r in self.all.items():
            for sid in r.get("sources", []):
                self.assertIn(sid, data, rid)
        for sid, s in data.items():
            self.assertTrue(s["url"].startswith("https://"), sid)
            self.assertRegex(s["fetchedUtc"], r"^\d{4}-\d\d-\d\d$")
            if not s["verified"]:
                self.assertTrue(any(w in s["claim"].lower() for w in ("juriste", "relire", "confirm")), sid)

    def test_prospecting_and_legal_recipes_flag_a_lawyer(self):
        for rid in ("alex/gestion-prospects", "alex/relance-pipeline-dormant", "maya/sequences-email-nurturing"):
            n = self.all[rid].get("legalNotice", "")
            self.assertIn("juriste", n, rid)
            self.assertIn("BROUILLONS", n.upper(), rid)
        for rid in ("clara/redaction-contrat-prestation", "clara/cgv-cgu-confidentialite", "sophie/onboarding-contrat-travail"):
            self.assertIn("juriste", self.all[rid]["legalNotice"], rid)

    def test_no_outward_action_without_approval_and_none_high_by_default(self):
        for rid, r in self.all.items():
            for a in r.get("approvals", []):
                self.assertIn(a["risk"], ("low", "medium"), rid)
                self.assertNotIn(a["operation"], ("DELETE", "CREATE_REFUND", "CREATE_PAYOUT", "CREATE_PAYMENT", "PLACE_CALL"), rid)
            self.assertIn("approbation", " ".join(r["forbidden"]), rid)

    def test_prospect_csv_demands_source_url_on_every_row(self):
        c = next(c for c in self.all["alex/gestion-prospects"]["definitionOfDone"] if c["id"] == "C1")["check"]
        self.assertIn("source_url", c["noEmpty"])
        self.assertGreaterEqual(c["minRows"], 30)

    def test_catalog_is_complete_and_honest(self):
        cat = _load("core/projects/RECIPE-CATALOG.json")["workers"]
        self.assertEqual(sorted(cat), WORKERS17)
        known = set(self.all)
        for w, rows in cat.items():
            prof = json.load(open(os.path.join(REPO, "workers", w, "install-profile.json"), encoding="utf-8-sig"))
            self.assertEqual([r["serviceId"] for r in rows], [s["id"] for s in prof["services"]], w)
            for r in rows:
                if r["recipes"]:
                    self.assertTrue(set(r["recipes"]) <= known)
                else:
                    self.assertTrue(r.get("reason"), "%s/%s sans recette ni raison" % (w, r["serviceId"]))

    def test_generated_files_match_the_source(self):
        import subprocess
        p = subprocess.run([sys.executable, os.path.join(REPO, "core", "projects", "recipes_src", "build.py"), "--check"], capture_output=True, text=True, encoding="utf-8")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


class RecipeChecksRunForReal(unittest.TestCase):
    """Les critères automatiques ne sont pas décoratifs : ils échouent sur un espace vide et passent sur des fichiers conformes."""

    def test_checks_fail_when_empty_and_pass_when_compliant(self):
        done = 0
        for rid, r in recipes.load_all(REPO).items():
            auto = [c for c in r["definitionOfDone"] if c["kind"] == "auto" and c["check"]["type"] in ("file_exists", "file_contains", "csv_check", "count_matches")]
            if not auto:
                continue
            with tempfile.TemporaryDirectory() as empty, tempfile.TemporaryDirectory() as good:
                synth_workspace(good, r)
                for c in auto:
                    with self.subTest(recipe=rid, criterion=c["id"]):
                        self.assertFalse(pc.run_check(pc.CheckCtx(empty), c["check"])["ok"], "passe à vide")
                        res = pc.run_check(pc.CheckCtx(good), c["check"])
                        self.assertTrue(res["ok"], res["findings"])
                        done += 1
        self.assertGreater(done, 150)

    def test_honesty_check_needs_sources_et_limites_in_any_accent(self):
        c = next(x for x in recipes.get("emma/calendrier-social-30j")["definitionOfDone"] if x["id"] == "CH")["check"]
        for body, ok in (("# Rapport\n## Sources et limites\nok", True), ("## SOURCES ET LIMITES", True), ("rien", False)):
            with tempfile.TemporaryDirectory() as d:
                os.makedirs(os.path.join(d, "deliverables"))
                open(os.path.join(d, c["path"]), "w", encoding="utf-8").write(body)
                self.assertEqual(pc.run_check(pc.CheckCtx(d), c)["ok"], ok, body)

    def test_fabrication_guards_catch_a_planted_defect(self):
        r = recipes.get("alex/gestion-prospects")
        c4 = next(x for x in r["definitionOfDone"] if x["id"] == "C4")["check"]
        for body, ok in (("entreprise;site\nAcme;https://acme.ch\n", True), ("entreprise;site\nAcme;https://linkedin.com/in/jean-dupont\n", False), ("contact\njean@gmail.com\n", False)):
            with tempfile.TemporaryDirectory() as d:
                os.makedirs(os.path.join(d, "deliverables"))
                open(os.path.join(d, c4["path"]), "w", encoding="utf-8").write(body)
                self.assertEqual(pc.run_check(pc.CheckCtx(d), c4)["ok"], ok, body)
        r = recipes.get("maya/publicites-meta-google")
        c4 = next(x for x in r["definitionOfDone"] if x["id"] == "C4")["check"]
        for body, ok in (("plateforme;texte\nmeta;Découvrez nos thés\n", True), ("plateforme;texte\nmeta;Résultats garantis\n", False), ("plateforme;texte\nmeta;Augmentez vos ventes de 40 % \n", False)):
            with tempfile.TemporaryDirectory() as d:
                os.makedirs(os.path.join(d, "deliverables"))
                open(os.path.join(d, c4["path"]), "w", encoding="utf-8").write(body)
                self.assertEqual(pc.run_check(pc.CheckCtx(d), c4)["ok"], ok, body)


class RecipeSelectionAndRender(unittest.TestCase):
    def test_example_of_each_recipe_selects_it_for_its_worker(self):
        for rid, r in recipes.load_all(REPO).items():
            for ex in r["triggers"]["examples"]:
                with self.subTest(recipe=rid, example=ex):
                    cands = recipes.candidates(r["workerId"], ex, "fr", "scale")
                    self.assertTrue(cands, "aucun candidat")
                    self.assertIn(rid, [x[0]["id"] for x in cands[:2]], [(x[0]["id"], x[1]) for x in cands[:4]])

    def test_chloe_sees_all_and_picks_the_launch_recipe(self):
        c = recipes.candidates("chloe", "Lance ma boutique de bougies : site, réseaux, publicités et SEO", "fr", "equipe")
        self.assertEqual(c[0][0]["id"], "chloe/lancement-offre")

    def test_nonsense_goal_matches_nothing_and_plan_rank_adds_a_point(self):
        self.assertEqual(recipes.candidates("lucas", "bonjour comment ça va", "fr", "equipe"), [])
        hi = recipes.candidates("lucas", "créer le site vitrine de mon cabinet", "fr", "equipe")[0][1]
        lo = recipes.candidates("lucas", "créer le site vitrine de mon cabinet", "fr", "solo")[0][1]
        self.assertEqual(hi - lo, 1)

    def test_english_goal_skips_french_only_recipes(self):
        self.assertEqual(recipes.candidates("alex", "find prospects for my accounting software", "en", "equipe"), [])

    def test_render_limits(self):
        for rid, r in recipes.load_all(REPO).items():
            with self.subTest(recipe=rid):
                p = recipes.render_for_planning(r, {"allowedNow": 80})
                self.assertLessEqual(len(p), recipes.MAX_PLANNING_CHARS)
                self.assertIn(rid, p)
                self.assertIn("recipeDeviations", p)
                self.assertIn("Credits disponibles maintenant : 80", p)
                s = recipes.render_for_step(r, "S1")
                self.assertLessEqual(len(s), recipes.MAX_STEP_CHARS)
                self.assertIn("Interdit", s)
        self.assertEqual(recipes.render_for_step(recipes.get("lucas/site-vitrine-pro"), "S99"), "")

    def test_public_summary_has_no_internal_fields(self):
        s = recipes.public_summary(recipes.get("alex/gestion-prospects"))
        self.assertEqual(s["workerId"], "alex")
        self.assertNotIn("steps", s)
        self.assertNotIn("_path", s)
        self.assertTrue(s["approvals"])

    def test_validate_catches_defects(self):
        good = json.loads(json.dumps(recipes.get("emma/calendrier-social-30j")))
        ops = recipes.operation_table(REPO)

        def errs(mut):
            r = json.loads(json.dumps(good))
            mut(r)
            return recipes.validate(r, root=REPO, op_table=ops)
        self.assertTrue(any("cycle" in e for e in errs(lambda r: r["steps"][0].update(dependsOn=["S4"]))))
        self.assertTrue(any("aucune etape ne le vise" in e for e in errs(lambda r: r["steps"][1].update(criteriaIds=[]))))
        self.assertTrue(any("type de controle inconnu" in e for e in errs(lambda r: r["definitionOfDone"][0]["check"].update(type="magic"))))
        self.assertTrue(any("Worker inconnu" in e for e in errs(lambda r: r["steps"][0].update(worker="zoe"))))
        self.assertTrue(any("OperationTable" in e for e in errs(lambda r: r["approvals"].append({"connector": "gmail", "operation": "SEND_MESSAGE", "risk": "low"}))))
        self.assertTrue(any("Somme" in e for e in errs(lambda r: r["steps"][0].update(estimateCredits=900))))
        self.assertTrue(any("secret" in e for e in errs(lambda r: r.update(guidance="clé sk-ant-abcdefghijklmnop"))))
        self.assertTrue(any("Variante" in e for e in errs(lambda r: r["budget"].update(variants={"x": {"drop": ["S42"]}}))))

    def test_loader_survives_a_broken_file(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "workers", "lucas", "recipes"))
            open(os.path.join(root, "workers", "lucas", "recipes", "bad.json"), "w").write("{not json")
            open(os.path.join(root, "workers", "lucas", "recipes", "ok.json"), "w").write(json.dumps({"id": "lucas/ok", "workerId": "lucas", "title": "t"}))
            self.assertEqual(list(recipes.load_all(root, refresh=True)), ["lucas/ok"])
        recipes.load_all(REPO, refresh=True)


if __name__ == "__main__":
    unittest.main(verbosity=1)
