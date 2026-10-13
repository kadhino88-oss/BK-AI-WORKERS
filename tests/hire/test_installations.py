"""InstallationStore (dashboard/installations.py) : validation, secrets, regles d'autonomie, canaux, readiness, isolation entre clients,
identifiants piegés (traversee de chemin), suppression. Utilise les VRAIS profils d'installation de workers/<id>/install-profile.json.

python tests/hire/test_installations.py   (Windows ou Linux, aucune dependance)
"""
import json
import os
import shutil
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import installations as inst  # noqa: E402

A, B = "CLI-CUST-AAAAAAAA", "CLI-CUST-BBBBBBBB"
OWNER = "CLI-DASHBOARD"


def good_alex(**over):
    cfg = {"enabled": True, "level": "equilibre",
           "knowledge": {"site_web": "https://www.atelier-martin.example", "offre_description": "Maintenance d'ascenseurs pour copropriétés.",
                         "zone_geographique": "Suisse romande"},
           "autonomy": {"lecture-recherche": "auto", "redaction": "auto", "brouillon-email": "draft", "envoi-externe": "off"},
           "channels": ["web", "schedule"]}
    cfg.update(over)
    return {"services": {"prospection-sortante": cfg}, "notes": "Répondre en vouvoyant."}


class StoreCase(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="bkinst-")
        self.addCleanup(shutil.rmtree, self.root, True)
        for w in ("alex", "nora"):
            os.makedirs(os.path.join(self.root, "workers", w))
            shutil.copy2(os.path.join(REPO, "workers", w, "install-profile.json"), os.path.join(self.root, "workers", w, "install-profile.json"))
        self.store = inst.InstallationStore(self.root)

    def errors(self, payload, worker="alex", client=A):
        with self.assertRaises(inst.InstallationError) as cm:
            self.store.upsert(client, worker, payload)
        return cm.exception.errors


