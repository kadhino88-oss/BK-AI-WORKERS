# -*- coding: utf-8 -*-
"""Atelier de sites DANS le moteur de projets (faux lanceur, aucun modèle) : un projet « site vitrine » va au bout — plan avec un critère
automatique site_check, étape de Lucas qui utilise les VRAIS outils (site_scaffold, workspace_write, site_build, site_check, site_package),
vérification où le moteur relance lui-même le contrôle, DONE ; puis la publication est préparée en articles d'approbation (brouillons de pages
WordPress) et une validation du client déclenche UN appel de connecteur, avec le contenu exact. Variante : un site qui garde une affirmation
inventée ne passe jamais (le contrôle du moteur fait échouer le critère, quel que soit l'avis du vérificateur).

    python tests/site-factory/test_engine_site.py"""
import json
import os
import shutil
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tests", "projects"))
import fixtures as fx  # noqa: E402
from engine_harness import Env  # noqa: E402
import project_tools  # noqa: E402
import projects_approvals as pa  # noqa: E402
import site_tools  # noqa: E402,F401  (site_check est aussi enregistré dans le processus du moteur, comme dans server.py)

RUNNER = os.path.join(HERE, "site_runner.py")


def site_actions(defect=None):
    """Actions d'un Worker : squelette par l'outil, puis les fichiers écrits (ceux du bon site), construction, contrôle, paquet."""
    ws = fx.make_good_site(build=False)
    try:
        writes = []
        base = os.path.join(ws, "site")
        for dp, _dn, fn in os.walk(base):
            for n in sorted(fn):
                full = os.path.join(dp, n)
                rel = os.path.relpath(full, ws).replace(os.sep, "/")
                with open(full, encoding="utf-8") as f:
                    content = f.read()
                if defect and rel == "site/src/pages/fr/index.html":
                    content = content.replace("<h2 id=\"titre-soins\">Nos soins</h2>", "<h2 id=\"titre-soins\">Nos soins</h2><p>Plus de 500 patients satisfaits.</p>")
                writes.append({"tool": "workspace_write", "input": {"path": rel, "mode": "overwrite", "content": content}})
    finally:
        fx.cleanup(ws)
    return ([{"tool": "site_scaffold", "input": fx.SCAFFOLD}] + writes +
            [{"tool": "site_build", "input": {}}, {"tool": "site_check", "input": {"profile": "vitrine"}}, {"tool": "site_package", "input": {}}])


def plan():
    return {"goal": "Créer le site vitrine du cabinet", "language": "fr", "assumptions": [{"id": "A1", "text": "FR et EN"}],
            "criteria": [{"id": "C1", "text": "Le site passe les contrôles automatiques", "kind": "auto",
                          "check": {"type": "site_check", "profile": "vitrine", "must": ["html", "meta", "links", "img", "a11y", "perf", "privacy", "i18n", "seo", "content"]}},
                         {"id": "C2", "text": "Le zip de mise en ligne existe", "kind": "auto", "check": {"type": "file_exists", "path": "deliverables/site-atelier-lumen.zip", "minBytes": 1000}}],
            "steps": [{"id": "S1", "title": "Construire le site", "worker": "lucas", "goal": "Site complet FR/EN", "criteriaIds": ["C1", "C2"],
                       "expectedOutputs": ["site/site.json", "deliverables/site-atelier-lumen.zip"], "estimateCredits": 6}],
            "estimate": {"creditsMin": 6, "creditsMax": 12, "hoursMin": 0.2, "hoursMax": 0.5}}


def scenario(defect=None):
    return {
        "plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan()}}], "complete": {"status": "DONE", "summary": "Plan prêt."}},
        "execute:S1": {"actions": site_actions(defect),
                       "complete": {"status": "DONE", "summary": "Site construit, contrôlé et empaqueté.",
                                    "deliverables": [{"path": "deliverables/site-atelier-lumen.zip", "title": "Site (zip)"}],
                                    "criteriaClaims": [{"criterionId": "C1", "claim": "contrôles passés", "evidence": [{"type": "file", "ref": "site/dist/index.html"}]},
                                                       {"criterionId": "C2", "claim": "zip produit", "evidence": [{"type": "file", "ref": "deliverables/site-atelier-lumen.zip"}]}],
                                    "summaryUpdate": "Site prêt.", "handoffNote": "site/ et deliverables/"}},
    }


