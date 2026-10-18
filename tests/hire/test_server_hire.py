"""Offre « Worker a l'unite » dans dashboard/server.py : droits d'acces, verrou de submit_task, variable BK_ALLOWED_WORKERS, embauche,
attribution, plan de facturation, purge a la suppression de compte, e-mail au proprietaire. Le vrai module server.py, sans PowerShell ni
reseau (subprocess.run et mailer.send_email sont remplaces).

python tests/hire/test_server_hire.py   (Windows ou Linux)
"""
import datetime
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
TMP = tempfile.mkdtemp(prefix="bkhiresrv-")
for rel in ("core/runtime/worker-runtime/WORKER-REGISTRY.json", "core/ai/LEVELS.json", "workers/alex/identity/identity.json",
            "workers/nora/identity/identity.json", "workers/maya/identity/identity.json", "workers/alex/install-profile.json",
            "workers/nora/install-profile.json", "dashboard/phone-agent/CLI-DASHBOARD.json"):
    dst = os.path.join(TMP, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(os.path.join(REPO, rel), dst)
os.environ["BK_ROOT"] = TMP
os.environ.pop("BK_PILOT_NOTIFY_EMAIL", None)
spec = importlib.util.spec_from_file_location("bk_server_hire", os.path.join(REPO, "dashboard", "server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
inst = server.inst

A, B, C = "CLI-CUST-AAAAAAAA", "CLI-CUST-BBBBBBBB", "CLI-CUST-CCCCCCCC"


def write_billing(client, plan, hired=None, **extra):
    state = {"planId": plan, "gridVersion": 2, "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": []}
    if hired is not None:
        state["hiredWorkers"] = hired
    state.update(extra)
    os.makedirs(server.BILLING_DATA_DIR, exist_ok=True)
    with open(server._billing_path(client), "w", encoding="utf-8") as f:
        json.dump(state, f)


def add_account(client, email=None, company="Test SA"):
    accounts = server._load_accounts()
    accounts.append({"accountId": client, "clientId": client, "email": email or client.lower() + "@mail-test.example",
                     "passwordHash": server._hash_password("motdepasse-test"), "companyName": company, "emailVerified": True})
    server._save_accounts(accounts)


class Fixture(unittest.TestCase):
    def setUp(self):
        for d in (server.BILLING_DATA_DIR, os.path.join(TMP, "runtime"), os.path.join(TMP, "core", "hire"), os.path.join(TMP, "core", "accounts", "data")):
            shutil.rmtree(d, ignore_errors=True)
        server.INSTALLS = inst.InstallationStore(TMP)
        server.HIRE_RATE.clear()
        server._HIRE_NOTIFIED.update(day="", n=0)


class Entitlement(Fixture):
    def test_plans(self):
        self.assertEqual((server.PLAN_CATALOG["solo"]["credits"], server.PLAN_CATALOG["solo"]["workerSlots"]), (250, 1))
        self.assertEqual((server.PLAN_CATALOG["trio"]["credits"], server.PLAN_CATALOG["trio"]["workerSlots"]), (500, 3))
        # Expectations changed on 2026-10-12 (owner-validated price grid, docs/PRICING.md): Pro is 1250 credits (was 1500), Enterprise has a
        # contractual cap instead of None (= unlimited), and "equipe" is new. Starter/Business keep their credits (legacy plans).
        for pid, credits in (("essai", 15), ("starter", 150), ("business", 600), ("equipe", 900), ("pro", 1250), ("scale", 4000),
                             ("enterprise", server.ENTERPRISE_DEFAULT_CREDITS)):
            self.assertEqual(server.PLAN_CATALOG[pid]["credits"], credits, pid)
            self.assertNotIn("workerSlots", server.PLAN_CATALOG[pid])
        self.assertEqual(server.INVOICE_ONLY_PLANS, {"solo", "trio", "equipe"})
        # Solo/Trio/Equipe are sold through Stripe Checkout when Stripe is configured, and stay "by invoice" when it is not.
        self.assertTrue(server.INVOICE_ONLY_PLANS <= server.PAID_PLANS_WITH_CHECKOUT)

    def test_worker_block_follows_the_plan(self):
        write_billing(A, "solo", ["alex"])
        write_billing(B, "essai")
        write_billing(C, "trio", ["alex", "nora"])
        self.assertIsNone(server.worker_block(A, "alex"))
        blocked = server.worker_block(A, "nora")
        self.assertEqual(blocked["error"], "WORKER_NOT_INCLUDED")
        self.assertIn("Nora", blocked["detail"])
        self.assertIn("Alex", blocked["detail"])
        self.assertEqual(blocked["workerId"], "nora")
        self.assertEqual(blocked["hire"]["hiredWorkers"], ["alex"])
        self.assertIsNotNone(server.worker_block(A, "chloe"))
        self.assertIsNotNone(server.worker_block(A, ""))
        self.assertIsNotNone(server.worker_block(A, None))
        for w in ("alex", "nora", "chloe", "maya", ""):
            self.assertIsNone(server.worker_block(B, w), w)
        self.assertIsNone(server.worker_block(C, "chloe"))
        self.assertIsNotNone(server.worker_block(C, "maya"))

    def test_owner_trial_and_unknown_ids_are_never_restricted_and_no_file_is_created_for_them(self):
        for cid in ("CLI-DASHBOARD", "CLI-TRIAL-PUBLIC", "", None, "../x"):
            self.assertIsNone(server.worker_block(cid, "alex"), cid)
            self.assertIsNone(server.allowed_workers_env(cid), cid)
        self.assertFalse(os.path.exists(server._billing_path("CLI-TRIAL-PUBLIC")))
        self.assertIsNone(server.worker_block(A, "alex"))                 # un client sans fichier de facturation : acces normal...
        self.assertFalse(os.path.exists(server._billing_path(A)))         # ... et la verification ne cree rien

    def test_an_unreadable_billing_file_refuses_instead_of_opening_everything(self):
        os.makedirs(server.BILLING_DATA_DIR, exist_ok=True)
        with open(server._billing_path(A), "w", encoding="utf-8") as f:
            f.write("{ ceci n'est pas du json")
        blocked = server.worker_block(A, "alex")
        self.assertEqual(blocked["error"], "WORKER_NOT_INCLUDED")
        self.assertEqual(server.allowed_workers_env(A), "-")

    def test_allowed_workers_env(self):
        write_billing(A, "solo", ["alex"])
        write_billing(B, "essai")
        write_billing(C, "trio", ["alex", "nora", "maya"])
        self.assertEqual(server.allowed_workers_env(A), "alex")
        self.assertIsNone(server.allowed_workers_env(B))
        self.assertEqual(server.allowed_workers_env(C), "alex,nora,maya")
        write_billing(A, "solo", [])
        self.assertEqual(server.allowed_workers_env(A), "-")

    def test_refused_for_hiring(self):
        self.assertIn("Nora", server.refused_for_hiring({"error": "WORKER_NOT_INCLUDED", "detail": "Nora ne fait pas partie"}))
        self.assertEqual(server.refused_for_hiring({"Status": "WORKER_NOT_INCLUDED", "FinalSynthesis": "Cette demande relève de Maya"}), "Cette demande relève de Maya")
        for ok in ({"Status": "SUCCESS"}, {"error": "SUBMIT_FAILED"}, None, "texte", []):
            self.assertIsNone(server.refused_for_hiring(ok))


class SubmitTaskLock(Fixture):
    def setUp(self):
        super().setUp()
        self.calls = []
        self._orig = server.subprocess.run

        def fake_run(cmd, **kw):
            self.calls.append((cmd, kw.get("env") or {}))
            out_file = cmd[cmd.index("-OutFile") + 1]
            with open(out_file, "w", encoding="utf-8") as f:
                json.dump({"Status": "SUCCESS", "Worker": "X"}, f)

            class P:
                returncode, stdout, stderr = 0, b"", b""
            return P()

        server.subprocess.run = fake_run
        self.addCleanup(setattr, server.subprocess, "run", self._orig)

    def test_a_worker_that_is_not_hired_never_starts_a_process(self):
        write_billing(A, "solo", ["alex"])
        for w in ("nora", "chloe", "", "../alex"):
            r = server.submit_task("Fais un devis", worker_id=w, client_id=A)
            self.assertEqual(r["error"], "WORKER_NOT_INCLUDED", w)
            self.assertTrue(r["detail"])
        self.assertEqual(self.calls, [])
        r = server.submit_task_limited("x", worker_id="nora", client_id=A)
        self.assertEqual(r["error"], "WORKER_NOT_INCLUDED")
        self.assertEqual(self.calls, [])
        self.assertEqual(server._ASYNC_ACTIVE.get(A, 0), 0, "la place de mission en cours est rendue")

    def test_async_refusal_becomes_an_error_job_not_a_done_job(self):
        write_billing(A, "solo", ["alex"])
        server.ASYNC_JOBS_DIR = os.path.join(TMP, "runtime", "async-jobs")
        res = server.submit_task_async("Fais un devis", worker_id="nora", client_id=A)
        end = time.time() + 10
        job = None
        while time.time() < end:
            job = server.read_async_job(res["jobId"])
            if job and job["status"] != "RUNNING":
                break
            time.sleep(0.05)
        self.assertEqual(job["status"], "ERROR")
        self.assertEqual(job["errorCode"], "WORKER_NOT_INCLUDED")
        self.assertIn("Nora", job["error"])
        self.assertEqual(self.calls, [])

    def test_the_hired_worker_runs_and_receives_the_allowed_list(self):
        write_billing(A, "trio", ["alex", "nora"])
        r = server.submit_task("Fais un devis", worker_id="alex", client_id=A)
        self.assertEqual(r["Status"], "SUCCESS")
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(self.calls[0][1].get("BK_ALLOWED_WORKERS"), "alex,nora")
        server.submit_task("Fais un devis", worker_id="chloe", client_id=A)           # Chloe (Trio) : meme liste, c'est elle qui s'y limite
        self.assertEqual(self.calls[1][1].get("BK_ALLOWED_WORKERS"), "alex,nora")

    def test_chloe_receives_a_cap_on_how_many_workers_she_can_call(self):
        # Revue du 2026-10-13 : le controle de quota ne regardait que le cout d'UNE mission alors que Chloe en lance une par Worker.
        write_billing(A, "equipe")                                                          # 900 credits
        os.makedirs(server.TASKS_DIR, exist_ok=True)

        def spend(n):
            with open(os.path.join(server.TASKS_DIR, "TASK-" + "%032X" % (len(os.listdir(server.TASKS_DIR)) + 1) + ".json"), "w", encoding="utf-8") as f:
                json.dump({"ClientId": A, "Credits": n, "CreatedAtUtc": "2026-10-20T00:00:00Z", "Status": "EXECUTED"}, f)
        spend(894)                                                                           # reste 6 credits
        server._utcnow = lambda: datetime.datetime(2026, 10, 21)
        self.addCleanup(setattr, server, "_utcnow", datetime.datetime.utcnow)
        server.submit_task("Prospection et marketing", worker_id="chloe", client_id=A, level="equilibre")
        self.assertEqual(self.calls[-1][1].get("BK_MAX_WORKERS"), "1")                      # 6 // 6 : un seul Worker
        server.submit_task("Prospection et marketing", worker_id="chloe", client_id=A, level="rapide")
        self.assertEqual(self.calls[-1][1].get("BK_MAX_WORKERS"), "6")
        server.submit_task("Prospection et marketing", worker_id="chloe", client_id=A, level="approfondi")
        self.assertEqual(self.calls[-1][1].get("BK_MAX_WORKERS"), "1")                      # jamais 0 : la porte d'entree a deja verifie qu'une mission passe
        shutil.rmtree(server.TASKS_DIR)
        os.makedirs(server.TASKS_DIR)
        spend(870)                                                                           # reste 30 credits
        server.submit_task("Prospection et marketing", worker_id="chloe", client_id=A, level="equilibre")
        self.assertEqual(self.calls[-1][1].get("BK_MAX_WORKERS"), "5")
        server.submit_task("Fais un devis", worker_id="alex", client_id=A, level="equilibre")      # un Worker seul n'appelle personne d'autre
        self.assertNotIn("BK_MAX_WORKERS", self.calls[-1][1])
        os.environ["BK_MAX_WORKERS"] = "2"                                                   # une valeur heritee du serveur n'est jamais transmise telle quelle
        self.addCleanup(os.environ.pop, "BK_MAX_WORKERS", None)
        server.submit_task("Fais un devis", worker_id="alex", client_id=A)
        self.assertNotIn("BK_MAX_WORKERS", self.calls[-1][1])
        for owner_like in ("CLI-DASHBOARD", "CLI-TRIAL-PUBLIC"):
            server.submit_task("Prospection et marketing", worker_id="chloe", client_id=owner_like)
            self.assertNotIn("BK_MAX_WORKERS", self.calls[-1][1], owner_like)
        self.assertIsNone(server.chloe_worker_cap("CLI-DASHBOARD"))

    def test_unrestricted_clients_get_no_list_even_if_the_server_environment_has_one(self):
        write_billing(B, "essai")
        os.environ["BK_ALLOWED_WORKERS"] = "alex"
        self.addCleanup(os.environ.pop, "BK_ALLOWED_WORKERS", None)
        server.submit_task("Fais un devis", worker_id="nora", client_id=B)
        self.assertNotIn("BK_ALLOWED_WORKERS", self.calls[0][1])
        server.submit_task("Fais un devis", worker_id="nora", client_id="CLI-DASHBOARD")
        self.assertNotIn("BK_ALLOWED_WORKERS", self.calls[1][1])
        server.submit_task("Essai", worker_id="chloe", client_id="CLI-TRIAL-PUBLIC")
        self.assertNotIn("BK_ALLOWED_WORKERS", self.calls[2][1])


class Billing(Fixture):
    def test_set_billing_plan_adapts_the_hired_list(self):
        write_billing(A, "trio", ["alex", "nora", "maya"], lastWorkerSwapAtUtc="2026-10-01T00:00:00Z")
        server.set_billing_plan("solo", client_id=A)
        state = server._billing_load(A)
        self.assertEqual(state["planId"], "solo")
        self.assertEqual(state["hiredWorkers"], ["alex"])
        self.assertNotIn("lastWorkerSwapAtUtc", state)
        server.set_billing_plan("starter", client_id=A)
        state = server._billing_load(A)
        self.assertEqual(state["hiredWorkers"], [])
        self.assertIsNone(server.worker_block(A, "nora"))
        write_billing(A, "solo", ["alex"])
        server.cancel_billing_plan(A)
        self.assertEqual(server._billing_load(A)["hiredWorkers"], [])
        self.assertIsNone(server.worker_block(A, "nora"))

    def test_get_billing_exposes_the_hire_state_without_changing_the_existing_plan_list(self):
        write_billing(A, "solo", ["alex"])
        b = server.get_billing(A)
        self.assertEqual((b["planId"], b["planName"], b["creditsTotal"], b["workerSlots"], b["hiredWorkers"]), ("solo", "Solo", 250, 1, ["alex"]))
        # Expectation changed on 2026-10-12: availablePlans is now the plan picker of the pricing grid (sold plans only, no trial, no legacy
        # plan for someone who is not on it); workerPlans is unchanged.
        self.assertEqual([p["planId"] for p in b["availablePlans"]], ["solo", "trio", "equipe", "pro", "scale", "enterprise"])
        self.assertEqual({p["planId"] for p in b["workerPlans"]}, {"solo", "trio"})
        self.assertTrue(next(p for p in b["workerPlans"] if p["planId"] == "trio")["chloeIncluded"])
        self.assertFalse(next(p for p in b["workerPlans"] if p["planId"] == "solo")["chloeIncluded"])
        self.assertEqual(b["hire"]["slotsLeft"], 0)

    def test_credits_of_a_worker_plan_are_consumed_like_any_other_plan(self):
        write_billing(A, "solo", ["alex"])
        os.makedirs(server.TASKS_DIR, exist_ok=True)
        self.addCleanup(shutil.rmtree, server.TASKS_DIR, True)
        real_now = server._utcnow
        server._utcnow = lambda: datetime.datetime(2026, 10, 12, 12, 0, 0)       # le quota est mensuel : on fige la date du test
        self.addCleanup(setattr, server, "_utcnow", real_now)
        with open(os.path.join(server.TASKS_DIR, "TASK-" + "A" * 32 + ".json"), "w", encoding="utf-8") as f:
            json.dump({"ClientId": A, "Credits": 250, "CreatedAtUtc": "2026-10-05T00:00:00Z"}, f)
        self.assertIn("quota est épuisé", server.subscription_blocks_mission(A))        # pas de missions illimitees


class Hiring(Fixture):
    def setUp(self):
        super().setUp()
        add_account(A)
        add_account(B)

    def test_hire_flow_and_swap_cooldown_with_the_real_billing_file(self):
        write_billing(A, "trio", ["alex"])
        p, s = server.hire_worker(A, "nora")
        self.assertEqual((s, p["ok"], p["hire"]["hiredWorkers"]), (200, True, ["alex", "nora"]))
        self.assertEqual(server._billing_load(A)["hiredWorkers"], ["alex", "nora"])
        p, s = server.hire_worker(A, "maya")
        p, s = server.hire_worker(A, "dario")
        self.assertEqual((s, p["error"]), (409, "NO_SLOT_LEFT"))
        p, s = server.hire_worker(A, "dario", "alex")
        self.assertEqual((s, p["replaced"]), (200, "alex"))
        p, s = server.hire_worker(A, "emma", "nora")
        self.assertEqual((s, p["error"]), (409, "SWAP_COOLDOWN"))
        self.assertIn("nextSwapAtUtc", p)
        self.assertEqual(server._billing_load(A)["hiredWorkers"], ["dario", "nora", "maya"])
        self.assertEqual(len(server._billing_load(A)["workerSwaps"]), 1)

    def test_hire_unknown_chloe_owner_and_classic_plan(self):
        write_billing(A, "solo", [])
        for wid, code, status in (("hacker", "UNKNOWN_WORKER", 404), ("chloe", "CHLOE_NOT_HIRABLE", 400), ("atlas", "UNKNOWN_WORKER", 404)):
            p, s = server.hire_worker(A, wid)
            self.assertEqual((s, p["error"]), (status, code), wid)
        write_billing(B, "essai")
        self.assertEqual(server.hire_worker(B, "alex")[1], 409)
        self.assertEqual(server.hire_worker("CLI-DASHBOARD", "alex")[1], 409)

    def test_replacing_a_worker_pauses_its_installation_and_closes_the_request(self):
        write_billing(A, "solo", ["alex"])
        server.INSTALLS.upsert(A, "alex", {"services": {}})
        server.record_hire_request(A, "nora", "svp")
        self.assertEqual(len(server.open_hire_requests(A)), 1)
        p, s = server.hire_worker(A, "nora", "alex")
        self.assertEqual(s, 200)
        self.assertEqual(server.INSTALLS.get(A, "alex")["status"], "paused")
        self.assertEqual(server.open_hire_requests(A), [])
        self.assertEqual(server._read_hire_requests()[0]["status"], "hired")

    def test_grant_workers_sets_the_plan_credits_and_list(self):
        write_billing(A, "essai")
        p, s = server.grant_workers(A, "trio", ["Alex", "nora"])
        self.assertEqual((s, p["planId"], p["credits"], p["newCycle"]), (200, "trio", 500, True))
        state = server._billing_load(A)
        self.assertEqual((state["planId"], state["hiredWorkers"], state["extraCredits"]), ("trio", ["alex", "nora"], 0))
        self.assertTrue(any("activé par BK Entreprise" in h["event"] for h in state["history"]))
        self.assertEqual(server.get_billing(A)["creditsTotal"], 500)
        first_cycle = state["cycleStartUtc"]
        time.sleep(0.01)
        p, s = server.grant_workers(A, "trio", ["alex", "maya"], new_cycle=False)
        self.assertEqual(server._billing_load(A)["cycleStartUtc"], first_cycle)
        first_paid = server._billing_load(A)["paidUntilUtc"]
        p, s = server.grant_workers(A, "trio", ["alex", "maya"])                 # facture suivante, avant le terme : la periode PAYEE s'allonge, la fenetre garde son ancrage
        self.assertEqual(server._billing_load(A)["cycleStartUtc"], first_cycle)
        self.assertEqual(server._billing_load(A)["paidUntilUtc"][:10], server._add_months(server._parse_utc(first_paid), 1).isoformat()[:10])
        p, s = server.grant_workers(A, "solo", ["alex"])                         # autre forfait : une fenetre neuve
        self.assertNotEqual(server._billing_load(A)["cycleStartUtc"], first_cycle)

    def test_grant_workers_refusals_leave_the_state_untouched(self):
        write_billing(A, "essai")
        before = server._billing_load(A)
        for args, code in ((("CLI-CUST-00000000", "solo", ["alex"]), "CLIENT_NOT_FOUND"), ((A, "starter", ["alex"]), "INVALID_PLAN"),
                           ((A, "solo", ["alex", "nora"]), "TOO_MANY_WORKERS"), ((A, "solo", []), "WORKERS_REQUIRED"), ((A, "solo", ["x"]), "UNKNOWN_WORKER"),
                           ((A, "solo", ["chloe"]), "CHLOE_NOT_HIRABLE"), (("../x", "solo", ["alex"]), "CLIENT_NOT_FOUND")):
            p, s = server.grant_workers(*args)
            self.assertEqual(p["error"], code, args)
        self.assertEqual(server._billing_load(A), before)
        write_billing(B, "starter", stripeSubscriptionId="sub_123")
        p, s = server.grant_workers(B, "solo", ["alex"])
        self.assertEqual((s, p["error"]), (409, "ACTIVE_SUBSCRIPTION"))
        self.assertEqual(server._billing_load(B)["planId"], "starter")

    def test_removed_workers_are_paused_by_a_grant(self):
        write_billing(A, "solo", ["alex"])
        server.INSTALLS.upsert(A, "alex", {"services": {}})
        server.grant_workers(A, "solo", ["nora"], new_cycle=False)
        self.assertEqual(server.INSTALLS.get(A, "alex")["status"], "paused")

    def test_open_hire_requests_are_never_dropped_to_make_room(self):
        # Revue du 2026-10-13 : le fichier gardait les 500 dernieres lignes quel que soit leur statut ; des comptes gratuits pouvaient chasser des demandes
        # ouvertes de la vue du proprietaire.
        rows = [{"id": f"HRQ-{i:04d}", "clientId": A, "workerId": "alex", "status": "open" if i % 2 == 0 else "granted"} for i in range(520)]
        server._write_hire_requests(rows)
        kept = server._read_hire_requests()
        self.assertEqual(len(kept), 500)
        self.assertEqual(sum(1 for r in kept if r["status"] == "open"), 260)             # toutes les ouvertes sont la
        self.assertEqual([r["id"] for r in kept if r["status"] == "granted"][0], "HRQ-0041")      # les 20 plus anciennes demandes traitees sont parties
        flood = [{"id": f"HRQ-{i:04d}", "clientId": A, "workerId": "alex", "status": "open"} for i in range(510)]
        server._write_hire_requests(flood)
        self.assertEqual(len(server._read_hire_requests()), 510)                          # que des ouvertes : on ne perd rien
        server._write_hire_requests(flood[:3])
        self.assertEqual(len(server._read_hire_requests()), 3)

    def test_installations_made_during_the_trial_are_paused_when_the_client_moves_to_a_worker_plan(self):
        # Revue du 2026-10-13 : seules les installations des Workers de l'ANCIENNE liste etaient pausees ; celles du temps de l'essai restaient « Actif »
        # (donc « Hors forfait » avec un interrupteur vivant) et reprenaient d'elles-memes si le Worker etait embauche plus tard.
        add_account(A)
        write_billing(A, "essai")
        server.INSTALLS.upsert(A, "alex", {"services": {}})
        server.INSTALLS.upsert(A, "nora", {"services": {}})
        server.INSTALLS.upsert(A, "maya", {"services": {}})
        server.INSTALLS.set_status(A, "maya", "paused")
        server.grant_workers(A, "solo", ["nora"])
        status = {w: server.INSTALLS.get(A, w)["status"] for w in ("alex", "nora", "maya")}
        self.assertEqual(status, {"alex": "paused", "nora": "draft", "maya": "paused"})
        self.assertEqual(server.INSTALLS.get(A, "alex")["pausedFrom"], "draft")
        self.assertEqual(server.INSTALLS.get(A, "maya")["pausedFrom"], "draft")                                  # deja en pause : intact
        server.hire_worker(A, "alex", "nora")                                      # echange : Nora (embauchee) est remplacee par Alex, Nora est mise en pause
        self.assertEqual(server.INSTALLS.get(A, "nora")["status"], "paused")
        self.assertEqual(server.INSTALLS.get(A, "alex")["status"], "paused")      # Alex est embauche mais reste en pause tant que le client ne la reprend pas
        # un forfait sans liste de Workers (Equipe) ne touche a rien
        write_billing(B, "essai")
        add_account(B)
        server.INSTALLS.upsert(B, "alex", {"services": {}})
        server.set_client_plan(B, "equipe")
        self.assertEqual(server.INSTALLS.get(B, "alex")["status"], "draft")

    def test_the_installation_route_never_drops_the_connection_on_a_mistyped_body(self):
        add_account(A)
        write_billing(A, "solo", ["alex"])
        for junk in ({"knowledge": "abc"}, {"knowledge": ["a"]}, {"autonomy": ["x"]}, {"autonomy": "auto"}):
            cfg = {"services": {"prospection-sortante": dict({"enabled": True}, **junk)}}
            p, s = server.save_installation(A, "alex", cfg)
            self.assertEqual((s, p["error"]), (400, "INSTALLATION_INVALID"), junk)
            self.assertTrue(p["errors"], junk)
        self.assertIsNone(server.INSTALLS.get(A, "alex"))


class InstallationApi(Fixture):
    def setUp(self):
        super().setUp()
        add_account(A)
        write_billing(A, "solo", ["alex"])

    def cfg(self):
        return {"services": {"prospection-sortante": {"enabled": True, "knowledge": {
            "site_web": "https://x.example", "offre_description": "Ascenseurs.", "zone_geographique": "Suisse"}}}, "notes": "ok"}

    def test_save_status_delete(self):
        p, s = server.save_installation(A, "alex", self.cfg())
        self.assertEqual((s, p["installation"]["status"], p["installation"]["readiness"]), (200, "draft", []))
        p, s = server.set_installation_status(A, "alex", "active")
        self.assertEqual((s, p["installation"]["status"]), (200, "active"))
        p, s = server.set_installation_status(A, "alex", "paused")
        self.assertTrue(server.installation_paused(A, "alex"))
        self.assertFalse(server.installation_paused(A, "nora"))
        self.assertFalse(server.installation_paused(B, "alex"))
        self.assertFalse(server.installation_paused(A, "../x"))
        self.assertTrue(server.INSTALLS.delete(A, "alex"))
        self.assertFalse(server.INSTALLS.delete(A, "alex"))

    def test_entitlement_is_required_to_install_or_activate_but_not_to_pause_or_delete(self):
        server.save_installation(A, "alex", self.cfg())
        p, s = server.save_installation(A, "nora", {"services": {}})
        self.assertEqual((s, p["error"]), (403, "WORKER_NOT_INCLUDED"))
        server.set_installation_status(A, "alex", "active")
        server.grant_workers(A, "solo", ["nora"], new_cycle=False)            # Alex n'est plus embauche (et son installation est mise en pause)
        p, s = server.set_installation_status(A, "alex", "active")
        self.assertEqual((s, p["error"]), (403, "WORKER_NOT_INCLUDED"))
        p, s = server.set_installation_status(A, "alex", "paused")
        self.assertEqual(s, 200)
        self.assertTrue(server.INSTALLS.delete(A, "alex"))

    def test_connectors_are_required_for_activation_when_the_profile_says_so(self):
        crm = {"services": {"suivi-crm-opportunites": {"enabled": True, "knowledge": {}}}}
        profile = inst.load_profile(TMP, "alex")
        service = next(s for s in profile["services"] if s["id"] == "suivi-crm-opportunites")
        crm["services"]["suivi-crm-opportunites"]["knowledge"] = {k["key"]: "valeur" for k in service["knowledgeFields"] if k.get("required")}
        server.save_installation(A, "alex", crm)
        p, s = server.set_installation_status(A, "alex", "active")
        self.assertEqual(s, 409)
        self.assertTrue(any("Hubspot" in e for e in p["errors"]), p)
        creds = os.path.join(server.CLIENT_CREDENTIALS_DIR, A)
        os.makedirs(creds, exist_ok=True)
        self.addCleanup(shutil.rmtree, creds, True)
        with open(os.path.join(creds, "hubspot.json"), "w", encoding="utf-8") as f:
            f.write("{}")
        p, s = server.set_installation_status(A, "alex", "active")
        self.assertEqual((s, p["installation"]["status"]), (200, "active"))

    def test_profile_payload_scoping(self):
        p, s = server.installation_profile_payload(A, "alex")
        self.assertEqual((s, p["entitled"], p["installation"]), (200, True, None))
        p, s = server.installation_profile_payload(A, "nora")
        self.assertEqual((s, p["entitled"]), (200, False))
        for bad in ("chloe", "ghost", "../alex", "ALEX", "alex\n", None, ""):
            self.assertEqual(server.installation_profile_payload(A, bad)[1], 404, repr(bad))
        server.save_installation(A, "alex", self.cfg())
        self.assertEqual(server.installations_payload(B), {"installations": []})
        self.assertEqual([i["workerId"] for i in server.installations_payload(A)["installations"]], ["alex"])


class AccountLifecycle(Fixture):
    def test_delete_account_purges_installations_and_hire_requests_and_export_includes_them(self):
        add_account(A)
        add_account(B)
        write_billing(A, "solo", ["alex"])
        write_billing(B, "solo", ["alex"])
        server.INSTALLS.upsert(A, "alex", {"services": {}})
        server.INSTALLS.upsert(B, "alex", {"services": {}})
        server.record_hire_request(A, "nora", "svp")
        server.record_hire_request(B, "nora", "svp")
        exported = server.export_account_data(A)
        self.assertEqual([i["workerId"] for i in exported["installations"]], ["alex"])
        self.assertEqual([r["workerId"] for r in exported["hireRequests"]], ["nora"])
        self.assertEqual(server.delete_account(A, "mauvais-mot-de-passe"), "INVALID_PASSWORD")
        self.assertTrue(os.path.isdir(os.path.join(TMP, "runtime", "installations", A)))           # un refus ne purge rien
        self.assertIsNone(server.delete_account(A, "motdepasse-test"))
        self.assertFalse(os.path.exists(os.path.join(TMP, "runtime", "installations", A)))
        self.assertEqual([r["clientId"] for r in server._read_hire_requests()], [B])
        self.assertTrue(os.path.isfile(os.path.join(TMP, "runtime", "installations", B, "ALEX.json")))


class OwnerEmail(Fixture):
    def setUp(self):
        super().setUp()
        add_account(A, company="Atelier <b>Martin</b> SA")
        self.sent = []
        self._orig = server.mailer.send_email
        self._orig_addr = server.pilot_program.owner_notify_address

        def fake_send(to, subject, html, text=None, gmail_bridge=None):
            self.sent.append((to, subject, html, text))
            return True, None

        server.mailer.send_email = fake_send
        self.addCleanup(setattr, server.mailer, "send_email", self._orig)
        self.addCleanup(setattr, server.pilot_program, "owner_notify_address", self._orig_addr)

    def wait_sent(self, n=1):
        end = time.time() + 5
        while time.time() < end and len(self.sent) < n:
            time.sleep(0.02)

    def test_no_address_means_no_mail_but_the_request_is_kept(self):
        server.pilot_program.owner_notify_address = lambda root: ""
        rec, created = server.record_hire_request(A, "nora", "svp")
        self.assertTrue(created)
        self.assertFalse(server._notify_owner_hire_request(rec, server._load_accounts()[0]))
        self.assertEqual(self.sent, [])
        self.assertEqual(len(server.open_hire_requests()), 1)

    def test_mail_content_is_escaped_and_capped_per_day(self):
        server.pilot_program.owner_notify_address = lambda root: "owner@mail-test.example"
        rec, _ = server.record_hire_request(A, "nora", "<script>alert(1)</script> Je veux Nora")
        self.assertTrue(server._notify_owner_hire_request(rec, server._load_accounts()[0]))
        self.wait_sent()
        to, subject, html, text = self.sent[0]
        self.assertEqual(to, "owner@mail-test.example")
        self.assertIn("Nora", subject)
        self.assertNotIn("<script>", html)
        self.assertIn("&lt;script&gt;", html)
        self.assertNotIn("<b>Martin</b>", html)
        self.assertIn("grant-workers", html)
        self.assertEqual(rec["message"], "<script>alert(1)</script> Je veux Nora")        # stocke tel quel (donnee), echappe a l'affichage/envoi
        server._HIRE_NOTIFIED.update(day=datetime.date.today().isoformat(), n=server.HIRE_NOTIFY_MAX_PER_DAY)
        self.assertFalse(server._notify_owner_hire_request(rec, server._load_accounts()[0]))

    def test_one_open_request_per_client_and_worker_and_the_message_is_capped(self):
        a, created = server.record_hire_request(A, "nora", "x" * 5000)
        b, created2 = server.record_hire_request(A, "nora", "autre")
        self.assertEqual((created, created2, a["id"] == b["id"]), (True, False, True))
        self.assertEqual(len(a["message"]), server.HIRE_REQUEST_MESSAGE_MAX)
        c, created3 = server.record_hire_request(A, "maya", "")
        self.assertTrue(created3)

    def test_open_requests_have_a_ceiling_so_the_file_and_the_owner_view_stay_bounded(self):
        # 2e revue : une demande ouverte n'est jamais supprimee, donc le fichier (reecrit en entier a chaque demande) grossissait sans fin.
        orig = server.HIRE_OPEN_MAX
        server.HIRE_OPEN_MAX = 2
        self.addCleanup(setattr, server, "HIRE_OPEN_MAX", orig)
        self.assertTrue(server.record_hire_request(A, "nora", "1")[1])
        self.assertTrue(server.record_hire_request(A, "maya", "2")[1])
        self.assertEqual(server.record_hire_request(A, "alex", "3"), (None, False))                  # plein : refuse, rien n'est ecrit
        self.assertEqual(len(server.open_hire_requests()), 2)
        again, created = server.record_hire_request(A, "nora", "bis")                                # une demande deja ouverte est toujours retrouvee
        self.assertEqual((created, again["workerId"]), (False, "nora"))


class WhatsApp(Fixture):
    def test_a_client_without_chloe_is_told_why_instead_of_retry_later(self):
        write_billing(A, "solo", ["alex"])
        sent = []
        orig = server.wa.send_text
        server.wa.send_text = lambda phone, text: sent.append(text) or True
        self.addCleanup(setattr, server.wa, "send_text", orig)

        class FakeStore:
            def client_for(self, phone):
                return A

        deps = server._wa_deps()
        server.wa._RATE.clear()
        server.wa._handle_message("41790000000", "Fais ma prospection", FakeStore(), deps)
        self.assertEqual(len(sent), 1)
        self.assertIn("Trio", sent[0])
        self.assertNotIn("Réessayez", sent[0])


class ChloePlanRoute(Fixture):
    """POST /api/chloe/plan par la vraie route HTTP (dans ce processus, submit_task remplace). Revue du 2026-10-13 : le plan d'une demande qui releve d'un
    Worker non embauche revenait en 200 avec une synthese vide d'action ; /api/chloe/task, lui, repondait 403."""

    def setUp(self):
        super().setUp()
        import threading
        import urllib.error
        import urllib.request
        from http.server import ThreadingHTTPServer
        self._urllib = (urllib.request, urllib.error)
        add_account(A)
        write_billing(A, "trio", ["nora"])
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)
        self.token = server.account_create_session({"clientId": A, "email": "a@mail-test.example"})
        orig = server.submit_task
        self.addCleanup(setattr, server, "submit_task", orig)

    def post(self, path, body):
        request, error = self._urllib
        req = request.Request(f"http://127.0.0.1:{self.httpd.server_address[1]}{path}", data=json.dumps(body).encode(), method="POST",
                              headers={"Content-Type": "application/json", "Cookie": "bk_account=" + self.token, "X-Forwarded-For": "198.51.100.8"})
        try:
            with request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read().decode("utf-8"))
        except error.HTTPError as e:
            return e.code, json.loads(e.read().decode("utf-8"))

    def test_the_plan_of_a_request_for_a_worker_that_is_not_hired_is_a_clear_403(self):
        refused = {"Orchestrator": "CHLOE", "SelectedWorkers": [], "NotIncludedWorkers": ["ALEX"], "Status": "WORKER_NOT_INCLUDED", "NextAction": "HIRE_WORKER",
                   "FinalSynthesis": "Cette demande relève de Alex, qui ne fait pas partie de vos Workers embauchés. Embauchez-le."}
        server.submit_task = lambda *a, **kw: dict(refused)
        st, out = self.post("/api/chloe/plan", {"objective": "Fais ma prospection commerciale"})
        self.assertEqual((st, out["error"], out["notIncludedWorkers"]), (403, "WORKER_NOT_INCLUDED", ["ALEX"]))
        self.assertIn("Embauchez-le", out["detail"])
        st, out = self.post("/api/chloe/task", {"objective": "Fais ma prospection commerciale", "level": "rapide"})      # et la route de mission : la meme reponse
        self.assertEqual((st, out["error"]), (403, "WORKER_NOT_INCLUDED"))
        server.submit_task = lambda *a, **kw: {"Orchestrator": "CHLOE", "SelectedWorkers": ["NORA"], "Status": "PLANNED"}
        st, out = self.post("/api/chloe/plan", {"objective": "Reponds a mes clients"})
        self.assertEqual((st, out["Status"], out["SelectedWorkers"]), (200, "PLANNED", ["NORA"]))                   # un vrai plan reste un 200


class RateLimits(Fixture):
    def test_limits_are_per_action_and_per_key(self):
        for _ in range(20):
            self.assertTrue(server.hire_rate_ok("hire", A))
        self.assertFalse(server.hire_rate_ok("hire", A))
        self.assertTrue(server.hire_rate_ok("hire", B))
        self.assertTrue(server.hire_rate_ok("hire-request", A))
        for _ in range(4):
            server.hire_rate_ok("hire-request", A)
        self.assertFalse(server.hire_rate_ok("hire-request", A))
        self.assertEqual(server.HIRE_BODY_LIMITS["install-write"], 200000)


if __name__ == "__main__":
    try:
        unittest.main(verbosity=2, exit=False)
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
