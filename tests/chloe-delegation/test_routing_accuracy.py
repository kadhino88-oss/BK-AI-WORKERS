"""Precision du routage de Chloe : l'ANCIEN routeur (mots-cles, puis repli IA qui renvoie des identifiants) contre le NOUVEAU (routeur a modele, plan de
sous-taches), sur un jeu de demandes de clients etiquetees a la main (routing_cases.json : 17 Workers, plusieurs metiers, paraphrases, autres langues,
salutations, textes qui cherchent a detourner le routeur).

  - HarnessSynthetic : le banc d'essai et les cles de cassette sont verifies avec une cassette fabriquee ici (aucun modele reel).
  - RecordedAccuracy : rejeu HORS LIGNE de la cassette enregistree avec le VRAI modele (record_routing.ps1, une fois, avec l'accord du proprietaire pour
    la depense) : aucun reseau, aucun cout. Si le prompt du routeur ou les mots-cles changent, la cassette est perimee et le test le dit :
    relancer record_routing.ps1 (voir docs/CHLOE-DELEGATION.md).

PowerShell 7 requis.   wsl -e python3 tests/chloe-delegation/test_routing_accuracy.py
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import PWSH, REPO, as_list  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
CASES = os.path.join(HERE, "routing_cases.json")
CASSETTE = os.path.join(HERE, "routing_cassette.json")


def load_cases():
    with open(CASES, encoding="utf-8") as f:
        return json.load(f)["cases"]


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def replay(cassette_path, cases_path=CASES):
    """Rejoue les demandes avec la cassette (replay_routing.ps1, dans PowerShell 7) et renvoie le document de predictions."""
    tmp = tempfile.mkdtemp(prefix="bkreplay-")
    out = os.path.join(tmp, "out.json")
    env = dict(os.environ, REPO=REPO, CASES_FILE=cases_path, CASSETTE_FILE=cassette_path, OUT_FILE=out)
    p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", os.path.join(HERE, "replay_routing.ps1")], capture_output=True, text=True,
                       encoding="utf-8", errors="replace", env=env, timeout=900)
    assert os.path.isfile(out), p.stdout + p.stderr
    with open(out, encoding="utf-8-sig") as f:
        return json.load(f)


def score(predicted, case):
    """(exact, rappel, precision) d'un ensemble de Workers contre must / may du cas."""
    p, must, ok = set(predicted), set(case["must"]), set(case["must"]) | set(case["may"])
    recall = 1.0 if not must else len(p & must) / len(must)
    precision = (1.0 if not p else len(p & ok) / len(p)) if must else (1.0 if not p else 0.0)
    exact = must <= p <= ok
    return exact, recall, precision


def evaluate(cases, predictions, router):
    """Moyennes d'un routeur ('old' ou 'new') ; un cas « direct » est reussi quand rien n'est delegue et que le routeur a repondu lui-meme."""
    by_id = {p["id"]: p for p in predictions}
    rows = []
    for c in cases:
        pred = by_id[c["id"]]
        r = pred[router]
        workers = as_list(r["workers"])
        if c["kind"] == "direct":
            good = not workers and (r["mode"] == "direct_reply" if router == "new" else bool(r["direct"]))
            rows.append({"id": c["id"], "kind": c["kind"], "exact": good, "recall": 1.0 if good else 0.0, "precision": 1.0 if good else 0.0, "workers": workers})
            continue
        exact, recall, precision = score(workers, c)
        rows.append({"id": c["id"], "kind": c["kind"], "exact": exact, "recall": recall, "precision": precision, "workers": workers})
    n = len(rows)
    f1s = [0.0 if (r["recall"] + r["precision"]) == 0 else 2 * r["recall"] * r["precision"] / (r["recall"] + r["precision"]) for r in rows]
    return {"exact": sum(r["exact"] for r in rows) / n, "recall": sum(r["recall"] for r in rows) / n, "precision": sum(r["precision"] for r in rows) / n,
            "f1": sum(f1s) / n, "rows": rows}


def by_kind(result):
    out = {}
    for r in result["rows"]:
        out.setdefault(r["kind"], []).append(r["exact"])
    return {k: sum(v) / len(v) for k, v in out.items()}


