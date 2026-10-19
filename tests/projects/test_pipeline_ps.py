# -*- coding: utf-8 -*-
"""Un projet COMPLET de bout en bout : le moteur Python (dashboard/projects*.py) pilote le VRAI lanceur PowerShell (Project-StepRunner.ps1,
Project-Loop.ps1, outils Python) contre la fausse API Anthropic à cassettes (tests/projects/fake_api.ps1). Aucun réseau, aucun coût, aucune vraie clé.

Scénario 1 : le plan est établi, deux Workers écrivent leurs fichiers, le contrôleur qualité REFUSE un critère (un texte d'exemple est resté dans la page
d'accueil), une étape de correction le répare, la seconde vérification passe, le rapport final est écrit et le projet est TERMINÉ.
Scénario 2 : une action sortante préparée par le lanceur attend le client (une exécution, jamais deux), l'étape suivante en dépend.

PowerShell 7 requis. Sous Windows : wsl -e python3 tests/projects/test_pipeline_ps.py"""
import json
import os
import shutil
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import runner_harness as rh  # noqa: E402
from engine_harness import CLIENT, Env  # noqa: E402
from runner_harness import FAKE_KEY, PWSH, complete, msg, tu, usage  # noqa: E402

DRIVER = r'''
param([string]$InFile, [string]$OutFile)
$In = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json
$Name = "$($In.stepId)-$($In.attempt)"
New-Item -ItemType Directory -Force -Path (Join-Path $env:BK_ROOT "_test/logs") | Out-Null
$env:FAKE_CASSETTE = Join-Path $env:BK_ROOT "_test/cassettes/$Name.json"
$env:FAKE_LOG = Join-Path $env:BK_ROOT "_test/logs/$Name.jsonl"
. (Join-Path $env:BK_ROOT "_test/fake_api.ps1")
& (Join-Path $env:BK_ROOT "core/ai/adapters/Project-StepRunner.ps1") -InFile $InFile -OutFile $OutFile
exit $LASTEXITCODE
'''

BAD_HTML = "<h1>Cabinet de physiotherapie</h1><p>Lorem ipsum dolor sit amet, texte d'exemple a remplacer.</p>"
GOOD_HTML = "<h1>Cabinet de physiotherapie</h1><p>Prenez rendez-vous au 021 555 12 34.</p><p>[A COMPLETER : adresse du cabinet]</p>"
ABOUT_HTML = "<h1>A propos</h1><p>Notre equipe vous accueille du lundi au vendredi.</p>"


def u():
    return usage(12000, 900)


def work_report(path, title, criteria):
    return complete(9, summary=f"{title} ecrit.", deliverables=[{"path": path, "title": title}],
                    criteriaClaims=[{"criterionId": c, "claim": "met", "evidence": [{"type": "file", "ref": path}]} for c in criteria],
                    summaryUpdate=f"{title} fait.", handoffNote=f"Fichier : {path}")


def site_plan():
    return {"goal": "Creer la page vitrine du cabinet", "language": "fr", "assumptions": [{"id": "A1", "text": "Deux pages"}],
            "criteria": [{"id": "C1", "text": "La page d'accueil existe", "kind": "auto", "check": {"type": "file_exists", "path": "site/index.html", "minBytes": 20}},
                         {"id": "C2", "text": "Aucun texte d'exemple ne reste dans l'accueil", "kind": "auto",
                          "check": {"type": "file_contains", "path": "site/index.html", "mustContain": ["Cabinet"], "mustNotContain": ["lorem ipsum"]}},
                         {"id": "C3", "text": "La page A propos presente l'equipe", "kind": "rubric", "rubric": "Une phrase sur l'equipe, aucun chiffre invente."}],
            "steps": [{"id": "S1", "title": "Page d'accueil", "worker": "lucas", "goal": "Ecrire la page d'accueil", "criteriaIds": ["C1", "C2"], "expectedOutputs": ["site/index.html"],
                       "estimateCredits": 6},
                      {"id": "S2", "title": "Page A propos", "worker": "emma", "goal": "Ecrire la page A propos", "criteriaIds": ["C3"], "expectedOutputs": ["site/about.html"],
                       "estimateCredits": 6}],
            "estimate": {"creditsMin": 12, "creditsMax": 30, "hoursMin": 0.2, "hoursMax": 0.5}}


