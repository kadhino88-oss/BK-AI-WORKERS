# -*- coding: utf-8 -*-
"""core/ai/Invoke-EngineChain.ps1 (executeur de chaine) et core/ai/AI-PROVIDER-ENGINE-LOCAL.ps1 (moteur de secours) avec un plan produit par le VRAI routeur
(dashboard/provider_router.py) : repli seulement le long de la chaine et jamais en silence, disjoncteur, plafond de depense Claude, essai verrouille sur la
chaine gratuite, cle personnelle sans repli, etiquette du moteur, reponse de secours a 0 credit.

L'API d'Anthropic est SIMULEE (tests/providers/shim_anthropic.ps1) : aucun appel reseau, aucun cout. PowerShell 7 requis (sous Windows : dans WSL).
    python3 -m unittest tests/providers/test_engine_chain.py -v
"""
import base64
import json
import os
import shutil
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "dashboard"))
import fake_openai  # noqa: E402
import harness  # noqa: E402
import provider_router as pr  # noqa: E402
from harness import CLIENT, PWSH, TASK, Run  # noqa: E402

CHAIN = "core/ai/Invoke-EngineChain.ps1"
LOCAL = "core/ai/AI-PROVIDER-ENGINE-LOCAL.ps1"
KEY = "sk-ant-PLATFORM-KEY-FOR-TESTS-ONLY-0001"
with open(os.path.join(harness.REPO, "core", "ai", "LEVELS.json"), encoding="utf-8-sig") as f:
    LEVELS = json.load(f)["levels"]
PRE = '. (Join-Path $env:BK_ROOT "_test/shim_anthropic.ps1")'
STORE_BYOK = r'''
param($ClientId, $ProjectId, $WorkerId, $TaskId, $Objective, $Model)
. (Join-Path $env:BK_ROOT "core/connectors/Client-Credential-Store.ps1")
Set-BKClientCredentialValue -ClientId $ClientId -Provider "ai_engine" -PlainText $env:T_BYOK_JSON
Write-Output '{"stored":true}'
exit 0
'''


