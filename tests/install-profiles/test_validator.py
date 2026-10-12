#!/usr/bin/env python3
"""Tests du validateur de profils d'installation : chaque regle doit REFUSER un profil fautif.

Principe : on part du vrai profil d'Alex (valide), on le modifie en memoire, et on verifie que
validate_profiles.py signale bien l'erreur attendue. Le validateur ne sert a rien s'il laisse passer
un "auto" sur un envoi, un connecteur inexistant ou un canal annonce disponible a tort.

Usage : python tests/install-profiles/test_validator.py
"""
import copy
import importlib.util
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("validate_profiles", os.path.join(HERE, "validate_profiles.py"))
vp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vp)

CATALOG = vp.load_catalog()
PROVIDERS = vp.load_guide_providers()
DISPATCH = vp.load_dispatch_ops()
with open(os.path.join(vp.ROOT, "workers", "alex", "install-profile.json"), encoding="utf-8") as _f:
    BASE = json.load(_f)


def run(mutator=None, raw_suffix=""):
    """Valide une copie modifiee du profil d'Alex ; renvoie la liste des erreurs."""
    prof = copy.deepcopy(BASE)
    if mutator:
        mutator(prof)
    vp.errors.clear()
    vp.check_profile_data("alex", prof, json.dumps(prof, ensure_ascii=False) + raw_suffix,
                          CATALOG, PROVIDERS, DISPATCH)
    return list(vp.errors)


def svc(prof, sid):
    return next(s for s in prof["services"] if s["id"] == sid)


def rule(service, category):
    return next(r for r in service["autonomyRules"] if r["category"] == category)