class Upsert(StoreCase):
    def test_a_valid_configuration_is_saved_as_a_draft_with_labels_from_the_profile(self):
        rec = self.store.upsert(A, "alex", good_alex())
        self.assertEqual((rec["workerId"], rec["clientId"], rec["status"]), ("alex", A, "draft"))
        svc = rec["services"]["prospection-sortante"]
        self.assertTrue(svc["enabled"])
        self.assertIn("Prospection", svc["label"])
        self.assertEqual(svc["level"], "equilibre")
        self.assertEqual(svc["autonomy"]["brouillon-email"], "draft")
        path = os.path.join(self.root, "runtime", "installations", A, "ALEX.json")
        self.assertTrue(os.path.isfile(path))
        with open(path, encoding="utf-8") as f:
            self.assertEqual(json.load(f)["services"]["prospection-sortante"]["knowledge"]["zone_geographique"], "Suisse romande")
        self.assertEqual([f for f in os.listdir(os.path.dirname(path)) if f.startswith(".tmp-")], [])      # ecriture atomique : aucun reste

    def test_upsert_never_activates(self):
        self.assertEqual(self.store.upsert(A, "alex", good_alex())["status"], "draft")
        self.store.set_status(A, "alex", "active")
        self.assertEqual(self.store.upsert(A, "alex", good_alex())["status"], "active")        # une modification complete garde l'activation

    def test_editing_an_active_installation_into_an_incomplete_one_drops_it_back_to_draft(self):
        self.store.upsert(A, "alex", good_alex())
        self.store.set_status(A, "alex", "active")
        broken = good_alex()
        broken["services"]["prospection-sortante"]["knowledge"]["site_web"] = ""
        self.assertEqual(self.store.upsert(A, "alex", broken)["status"], "draft")

    def test_paused_stays_paused_after_an_edit(self):
        self.store.upsert(A, "alex", good_alex())
        self.store.set_status(A, "alex", "active")
        self.store.set_status(A, "alex", "paused")
        self.assertEqual(self.store.upsert(A, "alex", good_alex())["status"], "paused")

    def test_unknown_service_field_category_and_mode_are_refused_in_french(self):
        e = self.errors({"services": {"service-inconnu": {"enabled": True}}})
        self.assertTrue(any("service inconnu" in m for m in e), e)
        bad = good_alex()
        bad["services"]["prospection-sortante"]["knowledge"]["champ_inexistant"] = "x"
        self.assertTrue(any("champ non prevu" in m for m in self.errors(bad)))
        bad = good_alex()
        bad["services"]["prospection-sortante"]["autonomy"]["categorie-inconnue"] = "ask"
        self.assertTrue(any("categorie non prevue" in m for m in self.errors(bad)))
        bad = good_alex()
        bad["services"]["prospection-sortante"]["autonomy"]["redaction"] = "tout-faire"
        self.assertTrue(any("mode invalide" in m for m in self.errors(bad)))

    def test_auto_is_refused_on_every_high_risk_category_and_accepted_on_low_risk(self):
        profile = inst.load_profile(self.root, "alex")
        checked = 0
        for svc in profile["services"]:
            for rule in svc["autonomyRules"]:
                bad = {"services": {svc["id"]: {"enabled": True, "autonomy": {rule["category"]: "auto"}}}}
                if rule["risk"] == "low" and rule["defaultMode"] != "off" and rule["category"] in ("lecture-recherche", "redaction"):
                    self.store.upsert(A, "alex", bad)           # lecture / redaction : "auto" autorise
                elif rule["risk"] != "low":
                    checked += 1
                    e = self.errors(bad)
                    self.assertTrue(any("validation du client obligatoire" in m for m in e), (rule["category"], e))
                    ok = {"services": {svc["id"]: {"enabled": True, "autonomy": {rule["category"]: "draft"}}}}
                    self.store.upsert(A, "alex", ok)             # le meme risque reste configurable en brouillon / demande / off
        self.assertGreater(checked, 3)

    def test_secrets_are_refused_in_every_knowledge_field_and_in_the_notes(self):
        samples = ["mot de passe : Tr0ub4dor&3xyz", "password=hunter22xx", "ma clé api: abcdef123456", "token: ghp_abcdefghijklmnopqrstuvwxyz0123",
                   "sk-ant-api03-abcdefghijklmnopqrstuvwx", "carte 4111 1111 1111 1111", "IBAN : CH93 0076 2011 6238 5295 7",
                   "CH9300762011623852957", "-----BEGIN RSA PRIVATE KEY-----", "xoxb-1234567890-abcdefghij", "AIzaSyA1234567890abcdefghijklmnop"]
        for s in samples:
            bad = good_alex()
            bad["services"]["prospection-sortante"]["knowledge"]["offre_description"] = "Texte normal. " + s
            e = self.errors(bad)
            self.assertTrue(any("ne saisissez jamais" in m for m in e), (s, e))
            self.assertFalse(os.path.exists(os.path.join(self.root, "runtime", "installations", A, "ALEX.json")), s)
            e = self.errors({"services": {}, "notes": s})
            self.assertTrue(any("notes" in m for m in e), (s, e))
        ok = good_alex()
        ok["services"]["prospection-sortante"]["knowledge"]["offre_description"] = "Atelier Martin SA, 021 000 00 00, ouvert 8h-17h, TVA CHE-123.456.789"
        self.store.upsert(A, "alex", ok)             # un texte d'entreprise normal passe

    def test_length_limits(self):
        bad = good_alex()
        bad["services"]["prospection-sortante"]["knowledge"]["offre_description"] = "x" * (inst.MAX_VALUE_CHARS + 1)
        self.assertTrue(any("caracteres maximum" in m for m in self.errors(bad)))
        self.assertTrue(any("notes" in m for m in self.errors({"services": {}, "notes": "y" * (inst.MAX_NOTES_CHARS + 1)})))

    def test_not_a_dict_and_garbage_shapes_do_not_crash(self):
        for payload in ([], "texte", None, 12):
            self.errors(payload)
        rec = self.store.upsert(A, "alex", {"services": {"prospection-sortante": {"enabled": True, "knowledge": None, "autonomy": None, "channels": "email"}}})
        self.assertEqual(rec["services"]["prospection-sortante"]["channels"], [])

    def test_planned_channels_are_never_stored_as_active(self):
        rec, warnings = self.store.upsert_with_warnings(A, "alex", good_alex(channels=["web", "schedule", "phone", "whatsapp", "email", "inconnu"]))
        self.assertEqual(rec["services"]["prospection-sortante"]["channels"], ["web", "schedule"])        # ce service n'offre ni phone ni whatsapp
        self.assertEqual(len(warnings), 1)
        self.assertIn("e-mail", warnings[0])
        lead = {"services": {"qualification-lead-entrant": {"enabled": True, "channels": ["web", "phone", "whatsapp", "email"]}}}
        rec, warnings = self.store.upsert_with_warnings(A, "alex", lead)
        self.assertEqual(rec["services"]["qualification-lead-entrant"]["channels"], ["web"])
        text = " ".join(warnings)
        self.assertIn("téléphone", text)
        self.assertIn("WhatsApp", text)
        self.assertIn("pas encore disponible", text)
        self.assertEqual(inst.live_channels(inst.load_profile(self.root, "alex")), ("web", "schedule"))
        self.assertEqual(inst.live_channels(None), ("web", "schedule"))

    def test_a_worker_without_a_profile_is_generic_and_free_form_auto_is_still_refused(self):
        self.errors({"services": {"x": {"autonomy": {"envoi": "auto"}}}}, worker="dario")
        rec = self.store.upsert(A, "dario", {"services": {"general": {"enabled": True, "knowledge": {"note": "ok"}, "autonomy": {"envoi": "draft"}}}})
        self.assertEqual(rec["workerId"], "dario")


