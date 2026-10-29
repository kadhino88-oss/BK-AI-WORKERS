# -*- coding: utf-8 -*-
"""dashboard/server.py : choix du moteur d'IA par mission, sans PowerShell ni reseau (subprocess.run et le coffre chiffre sont remplaces).

    python tests/providers/test_server_engine.py       (Windows ou Linux)

Couvre : GET /api/engine (engine_status), moteur de l'essai / du client payant / du proprietaire / de l'essai public, reglages du proprietaire (validation,
journal), cle personnelle (forme, isolement entre clients, desactivation, suppression, purge a la suppression du compte, export), variables posees sur le
processus d'une mission (aucune sans choix du proprietaire, rien d'herite d'une ancienne mission), alerte de depense apres une mission, matrice de capacites.
"""
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
TMP = tempfile.mkdtemp(prefix="bkengsrv-")
for rel in ("core/runtime/worker-runtime/WORKER-REGISTRY.json", "core/ai/LEVELS.json", "workers/noah/identity/identity.json", "workers/alex/identity/identity.json",
            "dashboard/phone-agent/CLI-DASHBOARD.json"):
    dst = os.path.join(TMP, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(os.path.join(REPO, rel), dst)
os.environ["BK_ROOT"] = TMP
for k in ("BK_AI_PROVIDER", "BK_OLLAMA_URL", "BK_OLLAMA_MODEL", "BK_CLAUDE_DAILY_CHF", "BK_CLAUDE_MONTHLY_CHF", "BK_ENGINE_PLAN", "BK_PILOT_NOTIFY_EMAIL"):
    os.environ.pop(k, None)
spec = importlib.util.spec_from_file_location("bk_server_engine", os.path.join(REPO, "dashboard", "server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)
pr = server.provider_router

A, B = "CLI-CUST-AAAAAAAA", "CLI-CUST-BBBBBBBB"
KEY_A = "sk-ant-" + "AliceKey0123456789abcdef"
KEY_B = "sk-ant-" + "BobKey0123456789abcdefgh"
OLLAMA = {"endpoints": {"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}}}


def write_billing(client, plan):
    state = {"planId": plan, "gridVersion": 2, "cycleStartUtc": "2026-10-01T00:00:00Z", "extraCredits": 0, "history": []}
    os.makedirs(server.BILLING_DATA_DIR, exist_ok=True)
    with open(server._billing_path(client), "w", encoding="utf-8") as f:
        json.dump(state, f)


def add_account(client, password="motdepasse-test"):
    accounts = server._load_accounts()
    accounts.append({"accountId": client, "clientId": client, "email": client.lower() + "@mail-test.example", "passwordHash": server._hash_password(password),
                     "companyName": "Test SA", "emailVerified": True})
    server._save_accounts(accounts)


class FakeVault:
    """Remplace store_client_connector_credential : garde ce que le serveur voudrait chiffrer, sans PowerShell."""

    def __init__(self):
        self.stored = {}
        self.calls = []

    def __call__(self, client_id, provider, value, reserved=False):
        self.calls.append((client_id, provider, bool(value), reserved))
        if provider != "ai_engine" or not reserved:
            return {"ok": False, "error": "UNKNOWN_PROVIDER"}
        d = os.path.join(server.CLIENT_CREDENTIALS_DIR, client_id)
        path = os.path.join(d, "ai_engine.json")
        if value:
            os.makedirs(d, exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                json.dump({"ciphertext": "x" * 40, "updatedAtUtc": "now"}, f)
            self.stored[client_id] = value
        else:
            self.stored.pop(client_id, None)
            if os.path.isfile(path):
                os.remove(path)
        return {"ok": True}


class Fixture(unittest.TestCase):
    def setUp(self):
        for d in (server.BILLING_DATA_DIR, os.path.join(TMP, "runtime"), os.path.join(TMP, "core", "accounts"), os.path.join(TMP, "core", "ai", "data"),
                  server.CLIENT_CREDENTIALS_DIR):
            shutil.rmtree(d, ignore_errors=True)
        server.CRED_SAVE_RATE.clear()
        self.vault = FakeVault()
        self._orig = server.store_client_connector_credential
        server.store_client_connector_credential = self.vault
        self.addCleanup(setattr, server, "store_client_connector_credential", self._orig)
        self.alerts = []
        self._orig_notify = server._notify_engine_alert
        server._notify_engine_alert = lambda subject, text: self.alerts.append(subject)
        self.addCleanup(setattr, server, "_notify_engine_alert", self._orig_notify)
        write_billing(A, "essai")
        write_billing(B, "equipe")

    def owner_set(self, patch):
        payload, status = server.admin_apply_engine_settings(patch)
        self.assertEqual(status, 200, payload)
        return payload


class EngineStatus(Fixture):
    def test_nothing_chosen_means_claude_and_nothing_written(self):
        for client in (A, B, server.DASHBOARD_CLIENT_ID, server.TRIAL_CLIENT_ID):
            v = server.engine_status(client)
            self.assertEqual((v["provider"], v["summary"], v["explicit"]), ("anthropic", "Moteur : Claude", False), client)
        self.assertFalse(os.path.isfile(pr.settings_path(TMP)))
        self.assertEqual(pr.plan_env(server.engine_plan_for(A, "rapide")), {})

    def test_trial_accounts_run_locally_and_paying_ones_on_claude_once_the_owner_configured_ollama(self):
        self.owner_set(OLLAMA)
        trial = server.engine_status(A)
        self.assertEqual((trial["provider"], trial["local"], trial["reason"]), ("ollama", True, "trial"))
        self.assertEqual(trial["summary"], "Moteur local (Llama 3) : réponses plus simples, pas de recherche web ni de fichiers Office")
        self.assertEqual(server.engine_status(server.TRIAL_CLIENT_ID)["provider"], "ollama", "essai public (visiteur) idem")
        paying = server.engine_status(B)
        self.assertEqual((paying["provider"], paying["explicit"]), ("anthropic", False))
        self.assertEqual(server.engine_status(server.DASHBOARD_CLIENT_ID)["provider"], "anthropic", "le proprietaire n'est jamais verrouille sur le moteur gratuit")

    def test_response_never_carries_an_address_or_a_token(self):
        self.owner_set(OLLAMA)
        text = json.dumps(server.engine_status(A))
        self.assertNotIn("127.0.0.1", text)
        self.assertNotIn("11434", text)
        self.assertNotIn("Bearer", text)

    def test_level_changes_nothing_for_the_default_chain_and_is_normalised(self):
        v = server.engine_status(B, "approfondi")
        self.assertEqual(v["level"], "approfondi")
        self.assertEqual(server.engine_status(A, "approfondi")["level"], "rapide", "l'essai est verrouille sur Rapide")

    def test_capabilities_for_project_mode(self):
        self.owner_set(OLLAMA)
        local = server.engine_capabilities(A)
        claude = server.engine_capabilities(B)
        self.assertFalse(local["officeFiles"] or local["codeExecution"] or local["webSearch"] or local["longProjects"])
        self.assertTrue(claude["officeFiles"] and claude["codeExecution"] and claude["webSearch"] and claude["longProjects"])
        self.assertEqual((local["toolUse"], claude["toolUse"]), ("weak", "reliable"))

    def test_matrix_lists_every_engine(self):
        m = server.engine_status(B)["matrix"]
        self.assertEqual(set(m), {"anthropic", "ollama", "swiss", "byok-anthropic", "byok-openai_compat"})

    def test_breaker_and_ceiling_show_in_the_status(self):
        self.owner_set(dict(OLLAMA, defaultChain=["anthropic", "ollama"], ceiling={"dailyChf": 1.0}))
        v = server.engine_status(B)
        self.assertEqual([c["provider"] for c in v["chain"]], ["anthropic", "ollama"])
        day = pr._day_key(time.time())
        pr._write_atomic(pr.spend_path(TMP), {"days": {day: {"chf": 1.5, "usd": 1.5, "missions": 1}}, "months": {day[:7]: {"chf": 1.5, "usd": 1.5, "missions": 1}}})
        v = server.engine_status(B)
        self.assertEqual(v["provider"], "ollama")
        self.assertIn({"id": "anthropic", "why": "spending-ceiling"}, v["skipped"])


class OwnerSettings(Fixture):
    def test_valid_settings_are_saved_and_logged_without_values(self):
        payload = self.owner_set({"defaultChain": ["ollama", "anthropic"], "ceiling": {"dailyChf": 5, "monthlyChf": 80}, **OLLAMA})
        self.assertEqual(payload["engine"]["defaultChain"], ["ollama", "anthropic"])
        self.assertEqual(payload["engine"]["ceiling"]["monthlyChf"], 80)
        events = server.load_json(server.ACTIVITY_LOG_PATH, [])
        last = [e for e in events if e.get("kind") == "engine_settings"][-1]
        self.assertEqual(last["fields"], ["ceiling", "defaultChain", "endpoints"])
        self.assertNotIn("11434", json.dumps(last))

    def test_invalid_settings_are_rejected_with_the_fields_and_nothing_is_written(self):
        payload, status = server.admin_apply_engine_settings({"endpoints": {"ollama": {"url": "http://8.8.8.8:11434", "model": "m"}}, "ceiling": {"dailyChf": -2}})
        self.assertEqual(status, 400)
        self.assertEqual(payload["error"], "INVALID_SETTINGS")
        self.assertEqual({e["field"] for e in payload["errors"]}, {"endpoints.ollama.url", "ceiling.dailyChf"})
        self.assertFalse(os.path.isfile(pr.settings_path(TMP)))

    def test_a_secret_key_in_the_body_is_refused(self):
        payload, status = server.admin_apply_engine_settings({"apiKey": "sk-ant-xxxxxxxxxxxxxxxxxxxxxxxx"})
        self.assertEqual(status, 400)


class Byok(Fixture):
    def test_valid_key_is_stored_encrypted_only_through_the_vault_and_never_returned(self):
        payload, status = server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload["byok"]["configured"], True)
        self.assertNotIn(KEY_A, json.dumps(payload))
        self.assertEqual(self.vault.calls, [(A, "ai_engine", True, True)])
        stored = json.loads(self.vault.stored[A])
        self.assertEqual((stored["kind"], stored["key"]), ("anthropic", KEY_A), "la cle part vers le coffre chiffre, et nulle part ailleurs")
        meta = open(pr.byok_meta_path(TMP, A), encoding="utf-8").read()
        self.assertNotIn(KEY_A, meta)
        self.assertNotIn(KEY_A, open(server.ACTIVITY_LOG_PATH, encoding="utf-8").read(), "la cle n'est pas dans le journal d'activite")
        v = server.engine_status(A)
        self.assertEqual((v["provider"], v["label"]), ("byok", "Votre clé (Claude)"))
        self.assertNotIn(KEY_A, json.dumps(v))

    def test_bad_keys_and_bad_addresses_are_refused_before_anything_is_stored(self):
        for body in ({"kind": "anthropic", "key": "nope"}, {"kind": "zzz", "key": KEY_A}, {"kind": "anthropic"}, {"kind": "anthropic", "key": 12345},
                     {"kind": "openai_compat", "key": "k" * 24, "endpoint": "https://evil.example/v1", "model": "m"},
                     {"kind": "openai_compat", "key": "k" * 24, "endpoint": "http://api.mistral.ai/v1", "model": "m"},
                     {"kind": "openai_compat", "key": "k" * 24, "endpoint": "https://api.mistral.ai/v1", "model": ""}):
            payload, status = server.store_byok(A, body)
            self.assertEqual((status, payload["error"]), (400, "INVALID_FIELD"), body)
        self.assertEqual(self.vault.calls, [])
        self.assertFalse(os.path.isfile(pr.byok_meta_path(TMP, A)))

    def test_only_customer_accounts_may_store_a_key(self):
        for cid in (server.DASHBOARD_CLIENT_ID, server.TRIAL_CLIENT_ID, "../../x"):
            payload, status = server.store_byok(cid, {"kind": "anthropic", "key": KEY_A})
            self.assertEqual(status, 403, cid)
        self.assertEqual(self.vault.calls, [])

    def test_two_clients_are_isolated(self):
        server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        server.store_byok(B, {"kind": "openai_compat", "key": "mk-" + "BobKey0123456789abcdef", "endpoint": "https://api.mistral.ai/v1", "model": "mistral-large-latest"})
        va, vb = server.engine_status(A), server.engine_status(B)
        self.assertEqual((va["provider"], va["byok"]["kind"]), ("byok", "anthropic"))
        self.assertEqual((vb["provider"], vb["byok"]["kind"], vb["byok"]["host"]), ("byok", "openai_compat", "api.mistral.ai"))
        self.assertNotEqual(self.vault.stored[A], self.vault.stored[B])
        plan_a, plan_b = server.engine_plan_for(A, "rapide"), server.engine_plan_for(B, "rapide")
        self.assertEqual(plan_a["chain"][0]["adapter"], "anthropic")
        self.assertEqual(plan_b["chain"][0]["adapter"], "openai_compat")
        self.assertNotIn(KEY_A, json.dumps(plan_a) + json.dumps(plan_b), "la cle ne figure jamais dans le plan passe au processus de la mission")
        server.remove_byok(A)
        self.assertEqual(server.engine_status(A)["provider"], "anthropic")
        self.assertEqual(server.engine_status(B)["provider"], "byok", "retirer la cle d'un client ne touche pas l'autre")

    def test_disable_keeps_the_key_but_stops_using_it(self):
        server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        payload, status = server.store_byok(A, {"enabled": False})
        self.assertEqual((status, payload["byok"]["enabled"]), (200, False))
        self.assertEqual(server.engine_status(A)["provider"], "anthropic")
        self.assertIn(A, self.vault.stored)
        server.store_byok(A, {"enabled": True})
        self.assertEqual(server.engine_status(A)["provider"], "byok")
        self.assertEqual(server.store_byok(B, {"enabled": True})[1], 404, "rien a activer sans cle")

    def test_removal_is_idempotent_and_clears_the_vault(self):
        server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        self.assertEqual(server.remove_byok(A)[1], 200)
        self.assertEqual(server.remove_byok(A)[1], 200)
        self.assertNotIn(A, self.vault.stored)
        self.assertFalse(os.path.isfile(pr.byok_meta_path(TMP, A)))

    def key_file(self, client):
        return os.path.join(server.CLIENT_CREDENTIALS_DIR, client, "ai_engine.json")

    def failing_vault(self):
        """Ce que renvoie le vrai pont quand PowerShell depasse ses 20 s (demarrage a froid) : rien n'a ete supprime."""
        calls = []

        def vault(client_id, provider, value, reserved=False):
            calls.append((client_id, provider, bool(value), reserved))
            return {"ok": False, "error": "STORE_CREDENTIAL_TIMEOUT"}
        server.store_client_connector_credential = vault
        return calls

    def test_a_vault_timeout_on_removal_still_removes_the_key_file_before_saying_so(self):
        add_account(A)
        server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        calls = self.failing_vault()
        payload, status = server.remove_byok(A)
        self.assertEqual(len(calls), 1, "le coffre est bien appele d'abord")
        self.assertEqual((status, payload), (200, {"ok": True, "byok": {"configured": False}}))
        self.assertFalse(os.path.isfile(self.key_file(A)), "supprimer ne demande aucun dechiffrement : le serveur retire le fichier lui-meme")
        self.assertFalse(os.path.isfile(pr.byok_meta_path(TMP, A)))
        self.assertFalse(server.export_account_data(A)["aiEngineKey"]["configured"])

    def test_a_removal_that_did_not_happen_is_never_reported_as_done(self):
        add_account(A)
        server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        self.failing_vault()
        real_remove = os.remove

        def stuck(path, *a, **kw):
            if os.path.basename(str(path)) == "ai_engine.json":
                raise PermissionError("fichier verrouille")
            return real_remove(path, *a, **kw)
        server.os.remove = stuck
        self.addCleanup(setattr, server.os, "remove", real_remove)
        payload, status = server.remove_byok(A)
        self.assertEqual((status, payload["error"]), (500, "STORE_FAILED"))
        self.assertIn("toujours enregistrée", payload["message"])
        self.assertNotIn("byok", payload, "aucun « configured: false » pour une cle encore sur le disque")
        self.assertTrue(os.path.isfile(self.key_file(A)))
        self.assertTrue(os.path.isfile(pr.byok_meta_path(TMP, A)), "la description reste : le client voit toujours sa cle")
        self.assertTrue(server.export_account_data(A)["aiEngineKey"]["configured"], "l'export dit la verite")
        self.assertEqual(server.engine_status(A)["provider"], "byok")
        server.os.remove = real_remove
        server.store_client_connector_credential = self.vault
        self.assertEqual(server.remove_byok(A)[0], {"ok": True, "byok": {"configured": False}}, "un nouvel essai aboutit")
        self.assertFalse(os.path.isfile(self.key_file(A)))

    def test_rate_limited(self):
        for _ in range(server.CRED_SAVE_MAX_PER_HOUR):
            server.store_byok(A, {"kind": "anthropic", "key": "bad"})
        payload, status = server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        self.assertEqual(status, 429)

    def test_account_deletion_purges_the_key_and_its_description_but_not_another_clients(self):
        add_account(A)
        add_account(B)
        server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        server.store_byok(B, {"kind": "anthropic", "key": KEY_B})
        self.assertIsNone(server.delete_account(A, "motdepasse-test"))
        self.assertFalse(os.path.isdir(os.path.join(server.CLIENT_CREDENTIALS_DIR, A)))
        self.assertFalse(os.path.isfile(pr.byok_meta_path(TMP, A)))
        self.assertTrue(os.path.isfile(os.path.join(server.CLIENT_CREDENTIALS_DIR, B, "ai_engine.json")))
        self.assertTrue(os.path.isfile(pr.byok_meta_path(TMP, B)))

    def test_export_reports_the_key_state_without_the_key_and_hides_it_from_the_tools_list(self):
        add_account(A)
        server.store_byok(A, {"kind": "anthropic", "key": KEY_A})
        os.makedirs(os.path.join(server.CLIENT_CREDENTIALS_DIR, A), exist_ok=True)
        with open(os.path.join(server.CLIENT_CREDENTIALS_DIR, A, "slack.json"), "w", encoding="utf-8") as f:
            f.write("{}")
        data = server.export_account_data(A)
        self.assertEqual(data["connectedTools"], ["slack"])
        self.assertTrue(data["aiEngineKey"]["configured"])
        self.assertNotIn(KEY_A, json.dumps(data))

    def test_the_reserved_vault_name_cannot_be_written_by_a_connector_route(self):
        self.assertEqual(self._orig("CLI-CUST-AAAAAAAA", "ai_engine", "x")["error"], "UNKNOWN_PROVIDER")


class ProcessEnvironmentOfAMission(Fixture):
    """Ce que submit_task pose sur le processus PowerShell de la mission."""

    def capture(self, client, level=None, objective="Bonjour", stale=None):
        seen = {}

        def fake_run(cmd, capture_output=True, timeout=0, env=None):
            seen["env"] = dict(env or {})
            out = cmd[cmd.index("-OutFile") + 1]
            with open(out, "w", encoding="utf-8") as f:
                json.dump({"TaskId": "TASK-" + "A" * 32, "Status": "EXECUTED", "Result": {"Answer": "ok"}}, f)

            class P:
                returncode, stdout, stderr = 0, b"", b""
            return P()
        old_run, old_env = server.subprocess.run, dict(os.environ)
        server.subprocess.run = fake_run
        try:
            if stale:
                os.environ.update(stale)
            server.submit_task(objective, worker_id="noah", client_id=client, level=level)
        finally:
            server.subprocess.run = old_run
            os.environ.clear()
            os.environ.update(old_env)
        return seen["env"]

    def test_no_variable_is_set_while_the_owner_has_chosen_nothing(self):
        env = self.capture(B, "rapide")
        for name in pr.PLAN_ENV_NAMES:
            self.assertNotIn(name, env)

    def test_a_stale_plan_inherited_from_the_server_environment_is_removed(self):
        env = self.capture(B, "rapide", stale={"BK_ENGINE_PLAN": '{"chain":[{"id":"ollama"}]}', "BK_ENGINE_BUDGET_CHF": "9"})
        self.assertNotIn("BK_ENGINE_PLAN", env)
        self.assertNotIn("BK_ENGINE_BUDGET_CHF", env)

    def test_trial_gets_the_free_chain_and_a_paying_client_does_not(self):
        self.owner_set(OLLAMA)
        trial = json.loads(self.capture(A, "rapide")["BK_ENGINE_PLAN"])
        self.assertEqual([e["id"] for e in trial["chain"]], ["ollama"])
        self.assertEqual(trial["reason"], "trial")
        self.assertNotIn("BK_ENGINE_PLAN", self.capture(B, "rapide"))

    def test_the_plan_carries_the_request_needs_and_no_token(self):
        self.owner_set(OLLAMA)
        env = self.capture(A, "rapide", objective="Fais-moi un fichier Excel", stale={"BK_SECRET_OLLAMA": "tok-should-not-be-in-plan-0123456"})
        plan = env["BK_ENGINE_PLAN"]
        self.assertEqual(json.loads(plan)["needs"], ["officeFiles"])
        self.assertNotIn("tok-should-not-be-in-plan", plan)

    def test_a_client_key_mission_gets_the_byok_chain_without_the_key(self):
        server.store_byok(B, {"kind": "anthropic", "key": KEY_B})
        env = self.capture(B, "rapide")
        plan = json.loads(env["BK_ENGINE_PLAN"])
        self.assertEqual([e["id"] for e in plan["chain"]], ["byok"])
        self.assertNotIn(KEY_B, env["BK_ENGINE_PLAN"])
        self.assertFalse(any(KEY_B in str(v) for v in env.values()), "la cle n'est dans aucune variable du processus de la mission")

    def test_the_remaining_budget_is_passed_and_an_alert_follows_the_mission(self):
        self.owner_set({"ceiling": {"dailyChf": 2.0}})
        day = pr._day_key(time.time())
        pr._write_atomic(pr.spend_path(TMP), {"days": {day: {"chf": 1.7, "usd": 1.7, "missions": 3}}, "months": {day[:7]: {"chf": 1.7, "usd": 1.7, "missions": 3}}})
        env = self.capture(B, "rapide")
        self.assertAlmostEqual(float(env["BK_ENGINE_BUDGET_CHF"]), 0.3, places=2)
        self.assertTrue(self.alerts and "80 %" in self.alerts[0], self.alerts)
        before = len(self.alerts)
        self.capture(B, "rapide")
        self.assertEqual(len(self.alerts), before, "une seule alerte par palier et par periode")

    def test_a_broken_settings_file_never_blocks_a_mission(self):
        os.makedirs(os.path.dirname(pr.settings_path(TMP)), exist_ok=True)
        with open(pr.settings_path(TMP), "w", encoding="utf-8") as f:
            f.write("{pas du json")
        env = self.capture(B, "rapide")
        self.assertNotIn("BK_ENGINE_PLAN", env)


class MissionResultsShowTheEngine(Fixture):
    ENGINE = {"provider": "ollama", "model": "llama3:latest", "local": True, "failedOver": True, "label": "Moteur local (Llama 3)", "byok": False,
              "attempts": [{"provider": "anthropic", "outcome": "failed", "reason": "billing"}], "summary": "x"}

    def test_public_engine_view_hides_the_technical_details(self):
        pub = server._engine_public(self.ENGINE)
        self.assertEqual(set(pub), {"provider", "model", "local", "failedOver", "label", "byok"})
        self.assertIsNone(server._engine_public(None))
        self.assertIsNone(server._engine_public({"nothing": 1}))

    def test_summaries_for_zapier_make_carry_the_engine(self):
        single = server._summarize_mission_result({"TaskId": "T", "Worker": "NOAH", "Status": "EXECUTED", "Result": {"Answer": "ok", "Engine": self.ENGINE}})
        self.assertEqual(single["engine"]["label"], "Moteur local (Llama 3)")
        multi = server._summarize_mission_result({"Status": "SUCCESS", "Results": [{"TaskId": "T", "Worker": "NOAH", "Status": "SUCCESS", "Result": {"Answer": "ok", "Engine": self.ENGINE}}]})
        self.assertEqual(multi["results"][0]["engine"]["provider"], "ollama")
        none = server._summarize_mission_result({"TaskId": "T", "Worker": "NOAH", "Status": "EXECUTED", "Result": {"Answer": "ok"}})
        self.assertIsNone(none["engine"], "sans plan de moteurs : null, comme un champ en plus")

    def test_activity_lists_keep_the_engine_of_each_mission(self):
        os.makedirs(server.TASKS_DIR, exist_ok=True)
        rec = {"TaskId": "TASK-" + "C" * 32, "Request": "x", "Worker": "NOAH", "Status": "EXECUTED", "Authorized": True, "ClientId": A, "CreatedAtUtc": "2026-10-26T10:00:00Z",
               "Result": {"Answer": "ok", "Engine": self.ENGINE}}
        with open(os.path.join(server.TASKS_DIR, rec["TaskId"] + ".json"), "w", encoding="utf-8") as f:
            json.dump(rec, f)
        self.assertEqual(server.get_worker_activity("NOAH", A)[0]["engine"]["label"], "Moteur local (Llama 3)")
        self.assertEqual(server.get_client_missions(A)[0]["engine"]["failedOver"], True)
        self.assertEqual(server.get_worker_activity("NOAH", B), [], "un autre client ne voit rien")


def tearDownModule():
    shutil.rmtree(TMP, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
