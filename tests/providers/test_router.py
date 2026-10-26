# -*- coding: utf-8 -*-
"""dashboard/provider_router.py : le routeur de moteurs d'IA (aucun reseau, aucun PowerShell).

    python tests/providers/test_router.py       (Windows ou Linux)

Couvre : comportement INCHANGE tant que rien n'est choisi, chaines par niveau, essai verrouille sur la chaine gratuite, cle personnelle (jamais de repli vers
nos moteurs), disjoncteur, plafond de depense Claude (80 %, atteint, bascule honnete), repli seulement le long de la chaine, matrice de capacites par moteur,
reglages du proprietaire (validation, secrets), description de la cle personnelle (jamais la cle).
"""
import json
import os
import shutil
import sys
import tempfile
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import provider_router as pr  # noqa: E402

with open(os.path.join(REPO, "core", "ai", "LEVELS.json"), encoding="utf-8-sig") as f:
    LEVELS = json.load(f)["levels"]
OLLAMA_ENV = {"BK_OLLAMA_URL": "http://127.0.0.1:11434", "BK_OLLAMA_MODEL": "llama3:latest"}
CLIENT = "CLI-CUST-AAAAAAAA"
NOW = 1_790_000_000.0          # un jour UTC fixe


class Base(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bkrouter-")
        self.addCleanup(shutil.rmtree, self.root, True)

    def settings(self, **kw):
        s, errors = pr.apply_settings(self.root, kw, levels=LEVELS, env=OLLAMA_ENV, resolver=lambda h, p: ["127.0.0.1"])
        self.assertEqual(errors, [], errors)
        return s

    def spend(self, chf, now=NOW):
        day = pr._day_key(now)
        pr._write_atomic(pr.spend_path(self.root), {"days": {day: {"chf": chf, "usd": chf, "missions": 1}}, "months": {day[:7]: {"chf": chf, "usd": chf, "missions": 1}}})

    def plan(self, level="equilibre", env=None, **kw):
        return pr.resolve_plan(self.root, kw.pop("client", CLIENT), level, kw.pop("objective", ""), now=NOW, env=env if env is not None else {}, levels=LEVELS, **kw)

    def ids(self, plan):
        return [e["id"] for e in plan["chain"]]


class NothingChangesUntilTheOwnerChooses(Base):
    def test_default_plan_is_implicit_claude_and_sets_no_variable(self):
        plan = self.plan()
        self.assertEqual(self.ids(plan), ["anthropic"])
        self.assertFalse(plan["explicit"])
        self.assertEqual(plan["reason"], "default")
        self.assertEqual(pr.plan_env(plan), {}, "aucune variable posee : le chemin Claude tourne comme avant")

    def test_trial_without_a_free_engine_keeps_the_old_behaviour(self):
        plan = self.plan("rapide", trial=True)
        self.assertEqual(self.ids(plan), ["anthropic"])
        self.assertFalse(plan["explicit"])

    def test_env_provider_explicit_anthropic_is_still_implicit(self):
        plan = self.plan(env={"BK_AI_PROVIDER": "anthropic"})
        self.assertFalse(plan["explicit"])

    def test_aliases_of_the_environment_variable(self):
        plan = self.plan(env=dict(OLLAMA_ENV, BK_AI_PROVIDER="local,claude"))
        self.assertEqual(self.ids(plan), ["ollama", "anthropic"])


class Chains(Base):
    def test_env_chain_prefers_the_local_engine_then_claude(self):
        plan = self.plan(env=dict(OLLAMA_ENV, BK_AI_PROVIDER="ollama,anthropic"))
        self.assertEqual(self.ids(plan), ["ollama", "anthropic"])
        self.assertTrue(plan["explicit"])
        self.assertEqual(plan["preferred"], "ollama")
        self.assertIn("BK_ENGINE_PLAN", pr.plan_env(plan))
        decoded = json.loads(pr.plan_env(plan)["BK_ENGINE_PLAN"])
        self.assertEqual([e["id"] for e in decoded["chain"]], ["ollama", "anthropic"])
        self.assertNotIn("token", json.dumps(decoded).lower().replace("tokenpresent", ""), "aucun jeton dans le plan")

    def test_an_engine_without_address_is_skipped_not_invented(self):
        plan = self.plan(env={"BK_AI_PROVIDER": "ollama,anthropic"})          # pas de BK_OLLAMA_URL
        self.assertEqual(self.ids(plan), ["anthropic"])
        self.assertEqual(plan["skipped"], [{"id": "ollama", "why": "not-configured"}])

    def test_level_chain_in_levels_json(self):
        levels = json.loads(json.dumps(LEVELS))
        levels["rapide"]["providers"] = ["ollama", "anthropic"]
        plan = pr.resolve_plan(self.root, CLIENT, "rapide", "", now=NOW, env=OLLAMA_ENV, levels=levels)
        self.assertEqual(self.ids(plan), ["ollama", "anthropic"])
        self.assertEqual(plan["reason"], "level")
        other = pr.resolve_plan(self.root, CLIENT, "equilibre", "", now=NOW, env=OLLAMA_ENV, levels=levels)
        self.assertEqual(self.ids(other), ["anthropic"], "les autres niveaux gardent la chaine par defaut")

    def test_owner_level_chain_overrides_levels_json(self):
        self.settings(levelChains={"approfondi": ["anthropic", "ollama"]}, endpoints={"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}})
        plan = self.plan("approfondi")
        self.assertEqual(self.ids(plan), ["anthropic", "ollama"])

    def test_failover_only_along_the_allowed_chain(self):
        """Une chaine « moteur local seul » dont le moteur est mis de cote ne se rabat JAMAIS sur Claude."""
        self.settings(defaultChain=["ollama"], endpoints={"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}})
        pr.mark_unhealthy(self.root, "ollama", "connection", now=NOW)
        plan = self.plan()
        self.assertEqual(self.ids(plan), [])
        self.assertEqual(plan["degradedReason"], "no-engine-available")
        self.assertEqual(plan["skipped"][0]["id"], "ollama")


class TrialIsLockedToTheFreeChain(Base):
    def test_trial_uses_the_local_engine_only(self):
        self.settings(endpoints={"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}}, defaultChain=["anthropic", "ollama"])
        plan = self.plan("rapide", trial=True)
        self.assertEqual(self.ids(plan), ["ollama"])
        self.assertEqual(plan["reason"], "trial")
        self.assertTrue(plan["chain"][0]["free"])
        self.assertTrue(plan["chain"][0]["local"])

    def test_trial_never_falls_back_to_claude_when_the_local_engine_is_down(self):
        self.settings(endpoints={"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}})
        pr.mark_unhealthy(self.root, "ollama", "connection", now=NOW)
        plan = self.plan("rapide", trial=True)
        self.assertEqual(self.ids(plan), [])
        self.assertEqual(plan["degradedReason"], "free-chain-unavailable")

    def test_the_owner_cannot_put_claude_in_the_free_chain(self):
        _, errors = pr.apply_settings(self.root, {"freeChain": ["anthropic"]}, levels=LEVELS)
        self.assertTrue(errors)
        self.assertEqual(pr.free_chain(pr.load_settings(self.root)), ["ollama"])


class Byok(Base):
    META = {"kind": "anthropic", "host": "api.anthropic.com", "endpoint": "https://api.anthropic.com", "model": "", "enabled": True}

    def test_byok_has_its_own_chain_and_never_falls_back_to_ours(self):
        plan = self.plan(byok=self.META)
        self.assertEqual(self.ids(plan), ["byok"])
        self.assertFalse(plan["creditsFreeOnFailover"])
        self.assertEqual(plan["reason"], "byok")
        self.assertEqual(plan["chain"][0]["label"], "Votre clé (Claude)")

    def test_byok_ignores_the_spending_ceiling_and_the_circuit_of_our_engines(self):
        self.settings(ceiling={"dailyChf": 1.0})
        self.spend(5.0)
        pr.mark_unhealthy(self.root, "anthropic", "billing", now=NOW)
        plan = self.plan(byok=self.META)
        self.assertEqual(self.ids(plan), ["byok"])

    def test_a_disabled_key_is_not_used(self):
        plan = self.plan(byok=dict(self.META, enabled=False))
        self.assertEqual(self.ids(plan), ["anthropic"])

    def test_the_public_trial_never_uses_a_client_key(self):
        plan = self.plan(client="CLI-TRIAL-PUBLIC", byok=self.META)
        self.assertNotIn("byok", self.ids(plan))

    def test_public_view_never_contains_the_key(self):
        key = "sk-ant-" + "A1b2C3d4" * 5
        ok, err, info = pr.validate_byok({}, "anthropic", key)
        self.assertTrue(ok, err)
        pr.save_byok_meta(self.root, CLIENT, "anthropic", info["host"], info["endpoint"], info["model"])
        view = pr.byok_public_view(pr.load_byok_meta(self.root, CLIENT))
        with open(pr.byok_meta_path(self.root, CLIENT), encoding="utf-8") as f:
            on_disk = f.read()
        for blob in (json.dumps(view), on_disk, json.dumps(info)):
            self.assertNotIn(key, blob)
            self.assertNotIn(key[:12], blob)
        self.assertTrue(view["configured"])

    def test_validation_is_by_shape_only(self):
        self.assertFalse(pr.validate_byok({}, "anthropic", "pas-une-cle")[0])
        self.assertFalse(pr.validate_byok({}, "anthropic", "sk-ant-court")[0])
        self.assertFalse(pr.validate_byok({}, "inconnu", "x" * 30)[0])
        generic = "mk-" + "a1B2c3D4" * 4
        self.assertFalse(pr.validate_byok({}, "openai_compat", generic, "https://api.mistral.ai/v1", "")[0], "le modele est obligatoire")
        ok, err, info = pr.validate_byok({}, "openai_compat", generic, "https://api.mistral.ai/v1", "mistral-large-latest")
        self.assertTrue(ok, err)
        self.assertEqual(info["host"], "api.mistral.ai")

    def test_a_client_cannot_aim_the_server_at_an_address_of_their_choice(self):
        generic = "mk-" + "a1B2c3D4" * 4
        for url in ("http://api.mistral.ai/v1", "https://169.254.169.254/v1", "https://127.0.0.1/v1", "https://evil.example/v1", "https://user:pw@api.mistral.ai/v1",
                    "file:///etc/passwd", "https://10.0.0.5/v1"):
            ok, err, _ = pr.validate_byok({}, "openai_compat", generic, url, "m")
            self.assertFalse(ok, url)
            self.assertEqual(err["field"], "endpoint", url)
        # un hote ajoute par le proprietaire devient acceptable, rien d'autre
        ok, _, _ = pr.validate_byok({"byokAllowedHosts": ["ai.exemple.ch"]}, "openai_compat", generic, "https://ai.exemple.ch/v1", "m")
        self.assertTrue(ok)


class SpendingCeiling(Base):
    def setUp(self):
        super().setUp()
        self.settings(ceiling={"dailyChf": 2.0, "monthlyChf": 20.0}, endpoints={"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}})

    def test_remaining_budget_is_the_smaller_of_the_two_ceilings(self):
        self.spend(0.5)
        st = pr.ceiling_status(self.root, pr.load_settings(self.root), NOW)
        self.assertEqual((st["configured"], st["reached"], st["which"]), (True, False, "day"))
        self.assertAlmostEqual(st["remainingChf"], 1.5, places=3)
        plan = self.plan()
        self.assertEqual(self.ids(plan), ["anthropic"])
        self.assertAlmostEqual(plan["budgetChf"], 1.5, places=3)
        self.assertAlmostEqual(float(pr.plan_env(plan)["BK_ENGINE_BUDGET_CHF"]), 1.5, places=3)

    def test_reaching_the_ceiling_switches_to_the_free_chain_with_an_honest_reason(self):
        self.spend(2.0)
        plan = self.plan()
        self.assertEqual(self.ids(plan), ["ollama"])
        self.assertEqual(plan["reason"], "spending-ceiling")
        self.assertEqual(plan["preferred"], "anthropic", "le moteur prevu reste Claude : le repli sera donc affiche comme tel")
        self.assertTrue(plan["explicit"])
        self.assertIn({"id": "anthropic", "why": "spending-ceiling"}, plan["skipped"])

    def test_reaching_the_ceiling_without_a_free_engine_leaves_no_engine_rather_than_spending(self):
        self.settings(endpoints={"ollama": None})
        self.spend(2.5)
        plan = self.plan()
        self.assertEqual(self.ids(plan), [], "pas de moteur gratuit configure : Claude n'est pas appele au-dela du plafond")

    def test_alert_at_80_percent_then_when_reached_each_once_per_period(self):
        sent = []
        self.spend(1.4)
        self.assertEqual(pr.maybe_alert(self.root, pr.load_settings(self.root), NOW, lambda s, t: sent.append(s)), [], "1,40 sur 2 = 70 % : rien")
        self.spend(1.7)
        first = pr.maybe_alert(self.root, pr.load_settings(self.root), NOW, lambda s, t: sent.append(s))
        self.assertEqual([a["scope"] for a in first], ["day"])
        self.assertIn("à 80 %", sent[0])
        self.assertEqual(pr.maybe_alert(self.root, pr.load_settings(self.root), NOW, lambda s, t: sent.append(s)), [], "une seule alerte par palier et par periode")
        self.spend(2.1)
        reached = pr.maybe_alert(self.root, pr.load_settings(self.root), NOW, lambda s, t: sent.append(s))
        self.assertEqual([a["reached"] for a in reached], [True])
        self.assertIn("ATTEINT", sent[-1])
        self.assertEqual(pr.maybe_alert(self.root, pr.load_settings(self.root), NOW, lambda s, t: sent.append(s)), [])
        self.assertEqual(len(sent), 2)
        # le lendemain, une nouvelle periode : le compteur du jour repart de zero (aucune alerte)
        tomorrow = NOW + 86400
        self.assertEqual(pr.maybe_alert(self.root, pr.load_settings(self.root), tomorrow, lambda s, t: sent.append(s)), [])

    def test_alerts_can_be_turned_off_and_a_failing_mailer_never_breaks_a_mission(self):
        self.settings(ceiling={"alert": False})
        self.spend(1.9)
        self.assertEqual(pr.maybe_alert(self.root, pr.load_settings(self.root), NOW, lambda s, t: 1 / 0), [])
        self.settings(ceiling={"alert": True})

        def boom(subject, text):
            raise RuntimeError("smtp down")
        pr.maybe_alert(self.root, pr.load_settings(self.root), NOW, boom)       # ne leve pas

    def test_no_ceiling_means_no_budget_and_no_alert(self):
        pr.apply_settings(self.root, {"ceiling": None}, levels=LEVELS)
        self.spend(100)
        plan = self.plan()
        self.assertIsNone(plan["budgetChf"])
        self.assertEqual(self.ids(plan), ["anthropic"])
        self.assertEqual(pr.maybe_alert(self.root, pr.load_settings(self.root), NOW), [])


class CircuitBreaker(Base):
    def test_billing_error_sets_the_engine_aside_for_a_few_minutes(self):
        self.settings(defaultChain=["anthropic", "ollama"], endpoints={"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}})
        pr.mark_unhealthy(self.root, "anthropic", "billing", now=NOW)
        plan = self.plan()
        self.assertEqual(self.ids(plan), ["ollama"])
        self.assertEqual(plan["preferred"], "anthropic")
        self.assertEqual(plan["skipped"][0]["why"], "circuit-open:billing")
        self.assertEqual(pr.health_snapshot(self.root, NOW)["anthropic"]["reason"], "billing")
        later = NOW + pr.BREAKER_SECONDS + 1
        plan_later = pr.resolve_plan(self.root, CLIENT, "equilibre", "", now=later, env={}, levels=LEVELS)
        self.assertEqual(self.ids(plan_later), ["anthropic", "ollama"], "le disjoncteur se referme tout seul")

    def test_clearing_one_engine_leaves_the_others(self):
        pr.mark_unhealthy(self.root, "anthropic", "billing", now=NOW)
        pr.mark_unhealthy(self.root, "ollama", "connection", now=NOW)
        pr.clear_health(self.root, "anthropic")
        self.assertEqual(list(pr.health_snapshot(self.root, NOW)), ["ollama"])


class Capabilities(Base):
    def test_matrix_is_honest_per_engine(self):
        m = pr.capability_matrix()
        self.assertEqual(set(m), {"anthropic", "ollama", "swiss", "byok-anthropic", "byok-openai_compat"})
        claude, local = m["anthropic"], m["ollama"]
        self.assertTrue(all(claude[k] for k in ("webSearch", "webFetch", "codeExecution", "officeFiles", "textFiles", "longProjects")))
        self.assertEqual(claude["toolUse"], "reliable")
        self.assertFalse(local["webSearch"])
        self.assertFalse(local["codeExecution"])
        self.assertFalse(local["officeFiles"])
        self.assertFalse(local["longProjects"])
        self.assertTrue(local["webFetch"] and local["textFiles"])
        self.assertEqual(local["toolUse"], "weak")
        self.assertIn("plus simples", local["languageNote"])
        self.assertIn("recherche web", local["limitsFr"])
        self.assertIn("fichiers Office (Excel, Word, PowerPoint, PDF)", local["limitsFr"])
        self.assertEqual(claude["limitsFr"], [])
        self.assertIsNotNone(local["webFetchNote"])

    def test_engine_supports_is_the_function_project_mode_calls(self):
        self.assertTrue(pr.engine_supports("anthropic", "officeFiles"))
        self.assertFalse(pr.engine_supports("ollama", "officeFiles"))
        self.assertFalse(pr.engine_supports("ollama", "longProjects"))
        self.assertFalse(pr.engine_supports("ollama", "toolUse"), "toolUse : seulement « reliable » vaut oui")
        self.assertTrue(pr.engine_supports("anthropic", "toolUse"))
        self.assertTrue(pr.engine_supports("byok", "webSearch", byok_kind="anthropic"))
        self.assertFalse(pr.engine_supports("byok", "webSearch", byok_kind="openai_compat"))
        self.assertFalse(pr.engine_supports("anthropic", "inconnu"))

    def test_search_endpoint_configured_by_the_owner_enables_web_search_only_then(self):
        self.assertFalse(pr.capabilities_for("ollama")["webSearch"])
        self.assertTrue(pr.capabilities_for("ollama", search_endpoint=True)["webSearch"])

    def test_labels_and_summaries_in_plain_french(self):
        self.assertEqual(pr.engine_summary("anthropic"), "Moteur : Claude")
        self.assertEqual(pr.engine_summary("ollama", "llama3:latest"), "Moteur local (Llama 3) : réponses plus simples, pas de recherche web ni de fichiers Office")
        self.assertEqual(pr.engine_label("ollama", "llama3:latest"), "Moteur local (Llama 3)")
        self.assertEqual(pr.engine_label("byok", "x", "anthropic"), "Votre clé (Claude)")

    def test_a_local_answer_is_never_labelled_claude(self):
        for model in ("llama3:latest", "qwen2.5:1.5b", "mistral:7b", ""):
            self.assertNotEqual(pr.engine_label("ollama", model), "Claude")
            self.assertNotEqual(pr.engine_summary("ollama", model), "Moteur : Claude")

    def test_needs_are_detected_from_the_request_and_noted_honestly(self):
        self.assertEqual(pr.needs_from_objective("Fais-moi un tableau Excel du budget"), ["officeFiles"])
        self.assertIn("webSearch", pr.needs_from_objective("Cherche sur le web les prix de mes concurrents"))
        self.assertIn("codeExecution", pr.needs_from_objective("Execute le script python pour calculer"))
        self.assertEqual(pr.needs_from_objective("Ecris un mail de relance poli"), [])
        note = pr.gap_note("Moteur local (Llama 3)", ["officeFiles"], pr.capabilities_for("ollama"))
        self.assertIn("Cette partie n'a PAS été réalisée", note)
        self.assertEqual(pr.gap_note("Claude", ["officeFiles"], pr.capabilities_for("anthropic")), "")

    def test_plan_carries_the_needs_for_the_executor(self):
        plan = self.plan(objective="Prépare un fichier Excel")
        self.assertEqual(plan["needs"], ["officeFiles"])


class SearchEndpoint(Base):
    def test_a_local_engine_has_no_web_search_until_the_owner_configures_an_endpoint(self):
        self.settings(endpoints={"ollama": {"url": "http://127.0.0.1:11434", "model": "llama3:latest"}})
        before = self.plan("rapide", trial=True)
        self.assertFalse(before["chain"][0]["caps"]["webSearch"])
        self.assertIsNone(before["chain"][0]["searchUrl"])
        self.settings(search={"url": "http://127.0.0.1:8888"})
        after = self.plan("rapide", trial=True)
        self.assertTrue(after["chain"][0]["caps"]["webSearch"])
        self.assertEqual(after["chain"][0]["searchUrl"], "http://127.0.0.1:8888")
        view = pr.engine_view(after)
        self.assertTrue(view["capabilities"]["webSearch"])
        self.assertIn("point de recherche", view["capabilities"]["webSearchNote"])
        self.assertNotIn("recherche web", view["capabilities"]["limitsFr"])
        self.assertTrue(pr.capabilities_for("ollama", search_endpoint=True)["webSearch"])

    def test_claude_keeps_its_own_search_and_no_note(self):
        caps = pr.capabilities_for("anthropic", search_endpoint=True)
        self.assertTrue(caps["webSearch"])
        self.assertIsNone(caps["webSearchNote"])

    def test_unsafe_search_addresses_are_refused(self):
        for url in ("http://8.8.8.8:8080", "http://169.254.169.254/", "ftp://127.0.0.1", "https://127.0.0.1:8888", "http://u:p@127.0.0.1"):
            _, errors = pr.apply_settings(self.root, {"search": {"url": url}}, levels=LEVELS, env={}, resolver=lambda h, p: [h])
            self.assertTrue(errors, url)
            self.assertEqual(errors[0]["field"], "search.url")
        self.assertFalse(os.path.isfile(pr.settings_path(self.root)))

    def test_search_can_be_cleared_and_never_stores_a_token(self):
        self.settings(search={"url": "http://100.101.102.103:8080"})
        self.assertEqual(pr.search_url(pr.load_settings(self.root)), "http://100.101.102.103:8080")
        self.assertNotIn("token", open(pr.settings_path(self.root), encoding="utf-8").read().lower())
        self.settings(search=None)
        self.assertEqual(pr.search_url(pr.load_settings(self.root)), "")

    def test_environment_variable_is_enough(self):
        self.assertEqual(pr.search_url({}, {"BK_SEARCH_URL": "http://192.168.1.50:8080"}), "http://192.168.1.50:8080")
        self.assertEqual(pr.search_url({}, {"BK_SEARCH_URL": "https://search.exemple.ch"}), "", "https sans jeton : pas configure")
        self.assertEqual(pr.search_url({}, {"BK_SEARCH_URL": "https://search.exemple.ch", "BK_SECRET_SEARCH": "x" * 20}), "https://search.exemple.ch")


class OwnerSettings(Base):
    def apply(self, patch):
        return pr.apply_settings(self.root, patch, levels=LEVELS, env={}, resolver=lambda h, p: ["127.0.0.1"])

    def test_valid_settings_are_saved_without_any_secret(self):
        s, errors = self.apply({"defaultChain": ["ollama", "anthropic"], "endpoints": {"ollama": {"url": "http://100.101.102.103:11434", "model": "qwen2.5:7b"}},
                                "ceiling": {"dailyChf": 5, "monthlyChf": 80}, "levelChains": {"rapide": ["ollama", "anthropic"]}})
        self.assertEqual(errors, [])
        raw = open(pr.settings_path(self.root), encoding="utf-8").read()
        self.assertIn("100.101.102.103", raw)
        self.assertNotIn("secret", raw.lower())
        self.assertNotIn("bearer", raw.lower())
        view = pr.settings_view(self.root, env={})
        self.assertEqual(view["defaultChain"], ["ollama", "anthropic"])
        self.assertEqual(view["endpoints"]["ollama"]["model"], "qwen2.5:7b")
        self.assertFalse(view["endpoints"]["ollama"]["tokenPresent"])
        self.assertEqual(view["ceiling"]["dailyChf"], 5)

    def test_unsafe_addresses_are_refused_and_nothing_is_written(self):
        for url in ("http://8.8.8.8:11434", "http://169.254.169.254/v1", "http://user:pw@127.0.0.1:11434", "ftp://127.0.0.1", "file:///etc/passwd", "https://127.0.0.1:11434"):
            s, errors = self.apply({"endpoints": {"ollama": {"url": url, "model": "m"}}})
            self.assertTrue(errors, url)
        self.assertFalse(os.path.isfile(pr.settings_path(self.root)), "rien n'est ecrit quand il y a une erreur")

    def test_https_endpoint_needs_a_server_side_token(self):
        s, errors = self.apply({"endpoints": {"swiss": {"url": "https://ai.exemple.ch/v1", "model": "apertus"}}})
        self.assertEqual(errors[0]["code"], "TOKEN_REQUIRED")
        self.assertIn("BK_SECRET_SWISS", errors[0]["message"])
        s, errors = pr.apply_settings(self.root, {"endpoints": {"swiss": {"url": "https://ai.exemple.ch/v1", "model": "apertus"}}}, levels=LEVELS,
                                      env={"BK_SECRET_SWISS": "x" * 20}, resolver=lambda h, p: ["93.184.216.34"])
        self.assertEqual(errors, [])

    def test_invalid_values_are_listed_by_field(self):
        _, errors = self.apply({"defaultChain": ["anthropic", "gpt5"], "levelChains": {"nimporte": ["ollama"]}, "ceiling": {"dailyChf": -3}, "inconnu": 1})
        fields = {e["field"] for e in errors}
        self.assertTrue({"defaultChain", "levelChains.nimporte", "ceiling.dailyChf", "inconnu"} <= fields, fields)

    def test_secrets_never_enter_the_settings_file(self):
        _, errors = self.apply({"token": "abc", "apiKey": "sk-ant-xxxxxxxxxxxxxxxxxxxxx"})
        self.assertEqual(len(errors), 2)

    def test_clearing_a_setting_restores_the_default(self):
        self.apply({"defaultChain": ["ollama"], "ceiling": {"dailyChf": 5}})
        s, errors = self.apply({"defaultChain": None, "ceiling": None})
        self.assertEqual(errors, [])
        self.assertNotIn("defaultChain", s)
        self.assertEqual(pr.default_chain(s, {}), ["anthropic"])
        self.assertFalse(pr.ceiling_status(self.root, s, NOW)["configured"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