class ValidatorTests(unittest.TestCase):
    def assertHas(self, errors, needle):
        self.assertTrue(any(needle in e for e in errors), f"{needle!r} absent de : {errors}")

    def test_baseline_is_valid(self):
        self.assertEqual(run(), [])

    def test_all_real_profiles_pass(self):
        vp.errors.clear()
        catalog, providers, dispatch = vp.load_catalog(), vp.load_guide_providers(), vp.load_dispatch_ops()
        for wid in vp.WORKER_IDS:
            vp.validate_profile(wid, catalog, providers, dispatch)
        self.assertEqual(list(vp.errors), [])

    def test_dispatch_table_is_read(self):
        self.assertIn("READ_MESSAGES", DISPATCH["gmail"])
        self.assertIn("CREATE_TASK", DISPATCH["hubspot"])
        self.assertIn("PLACE_CALL", DISPATCH["twilio"])
        self.assertIn("POST_MESSAGE", DISPATCH["slack"])

    # ---- loi de la plateforme ----
    def test_medium_or_high_risk_never_auto(self):
        def m(p):
            rule(svc(p, "prospection-sortante"), "redaction")["risk"] = "medium"
        self.assertHas(run(m), "ne peut jamais etre en mode auto")

    def test_sensitive_wording_in_auto_rule(self):
        def m(p):
            rule(svc(p, "prospection-sortante"), "redaction")["examples"].append("Envoyer l'email au prospect")
        self.assertHas(run(m), "action sensible")

    def test_sensitive_category_never_auto(self):
        def m(p):
            r = rule(svc(p, "prospection-sortante"), "envoi-externe")
            r["defaultMode"], r["maxAutoPerDay"], r["risk"] = "auto", 5, "low"
        self.assertHas(run(m), "ne peut jamais etre en mode auto")

    def test_write_operation_never_auto(self):
        def m(p):
            r = rule(svc(p, "relances-reactivation"), "ecriture-crm")
            r["defaultMode"], r["maxAutoPerDay"] = "auto", 5
        self.assertHas(run(m), "jamais en mode auto")

    def test_write_operation_needs_a_governing_rule(self):
        def m(p):
            s = svc(p, "relances-reactivation")
            s["autonomyRules"] = [r for r in s["autonomyRules"] if r["category"] != "ecriture-crm"]
        self.assertHas(run(m), "aucune autonomyRule ne la gouverne")

    def test_crm_write_requires_ask_or_off(self):
        def m(p):
            rule(svc(p, "relances-reactivation"), "ecriture-crm")["defaultMode"] = "draft"
        self.assertHas(run(m), "ask ou off")

    def test_outbound_operation_with_misleading_name(self):
        def m(p):
            s = svc(p, "prospection-sortante")
            s["optionalConnectors"].append("slack.controlled")
            s["connectorOperations"]["slack.controlled"] = ["POST_MESSAGE"]
            s["autonomyRules"].append({"category": "ecriture-slack", "label": "Poster dans Slack",
                                       "examples": ["Poster un message"], "risk": "medium", "defaultMode": "draft",
                                       "maxAutoPerDay": None, "operations": ["slack.controlled:POST_MESSAGE"]})
        self.assertHas(run(m), "sort chez un tiers")

    def test_auto_requires_cap_and_non_auto_forbids_it(self):
        def m1(p):
            rule(svc(p, "prospection-sortante"), "redaction")["maxAutoPerDay"] = None
        self.assertHas(run(m1), "plafond maxAutoPerDay")

        def m2(p):
            rule(svc(p, "prospection-sortante"), "envoi-externe")["maxAutoPerDay"] = 3
        self.assertHas(run(m2), "null hors mode auto")

    # ---- connecteurs, competences, operations ----
    def test_unknown_connector(self):
        def m(p):
            svc(p, "prospection-sortante")["optionalConnectors"].append("inexistant.controlled")
        self.assertHas(run(m), "connecteur inconnu")

    def test_generic_connector_rejected(self):
        def m(p):
            svc(p, "prospection-sortante")["optionalConnectors"].append("crm.controlled")
        self.assertHas(run(m), "categorie generique")

    def test_not_client_connectable_rejected(self):
        def m(p):
            svc(p, "prospection-sortante")["optionalConnectors"].append("salesforce.controlled")
        self.assertHas(run(m), "pas encore connectable")

    def test_provider_key_is_accepted_and_normalised(self):
        def m(p):
            s = svc(p, "preparation-rendez-vous")
            s["optionalConnectors"] = ["calendar.controlled", "outlook_calendar.controlled"]
        self.assertEqual(run(m), [])

    def test_unknown_skill(self):
        def m(p):
            svc(p, "prospection-sortante")["skills"].append("COMPETENCE_FANTOME")
        self.assertHas(run(m), "competence inconnue")

    def test_operation_must_exist(self):
        def m(p):
            svc(p, "prospection-sortante")["connectorOperations"]["hubspot.controlled"] = ["CREATE_CONTACT"]
        self.assertHas(run(m), "inexistante")

    def test_connector_operations_must_cover_every_connector(self):
        def m(p):
            del svc(p, "prospection-sortante")["connectorOperations"]["pipedrive.controlled"]
        self.assertHas(run(m), "doit lister les operations")

    # ---- canaux ----
    def test_planned_channel_cannot_be_available(self):
        for ch in ("email", "phone", "whatsapp"):
            def m(p, ch=ch):
                p["channelSupport"][ch] = "available"
            self.assertHas(run(m), "n'existe pas encore")

    def test_web_and_schedule_must_stay_available(self):
        def m(p):
            p["channelSupport"]["web"] = "planned"
        self.assertHas(run(m), "doit etre 'available'")

    def test_channel_used_but_marked_no(self):
        def m(p):
            p["channelSupport"]["email"] = "no"
        self.assertHas(run(m), "alors que channelSupport.email = 'no'")

    def test_schedule_needs_frequency(self):
        def m(p):
            del svc(p, "prospection-sortante")["suggestedFrequencyMinutes"]
        self.assertHas(run(m), "suggestedFrequencyMinutes")

    def test_every_service_has_web_channel(self):
        def m(p):
            svc(p, "prevision-pipeline")["channels"] = ["schedule"]
        self.assertHas(run(m), "canal 'web'")

    # ---- structure ----
    def test_missing_test_scenario(self):
        def m(p):
            del svc(p, "prospection-sortante")["testScenario"]
        self.assertHas(run(m), "cle manquante : testScenario")

    def test_test_scenario_must_state_no_real_action(self):
        def m(p):
            svc(p, "prospection-sortante")["testScenario"]["objective"] = (
                "Trouve 5 entreprises, écris le premier email pour chacune puis envoie-le tout de suite à chaque prospect.")
        self.assertHas(run(m), "aucune action reelle")

    def test_needs_a_required_knowledge_field(self):
        def m(p):
            for f in svc(p, "prospection-sortante")["knowledgeFields"]:
                f["required"] = False
        self.assertHas(run(m), "required=true")

    def test_service_count_bounds(self):
        def few(p):
            p["services"] = p["services"][:3]
        self.assertHas(run(few), "4 a 8 services")

        def many(p):
            while len(p["services"]) < 9:
                extra = copy.deepcopy(p["services"][0])
                extra["id"] = f"service-supplementaire-{len(p['services'])}"
                extra["label"] = f"Service supplémentaire {len(p['services'])}"
                p["services"].append(extra)
        self.assertHas(run(many), "4 a 8 services")

    def test_duplicate_service_id(self):
        def m(p):
            p["services"][1]["id"] = p["services"][0]["id"]
        self.assertHas(run(m), "en double")

    def test_service_id_must_be_a_slug(self):
        def m(p):
            p["services"][0]["id"] = "Prospection Sortante"
        self.assertHas(run(m), "slug attendu")

    def test_missing_top_level_key_and_unknown_key(self):
        def m(p):
            del p["tagline"]
            p["surprise"] = 1
        errs = run(m)
        self.assertHas(errs, "cle manquante : tagline")
        self.assertHas(errs, "cles inconnues")

    def test_worker_id_matches_folder(self):
        def m(p):
            p["workerId"] = "amina"
        self.assertHas(run(m), "workerId doit etre")

    def test_installation_steps_bounds(self):
        def m(p):
            p["installationSteps"] = ["Étape un très courte mais valable.", "Deuxième étape suffisamment longue."]
        self.assertHas(run(m), "installationSteps")

    def test_forbidden_names(self):
        for word in ("Kader", "SWELTR", "Saveurs d'Afrik"):
            def m(p, word=word):
                p["idealFor"] = p["idealFor"] + " Client historique : " + word
            self.assertHas(run(m), "mot interdit")

    def test_placeholder_text(self):
        def m(p):
            p["tagline"] = "TODO à écrire plus tard pour ce Worker"
        self.assertHas(run(m), "texte provisoire")

    def test_bom_is_rejected(self):
        import tempfile
        with tempfile.NamedTemporaryFile("wb", suffix=".json", delete=False) as f:
            f.write(b"\xef\xbb\xbf{}")
            name = f.name
        try:
            with self.assertRaises(ValueError):
                vp.load_json(name)
        finally:
            os.remove(name)

    def test_display_name_is_accent_insensitive(self):
        # "Lea" (identity.json) et "Léa" (profil) designent le meme Worker.
        self.assertEqual(vp.fold("Léa"), vp.fold("Lea"))


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