def synthetic_cassette(cases, new_plans, legacy_answers):
    """Cassette fabriquee : pour chaque demande, la reponse (appel d'outil) du nouveau routeur et celle (texte JSON) de l'ancien."""
    entries = {}
    for c in cases:
        user_new = "Plan the work for this client request.\n\n<client_request>\n" + c["request"] + "\n</client_request>"
        plan = new_plans[c["id"]]
        entries[sha(user_new)] = {"id": "msg_n", "type": "message", "role": "assistant", "stop_reason": "tool_use", "usage": {"input_tokens": 3000, "output_tokens": 200},
                                  "content": [{"type": "tool_use", "id": "toolu_1", "name": "submit_route_plan", "input": plan}]}
        entries[sha(c["request"])] = {"id": "msg_o", "type": "message", "role": "assistant", "stop_reason": "end_turn", "usage": {"input_tokens": 900, "output_tokens": 30},
                                      "content": [{"type": "text", "text": json.dumps(legacy_answers[c["id"]])}]}
    return {"meta": {"schema": "BK-ROUTING-CASSETTE-V1", "model": "claude-haiku-5-5"}, "entries": entries}


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class HarnessSynthetic(unittest.TestCase):
    def test_the_harness_replays_both_routers_from_a_cassette_with_exact_keys(self):
        cases = [c for c in load_cases() if c["id"] in ("s-lea", "d-nora", "p-nora", "x-greet", "m-site")]
        plans = {
            "s-lea": {"mode": "mission", "subtasks": [{"id": "T1", "worker": "lea", "objective": "Cree le logo et la charte du cabinet."}]},
            "d-nora": {"mode": "mission", "subtasks": [{"id": "T1", "worker": "nora", "objective": "Reponds au client qui conteste sa facture."}]},
            "p-nora": {"mode": "mission", "subtasks": [{"id": "T1", "worker": "nora", "objective": "Reponds aux questions des clients."}]},
            "x-greet": {"mode": "direct_reply", "directReply": "Bonjour ! Que puis-je faire pour vous ?", "subtasks": []},
            "m-site": {"mode": "mission", "subtasks": [
                {"id": "T1", "worker": "lea", "objective": "Cree l'identite visuelle du cabinet."}, {"id": "T2", "worker": "emma", "objective": "Ecris les textes des pages."},
                {"id": "T3", "worker": "lucas", "objective": "Construis les pages.", "dependsOn": ["T1", "T2"]},
                {"id": "T4", "worker": "seoya", "objective": "Optimise le referencement.", "dependsOn": ["T3"]}]},
        }
        legacy = {"s-lea": {"workers": ["lea"], "direct_reply": None}, "d-nora": {"workers": ["nora"], "direct_reply": None},
                  "p-nora": {"workers": ["nora"], "direct_reply": None}, "x-greet": {"workers": [], "direct_reply": "Bonjour !"},
                  "m-site": {"workers": ["lucas"], "direct_reply": None}}
        tmp = tempfile.mkdtemp(prefix="bkcas-")
        cases_path, cassette_path = os.path.join(tmp, "cases.json"), os.path.join(tmp, "cassette.json")
        with open(cases_path, "w", encoding="utf-8") as f:
            json.dump({"cases": cases}, f, ensure_ascii=False)
        with open(cassette_path, "w", encoding="utf-8") as f:
            json.dump(synthetic_cassette(cases, plans, legacy), f, ensure_ascii=False)
        doc = replay(cassette_path, cases_path)
        got = {p["id"]: p for p in doc["predictions"]}
        self.assertEqual(as_list(got["s-lea"]["new"]["workers"]), ["lea"])
        self.assertEqual(got["x-greet"]["new"]["mode"], "direct_reply")
        self.assertEqual(as_list(got["m-site"]["new"]["workers"]), ["lea", "emma", "lucas", "seoya"])
        self.assertEqual(as_list(got["m-site"]["new"]["edges"]), ["T1->T3", "T2->T3", "T3->T4"])
        self.assertEqual(got["s-lea"]["old"]["via"], "keywords", "l'ancien routeur lit les mots-cles d'abord (« logo »)")
        self.assertEqual(got["m-site"]["old"]["via"], "ai", "aucun mot-cle sans accent dans « identité visuelle » : l'ancien routeur passe au repli IA")
        self.assertEqual(as_list(got["m-site"]["old"]["workers"]), ["lucas"])
        self.assertEqual(got["x-greet"]["old"]["via"], "ai")
        self.assertTrue(got["x-greet"]["old"]["direct"])
        self.assertEqual(as_list(got["p-nora"]["old"]["workers"]), ["nora"], "aucun mot-cle : repli IA de l'ancien routeur")
        old, new = evaluate(cases, doc["predictions"], "old"), evaluate(cases, doc["predictions"], "new")
        self.assertGreater(new["exact"], old["exact"])
        self.assertEqual(len(doc["promptSha"]), 64)