class Readiness(StoreCase):
    def test_nothing_enabled_or_required_field_missing_blocks_activation(self):
        self.store.upsert(A, "alex", {"services": {}})
        with self.assertRaises(inst.InstallationError) as cm:
            self.store.set_status(A, "alex", "active")
        self.assertIn("Choisissez au moins un service.", cm.exception.errors)
        bad = good_alex()
        bad["services"]["prospection-sortante"]["knowledge"].pop("zone_geographique")
        rec = self.store.upsert(A, "alex", bad)
        missing = self.store.readiness(rec)
        self.assertEqual(len(missing), 1)
        self.assertIn("Zone géographique visée", missing[0])
        self.assertIn("obligatoire", missing[0])
        with self.assertRaises(inst.InstallationError) as cm:
            self.store.set_status(A, "alex", "active")
        self.assertEqual(cm.exception.errors, missing)
        self.assertEqual(self.store.get(A, "alex")["status"], "draft")

    def test_a_complete_installation_activates_and_can_be_paused_and_resumed(self):
        self.store.upsert(A, "alex", good_alex())
        self.assertEqual(self.store.readiness(self.store.get(A, "alex")), [])
        rec = self.store.set_status(A, "alex", "active")
        self.assertEqual(rec["status"], "active")
        self.assertTrue(rec["installedAtUtc"])
        self.assertEqual(self.store.set_status(A, "alex", "paused")["status"], "paused")
        self.assertEqual(self.store.set_status(A, "alex", "active")["status"], "active")
        self.assertEqual(self.store.set_status(A, "alex", "draft")["status"], "draft")

    def test_pausing_never_needs_readiness(self):
        self.store.upsert(A, "alex", {"services": {}})
        self.assertEqual(self.store.set_status(A, "alex", "paused")["status"], "paused")

    def test_invalid_status_and_missing_installation(self):
        self.store.upsert(A, "alex", good_alex())
        for bad in ("actif", "", None, "ACTIVE"):
            with self.assertRaises(inst.InstallationError):
                self.store.set_status(A, "alex", bad)
        with self.assertRaises(inst.InstallationError) as cm:
            self.store.set_status(A, "nora", "paused")
        self.assertIn("aucune installation", cm.exception.errors[0])

    def test_required_tools_are_checked_when_the_server_gives_the_connected_set(self):
        cfg = {"enabled": True, "knowledge": {"site_web": "https://x.example", "offre_description": "o", "zone_geographique": "z"}}
        # suivi-crm-opportunites : HubSpot OU Pipedrive obligatoire
        profile = inst.load_profile(self.root, "alex")
        crm = next(s for s in profile["services"] if s["id"] == "suivi-crm-opportunites")
        knowledge = {f["key"]: "valeur" for f in crm["knowledgeFields"] if f.get("required")}
        rec = self.store.upsert(A, "alex", {"services": {"suivi-crm-opportunites": {"enabled": True, "knowledge": knowledge}}})
        self.assertEqual(self.store.readiness(rec), [])                                   # sans information de connexion : non verifie
        missing = self.store.readiness(rec, connected=set())
        self.assertEqual(len(missing), 1)
        self.assertIn("Hubspot", missing[0])
        self.assertIn("Pipedrive", missing[0])
        self.assertEqual(self.store.readiness(rec, connected={"pipedrive.controlled"}), [])
        with self.assertRaises(inst.InstallationError):
            self.store.set_status(A, "alex", "active", connected=set())
        self.assertEqual(self.store.set_status(A, "alex", "active", connected={"hubspot.controlled"})["status"], "active")
        self.assertIn("hubspot.controlled", inst.profile_connector_ids(profile))
        del cfg


