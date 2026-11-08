"""Chloe delegue a tous les Workers : droits par forfait (dashboard/chloe_scope.py) et credits, branches sur le VRAI dashboard/server.py.

Aucun PowerShell, aucun reseau : subprocess.run est remplace par un faux qui note la commande et l'environnement.
python tests/chloe-delegation/test_scope_server.py   (Windows ou Linux)
"""
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import types
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
TMP = tempfile.mkdtemp(prefix="bkchloescope-")
ALL = [w for w in ("alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya", "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis")]
for rel in ["core/runtime/worker-runtime/WORKER-REGISTRY.json", "core/ai/LEVELS.json", "dashboard/phone-agent/CLI-DASHBOARD.json"] + [f"workers/{w}/identity/identity.json" for w in ALL]:
    dst = os.path.join(TMP, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(os.path.join(REPO, rel), dst)
os.environ["BK_ROOT"] = TMP
spec = importlib.util.spec_from_file_location("bk_server_chloe", os.path.join(REPO, "dashboard", "server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
REAL_USAGE = getattr(server, "USAGE", None)        # le service reel (inerte tant que BK_USAGE_WINDOWS n'est pas 1) : restaure apres chaque test

A = "CLI-CUST-AAAAAAAA"


def write_billing(client, plan, hired=None, **extra):
    state = {"planId": plan, "gridVersion": 2, "cycleStartUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 3600)), "extraCredits": 0, "history": []}
    if hired is not None:
        state["hiredWorkers"] = hired
    state.update(extra)
    os.makedirs(server.BILLING_DATA_DIR, exist_ok=True)
    with open(server._billing_path(client), "w", encoding="utf-8") as f:
        json.dump(state, f)


class FakeWindow:
    def __init__(self, resets):
        self.resetsAtUtc = resets


class FakeUsage:
    """Interface du service des fenetres d'usage (dashboard/usage.py du chantier « limites ») : remaining(client) -> vue, enforced."""
    def __init__(self, allowed, binding="session", resets="2026-10-20T08:00:00Z", enforced=True, exempt=False):
        self.enforced = enforced
        self._view = types.SimpleNamespace(allowedNow=allowed, binding=binding, exempt=exempt, session=FakeWindow(resets), week=FakeWindow(resets), month=FakeWindow(resets))

    def remaining(self, client_id):
        return self._view

    def __getattr__(self, name):
        # le reste de l'interface (billing_used, mission_begin / mission_end, charge, purge...) : celui du vrai service, inerte (mode « off »)
        if REAL_USAGE is None or name.startswith("__"):
            raise AttributeError(name)
        return getattr(REAL_USAGE, name)


class Fixture(unittest.TestCase):
    def setUp(self):
        shutil.rmtree(server.BILLING_DATA_DIR, ignore_errors=True)
        shutil.rmtree(os.path.join(TMP, "runtime"), ignore_errors=True)
        server.INSTALLS = server.inst.InstallationStore(TMP)
        self.addCleanup(lambda: server.__dict__.__setitem__("USAGE", REAL_USAGE) if REAL_USAGE is not None else server.__dict__.pop("USAGE", None))


class ScopeByPlan(Fixture):
    def test_every_whole_team_plan_gives_chloe_all_seventeen_workers(self):
        for plan in ("essai", "equipe", "pro", "scale", "enterprise"):
            write_billing(A, plan)
            sc = server.CHLOE_SCOPE.project_scope(A)
            self.assertTrue(sc["chloe"], plan)
            self.assertEqual(sorted(sc["allowed"]), sorted(ALL), plan)
            self.assertEqual((sc["denied"], sc["hireOffer"]), ([], False), plan)
            self.assertNotIn("atlas", sc["allowed"])
            self.assertIsNone(server.allowed_workers_env(A), plan)
            self.assertIsNone(server.worker_block(A, "chloe"), plan)
            self.assertIsNone(server.worker_block(A, "clara"), plan)

    def test_trio_gives_chloe_the_three_hired_workers_and_names_the_ones_that_are_missing(self):
        write_billing(A, "trio", ["lea", "emma", "lucas"])
        sc = server.CHLOE_SCOPE.project_scope(A)
        self.assertTrue(sc["chloe"])
        self.assertEqual(sc["allowed"], ["lea", "emma", "lucas"])
        self.assertEqual(len(sc["denied"]), 14)
        self.assertTrue(sc["hireOffer"])
        clara = next(d for d in sc["denied"] if d["workerId"] == "clara")
        self.assertEqual(clara["code"], "NOT_HIRED")
        self.assertIn("Clara ne fait pas partie de vos Workers embauchés", clara["reason"])
        self.assertEqual(server.allowed_workers_env(A), "lea,emma,lucas")
        # le client echange un Worker : la portee suit, sans redemarrage
        write_billing(A, "trio", ["lea", "emma", "clara"])
        self.assertEqual(server.CHLOE_SCOPE.project_scope(A)["allowed"], ["lea", "emma", "clara"])

    def test_solo_has_no_chloe_and_only_its_hired_worker(self):
        write_billing(A, "solo", ["lucas"])
        sc = server.CHLOE_SCOPE.project_scope(A)
        self.assertFalse(sc["chloe"])
        self.assertEqual(sc["allowed"], ["lucas"])
        self.assertEqual(len(sc["denied"]), 16)
        self.assertEqual(server.worker_block(A, "chloe")["error"], "WORKER_NOT_INCLUDED")

    def test_an_unreadable_or_empty_trio_opens_nothing_by_default(self):
        write_billing(A, "trio", [])
        sc = server.CHLOE_SCOPE.project_scope(A)
        self.assertEqual(sc["allowed"], [])
        self.assertEqual(server.allowed_workers_env(A), "-")
        # lecture impossible du fichier : jamais « tous »
        with open(server._billing_path(A), "w", encoding="utf-8") as f:
            f.write("{ pas du json")
        self.assertEqual(server.allowed_workers_env(A), "-")

    def test_the_owner_and_the_public_trial_are_never_restricted(self):
        for client in (server.DASHBOARD_CLIENT_ID, "CLI-TRIAL-PUBLIC"):
            sc = server.CHLOE_SCOPE.project_scope(client)
            self.assertEqual((sc["chloe"], sorted(sc["allowed"]), sc["denied"]), (True, sorted(ALL), []), client)
            self.assertIsNone(server.chloe_worker_cap(client, "equilibre"), client)

    def test_the_owner_can_change_the_trio_rule_in_one_table(self):
        write_billing(A, "trio", ["lea"])
        scope = server.CHLOE_SCOPE
        self.assertEqual(scope.delegation_mode("trio"), "hired_only")
        self.assertEqual(scope.delegation_mode("equipe"), "all")
        flipped = server._chloe_scope.ChloeScope(
            worker_ids=server.get_worker_ids, allowed_workers_env=lambda c: None, worker_block=lambda c, w: None, delegation={"default": "all"},
            plan_id_of=lambda c: "trio")
        self.assertEqual(sorted(flipped.project_scope(A)["allowed"]), sorted(ALL))
        guarded = server._chloe_scope.ChloeScope(
            worker_ids=server.get_worker_ids, allowed_workers_env=lambda c: None, worker_block=lambda c, w: None, plan_id_of=lambda c: "trio")
        self.assertEqual(guarded.project_scope(A)["allowed"], [], "emplacements illisibles : rien d'ouvert par defaut")

    def test_a_paused_installation_is_flagged_but_stays_delegable_for_a_manual_mission(self):
        write_billing(A, "equipe")
        scope = server._chloe_scope.ChloeScope(
            worker_ids=server.get_worker_ids, allowed_workers_env=server.allowed_workers_env, worker_block=server.worker_block,
            installation_paused=lambda client, worker: worker == "lea", plan_id_of=lambda c: "equipe")
        sc = scope.project_scope(A)
        self.assertEqual(sc["paused"], ["lea"])
        self.assertIn("lea", sc["allowed"])


class CreditBudget(Fixture):
    def test_the_only_bound_on_workers_is_what_the_credits_pay_for(self):
        write_billing(A, "equipe")                                   # 900 credits : jamais « 3 Workers au plus »
        self.assertEqual(server.chloe_worker_cap(A, "rapide"), 900)
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 150)
        self.assertEqual(server.chloe_worker_cap(A, "approfondi"), 75)
        write_billing(A, "essai")
        self.assertEqual(server.chloe_worker_cap(A, "rapide"), 15)
        write_billing(A, "equipe")
        os.makedirs(server.TASKS_DIR, exist_ok=True)
        with open(os.path.join(server.TASKS_DIR, "TASK-" + "C" * 32 + ".json"), "w", encoding="utf-8") as f:
            json.dump({"TaskId": "TASK-" + "C" * 32, "ClientId": A, "Worker": "ALEX", "Status": "EXECUTED", "Credits": 895,
                       "CreatedAtUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f)
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 1, "au moins un : subscription_blocks_mission a deja verifie qu'une mission est payable")

    def test_session_and_week_windows_bound_it_when_the_usage_service_is_wired(self):
        write_billing(A, "equipe")
        server.USAGE = FakeUsage(allowed=14, binding="session", resets="2026-10-20T08:00:00Z")
        budget = server.CHLOE_SCOPE.mission_budget(A, "equilibre")
        self.assertEqual((budget["workers"], budget["creditsAllowed"], budget["binding"], budget["source"]), (2, 14, "session", "usage"))
        self.assertEqual(budget["resetsAtUtc"], "2026-10-20T08:00:00Z")
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 2)
        # fenetres non appliquees (BK_USAGE_WINDOWS=0 ou shadow) ou compte exempte : le solde du mois decide
        server.USAGE = FakeUsage(allowed=14, enforced=False)
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 150)
        server.USAGE = FakeUsage(allowed=14, exempt=True)
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 150)
        # un grand livre qui plante ne bloque jamais Chloe
        broken = FakeUsage(allowed=1)
        broken.remaining = lambda c: (_ for _ in ()).throw(RuntimeError("ledger unreadable"))
        server.USAGE = broken
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 150)

    def test_the_server_gives_chloe_its_budget_and_nothing_to_a_single_worker(self):
        write_billing(A, "trio", ["lea", "emma", "lucas"])
        server.USAGE = FakeUsage(allowed=30, binding="week", resets="2026-10-26T10:00:00Z")
        calls = []

        def fake_run(cmd, **kw):
            calls.append((cmd, kw.get("env") or {}))
            return types.SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        original = server.subprocess.run
        server.subprocess.run = fake_run
        try:
            server.submit_task("Lance mon offre", worker_id="chloe", client_id=A, level="equilibre")
            server.submit_task("Fais un logo", worker_id="lea", client_id=A, level="equilibre")
            server._JOB_CONTEXT.job_id = "JOB-" + "A" * 32
            server.submit_task("Lance mon offre", worker_id="chloe", client_id=A, level="equilibre")
            server._JOB_CONTEXT.job_id = ""
        finally:
            server.subprocess.run = original
        chloe_env, lea_env, job_env = calls[0][1], calls[1][1], calls[2][1]
        self.assertEqual(chloe_env["BK_ALLOWED_WORKERS"], "lea,emma,lucas")
        self.assertEqual(chloe_env["BK_MAX_WORKERS"], "5")                     # 30 credits // 6 (equilibre)
        self.assertNotIn("BK_CHLOE_RUN_ID", chloe_env)
        self.assertEqual(job_env["BK_CHLOE_RUN_ID"], "JOB-" + "A" * 32)
        self.assertNotIn("BK_MAX_WORKERS", lea_env, "le plafond du nombre de Workers ne concerne que Chloe")
        self.assertNotIn("BK_CHLOE_RUN_ID", lea_env)
        self.assertNotIn("BK_CHLOE_RESET_NOTE", lea_env)

    def test_the_budget_is_read_before_the_mission_reserves_its_own_credits(self):
        # Le chantier « limites » reserve les credits de la mission juste APRES le verrou d'embauche (worker_block) : cette reservation ne doit pas
        # reduire le plafond de Chloe pour la meme mission (7 Workers reserves, 1 seul appele). On la simule a cet endroit precis.
        write_billing(A, "equipe")
        fake = FakeUsage(allowed=42, binding="session")
        server.USAGE = fake
        calls = []
        original_run, original_block = server.subprocess.run, server.worker_block

        def fake_run(cmd, **kw):
            calls.append(kw.get("env") or {})
            return types.SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

        def block_then_reserve(client_id, worker_id):
            fake._view.allowedNow = 0           # la mission vient de reserver tout ce qui restait
            return original_block(client_id, worker_id)
        server.subprocess.run, server.worker_block = fake_run, block_then_reserve
        try:
            server.submit_task("Lance mon offre", worker_id="chloe", client_id=A, level="equilibre")
        finally:
            server.subprocess.run, server.worker_block = original_run, original_block
        self.assertEqual(calls[0]["BK_MAX_WORKERS"], "7", "42 credits // 6 (equilibre), lus avant la reservation de la mission")

    def test_the_quick_answer_choice_comes_from_the_request_field_only_and_only_for_chloe(self):
        write_billing(A, "equipe")
        self.assertEqual((server._chloe_mode_of({"mode": "mission"}), server._chloe_mode_of({"mode": " Mission "}), server._chloe_mode_of({"mode": "project"}),
                          server._chloe_mode_of({}), server._chloe_mode_of(None), server._chloe_mode_of({"mode": ["mission"]})), ("mission", "mission", None, None, None, None))
        calls = []

        def fake_run(cmd, **kw):
            calls.append(kw.get("env") or {})
            return types.SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        original, previous = server.subprocess.run, os.environ.get("BK_CHLOE_MODE")
        server.subprocess.run = fake_run
        os.environ["BK_CHLOE_MODE"] = "mission"            # une variable du serveur lui-meme ne decide pas a la place du client
        try:
            server.submit_task("Lance mon offre", worker_id="chloe", client_id=A, level="rapide", chloe_mode="mission")
            server.submit_task("Lance mon offre", worker_id="chloe", client_id=A, level="rapide")
            server.submit_task("Fais un logo", worker_id="lea", client_id=A, level="rapide", chloe_mode="mission")
        finally:
            server.subprocess.run = original
            if previous is None:
                os.environ.pop("BK_CHLOE_MODE", None)
            else:
                os.environ["BK_CHLOE_MODE"] = previous
        self.assertEqual(calls[0].get("BK_CHLOE_MODE"), "mission")
        self.assertNotIn("BK_CHLOE_MODE", calls[1])
        self.assertNotIn("BK_CHLOE_MODE", calls[2])

    def test_the_renewal_sentence_is_made_by_the_server_never_copied(self):
        write_billing(A, "equipe")
        server.USAGE = FakeUsage(allowed=14, binding="session", resets="2026-10-20T08:00:00Z")
        scope = server._chloe_scope.ChloeScope(
            worker_ids=server.get_worker_ids, allowed_workers_env=lambda c: None, worker_block=lambda c, w: None, usage=lambda: server.USAGE,
            level_credits=server.level_credits, fr_when=lambda iso: "demain à 08:00 " + "x" * 200, credits_remaining=lambda c: 900)
        env = scope.child_env(A, "equilibre", "chloe")
        self.assertEqual(list(env), ["BK_CHLOE_RESET_NOTE"])
        self.assertLessEqual(len(env["BK_CHLOE_RESET_NOTE"]), 70)
        self.assertEqual(scope.child_env(A, "equilibre", "lea"), {})


