# -*- coding: utf-8 -*-
"""File d'approbations d'un projet : de l'article préparé par un Worker à l'exécution UNE fois, en passant par le refus, la modification, les lots,
le risque élevé (confirmation saisie), l'expiration, le redémarrage, l'annulation et l'isolation entre clients. Faux lanceur, faux connecteur.

    python tests/projects/test_approvals.py"""
import copy
import json
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from engine_harness import CLIENT, CLIENT_B, Env, iso  # noqa: E402
import fake_runner  # noqa: E402
import projects_approvals as pa  # noqa: E402
import projects_store as ps  # noqa: E402

FAST = {"approvals": {"executeSpacingSec": 0, "executePerMinutePerClient": 1000}}


def work(path):
    return [{"tool": "workspace_write", "input": {"path": path, "mode": "overwrite", "content": f"<h1>{path}</h1> contenu"}},
            {"tool": "deliverable_register", "input": {"path": path, "title": path}}]


def ask(conn="slack", op="POST_MESSAGE", params=None, **extra):
    inp = {"connectorId": conn, "operation": op, "title": extra.pop("title", "Annonce au client"), "what": "Envoie le message",
           "params": params or {"channel": "#general", "text": "Bonjour à tous"}}
    inp.update(extra)
    return {"tool": "request_approval", "input": inp}