class Isolation(StoreCase):
    def test_two_clients_never_see_each_others_configuration(self):
        mine = good_alex()
        mine["notes"] = "note de A"
        theirs = good_alex()
        theirs["notes"] = "note de B"
        theirs["services"]["prospection-sortante"]["knowledge"]["site_web"] = "https://b.example"
        self.store.upsert(A, "alex", mine)
        self.store.upsert(B, "alex", theirs)
        self.store.upsert(B, "nora", {"services": {}})
        self.assertEqual(self.store.get(A, "alex")["notes"], "note de A")
        self.assertEqual(self.store.get(B, "alex")["services"]["prospection-sortante"]["knowledge"]["site_web"], "https://b.example")
        self.assertEqual([r["workerId"] for r in self.store.list(A)], ["alex"])
        self.assertEqual(sorted(r["workerId"] for r in self.store.list(B)), ["alex", "nora"])
        self.assertIsNone(self.store.get(A, "nora"))
        self.store.set_status(B, "alex", "paused")
        self.assertEqual(self.store.get(A, "alex")["status"], "draft")
        self.store.delete_client(B)
        self.assertEqual(self.store.list(B), [])
        self.assertEqual(len(self.store.list(A)), 1)

    def test_the_owner_account_can_install_for_itself(self):
        self.store.upsert(OWNER, "alex", good_alex())
        self.assertEqual(self.store.get(OWNER, "alex")["clientId"], OWNER)
        self.assertEqual(self.store.list(A), [])

    def test_trapped_identifiers_never_reach_the_disk(self):
        outside = os.path.join(self.root, "runtime", "outside.json")
        for client in ("CLI-../../x", "../CLI-CUST-AAAAAAAA", "CLI-CUST-AAAAAAAA/..", "CLI-CUST-AAAAAAAA\n", "cli-cust-aaaaaaaa", "", None, "CLI-", "CLI-A B"):
            with self.assertRaises(inst.InstallationError):
                self.store.upsert(client, "alex", good_alex())
            self.assertIsNone(self.store.get(client, "alex"))
            self.assertEqual(self.store.list(client), [])
        for worker in ("../alex", "alex/..", "..", "alex\n", "ALEX", "al ex", "", None, "a", "alex.json", "..\\alex"):
            with self.assertRaises(inst.InstallationError):
                self.store.upsert(A, worker, good_alex())
            self.assertIsNone(self.store.get(A, worker))
            self.assertIsNone(inst.load_profile(self.root, worker))
        self.assertFalse(os.path.exists(outside))
        base = os.path.join(self.root, "runtime", "installations")
        self.assertFalse(os.path.isdir(base) and os.listdir(base))            # rien n'a ete ecrit

    def test_delete_client_with_a_trapped_id_removes_nothing_else(self):
        self.store.upsert(A, "alex", good_alex())
        self.store.delete_client("CLI-../..")
        self.store.delete_client(None)
        self.assertEqual(len(self.store.list(A)), 1)
        self.assertTrue(os.path.isdir(os.path.join(self.root, "workers")))

    def test_a_tampered_record_with_another_client_id_is_never_served_to_the_wrong_account(self):
        self.store.upsert(A, "alex", good_alex())
        src = os.path.join(self.root, "runtime", "installations", A, "ALEX.json")
        os.makedirs(os.path.join(self.root, "runtime", "installations", B))
        shutil.copy2(src, os.path.join(self.root, "runtime", "installations", B, "ALEX.json"))
        # le dossier fait foi : B lit SON dossier ; la fiche porte le clientId d'origine, que l'API ne renvoie jamais a un autre compte que le proprietaire du dossier
        self.assertEqual(self.store.get(B, "alex")["clientId"], A)
        self.assertEqual([r["clientId"] for r in self.store.list(A)], [A])