@unittest.skipUnless(os.path.isfile(os.path.join(REPO, "dashboard", "usage.py")) and os.path.isfile(os.path.join(REPO, "core", "usage", "USAGE-LIMITS.json")),
                     "dashboard/usage.py (chantier « limites d'usage ») pas encore fusionne : le test s'active tout seul a la fusion")
class RealUsageService(Fixture):
    """L'adaptateur de Chloe contre le VRAI service des fenetres d'usage (et non une doublure)."""

    def test_the_session_window_of_the_real_service_bounds_the_workers_chloe_may_call(self):
        import usage as usage_mod
        os.makedirs(os.path.join(TMP, "core", "usage"), exist_ok=True)
        shutil.copy2(os.path.join(REPO, "core", "usage", "USAGE-LIMITS.json"), os.path.join(TMP, "core", "usage", "USAGE-LIMITS.json"))
        now = time.time()

        def plan_view(client_id):
            return {"planId": "equipe", "monthlyCredits": 900, "cycleStartUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - 3 * 86400)),
                    "renewsAtUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + 27 * 86400)), "exempt": False, "override": None}
        write_billing(A, "equipe")
        mode = {"v": "off"}
        import usage_wiring
        svc = usage_wiring.WiredUsage(server.__dict__)         # le service tel que server.py le branche (forfait lu dans la facturation du compte de test)
        svc._mode = lambda: mode["v"]
        server.USAGE = svc
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 150, "service inerte : le solde du mois")
        mode["v"] = "shadow"
        self.assertEqual(server.chloe_worker_cap(A, "equilibre"), 150, "ombre : rien n'est borne")
        mode["v"] = "on"
        budget = server.CHLOE_SCOPE.mission_budget(A, "equilibre")
        self.assertEqual((budget["source"], budget["binding"]), ("usage", "session"))
        self.assertEqual(budget["workers"], budget["creditsAllowed"] // 6)
        self.assertLess(budget["workers"], 150, "la session (environ 40 % de la semaine) borne avant le mois")
        reservation = svc.reserve(A, budget["creditsAllowed"] - 5, "mission", "TEST")
        self.assertTrue(hasattr(reservation, "id") or hasattr(reservation, "reservationId") or reservation is not None)
        after = server.CHLOE_SCOPE.mission_budget(A, "equilibre")
        self.assertEqual(after["workers"], 1, "il reste 5 credits : au moins un Worker (la porte du serveur a deja verifie qu'une mission est payable)")
        self.assertIsNotNone(after["resetsAtUtc"], "la fenetre est ouverte : l'heure de renouvellement est connue")
        env = server.CHLOE_SCOPE.child_env(A, "equilibre", "chloe")
        self.assertTrue(env.get("BK_CHLOE_RESET_NOTE"), "phrase de renouvellement fabriquee par le serveur")


class AttachPendingActions(Fixture):
    def test_every_prepared_action_comes_back_with_the_worker_that_prepared_it(self):
        os.makedirs(server.PENDING_ACTIONS_DIR, exist_ok=True)
        ids = ["TASK-" + c * 32 for c in "AB"]
        for tid, worker in zip(ids, ("EMMA", "ALEX")):
            with open(server._pending_action_path(tid), "w", encoding="utf-8") as f:
                json.dump({"taskId": tid, "clientId": A, "workerId": worker, "connectorId": "gmail", "operation": "DRAFT_MESSAGE", "params": {"To": "a@b.ch"}, "reason": "test"}, f)
        out = server.attach_pending_action({"Results": [{"Worker": "EMMA", "TaskId": ids[0]}, {"Worker": "ALEX", "TaskId": ids[1]}]})
        self.assertEqual([(p["taskId"], p["workerId"]) for p in out["pendingActions"]], [(ids[0], "EMMA"), (ids[1], "ALEX")])
        self.assertEqual(out["pendingAction"]["workerId"], "EMMA")


class PurgeAndTriage(Fixture):
    def test_deleting_an_account_removes_its_multi_worker_runs(self):
        run = os.path.join(TMP, "runtime", "chloe-runs", A, "RUN-1", "workspace", "handoff")
        other = os.path.join(TMP, "runtime", "chloe-runs", "CLI-CUST-BBBBBBBB", "RUN-2")
        os.makedirs(run)
        os.makedirs(other)
        server._purge_client_mission_artifacts(A, [])
        self.assertFalse(os.path.exists(os.path.join(TMP, "runtime", "chloe-runs", A)))
        self.assertTrue(os.path.isdir(other), "les missions des autres clients ne sont jamais touchees")

    def test_triage_adds_the_scope_and_passes_the_rights_through_the_environment(self):
        write_billing(A, "trio", ["lea", "emma", "lucas"])
        seen = {}

        def fake_triage(root, ps_cmd, request, env, timeout=60):
            seen.update(request=request, allowed=env.get("BK_ALLOWED_WORKERS"), root=root)
            return {"ok": True, "mode": "project", "why": "site complet", "workers": [], "notIncluded": ["clara"]}
        original = server._chloe_scope.run_triage
        server._chloe_scope.run_triage = fake_triage
        try:
            out = server.chloe_triage(A, "Cree mon site et fais relire mes CGV")
        finally:
            server._chloe_scope.run_triage = original
        self.assertEqual(out["mode"], "project")
        self.assertEqual(seen["allowed"], "lea,emma,lucas")
        self.assertEqual(out["scope"]["allowed"], ["lea", "emma", "lucas"])
        self.assertTrue(out["scope"]["hireOffer"])
        for _ in range(20):
            self.assertTrue(server.chloe_triage_rate_ok(A))
        self.assertFalse(server.chloe_triage_rate_ok(A), "20 aiguillages par heure et par client")
        self.assertTrue(server.chloe_triage_rate_ok("CLI-CUST-BBBBBBBB"))


class AsyncQueue(Fixture):
    """File d'attente : un serveur occupe fait attendre la mission, il ne la refuse plus (seule une file pleine refuse)."""

    def setUp(self):
        super().setUp()
        self.gate = threading.Event()
        self.started = []
        self.saved = (server.submit_task, server.attach_pending_action, server.ASYNC_MAX_PER_CLIENT, server.ASYNC_MAX_GLOBAL,
                      server.ASYNC_QUEUE_MAX_PER_CLIENT, server.ASYNC_QUEUE_MAX_GLOBAL, server.ASYNC_QUEUE_MAX_WAIT_SECONDS)

        def fake_submit(objective, worker_id="", plan_only=False, client_id="", level=None):
            self.started.append((client_id, objective))
            self.gate.wait(15)
            return {"Status": "SUCCESS", "Result": {"Answer": "ok"}}
        server.submit_task = fake_submit
        server.attach_pending_action = lambda r: r
        server.ASYNC_JOBS_DIR = os.path.join(TMP, "runtime", "async-jobs")
        server.ASYNC_MAX_PER_CLIENT, server.ASYNC_MAX_GLOBAL = 2, 3
        server.ASYNC_QUEUE_MAX_PER_CLIENT, server.ASYNC_QUEUE_MAX_GLOBAL = 2, 4
        with server._ASYNC_ACTIVE_LOCK:
            server._ASYNC_ACTIVE.clear()
            server._ASYNC_QUEUE.clear()

    def tearDown(self):
        self.gate.set()
        time.sleep(0.4)
        (server.submit_task, server.attach_pending_action, server.ASYNC_MAX_PER_CLIENT, server.ASYNC_MAX_GLOBAL,
         server.ASYNC_QUEUE_MAX_PER_CLIENT, server.ASYNC_QUEUE_MAX_GLOBAL, server.ASYNC_QUEUE_MAX_WAIT_SECONDS) = self.saved

    def wait_for(self, job_id, status, timeout=10):
        end = time.time() + timeout
        while time.time() < end:
            job = server.read_async_job(job_id)
            if job and job["status"] == status:
                return job
            time.sleep(0.05)
        self.fail(f"{job_id} never reached {status}: {server.read_async_job(job_id)}")

    def test_a_busy_server_queues_the_mission_with_its_position_and_runs_it_when_a_place_frees_up(self):
        a = server.submit_task_async("1", "chloe", "CLI-A")
        b = server.submit_task_async("2", "chloe", "CLI-A")
        c = server.submit_task_async("3", "chloe", "CLI-A")           # le client a deja 2 missions : la 3e attend
        d = server.submit_task_async("4", "chloe", "CLI-A")
        self.assertEqual((a["status"], b["status"], c["status"], d["status"]), ("RUNNING", "RUNNING", "QUEUED", "QUEUED"))
        self.assertEqual((c["queuePosition"], d["queuePosition"]), (1, 2))
        job = server.read_async_job(c["jobId"])
        self.assertEqual((job["status"], job["queuePosition"]), ("QUEUED", 1))
        self.assertEqual(server.read_async_job(d["jobId"])["queuePosition"], 2)
        time.sleep(0.3)
        self.assertEqual([x[1] for x in self.started], ["1", "2"], "la file ne lance rien tant que la place manque")
        full = server.submit_task_async("5", "chloe", "CLI-A")        # file du client pleine : le seul refus qui reste
        self.assertEqual(full["error"], "TOO_MANY_RUNNING_MISSIONS")
        self.assertIn("en attente", full["detail"])
        self.gate.set()
        for j in (a, b, c, d):
            self.wait_for(j["jobId"], "DONE")
        order = [x[1] for x in self.started]
        # 3 et 4 partent ensemble quand 1 et 2 finissent : leur ordre de demarrage est une course entre threads ;
        # ce qui compte, c'est que la file n'ait jamais devance les deux premiers.
        self.assertEqual(order[:2], ["1", "2"], "ordre d'arrivee")
        self.assertEqual(sorted(order[2:]), ["3", "4"], "ordre d'arrivee")
        self.assertEqual(server._ASYNC_QUEUE, [])
        self.assertEqual(server._ASYNC_ACTIVE, {})

    def test_a_client_at_its_cap_does_not_hold_back_the_missions_of_other_clients(self):
        a = server.submit_task_async("a1", "chloe", "CLI-A")
        b = server.submit_task_async("a2", "chloe", "CLI-A")
        c = server.submit_task_async("a3", "chloe", "CLI-A")          # en file : CLI-A est a son plafond (2)
        o = server.submit_task_async("b1", "chloe", "CLI-B")          # place libre sur le serveur (3 au plus) : part tout de suite
        self.assertEqual((c["status"], o["status"]), ("QUEUED", "RUNNING"))
        self.gate.set()
        for j in (a, b, c, o):
            self.wait_for(j["jobId"], "DONE")

    def test_a_mission_never_waits_more_than_the_limit_and_says_so(self):
        server.ASYNC_QUEUE_MAX_WAIT_SECONDS = 1
        a = server.submit_task_async("1", "chloe", "CLI-A")
        b = server.submit_task_async("2", "chloe", "CLI-A")
        c = server.submit_task_async("3", "chloe", "CLI-A")
        job = self.wait_for(c["jobId"], "ERROR", timeout=15)
        self.assertEqual(job["errorCode"], "QUEUE_TIMEOUT")
        self.assertIn("très sollicité", job["error"])
        self.assertEqual(server._ASYNC_QUEUE, [])
        self.gate.set()
        self.wait_for(a["jobId"], "DONE")
        self.wait_for(b["jobId"], "DONE")

    def test_the_boot_reaper_interrupts_queued_missions_too(self):
        os.makedirs(server.ASYNC_JOBS_DIR, exist_ok=True)
        job = {"jobId": "JOB-" + "F" * 32, "status": "QUEUED", "clientId": "CLI-F"}
        with open(server._async_job_path(job["jobId"]), "w", encoding="utf-8") as f:
            json.dump(job, f)
        server.reap_async_jobs(time.time(), boot=True)
        self.assertEqual(server.read_async_job(job["jobId"])["status"], "ERROR")

    def test_a_running_chloe_mission_shows_which_worker_is_working_and_nothing_else(self):
        job_id = "JOB-" + "9" * 32
        run = os.path.join(TMP, "runtime", "chloe-runs", A, job_id)
        os.makedirs(run)
        with open(os.path.join(run, "progress.json"), "w", encoding="utf-8") as f:
            json.dump({"runId": job_id, "tasks": [{"id": "T1", "worker": "lea", "name": "Lea", "status": "DONE", "reason": "", "answer": "SECRET TEXT"},
                                                  {"id": "T2", "worker": "lucas", "name": "Lucas", "status": "RUNNING", "reason": ""}]}, f)
        os.makedirs(server.ASYNC_JOBS_DIR, exist_ok=True)
        with open(server._async_job_path(job_id), "w", encoding="utf-8") as f:
            json.dump({"jobId": job_id, "status": "RUNNING", "clientId": A, "worker": "chloe", "objective": "x"}, f)
        job = server.read_async_job(job_id)
        self.assertEqual([(t["id"], t["status"]) for t in job["progress"]["tasks"]], [("T1", "DONE"), ("T2", "RUNNING")])
        self.assertNotIn("SECRET TEXT", json.dumps(job))
        self.assertIsNone(server._chloe_run_progress("CLI-../../x", job_id), "identifiant invalide : rien n'est lu")


if __name__ == "__main__":
    unittest.main(verbosity=2)