class EngineSiteTests(unittest.TestCase):
    def env(self, **kw):
        e = Env(runner_cmd=lambda i, o: [sys.executable, RUNNER, i, o, "Project-StepRunner"], **kw)
        self.addCleanup(e.close)
        old_root = project_tools.ROOT
        project_tools.ROOT = e.root                 # dans le serveur, project_tools.ROOT = BK_ROOT ; ici, le dossier du moteur de test
        self.addCleanup(setattr, project_tools, "ROOT", old_root)
        for rel in ("core/projects/site", "core/integrations/Connector-Site-Publish.ps1"):
            src = os.path.join(REPO, *rel.split("/"))
            dst = os.path.join(e.root, *rel.split("/"))
            if os.path.isdir(src):
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)
        return e

    def test_site_project_goes_to_done_then_publication_is_prepared_and_validated(self):
        e = self.env(scenario=scenario(), connectors=["wordpress"])
        pid = e.create(goal="Créer le site vitrine de mon cabinet de physiothérapie à Lausanne", worker="lucas")
        st = e.run_to_done(pid, timeout=180)
        self.assertEqual(st["status"], "DONE", st.get("statusReason"))
        for rel in ("site/dist/index.html", "site/dist/en/about/index.html", "deliverables/site-atelier-lumen.zip", "deliverables/MISE-EN-LIGNE.md", "notes/site-guide.md"):
            self.assertTrue(os.path.isfile(e.wspath(pid, rel)), rel)
        pdir = e.svc.store.project_dir(pid)
        rounds = sorted(d for d in os.listdir(os.path.join(pdir, "verification")) if d.isdigit())
        ver = json.load(open(os.path.join(pdir, "verification", rounds[-1], "verification.json"), encoding="utf-8"))
        self.assertEqual({c["id"]: c["verdict"] for c in ver["criteria"]}.get("C1"), "PASS")
        checks = [json.load(open(os.path.join(pdir, "verification", rounds[-1], "checks", n), encoding="utf-8"))
                  for n in os.listdir(os.path.join(pdir, "verification", rounds[-1], "checks"))]
        site_chk = [c for c in checks if c["type"] == "site_check"]
        self.assertTrue(site_chk and all(c["ok"] for c in site_chk), [c["findings"][:3] for c in site_chk])
        deliverables = {d["path"] for d in e.svc.store.read_json(pid, "deliverables.json")["items"]}
        self.assertIn("deliverables/site-atelier-lumen.zip", deliverables)
        self.assertIn("deliverables/MISE-EN-LIGNE.md", deliverables)
        self.assertEqual(e.connector_calls, [])                       # rien n'est sorti pendant le projet

        # publication préparée APRÈS la fin (route POST .../site/publish : même code, étape « PUBLISH »)
        out = project_tools.run_tool("site_publish_prepare", {"projectDir": pdir, "stepDir": "", "stepId": "PUBLISH", "kind": "execute", "worker": "lucas",
                                                               "input": {"target": "wordpress"}})
        self.assertTrue(out["ok"], out)
        with e.svc.store.txn(pid) as t:
            e.svc._ingest_approvals(t, rename_step="PUBLISH")
            e.svc.refresh_approval_counts(t)
        items = pa.load_items(e.svc.store, pid)
        wp = [i for i in items if i.get("connectorId") == "wordpress"]
        self.assertEqual(len(wp), 6, [(i.get("kind"), i.get("display", {}).get("title")) for i in items])
        self.assertTrue(all(i["status"] == "PENDING" and i["operation"] == "CREATE_PAGE_DRAFT" and i["risk"] == "medium" and i["reversible"] for i in wp))
        self.assertEqual(e.connector_calls, [])                       # préparé, pas publié
        home = next(i for i in wp if i["params"]["Slug"] == "accueil")
        e.svc.approve_approval(e.client, pid, home["id"])
        e.svc.executor.wait_idle(20)
        self.assertEqual(len(e.connector_calls), 1)
        conn, op, params, client = e.connector_calls[0]
        self.assertEqual((conn, op, client), ("wordpress", "CREATE_PAGE_DRAFT", e.client))
        self.assertEqual(params, home["params"])                       # le contenu exact validé par le client
        self.assertIn("Retrouver le plaisir de bouger", params["Content"])
        after = {i["id"]: i["status"] for i in pa.load_items(e.svc.store, pid)}
        self.assertEqual(after[home["id"]], "EXECUTED")
        self.assertEqual(sum(1 for i in wp if after[i["id"]] == "PENDING"), 5)

    def test_without_wordpress_publication_is_a_guided_manual_action(self):
        e = self.env(scenario=scenario(), connectors=[])
        pid = e.create(goal="Créer le site vitrine de mon cabinet", worker="lucas")
        self.assertEqual(e.run_to_done(pid, timeout=180)["status"], "DONE")
        pdir = e.svc.store.project_dir(pid)
        out = project_tools.run_tool("site_publish_prepare", {"projectDir": pdir, "stepDir": "", "stepId": "PUBLISH", "kind": "execute", "worker": "lucas",
                                                               "input": {"target": "wordpress"}})
        self.assertTrue(out["ok"], out)
        with e.svc.store.txn(pid) as t:
            e.svc._ingest_approvals(t, rename_step="PUBLISH")
        items = pa.load_items(e.svc.store, pid)
        self.assertEqual([i["kind"] for i in items], ["manual_action"])
        self.assertIn("MISE-EN-LIGNE.md", items[0]["display"]["what"])
        self.assertIn("pas connecté", items[0]["display"]["why"])

    def test_invented_claim_never_reaches_done(self):
        e = self.env(scenario=scenario(defect="claim"), connectors=[])
        pid = e.create(goal="Créer le site vitrine de mon cabinet", worker="lucas")
        st = e.drive(pid, lambda s: s["status"] in ("DONE", "FAILED", "CANCELLED", "WAITING_INPUT", "BUDGET_REACHED"), timeout=240)
        self.assertNotEqual(st["status"], "DONE", "une affirmation inventée a laissé passer le projet")
        pdir = e.svc.store.project_dir(pid)
        found = False
        for r in sorted(d for d in os.listdir(os.path.join(pdir, "verification")) if d.isdigit()):
            cdir = os.path.join(pdir, "verification", r, "checks")
            for n in os.listdir(cdir) if os.path.isdir(cdir) else []:
                c = json.load(open(os.path.join(cdir, n), encoding="utf-8"))
                if c["type"] == "site_check" and any(f["rule"] == "claims.unverified" for f in c["findings"]):
                    found = True
        self.assertTrue(found, "le contrôle du moteur doit nommer l'affirmation non vérifiée")


if __name__ == "__main__":
    unittest.main(verbosity=2)