def install_shim(root):
    shutil.copy2(os.path.join(HERE, "shim_anthropic.ps1"), os.path.join(root, "_test", "shim_anthropic.ps1"))
    shutil.copy2(os.path.join(HERE, "shim_redirect.ps1"), os.path.join(root, "_test", "shim_redirect.ps1"))
    with open(os.path.join(root, "_test", "store_byok.ps1"), "w", encoding="utf-8") as f:
        f.write(STORE_BYOK)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class ChainBase(unittest.TestCase):
    def setUp(self):
        self.servers = []
        self.root = None

    def tearDown(self):
        for s in self.servers:
            s.stop()
        if self.root:
            shutil.rmtree(self.root, ignore_errors=True)

    def new_root(self, **kw):
        self.root = harness.make_root(extra=install_shim, **kw)
        return self.root

    def ollama(self, script=None, **kw):
        srv = fake_openai.FakeOpenAI(script=script or [{"content": "Reponse du modele local."}], **kw)
        self.servers.append(srv)
        pr.apply_settings(self.root, {"endpoints": {"ollama": {"url": srv.url, "model": "llama3:latest"}}}, levels=LEVELS, env={}, resolver=lambda h, p: [h])
        return srv

    def configure(self, **settings):
        _, errors = pr.apply_settings(self.root, settings, levels=LEVELS, env={}, resolver=lambda h, p: [h])
        self.assertEqual(errors, [], errors)

    def plan(self, level="equilibre", client=CLIENT, objective="Bonjour", **kw):
        plan = pr.resolve_plan(self.root, client, level, objective, levels=LEVELS, env={}, **kw)
        self.assertTrue(plan["explicit"], plan)
        return plan

    def run_chain(self, plan, steps=None, script=CHAIN, env=None, level="", task=TASK, splat=None, key=KEY, platform_key=KEY):
        full = dict(pr.plan_env(plan))
        full.update({"T_PRE": PRE, "FAKE_ANTHROPIC": json.dumps(steps or [{"text": "Reponse de Claude."}]), "FAKE_ANTHROPIC_KEY": key,
                     "FAKE_ANTHROPIC_LOG": os.path.join(self.root, "_test", "anthropic.jsonl"), "BK_MISSION_LEVEL": level})
        if platform_key:
            full["BK_SECRET_ANTHROPIC"] = platform_key
        full.update(env or {})
        r = Run(script, root=self.root, env=full, task=task, splat=splat, model="NONE")
        return r

    def anthropic_calls(self):
        p = os.path.join(self.root, "_test", "anthropic.jsonl")
        if not os.path.isfile(p):
            return []
        with open(p, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    def health(self):
        p = os.path.join(self.root, "runtime", "engine", "health.json")
        return json.load(open(p, encoding="utf-8-sig")) if os.path.isfile(p) else {}

    def spend(self):
        p = os.path.join(self.root, "runtime", "engine", "spend.json")
        return json.load(open(p, encoding="utf-8-sig")) if os.path.isfile(p) else {}


class Failover(ChainBase):
    def test_claude_answers_first_and_its_cost_enters_the_ledger(self):
        self.new_root()
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"], ceiling={"dailyChf": 5})
        r = self.run_chain(self.plan("rapide"), [{"text": "Bonjour de Claude.", "usage": [20000, 2000]}], level="rapide")
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        e = r.result["engine"]
        self.assertEqual((e["provider"], e["failedOver"], e["local"], e["label"]), ("anthropic", False, False, "Claude"))
        self.assertEqual(r.result["answer"], "Bonjour de Claude.", "aucune note quand le moteur prevu a repondu")
        day = next(iter(self.spend()["days"].values()))
        self.assertGreater(day["chf"], 0, "le cout reel de la mission Claude est ajoute au registre de depense")
        self.assertEqual(day["missions"], 1)
        self.assertEqual(self.health(), {})

    def test_credit_exhausted_falls_over_to_the_local_engine_openly_and_trips_the_breaker(self):
        self.new_root()
        srv = self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"])
        plan = self.plan()
        r = self.run_chain(plan, [{"credit_error": True}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        res = r.result
        e = res["engine"]
        self.assertEqual((e["provider"], e["failedOver"], e["local"], e["creditsFree"]), ("ollama", True, True, True))
        self.assertEqual(e["label"], "Moteur local (Llama 3)")
        self.assertEqual(res["provider"], "ollama", "jamais etiquete Claude")
        self.assertTrue(res["answer"].startswith("Note : cette réponse vient du moteur « Moteur local (Llama 3) » et non de Claude"), res["answer"])
        self.assertIn("le crédit de ce fournisseur est épuisé", res["answer"])
        self.assertIn("Cette mission ne consomme aucun crédit", res["answer"])
        self.assertTrue(res["answer"].endswith("Reponse du modele local."))
        self.assertEqual([a["outcome"] for a in e["attempts"]], ["failed", "answered"])
        self.assertEqual(e["attempts"][0]["reason"], "billing")
        self.assertIn("anthropic", self.health(), "un credit epuise met Claude de cote quelques minutes")
        self.assertEqual(self.health()["anthropic"]["reason"], "billing")
        self.assertEqual(len(self.anthropic_calls()), 1)
        self.assertEqual(len(srv.chat_requests()), 1)

    def test_next_mission_does_not_wait_for_the_benched_engine(self):
        self.new_root()
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"])
        self.run_chain(self.plan(), [{"credit_error": True}])
        calls_before = len(self.anthropic_calls())
        # meme si le plan a ete calcule AVANT l'ouverture du disjoncteur (autre mission en parallele), l'executeur relit la sante
        pr.clear_health(self.root)
        plan_before = self.plan()
        pr.mark_unhealthy(self.root, "anthropic", "billing")
        r = self.run_chain(plan_before, [{"text": "ne doit pas etre appele"}], task="TASK-" + "B" * 32)
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertEqual(len(self.anthropic_calls()), calls_before, "Claude n'est pas rappele tant que le disjoncteur est ouvert")
        self.assertEqual(r.result["engine"]["attempts"][0], {"provider": "anthropic", "outcome": "skipped", "reason": "circuit-open"})
        self.assertIn("indisponible depuis quelques minutes", r.result["answer"])

    def test_one_off_errors_do_not_bench_the_engine_but_still_fall_over_for_this_mission(self):
        self.new_root()
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"])
        r = self.run_chain(self.plan(), [{"timeout": True}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertEqual(r.result["engine"]["provider"], "ollama")
        self.assertEqual(r.result["engine"]["attempts"][0]["reason"], "timeout")
        self.assertIn("il a mis trop de temps à répondre", r.result["answer"])
        self.assertEqual(self.health(), {}, "un delai ponctuel ne met pas Claude de cote")

    def test_authentication_error_benches_the_engine(self):
        self.new_root()
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"])
        r = self.run_chain(self.plan(), [{"auth_error": True}])
        self.assertEqual(r.result["engine"]["provider"], "ollama")
        self.assertEqual(self.health()["anthropic"]["reason"], "auth")

    def test_no_engine_answers_means_an_honest_error_and_never_a_silent_other_engine(self):
        self.new_root()
        dead = self.ollama()
        dead.stop()
        self.servers.remove(dead)
        self.configure(defaultChain=["anthropic", "ollama"])
        r = self.run_chain(self.plan(), [{"credit_error": True}])
        self.assertEqual(r.exit, 1)
        self.assertEqual(r.result["status"], "ERROR")
        self.assertTrue(r.result["error"].startswith("NO_ENGINE_AVAILABLE"))
        self.assertIn("Aucun moteur d'IA n'a pu répondre", r.result["user_message"])
        self.assertIn("ne consomme aucun crédit", r.result["user_message"])
        self.assertEqual([a["provider"] for a in r.result["engine"]["attempts"]], ["anthropic", "ollama"])
        self.assertEqual(set(self.health()), {"anthropic", "ollama"})


class FreeChainForTheTrial(ChainBase):
    def test_trial_runs_on_the_local_engine_and_claude_is_never_called(self):
        self.new_root()
        srv = self.ollama([{"content": "Voici un apercu."}])
        r = self.run_chain(self.plan("rapide", trial=True), [{"text": "ne doit jamais etre appele"}], level="rapide")
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        e = r.result["engine"]
        self.assertEqual((e["provider"], e["failedOver"], e["local"], e["free"], e["creditsFree"]), ("ollama", False, True, True, False))
        self.assertEqual(r.result["answer"], "Voici un apercu.", "une mission voulue sur le moteur local n'a pas de note de repli")
        self.assertEqual(self.anthropic_calls(), [])
        self.assertEqual(len(srv.chat_requests()), 1)

    def test_trial_with_the_local_engine_down_is_unavailable_not_silently_paid(self):
        self.new_root()
        dead = self.ollama()
        dead.stop()
        self.servers.remove(dead)
        r = self.run_chain(self.plan("rapide", trial=True), [{"text": "ne doit jamais etre appele"}])
        self.assertEqual(r.exit, 1)
        self.assertEqual(self.anthropic_calls(), [], "l'essai ne se rabat jamais sur Claude")
        self.assertEqual(list(self.health()), ["ollama"])
        self.assertEqual(self.health()["ollama"]["reason"], "connection")


class SpendingCeilingInTheExecutor(ChainBase):
    def write_spend(self, chf):
        from datetime import datetime, timezone
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        os.makedirs(os.path.join(self.root, "runtime", "engine"), exist_ok=True)
        with open(os.path.join(self.root, "runtime", "engine", "spend.json"), "w", encoding="utf-8") as f:
            json.dump({"days": {day: {"chf": chf, "usd": chf, "missions": 3}}, "months": {day[:7]: {"chf": chf, "usd": chf, "missions": 3}}}, f)

    def test_reached_ceiling_switches_to_the_free_chain_with_an_honest_note(self):
        self.new_root()
        self.ollama()
        self.configure(ceiling={"dailyChf": 1.0})
        self.write_spend(1.2)
        plan = self.plan()
        self.assertEqual([e["id"] for e in plan["chain"]], ["ollama"])
        r = self.run_chain(plan, [{"text": "ne doit jamais etre appele"}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertEqual(r.result["engine"]["provider"], "ollama")
        self.assertTrue(r.result["engine"]["failedOver"])
        self.assertIn("le plafond de dépense Claude fixé par le propriétaire est atteint", r.result["answer"])
        self.assertEqual(self.anthropic_calls(), [])

    def test_the_note_names_the_ceiling_even_when_the_free_engine_was_already_in_the_chain(self):
        self.new_root()
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"], ceiling={"dailyChf": 1.0})
        self.write_spend(1.2)
        plan = self.plan()
        self.assertEqual([e["id"] for e in plan["chain"]], ["ollama"])
        r = self.run_chain(plan, [{"text": "ne doit jamais etre appele"}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertIn("le plafond de dépense Claude fixé par le propriétaire est atteint", r.result["answer"])
        self.assertIn({"provider": "anthropic", "outcome": "skipped", "reason": "spending-ceiling"}, r.result["engine"]["attempts"])

    def test_a_benched_engine_at_plan_time_is_named_in_the_note(self):
        self.new_root()
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"])
        pr.mark_unhealthy(self.root, "anthropic", "billing")
        r = self.run_chain(self.plan(), [{"text": "ne doit jamais etre appele"}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertIn("il est indisponible depuis quelques minutes", r.result["answer"])
        self.assertEqual(self.anthropic_calls(), [])

    def test_ceiling_reached_between_planning_and_calling_is_still_respected(self):
        """Deux missions en parallele : le plan de la seconde a ete fait avant que la premiere ne depasse le plafond."""
        self.new_root()
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"], ceiling={"dailyChf": 1.0})
        plan = self.plan()
        self.assertIn("anthropic", [e["id"] for e in plan["chain"]])
        self.write_spend(1.5)
        r = self.run_chain(plan, [{"text": "ne doit jamais etre appele"}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertEqual(r.result["engine"]["provider"], "ollama")
        self.assertEqual(r.result["engine"]["attempts"][0], {"provider": "anthropic", "outcome": "skipped", "reason": "spending-ceiling"})
        self.assertEqual(self.anthropic_calls(), [])

    def test_paid_claude_calls_before_a_failure_still_enter_the_ledger(self):
        """Claude facture un premier tour (appel d'outil) puis echoue (delai, puis credit epuise en cours de mission) : la mission passe au moteur local et ne
        coute rien au client, mais la plateforme a paye Anthropic : le registre du plafond le compte."""
        self.new_root(activated=("gmail",))
        self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"], ceiling={"dailyChf": 5})
        read = {"tool_use": {"connectorId": "gmail", "operation": "READ_MESSAGES", "reason": "lire"}, "usage": [30000, 3000]}
        r = self.run_chain(self.plan(), [read, {"timeout": True}], level="equilibre")
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertEqual(len(self.anthropic_calls()), 2)
        self.assertEqual([(a["provider"], a["outcome"], a["reason"]) for a in r.result["engine"]["attempts"]],
                         [("anthropic", "failed", "timeout"), ("ollama", "answered", "")])
        self.assertTrue(r.result["engine"]["creditsFree"])
        day = next(iter(self.spend()["days"].values()))
        self.assertGreater(day["chf"], 0.05, "le premier appel facture (30 000 + 3 000 jetons Sonnet) est compte")
        self.assertEqual(day["missions"], 1)
        first = day["chf"]
        r2 = self.run_chain(self.plan(), [read, {"credit_error": True}], level="equilibre", task="TASK-" + "C" * 32)
        self.assertEqual(r2.exit, 0, r2.proc.stderr + r2.stdout)
        self.assertEqual(r2.result["engine"]["attempts"][0]["reason"], "billing")
        day = next(iter(self.spend()["days"].values()))
        self.assertGreater(day["chf"], first + 0.05, "credit epuise en cours de mission : l'appel deja facture est compte aussi")
        self.assertEqual(day["missions"], 2)

    def test_remaining_budget_caps_the_claude_loop_itself(self):
        self.new_root(activated=("gmail",))
        self.configure(ceiling={"dailyChf": 1.0})
        self.write_spend(0.9995)           # il reste 0,0005 CHF : le premier appel est permis, le suivant ne l'est pas
        plan = self.plan("rapide")
        self.assertAlmostEqual(plan["budgetChf"], 0.0005, places=4)
        steps = [{"tool_use": {"connectorId": "gmail", "operation": "READ_MESSAGES", "reason": "lire"}, "usage": [200000, 5000]}, {"text": "ne doit pas etre appele"}]
        r = self.run_chain(plan, steps, level="rapide")
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertTrue(r.result["cost_capped"], "la boucle s'arrete avant l'appel qui depasserait le reste du plafond")
        self.assertEqual(len(self.anthropic_calls()), 1)
        self.assertIn("plafond de coût", r.result["answer"])
        self.assertEqual(r.result["engine"]["provider"], "anthropic")


class ClientKey(ChainBase):
    def store_key(self, kind="anthropic", key="sk-ant-CLIENT-OWN-KEY-0123456789abcdef", **extra):
        self.client_key = key
        enc = base64.b64encode(os.urandom(32)).decode()
        self.enc_env = {"BK_SECRET_CRED_ENCRYPTION_KEY": enc}
        body = {"kind": kind, "key": key, "endpoint": "https://api.anthropic.com" if kind == "anthropic" else "https://api.mistral.ai/v1", "model": ""}
        body.update(extra)
        r = Run("_test/store_byok.ps1", root=self.root, env=dict(self.enc_env, T_BYOK_JSON=json.dumps(body)))
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)

    def byok_plan(self, kind="anthropic"):
        meta = {"kind": kind, "host": "api.anthropic.com", "endpoint": "https://api.anthropic.com", "model": "", "enabled": True}
        return pr.resolve_plan(self.root, CLIENT, "equilibre", "Bonjour", byok=meta, levels=LEVELS, env={})

    def test_client_key_is_used_for_that_clients_mission_and_the_platform_key_is_not(self):
        self.new_root()
        self.store_key()
        r = self.run_chain(self.byok_plan(), [{"text": "Reponse avec votre cle.", "usage": [5000, 500]}], key=self.client_key, platform_key="sk-ant-PLATFORM-NOT-THE-CLIENTS-00000",
                           env=self.enc_env, level="rapide")
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertTrue(all(c["keyOk"] for c in self.anthropic_calls()), "la requete part avec la cle du client")
        e = r.result["engine"]
        self.assertEqual((e["provider"], e["byok"], e["failedOver"], e["creditsFree"]), ("byok", True, False, False))
        self.assertEqual(e["label"], "Votre clé (Claude)")
        self.assertEqual(r.result["provider"], "byok")
        self.assertEqual(self.spend(), {}, "la depense de la cle d'un client n'entre jamais dans le plafond de la plateforme")
        self.assertNotIn(self.client_key, r.stdout + r.proc.stdout + r.proc.stderr, "la cle ne ressort jamais")

    def test_a_failing_client_key_never_falls_back_on_our_engines_or_our_key(self):
        self.new_root()
        srv = self.ollama()
        self.configure(defaultChain=["anthropic", "ollama"])
        self.store_key()
        r = self.run_chain(self.byok_plan(), [{"credit_error": True}], key=self.client_key, platform_key="sk-ant-PLATFORM-NOT-THE-CLIENTS-00000", env=self.enc_env)
        self.assertEqual(r.exit, 1)
        self.assertTrue(r.result["error"].startswith("NO_ENGINE_AVAILABLE"))
        self.assertEqual(len(srv.chat_requests()), 0, "pas de repli vers le moteur de la plateforme : ce serait une depense cachee")
        self.assertEqual(len(self.anthropic_calls()), 1)
        self.assertEqual(self.health(), {}, "la cle d'un client ne met pas un moteur de la plateforme de cote")

    def test_openai_compatible_client_key_reaches_its_provider_with_the_key_in_the_header_only(self):
        """Hote public de la liste blanche (adresse fictive 93.184.216.34), https obligatoire, cle du client en en-tete ; la requete est redirigee vers un faux serveur local."""
        self.new_root()
        key = "mk-CLIENT-MISTRAL-KEY-0123456789abcdef"
        srv = fake_openai.FakeOpenAI(script=[{"content": "Reponse du fournisseur du client."}], token=key)
        self.servers.append(srv)
        self.configure(byokAllowedHosts=["93.184.216.34"])
        self.store_key(kind="openai_compat", key=key, endpoint="https://93.184.216.34/v1", model="mistral-large-latest")
        meta = {"kind": "openai_compat", "host": "93.184.216.34", "endpoint": "https://93.184.216.34/v1", "model": "mistral-large-latest", "enabled": True}
        plan = pr.resolve_plan(self.root, CLIENT, "equilibre", "Bonjour", byok=meta, levels=LEVELS, env={})
        self.assertIn("93.184.216.34", plan["chain"][0]["allowedHosts"])
        full = dict(self.enc_env, T_PRE='. (Join-Path $env:BK_ROOT "_test/shim_redirect.ps1")', FAKE_REDIRECT_FROM="https://93.184.216.34", FAKE_REDIRECT_BASE=srv.url,
                    BK_ENGINE_SKIP_PROBE="1")
        r = self.run_chain(plan, env=full)
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        e = r.result["engine"]
        self.assertEqual((e["provider"], e["byok"], e["failedOver"], e["local"]), ("byok", True, False, False))
        self.assertEqual(e["label"], "Votre clé (Mistral)")
        self.assertEqual(r.result["model"], "mistral-large-latest")
        self.assertEqual(r.result["answer"], "Reponse du fournisseur du client.")
        self.assertTrue(all(q["_auth"] for q in srv.chat_requests()), "la cle du client part en en-tete Authorization")
        for q in srv.chat_requests():
            self.assertNotIn(key, json.dumps({k: v for k, v in q.items() if not k.startswith("_")}), "la cle n'est dans aucun prompt")
        self.assertNotIn(key, r.stdout + r.proc.stdout + r.proc.stderr)
        self.assertEqual(self.spend(), {})

    def test_a_stored_client_endpoint_outside_the_allow_list_is_never_called(self):
        self.new_root()
        srv = fake_openai.FakeOpenAI(script=[{"content": "ne doit pas etre appele"}])
        self.servers.append(srv)
        self.store_key(kind="openai_compat", key="mk-CLIENT-KEY-0123456789abcdef", endpoint="https://93.184.216.34/v1", model="m")   # hote absent de la liste blanche
        meta = {"kind": "openai_compat", "host": "93.184.216.34", "endpoint": "https://93.184.216.34/v1", "model": "m", "enabled": True}
        plan = pr.resolve_plan(self.root, CLIENT, "equilibre", "Bonjour", byok=meta, levels=LEVELS, env={})
        full = dict(self.enc_env, T_PRE='. (Join-Path $env:BK_ROOT "_test/shim_redirect.ps1")', FAKE_REDIRECT_FROM="https://93.184.216.34", FAKE_REDIRECT_BASE=srv.url,
                    BK_ENGINE_SKIP_PROBE="1")
        r = self.run_chain(plan, env=full)
        self.assertEqual(r.exit, 1)
        self.assertEqual(srv.chat_requests(), [])
        self.assertTrue(r.result["error"].startswith("NO_ENGINE_AVAILABLE"))

    def test_without_a_stored_key_the_mission_is_refused_not_run_on_the_platform_key(self):
        self.new_root()
        self.configure(defaultChain=["anthropic"])
        enc = {"BK_SECRET_CRED_ENCRYPTION_KEY": base64.b64encode(os.urandom(32)).decode()}
        r = self.run_chain(self.byok_plan(), [{"text": "ne doit pas etre appele"}], env=enc)
        self.assertEqual(r.exit, 1)
        self.assertEqual(self.anthropic_calls(), [])


class Labels(ChainBase):
    def test_request_needing_office_files_gets_an_honest_note_on_the_local_engine(self):
        self.new_root()
        self.ollama([{"content": "Voici un tableau en texte."}])
        r = self.run_chain(self.plan("rapide", trial=True, objective="Fais-moi un fichier Excel du budget"))
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        self.assertIn("Remarque sur le moteur utilisé (Moteur local (Llama 3))", r.result["answer"])
        self.assertIn("Cette partie n'a PAS été réalisée", r.result["answer"])

    def test_no_note_when_the_engine_can_do_it(self):
        self.new_root()
        self.configure(defaultChain=["anthropic"], ceiling={"dailyChf": 50})
        r = self.run_chain(self.plan(objective="Fais-moi un fichier Excel du budget"), [{"text": "Fichier prepare."}])
        self.assertEqual(r.result["answer"], "Fichier prepare.")


class ProviderEngineFile(ChainBase):
    """AI-PROVIDER-ENGINE-LOCAL.ps1 : le fichier de resultat de la mission (memory/runtime/PROVIDER-<TaskId>.json) que lit Invoke-Worker-AI.ps1."""

    def provider_file(self, task=TASK):
        return json.load(open(os.path.join(self.root, "memory", "runtime", f"PROVIDER-{task}.json"), encoding="utf-8-sig"))

    def run_local(self, plan=None, steps=None, level="", env=None):
        e = dict(env or {})
        if plan is not None:
            return self.run_chain(plan, steps, script=LOCAL, splat={"Provider": "ANTHROPIC"}, env=e, level=level)
        full = {"T_PRE": PRE, "FAKE_ANTHROPIC": json.dumps(steps or [{"text": "Reponse de Claude."}]), "FAKE_ANTHROPIC_KEY": KEY, "BK_SECRET_ANTHROPIC": KEY,
                "FAKE_ANTHROPIC_LOG": os.path.join(self.root, "_test", "anthropic.jsonl"), "BK_MISSION_LEVEL": level}
        full.update(e)
        return Run(LOCAL, root=self.root, env=full, splat={"Provider": "ANTHROPIC"}, model="NONE")

    def test_a_local_answer_is_reported_with_the_engine_that_wrote_it(self):
        self.new_root()
        self.ollama([{"content": "Reponse locale."}])
        r = self.run_local(self.plan("rapide", trial=True), level="rapide")
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        res = self.provider_file()
        self.assertEqual((res["status"], res["mode"], res["provider"], res["model"]), ("SUCCESS", "LLM", "OLLAMA", "llama3:latest"))
        self.assertFalse(res["fallback"])
        self.assertEqual(res["answer"], "Reponse locale.")
        self.assertEqual((res["engine"]["provider"], res["engine"]["local"], res["engine"]["failedOver"]), ("ollama", True, False))
        self.assertNotIn("ANTHROPIC", json.dumps(res).upper().replace("ANTHROPIC-ADAPTER", ""), "rien dans le resultat ne designe Claude")

    def test_failover_is_visible_in_the_result_and_credit_free(self):
        self.new_root()
        self.ollama([{"content": "Reponse locale."}])
        self.configure(defaultChain=["anthropic", "ollama"])
        r = self.run_local(self.plan(), [{"credit_error": True}])
        res = self.provider_file()
        self.assertEqual(res["provider"], "OLLAMA")
        self.assertTrue(res["engine"]["failedOver"])
        self.assertTrue(res["engine"]["creditsFree"])
        self.assertFalse(res["fallback"], "une reponse du moteur de remplacement est une vraie reponse, pas la reponse de secours")

    def test_when_nobody_answers_the_canned_answer_is_unlabelled_and_flagged_degraded(self):
        self.new_root()
        self.configure(defaultChain=["anthropic"], ceiling={"dailyChf": 50})
        r = self.run_local(self.plan(), [{"credit_error": True}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        res = self.provider_file()
        self.assertEqual((res["status"], res["mode"], res["fallback"]), ("FALLBACK", "LOCAL", True))
        self.assertEqual((res["provider"], res["model"]), ("NONE", "NONE"), "la reponse de secours n'est jamais etiquetee Claude")
        self.assertTrue(res["fallback_reason"].startswith("NO_ENGINE_AVAILABLE"))
        self.assertIn("Aucun moteur d'IA n'a pu répondre", res["answer"])
        self.assertEqual(res["engine"]["provider"], "none")

    def test_without_a_plan_the_claude_path_is_exactly_what_it_was(self):
        self.new_root()
        r = self.run_local(None, [{"text": "Reponse de Claude.", "usage": [1000, 100]}])
        self.assertEqual(r.exit, 0, r.proc.stderr + r.stdout)
        res = self.provider_file()
        self.assertEqual((res["status"], res["mode"], res["provider"], res["answer"]), ("SUCCESS", "LLM", "ANTHROPIC", "Reponse de Claude."))
        self.assertNotIn("engine", res, "sans plan de moteurs, le fichier de resultat n'a aucun champ de plus")
        self.assertFalse(os.path.isdir(os.path.join(self.root, "runtime", "engine")) and os.listdir(os.path.join(self.root, "runtime", "engine")), "aucun fichier d'etat de moteur ecrit")

    def test_without_a_plan_a_credit_error_gives_the_same_canned_answer_as_before(self):
        self.new_root()
        r = self.run_local(None, [{"credit_error": True}])
        res = self.provider_file()
        self.assertEqual((res["status"], res["provider"], res["fallback"]), ("FALLBACK", "ANTHROPIC", True))
        self.assertEqual(res["answer"], "Le fournisseur IA externe n'est pas disponible. Le traitement local reste disponible.")
        self.assertNotIn("engine", res)


if __name__ == "__main__":
    unittest.main(verbosity=2)