def site_cassettes():
    ver = lambda c2, c2_ev: {"criteria": [  # noqa: E731
        {"id": "C1", "verdict": "PASS", "note": "La page existe.", "evidence": [{"type": "file", "ref": "site/index.html"}]},
        {"id": "C2", "verdict": c2, "note": "Verifie dans le fichier.", "evidence": c2_ev, "fixHint": "Remplacer le texte d'exemple par un vrai texte"},
        {"id": "C3", "verdict": "PASS", "note": "Presente l'equipe.", "evidence": [{"type": "excerpt", "ref": "site/about.html", "quote": "Notre equipe vous accueille"}]}],
        "overall": "PASS" if c2 == "PASS" else "FAIL", "summary": "Verification terminee."}
    return {
        "PLAN1-1": [msg([tu(1, "project_plan", {"action": "set", "plan": site_plan()}), complete(2, summary="Plan pret.")], "tool_use", u=u())],
        "S1-1": [msg([tu(1, "workspace_list", {"path": ""})], "tool_use", u=u()),
                 msg([tu(2, "workspace_write", {"path": "site/index.html", "content": BAD_HTML, "mode": "create"})], "tool_use", u=u()),
                 msg([tu(3, "deliverable_register", {"path": "site/index.html", "title": "Accueil", "kind": "site"}), work_report("site/index.html", "Accueil", ["C1", "C2"])], "tool_use", u=u())],
        "S2-1": [msg([tu(1, "workspace_write", {"path": "site/about.html", "content": ABOUT_HTML, "mode": "create"})], "tool_use", u=u()),
                 msg([tu(2, "deliverable_register", {"path": "site/about.html", "title": "A propos", "kind": "site"}), work_report("site/about.html", "A propos", ["C3"])], "tool_use", u=u())],
        "VER1-1": [msg([tu(1, "workspace_read", {"path": "site/index.html"})], "tool_use", u=u()),
                   msg([complete(2, summary="Un critere echoue.", verification=ver("FAIL", [{"type": "excerpt", "ref": "site/index.html", "quote": "Lorem ipsum dolor sit amet"}]))], "tool_use", u=u())],
        "VERC1-1": [msg([tu(1, "workspace_read", {"path": "site/about.html"}),
                         complete(2, summary="Aucune contradiction.", verification={"criteria": [{"id": "C-coherence", "verdict": "PASS", "note": "Memes faits, meme ton.", "evidence": [
                             {"type": "excerpt", "ref": "site/index.html", "quote": "Cabinet de physiotherapie"}, {"type": "excerpt", "ref": "site/about.html", "quote": "Notre equipe vous accueille"}]}],
                             "consistency": [], "overall": "PASS", "summary": "Coherent."})], "tool_use", u=u())],
        "FIX1-1-1": [msg([tu(1, "workspace_read", {"path": "site/index.html"})], "tool_use", u=u()),
                     msg([tu(2, "workspace_write", {"path": "site/index.html", "content": GOOD_HTML, "mode": "overwrite"})], "tool_use", u=u()),
                     msg([work_report("site/index.html", "Accueil corrige", ["C2"])], "tool_use", u=u())],
        "VER2-1": [msg([complete(1, summary="Tout est conforme.", verification=ver("PASS", [{"type": "excerpt", "ref": "site/index.html", "quote": "Prenez rendez-vous au 021 555 12 34"}]))], "tool_use", u=u())],
        "VERC2-1": [msg([complete(1, summary="Toujours coherent.", verification={"criteria": [{"id": "C-coherence", "verdict": "PASS", "note": "ok", "evidence": [
            {"type": "excerpt", "ref": "site/index.html", "quote": "Cabinet de physiotherapie"}]}], "consistency": [], "overall": "PASS"})], "tool_use", u=u())],
        "CONS1-1": [msg([complete(1, summary="Votre page vitrine est livree : site/index.html et site/about.html. Il reste a completer l'adresse du cabinet et a relire les textes avant publication.")],
                        "tool_use", u=u())],
    }