@unittest.skipUnless(PWSH and os.path.isfile(CASSETTE), "cassette d'enregistrement reel absente (record_routing.ps1)")
class RecordedAccuracy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(CASSETTE, encoding="utf-8") as f:
            cls.meta = json.load(f)["meta"]
        cls.cases = load_cases()
        cls.doc = replay(CASSETTE)
        cls.old = evaluate(cls.cases, cls.doc["predictions"], "old")
        cls.new = evaluate(cls.cases, cls.doc["predictions"], "new")
        cls.pred = {p["id"]: p for p in cls.doc["predictions"]}
        print("\n  routeur            exact  rappel  precision    F1")
        for name, r in (("ancien (mots-cles+IA)", cls.old), ("nouveau (modele)    ", cls.new)):
            print(f"  {name}  {r['exact']:.2f}   {r['recall']:.2f}    {r['precision']:.2f}      {r['f1']:.2f}")
        print("  par sorte de demande, exact : ancien", {k: round(v, 2) for k, v in by_kind(cls.old).items()}, "nouveau", {k: round(v, 2) for k, v in by_kind(cls.new).items()})
        print(f"  cassette : {cls.meta['model']}, {cls.meta['apiCalls']} appels, {cls.meta['inputTokens']} jetons en entree, {cls.meta['outputTokens']} en sortie, "
              f"cout estime {cls.meta['estimatedCostUsd']} USD")

    def test_the_cassette_is_for_the_current_prompt_and_keywords(self):
        self.assertEqual(self.doc["promptSha"], self.meta["promptSha"], "le prompt du routeur a change : relancer tests/chloe-delegation/record_routing.ps1")
        self.assertEqual(self.doc["routingSha"], self.meta["routingSha"], "worker-routing.json a change : relancer record_routing.ps1")
        self.assertEqual(self.meta["cases"], len(self.cases))
        self.assertLessEqual(self.meta["estimatedCostUsd"], 1.5)

    def test_the_new_router_beats_the_old_one(self):
        self.assertGreater(self.new["f1"], self.old["f1"])
        self.assertGreater(self.new["exact"], self.old["exact"])
        self.assertGreaterEqual(self.new["recall"], self.old["recall"])

    def test_the_new_router_covers_what_the_client_asked_for(self):
        self.assertGreaterEqual(self.new["recall"], 0.9)
        self.assertGreaterEqual(self.new["precision"], 0.85)
        self.assertGreaterEqual(self.new["exact"], 0.7)

    def test_multi_trade_requests_get_every_trade(self):
        for c in self.cases:
            if c["kind"] != "multi":
                continue
            got = set(as_list(self.pred[c["id"]]["new"]["workers"]))
            self.assertTrue(set(c["must"]) <= got or len(set(c["must"]) & got) >= len(c["must"]) - 1, (c["id"], sorted(got), c["must"]))

    def test_nothing_the_client_writes_gets_atlas_or_an_invented_worker_or_everyone_delegated_to(self):
        known = {"alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya", "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis"}
        for pid, p in self.pred.items():
            workers = set(as_list(p["new"]["workers"]))
            self.assertTrue(workers <= known, (pid, workers))
            self.assertLessEqual(len(workers), 6, (pid, "jamais tous les Workers pour une seule demande", workers))
        for cid in ("a-all-workers", "a-fence"):
            self.assertEqual(as_list(self.pred[cid]["new"]["workers"]), next(c["must"] for c in self.cases if c["id"] == cid), cid)

    def test_greetings_and_questions_about_the_service_are_answered_without_a_worker(self):
        for cid in ("x-greet", "x-price"):
            self.assertEqual((self.pred[cid]["new"]["mode"], as_list(self.pred[cid]["new"]["workers"])), ("direct_reply", []), cid)

    def test_independent_parts_are_declared_independent(self):
        multi = [c for c in self.cases if c["kind"] == "multi" and len(c["must"]) >= 3]
        with_parallel = 0
        for c in multi:
            p = self.pred[c["id"]]["new"]
            n = len(as_list(p["workers"]))
            if len(as_list(p["edges"])) < n * (n - 1) // 2 and len(as_list(p["edges"])) < n:
                with_parallel += 1
        self.assertGreaterEqual(with_parallel, max(1, len(multi) - 1), "le routeur doit laisser des parties en parallele, pas tout enchainer")


if __name__ == "__main__":
    unittest.main(verbosity=2)