def plan_with_approval_gate():
    """Le plan par défaut du faux lanceur, où S3 attend les actions préparées par S2 (requiresApprovalsFrom)."""
    plan = copy.deepcopy(fake_runner.default_plan({}))
    plan["steps"][2]["requiresApprovalsFrom"] = ["S2"]
    return {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan pret."}}


def s2_asking(*asks):
    return {"actions": work("site/about.html") + list(asks)}


class ApprovalTests(unittest.TestCase):
    def env(self, asks=None, connectors=("slack", "wordpress", "twilio"), gate=True, **kw):
        scenario = kw.pop("scenario", {})
        if gate:
            scenario.setdefault("plan", plan_with_approval_gate())
        if asks is not None:
            scenario["S2"] = s2_asking(*asks)
        limits = kw.pop("limits", FAST)
        e = Env(connectors=connectors, scenario=scenario, limits=limits, **kw)
        self.addCleanup(e.close)
        return e

    def waiting(self, e, pid):
        """Le projet attend les validations : S2 a préparé ses actions, S3 est bloquée, rien d'autre ne tourne."""
        st = e.drive(pid, lambda s: s["status"] == "WAITING_APPROVAL", timeout=60)
        self.assertEqual(st["steps"]["S3"]["status"], "BLOCKED")
        self.assertEqual(st["steps"]["S3"]["blockedReason"], "APPROVAL")
        return st

    def items(self, e, pid, status=None):
        return e.svc.list_approvals(CLIENT, pid, status)["approvals"]

    def settle(self, e):
        self.assertTrue(e.svc.executor.wait_idle(20))

    # ------------------------------------------------------------------ parcours complet
    def test_pending_to_executed_exactly_once_then_the_project_continues_and_finishes(self):
        e = self.env([ask()])
        pid = e.create()
        self.waiting(e, pid)
        rows = self.items(e, pid)
        self.assertEqual(len(rows), 1)
        a = rows[0]
        self.assertEqual((a["status"], a["risk"], a["connectorId"], a["operation"], a["worker"], a["stepId"]), ("PENDING", "medium", "slack", "POST_MESSAGE", "emma", "S2"))
        self.assertFalse(a["reversible"])
        self.assertEqual(e.connector_calls, [])                                                    # rien ne part sans le client
        e.svc.drain_notifications()
        self.assertEqual([n[1] for n in e.notifications].count("approval_needed"), 1)             # un seul e-mail, sans contenu
        out = e.svc.approve_approval(CLIENT, pid, a["id"])
        self.assertEqual(out["status"], "EXECUTING")
        self.settle(e)
        st = e.run_to_done(pid)
        self.assertEqual(st["status"], "DONE")
        self.assertEqual(len(e.connector_calls), 1)                                                # une seule exécution
        self.assertEqual(e.connector_calls[0], ("slack", "POST_MESSAGE", {"channel": "#general", "text": "Bonjour à tous"}, CLIENT))
        done = self.items(e, pid)[0]
        self.assertEqual((done["status"], done["execution"]["connectorStatus"]), ("EXECUTED", "SUCCESS"))
        self.assertTrue(done["execution"]["startedUtc"] and done["execution"]["finishedUtc"])
        types = [x["type"] for x in e.events(pid)]
        for t in ("approval_created", "approval_decided", "approval_executed"):
            self.assertIn(t, types)
        report = open(os.path.join(e.svc.store.project_dir(pid), "final-report.md"), encoding="utf-8").read()
        self.assertIn("EXECUTED", report)

    def test_a_step_that_requires_the_approvals_of_another_waits_for_it_even_without_a_dependency(self):
        plan = copy.deepcopy(fake_runner.default_plan({}))
        plan["steps"] = [dict(plan["steps"][0], id="S1", worker="emma", criteriaIds=["C1"], expectedOutputs=["site/index.html"]),
                         dict(plan["steps"][1], id="S2", worker="lucas", criteriaIds=["C2"], expectedOutputs=["site/about.html"], requiresApprovalsFrom=["S1"])]
        scen = {"plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan pret."}},
                "S1": {"actions": work("site/index.html") + [ask()]}}
        e = self.env(scenario=scen, gate=False)
        pid = e.create()
        st = e.drive(pid, lambda s: s["status"] == "WAITING_APPROVAL", timeout=60)
        self.assertEqual(st["steps"]["S1"]["status"], "DONE")
        self.assertEqual((st["steps"]["S2"]["status"], st["steps"]["S2"]["blockedReason"]), ("BLOCKED", "APPROVAL"))     # S2 n'a pas démarré
        self.assertFalse(os.path.exists(e.wspath(pid, "site/about.html")))
        e.svc.approve_approval(CLIENT, pid, self.items(e, pid)[0]["id"])
        self.settle(e)
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")

    def test_a_second_approval_of_the_same_action_never_executes_twice(self):
        e = self.env([ask()])
        pid = e.create()
        self.waiting(e, pid)
        aid = self.items(e, pid)[0]["id"]
        results = []

        def go():
            try:
                results.append(e.svc.approve_approval(CLIENT, pid, aid)["status"])
            except ps.ProjectError as ex:
                results.append(ex.code)
        threads = [threading.Thread(target=go) for _ in range(4)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        self.settle(e)
        self.assertEqual(results.count("EXECUTING"), 1)
        self.assertEqual(results.count("APPROVAL_NOT_PENDING"), 3)
        self.assertEqual(len(e.connector_calls), 1)

    def test_a_rejected_action_never_leaves_and_the_worker_is_told(self):
        e = self.env([ask()])
        pid = e.create()
        self.waiting(e, pid)
        aid = self.items(e, pid)[0]["id"]
        self.assertEqual(e.svc.reject_approval(CLIENT, pid, aid, "Pas ce ton-là")["status"], "REJECTED")
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")
        self.assertEqual(e.connector_calls, [])
        fb = [m for m in e.svc.store.read_jsonl(pid, "inbox.jsonl") if m.get("kind") == "approval_feedback"]
        self.assertEqual(len(fb), 1)
        self.assertEqual(fb[0]["worker"], "emma")
        self.assertIn("Pas ce ton-là", fb[0]["text"])
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.approve_approval(CLIENT, pid, aid)                                              # rejeté : on ne le « dé-rejette » pas
        self.assertEqual(cm.exception.code, "APPROVAL_NOT_PENDING")

    def test_the_client_can_edit_allowed_fields_and_the_edit_is_what_leaves(self):
        e = self.env([ask(params={"channel": "#general", "text": "Version brute", "token": "x"})])
        pid = e.create()
        self.waiting(e, pid)
        a = self.items(e, pid)[0]
        self.assertEqual(sorted(a["editableFields"]), ["channel", "text"])                        # un champ secret n'est jamais modifiable
        self.assertNotEqual(a["params"]["token"], "x")                                            # ... ni affiché en clair
        for bad in ({"token": "autre"}, {"inconnu": "x"}, {"text": {"a": 1}}):
            with self.assertRaises(ps.ProjectError) as cm:
                e.svc.approve_approval(CLIENT, pid, a["id"], bad)
            self.assertEqual(cm.exception.code, "INVALID_INPUT", bad)
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.approve_approval(CLIENT, pid, a["id"], {"text": "mot de passe : hunter2xyz123"})
        self.assertEqual(cm.exception.code, "SECRET_REFUSED")
        self.assertEqual(self.items(e, pid)[0]["status"], "PENDING")                              # les refus n'ont rien consommé
        e.svc.approve_approval(CLIENT, pid, a["id"], {"text": "Version corrigée par le client"})
        self.settle(e)
        self.assertEqual(e.connector_calls[0][2]["text"], "Version corrigée par le client")
        self.assertEqual(e.connector_calls[0][2]["channel"], "#general")
        self.assertEqual(self.items(e, pid)[0]["editedFields"], ["text"])
        fb = [m for m in e.svc.store.read_jsonl(pid, "inbox.jsonl") if m.get("kind") == "approval_feedback"]
        self.assertTrue(any("modifié" in m["text"] for m in fb))                                  # le Worker apprend de la correction

    def test_a_connector_failure_is_recorded_fed_back_and_not_retried(self):
        e = self.env([ask()])
        e.connector_result = {"Status": "ERROR", "Detail": "Slack a répondu 500"}
        pid = e.create()
        self.waiting(e, pid)
        aid = self.items(e, pid)[0]["id"]
        e.svc.approve_approval(CLIENT, pid, aid)
        self.settle(e)
        a = self.items(e, pid)[0]
        self.assertEqual(a["status"], "FAILED")
        self.assertIn("500", a["execution"]["detail"])
        self.assertIn("approval_failed", [x["type"] for x in e.events(pid)])
        e.drive(pid, lambda s: s["status"] in ("DONE", "RUNNING", "VERIFYING"), timeout=60)
        self.assertEqual(len(e.connector_calls), 1)
        fb = [m for m in e.svc.store.read_jsonl(pid, "inbox.jsonl") if m.get("kind") == "approval_feedback"]
        self.assertTrue(any("échoué" in m["text"] for m in fb))

    def test_a_secret_in_a_connector_answer_is_masked(self):
        e = self.env([ask()])
        e.connector_result = {"Status": "ERROR", "Detail": "invalid token sk-ant-api03-" + "A" * 40}
        pid = e.create()
        self.waiting(e, pid)
        e.svc.approve_approval(CLIENT, pid, self.items(e, pid)[0]["id"])
        self.settle(e)
        self.assertNotIn("sk-ant", json.dumps(self.items(e, pid)))

    # ------------------------------------------------------------------ risque, lots
    def test_high_risk_needs_the_typed_confirmation_and_never_goes_in_a_batch(self):
        e = self.env([ask("slack", "POST_MESSAGE", {"channel": "#a", "text": "x"}, recipients=25, title="Envoi à 25 personnes"),
                      ask("twilio", "PLACE_CALL", {"to": "+41215551234", "script": "Bonjour"}, title="Appel au client")])
        pid = e.create()
        self.waiting(e, pid)
        rows = self.items(e, pid)
        self.assertEqual({r["operation"]: r["risk"] for r in rows}, {"POST_MESSAGE": "high", "PLACE_CALL": "high"})
        for r in rows:
            with self.assertRaises(ps.ProjectError) as cm:
                e.svc.approve_approval(CLIENT, pid, r["id"])
            self.assertEqual(cm.exception.code, "CONFIRM_REQUIRED")
            with self.assertRaises(ps.ProjectError) as cm:
                e.svc.approve_approval(CLIENT, pid, r["id"], None, "oui")
            self.assertEqual(cm.exception.code, "CONFIRM_REQUIRED")
        self.assertEqual(e.connector_calls, [])
        twilio = next(r for r in rows if r["connectorId"] == "twilio")
        batch = e.svc.batch_approvals(CLIENT, pid, [twilio["id"]], "approve")
        self.assertEqual(batch["results"][0]["error"], "BATCH_NOT_ALLOWED")
        self.assertEqual(e.connector_calls, [])
        e.svc.approve_approval(CLIENT, pid, twilio["id"], None, "J'autorise")
        self.settle(e)
        self.assertEqual([c[:2] for c in e.connector_calls], [("twilio", "PLACE_CALL")])

    def test_the_risk_is_recomputed_by_the_engine_so_an_item_cannot_understate_it(self):
        e = self.env(None, gate=False)
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        forged = {"id": "APR-0000ab01", "batchId": None, "projectId": pid, "stepId": "S1", "worker": "lucas", "createdUtc": iso(time.time()), "expiresUtc": iso(time.time() + 86400),
                  "kind": "connector_action", "connectorId": "twilio", "operation": "PLACE_CALL", "params": {"to": "+41215551234"}, "risk": "low", "status": "PENDING",
                  "display": {"title": "Un appel", "what": "Appelle"}, "dedupKey": "forged-1", "autoApproved": True}
        err, norm = pa.validate_item(e.root, CLIENT, forged, [], 0)
        self.assertIsNone(err)
        self.assertEqual(norm["risk"], "high")
        forged2 = dict(forged, id="APR-0000ab02", connectorId="slack", operation="POST_MESSAGE", params={"text": "x"}, status="EXECUTED", dedupKey="forged-2", autoApproved=True)
        err, norm = pa.validate_item(e.root, CLIENT, forged2, [], 0)
        self.assertEqual((norm["status"], norm["autoApproved"]), ("PENDING", False))             # « déjà exécuté » n'est accepté que pour un vrai brouillon
        draft = dict(forged, id="APR-0000ab03", connectorId="wordpress", operation="CREATE_DRAFT", params={"title": "x"}, status="EXECUTED", dedupKey="forged-3", autoApproved=True)
        err, norm = pa.validate_item(e.root, CLIENT, draft, [], 0)
        self.assertEqual((norm["status"], norm["autoApproved"]), ("EXECUTED", True))

    def test_a_batch_of_twelve_medium_actions_is_executed_in_order_once_each(self):
        asks = [ask(params={"channel": "#general", "text": f"Message numéro {i:02d}"}, title=f"Message {i:02d}") for i in range(12)]
        e = self.env(asks)
        pid = e.create()
        self.waiting(e, pid)
        ids = [r["id"] for r in self.items(e, pid)]
        self.assertEqual(len(ids), 12)
        self.assertEqual(len({r["batchId"] for r in self.items(e, pid)}), 1)
        res = e.svc.batch_approvals(CLIENT, pid, ids, "approve")["results"]
        self.assertEqual([x["status"] for x in res], ["EXECUTING"] * 12)
        self.settle(e)
        self.assertEqual([c[2]["text"] for c in e.connector_calls], [f"Message numéro {i:02d}" for i in range(12)])
        self.assertEqual({r["status"] for r in self.items(e, pid)}, {"EXECUTED"})
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")
        with self.assertRaises(ps.ProjectError):
            e.svc.batch_approvals(CLIENT, pid, ["APR-00000000"] * 1 + ids[:0], "burn")
        with self.assertRaises(ps.ProjectError):
            e.svc.batch_approvals(CLIENT, pid, [], "approve")

    def test_a_batch_cannot_mix_connectors_and_is_capped_at_fifty(self):
        e = self.env([ask(), ask("wordpress", "CREATE_DRAFT", {"title": "Article", "content": "Texte"}, title="Brouillon")])
        pid = e.create()
        self.waiting(e, pid)
        ids = [r["id"] for r in self.items(e, pid)]
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.batch_approvals(CLIENT, pid, ids, "approve")
        self.assertEqual(cm.exception.code, "INVALID_INPUT")
        with self.assertRaises(ps.ProjectError):
            e.svc.batch_approvals(CLIENT, pid, [f"APR-{i:08x}" for i in range(51)], "approve")
        self.assertEqual(e.connector_calls, [])

    def test_a_batch_reject_rejects_everything_and_runs_nothing(self):
        e = self.env([ask(params={"channel": "#g", "text": f"m{i}"}, title=f"M{i}") for i in range(3)])
        pid = e.create()
        self.waiting(e, pid)
        res = e.svc.batch_approvals(CLIENT, pid, [r["id"] for r in self.items(e, pid)], "reject", "Pas maintenant")["results"]
        self.assertEqual([x["status"] for x in res], ["REJECTED"] * 3)
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")
        self.assertEqual(e.connector_calls, [])

    # ------------------------------------------------------------------ ingestion : ce que le moteur refuse
    def test_ingestion_refuses_what_is_not_connected_unsafe_or_oversized_and_caps_the_queue(self):
        e = self.env(None, gate=False, limits={"approvals": {"executeSpacingSec": 0, "pendingPerProject": 3, "pendingPerClient": 4}})
        pid = e.create(auto_start=False)
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT")
        pdir = e.svc.store.project_dir(pid)
        now = time.time()

        def item(n, **over):
            d = {"id": f"APR-{n:08x}", "batchId": None, "projectId": pid, "stepId": "S1", "worker": "lucas", "createdUtc": iso(now), "expiresUtc": iso(now + 86400),
                 "kind": "connector_action", "connectorId": "slack", "operation": "POST_MESSAGE", "params": {"channel": "#g", "text": f"t{n}"}, "risk": "medium",
                 "status": "PENDING", "display": {"title": f"T{n}", "what": "Envoie"}, "dedupKey": f"k{n}"}
            d.update(over)
            return d
        rows = [item(1, connectorId="shopify", operation="CREATE_REFUND"),                           # connecteur non connecté
                item(2, params={"text": "mot de passe : hunter2xyz123"}),                              # secret
                item(3, params={"text": "x" * 9000}),                                                  # trop gros
                item(4, display={"title": "T4", "what": ""}),                                          # ce que l'action fait : obligatoire
                item(5, operation="SEARCH_MESSAGES"),                                                  # lecture : pas une action
                item(6), item(6, id="APR-00000066"),                                                   # doublon (même dedupKey)
                item(7), item(8), item(9)]                                                             # le plafond du projet (3) coupe la suite
        with open(os.path.join(pdir, "spool", "approvals-S1.jsonl"), "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
            f.write("pas du json\n")
        with e.svc.store.txn(pid) as t:
            new = e.svc._ingest_approvals(t)
        self.assertEqual(sorted(a["id"] for a in new), ["APR-00000006", "APR-00000007", "APR-00000008"])
        codes = [json.loads(x)["code"] for x in open(os.path.join(pdir, "events-engine.jsonl"), encoding="utf-8")]
        for c in ("CONNECTOR_MISSING", "SECRET_REFUSED", "TOO_LARGE", "APPROVAL_INVALID", "NOT_AN_ACTION", "APPROVAL_QUEUE_FULL"):
            self.assertIn(c, codes)
        self.assertEqual(len(self.items(e, pid)), 3)
        # plafond par client : un second projet du même client ne peut dépasser 4 en attente au total
        pid2 = e.create(auto_start=False)
        e.drive(pid2, lambda s: s["status"] == "WAITING_INPUT")
        with open(os.path.join(e.svc.store.project_dir(pid2), "spool", "approvals-S1.jsonl"), "w", encoding="utf-8") as f:
            for n in (21, 22):
                f.write(json.dumps(item(n, projectId=pid2)) + "\n")
        with e.svc.store.txn(pid2) as t:
            new2 = e.svc._ingest_approvals(t)
        self.assertEqual(len(new2), 1)

    def test_public_view_never_shows_secret_like_fields_and_truncates_long_text(self):
        v = pa.public_view({"id": "APR-00000001", "status": "PENDING", "kind": "connector_action", "display": {"title": "t"},
                            "params": {"text": "y" * 5000, "apiKey": "sk-123", "authorization": "Bearer abc", "channel": "#a"}, "risk": "low"})
        self.assertEqual(v["params"]["apiKey"], v["params"]["authorization"])
        self.assertNotIn("sk-123", json.dumps(v))
        self.assertTrue(v["params"]["text"].endswith("(tronqué)"))
        self.assertEqual(v["editableFields"], ["text", "channel"])

    # ------------------------------------------------------------------ expiration, rappels
    def test_expiry_blocks_the_dependent_step_with_a_clear_reason_and_the_client_can_ask_again(self):
        e = self.env([ask()])
        pid = e.create()
        self.waiting(e, pid)
        path = os.path.join(e.svc.store.project_dir(pid), "approvals.json")
        data = json.load(open(path, encoding="utf-8"))
        data["items"][0]["expiresUtc"] = iso(time.time() - 5)                                      # 7 jours écoulés
        json.dump(data, open(path, "w", encoding="utf-8"))
        # la maintenance des approbations passe toutes les 30 s (projects_steps.py) : un delai de 30 s etait une course perdue une fois sur deux
        st = e.drive(pid, lambda s: s["steps"]["S3"].get("blockedReason") == "APPROVAL_EXPIRED", timeout=90)
        self.assertEqual(self.items(e, pid)[0]["status"], "EXPIRED")
        e.drive(pid, lambda s: s["status"] == "WAITING_INPUT", timeout=30)
        self.assertEqual(e.state(pid)["waitingFor"], "APPROVAL_EXPIRED")
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.approve_approval(CLIENT, pid, self.items(e, pid)[0]["id"])
        self.assertEqual(cm.exception.code, "APPROVAL_EXPIRED")
        self.assertEqual(e.connector_calls, [])
        fb = [m for m in e.svc.store.read_jsonl(pid, "inbox.jsonl") if m.get("kind") == "approval_feedback"]
        self.assertTrue(any("expiré" in m["text"] for m in fb))

    def test_reminders_are_sent_at_day_one_and_day_three_only_once_each(self):
        items = [{"id": "APR-00000001", "status": "PENDING", "createdUtc": iso(time.time() - 2 * 86400)}]
        now = time.time()
        self.assertEqual(len(pa.reminders_due(items, now)), 1)
        self.assertEqual(pa.reminders_due(items, now), [])
        items[0]["createdUtc"] = iso(time.time() - 4 * 86400)
        self.assertEqual(len(pa.reminders_due(items, now)), 1)
        self.assertEqual(pa.reminders_due(items, now), [])
        self.assertEqual(items[0]["remindersSent"], [1, 3])
        self.assertEqual(pa.expire_due([{"id": "x", "status": "PENDING", "expiresUtc": iso(now - 1)}, {"id": "y", "status": "EXECUTED", "expiresUtc": iso(now - 1)}], now)[0]["id"], "x")

    # ------------------------------------------------------------------ redémarrage, annulation, isolation
    def test_a_restart_never_replays_an_action_that_was_already_dispatched(self):
        e = self.env([ask(), ask(params={"channel": "#b", "text": "jamais lancé"}, title="Deuxième")])
        pid = e.create()
        self.waiting(e, pid)
        path = os.path.join(e.svc.store.project_dir(pid), "approvals.json")
        data = json.load(open(path, encoding="utf-8"))
        a, b = data["items"]
        a.update(status="EXECUTING", execution={"startedUtc": iso(time.time()), "dispatchedUtc": iso(time.time()), "connectorStatus": None})     # le service est mort APRÈS l'appel
        b.update(status="EXECUTING", execution={"startedUtc": None, "dispatchedUtc": None})                                                        # ... et AVANT l'appel
        json.dump(data, open(path, "w", encoding="utf-8"))
        e.svc.stop(kill=True)
        e2 = e.svc = e.new_service()
        e2.reap(boot=True)
        self.assertTrue(e2.executor.wait_idle(20))
        rows = {r["id"]: r for r in self.items(e, pid)}
        self.assertEqual(rows[a["id"]]["status"], "UNKNOWN_CHECK_MANUALLY")                       # jamais rejoué : le client vérifie dans son outil
        self.assertEqual(rows[b["id"]]["status"], "EXECUTED")                                       # jamais lancé : exécuté maintenant, une fois
        self.assertEqual([c[2]["text"] for c in e.connector_calls], ["jamais lancé"])
        self.assertIn("vérifiez", rows[a["id"]]["execution"]["detail"])

    def test_cancelling_rejects_what_is_pending_and_nothing_can_be_approved_afterwards(self):
        e = self.env([ask()])
        pid = e.create()
        self.waiting(e, pid)
        aid = self.items(e, pid)[0]["id"]
        e.svc.cancel(CLIENT, pid)
        self.assertEqual(self.items(e, pid)[0]["status"], "REJECTED")
        with self.assertRaises(ps.ProjectError) as cm:
            e.svc.approve_approval(CLIENT, pid, aid)
        self.assertIn(cm.exception.code, ("INVALID_STATE", "APPROVAL_NOT_PENDING"))
        self.assertEqual(e.connector_calls, [])

    def test_another_client_can_neither_see_nor_decide_the_actions(self):
        e = self.env([ask()])
        pid = e.create()
        self.waiting(e, pid)
        aid = self.items(e, pid)[0]["id"]
        for fn in (lambda: e.svc.list_approvals(CLIENT_B, pid), lambda: e.svc.approve_approval(CLIENT_B, pid, aid), lambda: e.svc.reject_approval(CLIENT_B, pid, aid),
                   lambda: e.svc.batch_approvals(CLIENT_B, pid, [aid], "approve")):
            with self.assertRaises(ps.ProjectNotFound):
                fn()
        self.assertEqual(self.items(e, pid)[0]["status"], "PENDING")
        self.assertEqual(e.connector_calls, [])

    def test_the_executor_respects_the_per_client_rate(self):
        w = pa.RateWindow(3, now=lambda: 1000.0)
        for _ in range(3):
            self.assertEqual(w.wait_needed("c"), 0.0)
            w.note("c")
        self.assertGreater(w.wait_needed("c"), 0)
        self.assertEqual(w.wait_needed("autre"), 0.0)

    def test_manual_actions_are_confirmed_by_the_client_without_any_connector_call(self):
        e = self.env([{"tool": "request_approval", "input": {"kind": "manual", "title": "Ajouter l'enregistrement DNS", "details": "Chez votre hébergeur : A 203.0.113.10", "risk": "medium"}}])
        pid = e.create()
        self.waiting(e, pid)
        a = self.items(e, pid)[0]
        self.assertEqual((a["kind"], a["connectorId"]), ("manual_action", None))
        self.assertEqual(e.svc.approve_approval(CLIENT, pid, a["id"])["status"], "EXECUTED")
        self.assertEqual(self.items(e, pid)[0]["execution"]["connectorStatus"], "MANUAL")
        self.assertEqual(e.connector_calls, [])
        self.assertEqual(e.run_to_done(pid)["status"], "DONE")


if __name__ == "__main__":
    unittest.main(verbosity=2)