class PsEnv(Env):
    """Moteur de projets complet (Python) dont le lanceur d'étape est le vrai script PowerShell, relié à la fausse API par un pilote."""

    def __init__(self, cassettes, **kw):
        self.cassettes = cassettes
        kw["runner_cmd"] = lambda i, o: [PWSH, "-NoProfile", "-NonInteractive", "-File", self.driver, i, o]
        super().__init__(**kw)
        tpl = rh._template()
        for dp, _dirs, files in os.walk(tpl):                      # les fichiers du lanceur ; ceux que le banc a déjà posés (limites) ne sont pas écrasés
            rel = os.path.relpath(dp, tpl)
            os.makedirs(os.path.join(self.root, rel), exist_ok=True)
            for f in files:
                dst = os.path.join(self.root, rel, f)
                if not os.path.exists(dst):
                    shutil.copy2(os.path.join(dp, f), dst)
        for w in ("chloe", "lucas", "emma", "lea"):
            src = os.path.join(rh.REPO, "chloe" if w == "chloe" else os.path.join("workers", w), "identity")
            dst = os.path.join(self.root, "chloe" if w == "chloe" else os.path.join("workers", w), "identity")
            if os.path.isdir(src) and not os.path.isdir(dst):
                shutil.copytree(src, dst)
        os.makedirs(os.path.join(self.root, "_test", "cassettes"), exist_ok=True)
        shutil.copy2(os.path.join(rh.HERE, "fake_api.ps1"), os.path.join(self.root, "_test", "fake_api.ps1"))
        self.driver = os.path.join(self.root, "_test", "driver.ps1")
        with open(self.driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        for name, responses in cassettes.items():
            with open(os.path.join(self.root, "_test", "cassettes", name + ".json"), "w", encoding="utf-8") as f:
                json.dump({"responses": responses}, f)
        for sub in ("runtime/tasks", "memory/runtime"):
            os.makedirs(os.path.join(self.root, sub), exist_ok=True)

    def log(self, name):
        p = os.path.join(self.root, "_test", "logs", name + ".jsonl")
        if not os.path.isfile(p):
            return []
        with open(p, encoding="utf-8") as f:
            return [json.loads(x) for x in f if x.strip()]

    def read(self, pid, *parts):
        with open(os.path.join(self.svc.store.project_dir(pid), *parts), encoding="utf-8") as f:
            return f.read()


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) non installe")
class PipelineTests(unittest.TestCase):
    def setUp(self):
        self._env = {k: os.environ.get(k) for k in ("FAKE_KEY", "BK_SECRET_ANTHROPIC", "BK_PROJECT_BACKOFF_SCALE", "BK_PROJECT_CONVO_CACHE")}
        os.environ.update(FAKE_KEY=FAKE_KEY, BK_SECRET_ANTHROPIC=FAKE_KEY, BK_PROJECT_BACKOFF_SCALE="0.001")
        self.addCleanup(self._restore)

    def _restore(self):
        for k, v in self._env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def env(self, cassettes, **kw):
        e = PsEnv(cassettes, **kw)
        self.addCleanup(e.close)
        return e

    # ------------------------------------------------------------------ plan -> étapes -> vérification refusée -> correction -> terminé
    def test_a_project_plans_works_fails_one_criterion_fixes_it_and_completes(self):
        e = self.env(site_cassettes(), tick_sec=0.2)
        pid = e.create(goal="Creer la page vitrine de mon cabinet de physiotherapie a Lausanne")
        st = e.run_to_done(pid, timeout=420)
        self.assertEqual(st["status"], "DONE", json.dumps({k: (v["status"], v.get("error")) for k, v in st["steps"].items()}))
        # -- l'ordre réel des étapes, avec le Worker propriétaire de chacune
        kinds = {sid: (s["kind"], s["worker"], s["status"]) for sid, s in st["steps"].items()}
        self.assertEqual(kinds["PLAN1"][:2], ("plan", "chloe"))
        self.assertEqual(kinds["S1"][:2], ("execute", "lucas"))
        self.assertEqual(kinds["S2"][:2], ("execute", "emma"))
        self.assertEqual(kinds["VER1"][0], "verify")
        self.assertEqual(kinds["VERC1"][0], "verify")                                                 # deux Workers ont produit : relecture de coherence
        self.assertEqual(kinds["FIX1-1"], ("fix", "lucas", "DONE"))                                 # la correction va au Worker qui possède le critère
        self.assertEqual(kinds["VER2"][0], "verify")
        self.assertEqual(kinds["CONS1"][0], "consolidate")
        self.assertEqual((st["counters"]["verifyRounds"], st["counters"]["fixRounds"]), (2, 1))
        # -- la vérification : refus puis accord, verdicts décidés par le moteur
        v1 = json.loads(e.read(pid, "verification", "1", "verification.json"))
        v2 = json.loads(e.read(pid, "verification", "2", "verification.json"))
        self.assertEqual({c["id"]: c["verdict"] for c in v1["criteria"]}, {"C1": "PASS", "C2": "FAIL", "C3": "PASS", "C-coherence": "PASS"})
        self.assertEqual(v1["overall"], "FAIL")
        self.assertEqual({c["id"]: c["verdict"] for c in v2["criteria"]}, {"C1": "PASS", "C2": "PASS", "C3": "PASS", "C-coherence": "PASS"})
        self.assertTrue(all(c["evidence"] for c in v2["criteria"]))                                   # aucun PASS sans preuve résolue
        c2 = next(c for c in v1["criteria"] if c["id"] == "C2")
        self.assertTrue(any(ev["type"] == "check" for ev in c2["evidence"]))                          # le contrôle typé du moteur a tranché
        # -- les fichiers livrés : la version corrigée, pas l'ancienne
        index = open(e.wspath(pid, "site/index.html"), encoding="utf-8").read()
        self.assertIn("021 555 12 34", index)
        self.assertNotIn("Lorem", index)
        reg = json.loads(e.read(pid, "deliverables.json"))["items"]
        self.assertEqual({d["path"] for d in reg}, {"site/index.html", "site/about.html"})
        import hashlib
        entry = next(d for d in reg if d["path"] == "site/index.html")
        self.assertEqual(entry["sha256"], hashlib.sha256(index.encode("utf-8")).hexdigest())
        # -- la correction a reçu le constat du contrôleur ; le relais entre étapes existe
        fix_ctx = e.read(pid, "steps", "FIX1-1", "1", "context.md")
        self.assertIn("Remplacer le texte d'exemple", fix_ctx)
        self.assertIn("C2", fix_ctx)
        self.assertIn("Fichier : site/index.html", e.read(pid, "workspace", "handoff", "S1.md"))
        # -- chaque phase a son modèle ; le contrôleur n'a aucun outil d'écriture et une identité neutre
        self.assertEqual(e.log("PLAN1-1")[0]["model"], "claude-opus-5-5")
        self.assertEqual(e.log("S1-1")[0]["model"], "claude-sonnet-5-5")
        self.assertEqual(e.log("VER1-1")[0]["model"], "claude-opus-5-5")
        ver_call = e.log("VER1-1")[0]
        self.assertNotIn("workspace_write", ver_call["toolNames"])
        self.assertNotIn("use_connector", ver_call["toolNames"])
        self.assertIn("CONTROLEUR QUALITE", ver_call["systemText"])
        self.assertIn("PROJECT ADDENDUM", e.log("S1-1")[0]["systemText"])
        self.assertIn("RELECTURE DE COHERENCE", e.log("VERC1-1")[0]["systemText"])
        self.assertIn("VERIFICATION INDEPENDANTE", ver_call["systemText"])
        # -- rapport final : gabarit fixe, verdicts du tour 2
        report = e.read(pid, "final-report.md")
        for n in range(1, 9):
            self.assertIn(f"## {n}.", report)
        self.assertIn("| C2 — Aucun texte d'exemple ne reste dans l'accueil | PASS", report)
        # -- coût : chaque réponse de l'API est comptée une fois, réglée au grand livre d'usage
        ledger = e.svc.store.read_jsonl(pid, "cost-ledger.jsonl")
        self.assertEqual({r["stepId"] for r in ledger}, {"PLAN1", "S1", "S2", "VER1", "VERC1", "FIX1-1", "VER2", "VERC2", "CONS1"})
        self.assertGreater(st["budget"]["creditsCharged"], 0)
        self.assertEqual(sum(a for _r, a in e.usage.settled), st["budget"]["creditsCharged"])
        self.assertEqual(e.usage.rsv, {})                                                              # aucune réservation oubliée
        # -- aucun secret dans aucun fichier du projet
        for dp, _d, files in os.walk(e.svc.store.project_dir(pid)):
            for f in files:
                with open(os.path.join(dp, f), "rb") as fh:
                    self.assertNotIn(FAKE_KEY.encode(), fh.read(), os.path.join(dp, f))

    # ------------------------------------------------------------------ une action sortante attend le client
    def test_an_outward_action_prepared_by_the_runner_waits_for_the_client_and_runs_once(self):
        plan = {"goal": "Annoncer l'ouverture puis ecrire la page", "language": "fr",
                "criteria": [{"id": "C1", "text": "L'annonce est partie", "kind": "auto", "check": {"type": "approval_executed", "kind": "slack", "minCount": 1}},
                             {"id": "C2", "text": "La page existe", "kind": "auto", "check": {"type": "file_exists", "path": "site/index.html", "minBytes": 10}}],
                "steps": [{"id": "S1", "title": "Annonce", "worker": "emma", "goal": "Preparer l'annonce Slack", "criteriaIds": ["C1"], "connectors": ["slack"], "estimateCredits": 5},
                          {"id": "S2", "title": "Page", "worker": "lucas", "goal": "Ecrire la page", "criteriaIds": ["C2"], "expectedOutputs": ["site/index.html"],
                           "requiresApprovalsFrom": ["S1"], "estimateCredits": 5}],
                "estimate": {"creditsMin": 10, "creditsMax": 25, "hoursMin": 0.1, "hoursMax": 0.3}}
        ver = {"criteria": [{"id": "C1", "verdict": "PASS", "evidence": [], "note": "Action executee."},
                            {"id": "C2", "verdict": "PASS", "evidence": [{"type": "file", "ref": "site/index.html"}], "note": "ok"}], "overall": "PASS"}
        cass = {
            "PLAN1-1": [msg([tu(1, "project_plan", {"action": "set", "plan": plan}), complete(2, summary="Plan pret.")], "tool_use", u=u())],
            "S1-1": [msg([tu(1, "use_connector", {"connectorId": "slack", "operation": "POST_MESSAGE", "reason": "ouverture",
                                                  "params": {"channel": "#general", "text": "Le cabinet ouvre lundi."}})], "tool_use", u=u()),
                     msg([complete(2, summary="Annonce preparee, en attente de votre validation.", remaining=["Validation du client"])], "tool_use", u=u())],
            "S2-1": [msg([tu(1, "workspace_write", {"path": "site/index.html", "content": GOOD_HTML, "mode": "create"})], "tool_use", u=u()),
                     msg([tu(2, "deliverable_register", {"path": "site/index.html", "title": "Accueil"}), work_report("site/index.html", "Accueil", ["C2"])], "tool_use", u=u())],
            "VER1-1": [msg([complete(1, summary="Conforme.", verification=ver)], "tool_use", u=u())],
            "CONS1-1": [msg([complete(1, summary="La page est livree et l'annonce a ete envoyee apres votre validation.")], "tool_use", u=u())],
        }
        e = self.env(cass, connectors=("slack",), limits={"approvals": {"executeSpacingSec": 0}}, tick_sec=0.2)
        pid = e.create(goal="Annoncer l'ouverture du cabinet sur Slack puis ecrire la page d'accueil")
        st = e.drive(pid, lambda s: s["status"] == "WAITING_APPROVAL", timeout=240)
        self.assertEqual(st["steps"]["S2"]["blockedReason"], "APPROVAL")
        self.assertEqual(e.connector_calls, [])                                                       # rien n'est parti sans le client
        rows = e.svc.list_approvals(CLIENT, pid)["approvals"]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["status"], rows[0]["connectorId"], rows[0]["operation"], rows[0]["risk"], rows[0]["worker"]), ("PENDING", "slack", "POST_MESSAGE", "medium", "emma"))
        self.assertEqual(rows[0]["params"], {"channel": "#general", "text": "Le cabinet ouvre lundi."})
        self.assertIn("QUEUED:APR-", json.dumps(e.log("S1-1")[1]["lastMessage"]))                      # le Worker a reçu « mis en file » et a continué
        e.svc.approve_approval(CLIENT, pid, rows[0]["id"])
        self.assertTrue(e.svc.executor.wait_idle(30))
        st = e.run_to_done(pid, timeout=300)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual(len(e.connector_calls), 1)
        self.assertEqual(e.connector_calls[0][:2], ("slack", "POST_MESSAGE"))
        v = json.loads(e.read(pid, "verification", "1", "verification.json"))
        self.assertEqual(v["overall"], "PASS")


if __name__ == "__main__":
    unittest.main(verbosity=2)
