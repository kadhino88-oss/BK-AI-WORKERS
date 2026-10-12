# -*- coding: utf-8 -*-
"""Contrat interface <-> serveur de l'assistant d'installation, sur les 17 profils reels (workers/<id>/install-profile.json).

La logique de l'assistant (dashboard/app.js, bloc BK-PURE) est executee par node ; les charges utiles qu'elle produit sont ensuite validees par le VRAI
validateur du serveur (dashboard/installations.py) sur un dossier temporaire :
  - toute charge utile par defaut est acceptee (aucune erreur, aucun avertissement de canal indisponible) ;
  - "auto" n'est jamais envoye ni enregistre pour une action dont le risque n'est pas "low" ;
  - ce que l'assistant croit manquer pour activer correspond a ce que le serveur calcule (champs obligatoires, outils obligatoires) ;
  - les reglages d'autonomie enregistres couvrent toutes les regles du service, et rien d'autre.

Lancer : python tests/hire-ui/test_payload_contract.py      (python 3 + node)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import installations as inst  # noqa: E402

failures = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def main():
    node = shutil.which("node")
    if not node:
        print("SKIP : node absent")
        return 0
    p = subprocess.run([node, os.path.join(os.path.dirname(__file__), "dump_payloads.js")], capture_output=True, cwd=REPO)
    if p.returncode != 0:
        print(p.stderr.decode("utf-8", "replace"))
        raise SystemExit("dump_payloads.js a echoue")
    dumps = json.loads(p.stdout.decode("utf-8"))
    check("les 17 profils sont couverts", len(dumps) == 17, str(len(dumps)))

    root = tempfile.mkdtemp(prefix="bkhireui-contract-")
    try:
        for wid in dumps:
            os.makedirs(os.path.join(root, "workers", wid))
            shutil.copy(os.path.join(REPO, "workers", wid, "install-profile.json"), os.path.join(root, "workers", wid, "install-profile.json"))
        store = inst.InstallationStore(root)
        client = "CLI-CUST-CONTRACT1"
        for wid, d in sorted(dumps.items()):
            profile = inst.load_profile(root, wid)
            rules = {s["id"]: {r["category"]: r for r in s["autonomyRules"]} for s in profile["services"]}

            # 1. charge utile complete par defaut : acceptee telle quelle, sans avertissement
            try:
                rec, warnings = store.upsert_with_warnings(client, wid, d["full"])
            except inst.InstallationError as e:
                check(f"{wid} : charge utile complete acceptee", False, "; ".join(e.errors)[:300])
                continue
            check(f"{wid} : charge utile complete acceptee sans avertissement de canal", warnings == [], str(warnings)[:200])
            check(f"{wid} : tous les services sont enregistres actifs", all(s["enabled"] for s in rec["services"].values()) and len(rec["services"]) == len(profile["services"]))
            bad_auto = [(sid, cat) for sid, s in rec["services"].items() for cat, mode in s["autonomy"].items() if mode == "auto" and rules[sid][cat]["risk"] != "low"]
            check(f"{wid} : jamais d'autonomie complete hors risque faible", not bad_auto, str(bad_auto))
            cover = all(set(s["autonomy"]) == set(rules[sid]) for sid, s in rec["services"].items())
            check(f"{wid} : un reglage d'autonomie par action de chaque service", cover)
            live = set(d["live"])
            check(f"{wid} : canaux enregistres = canaux reellement disponibles du service", all(set(s["channels"]) <= live for s in rec["services"].values()))

            # 2. ce que manque le serveur = ce que croit manquer l'interface
            m = d["missing"]
            server_full_null = len(store.readiness(rec, profile, connected=None))
            server_full_none = len(store.readiness(rec, profile, connected=set()))
            check(f"{wid} : fiche complete, outils inconnus -> rien ne manque (interface {m['fullNull']}, serveur {server_full_null})", m["fullNull"] == 0 == server_full_null)
            check(f"{wid} : fiche complete, aucun outil connecte -> meme nombre de manques (interface {m['fullNone']}, serveur {server_full_none})", m["fullNone"] == server_full_none)

            rec2, _ = store.upsert_with_warnings(client, wid, d["empty"])
            server_empty_null = len(store.readiness(rec2, profile, connected=None))
            server_empty_none = len(store.readiness(rec2, profile, connected=set()))
            check(f"{wid} : services coches sans fiche -> champs obligatoires manquants identiques (interface {m['emptyNull']}, serveur {server_empty_null})", m["emptyNull"] == server_empty_null)
            check(f"{wid} : services coches sans fiche ni outil -> manques identiques (interface {m['emptyNone']}, serveur {server_empty_none})", m["emptyNone"] == server_empty_none)

            rec3, _ = store.upsert_with_warnings(client, wid, d["nothing"])
            check(f"{wid} : aucun service coche -> « choisissez un service » des deux cotes", m["nothingNull"] == 1 and len(store.readiness(rec3, profile, connected=None)) == 1)
            check(f"{wid} : l'enregistrement ne cree jamais une installation active", rec3["status"] == "draft" and rec["status"] == "draft")
            store.delete(client, wid)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print("\n" + ("TOUT PASSE" if not failures else f"{len(failures)} ECHEC(S)"))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