class ReviewFixes(StoreCase):
    """Revue du 2026-10-13 (branche ws/hire-final)."""

    def test_a_pause_remembers_where_it_came_from_and_nothing_but_an_explicit_status_lifts_it(self):
        self.store.upsert(A, "alex", good_alex())
        rec = self.store.set_status(A, "alex", "paused")                    # un BROUILLON se met en pause lui aussi : il recoit la fiche et ses automatisations tournent
        self.assertEqual((rec["status"], rec["pausedFrom"]), ("paused", "draft"))
        self.assertEqual(self.store.set_status(A, "alex", "paused")["pausedFrom"], "draft")           # re-pause : l'origine ne change pas
        self.assertEqual(self.store.upsert(A, "alex", good_alex())["status"], "paused")                # modifier la fiche ne leve jamais la pause
        broken = good_alex()
        broken["services"]["prospection-sortante"]["knowledge"]["site_web"] = ""
        rec = self.store.upsert(A, "alex", broken)
        self.assertEqual((rec["status"], rec["pausedFrom"]), ("paused", "draft"))
        rec = self.store.set_status(A, "alex", "draft")
        self.assertNotIn("pausedFrom", rec)
        self.store.upsert(A, "alex", good_alex())
        self.store.set_status(A, "alex", "active")
        rec = self.store.set_status(A, "alex", "paused")
        self.assertEqual((rec["status"], rec["pausedFrom"]), ("paused", "active"))
        rec = self.store.set_status(A, "alex", "active")
        self.assertEqual(rec["status"], "active")
        self.assertNotIn("pausedFrom", rec)

    def test_a_mistyped_knowledge_or_autonomy_is_a_validation_error_not_a_crash(self):
        for field, junk in (("knowledge", "abc"), ("knowledge", ["a"]), ("knowledge", 3), ("autonomy", ["x"]), ("autonomy", "auto"), ("autonomy", 5)):
            bad = good_alex()
            bad["services"]["prospection-sortante"][field] = junk
            e = self.errors(bad)
            self.assertTrue(any("prospection-sortante" in m and "invalide" in m for m in e), (field, junk, e))
        self.assertIsNone(self.store.get(A, "alex"))
        ok = good_alex()
        ok["services"]["prospection-sortante"]["knowledge"] = None            # absent ou null : une fiche vide, comme avant
        ok["services"]["prospection-sortante"]["autonomy"] = None
        self.assertEqual(self.store.upsert(A, "alex", ok)["services"]["prospection-sortante"]["autonomy"], {})

    def test_auto_is_refused_for_any_rule_that_writes_into_a_tool(self):
        # Le profil classe ces regles en risque faible, mais elles gouvernent une ECRITURE dans un outil (tache CRM, brouillon de message, carte...) :
        # elles restent ask / draft / off (docs/INSTALL-PROFILES.md).
        profile = inst.load_profile(self.root, "alex")
        writers = [(svc["id"], r["category"]) for svc in profile["services"] for r in svc["autonomyRules"] if r.get("operations") and r["risk"] == "low"]
        self.assertGreater(len(writers), 3)
        self.assertIn("ecriture-crm", [c for _, c in writers])
        for sid, cat in writers:
            e = self.errors({"services": {sid: {"enabled": True, "autonomy": {cat: "auto"}}}})
            self.assertTrue(any("validation du client obligatoire" in m for m in e), (sid, cat, e))
            for mode in ("off", "ask", "draft"):
                self.store.upsert(A, "alex", {"services": {sid: {"enabled": True, "autonomy": {cat: mode}}}})
        reads = [(svc["id"], r["category"]) for svc in profile["services"] for r in svc["autonomyRules"] if not r.get("operations") and r["risk"] == "low"]
        self.assertIn("lecture-recherche", [c for _, c in reads])
        for sid, cat in reads[:6]:
            self.store.upsert(A, "alex", {"services": {sid: {"enabled": True, "autonomy": {cat: "auto"}}}})      # lire, analyser, rediger : toujours possible

if __name__ == "__main__":
    unittest.main(verbosity=2)
