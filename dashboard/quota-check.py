#!/usr/bin/env python3
# BK-AI-WORKERS — verification de quota pour le chemin des automatisations.
#
# Le controle de quota d'origine (subscription_blocks_mission) ne vivait
# que dans les endpoints HTTP de server.py. Les automatisations declenchees
# par cron (deploy/tick-automations.sh -> Automation-Bridge.ps1 -Action tick
# -> Invoke-AutomationTick -> Invoke-AutomationRun -> Submit-Task.ps1) ne
# passaient par aucun de ces endpoints : un client au quota epuise voyait
# quand meme ses automatisations recurrentes s'executer. Ce petit
# utilitaire reutilise EXACTEMENT la meme regle que les endpoints (aucune
# duplication) : il importe server.py (sans effet de bord — le serveur HTTP
# ne demarre que sous __main__) et appelle subscription_blocks_mission.
#
# Usage : quota-check.py <ClientId> [<WorkerId> [scheduled]]
# Sortie : une ligne JSON sur stdout. {"blocked": false} si la mission est
# autorisee, sinon {"blocked": true, "code": "...", "detail": "<message>"}.
#   - code QUOTA_EXCEEDED       : credits epuises (ancien comportement, "detail" seul) ;
#   - code WORKER_NOT_INCLUDED  : offre "Worker a l'unite" (forfait Solo/Trio) : ce Worker n'est pas embauche par le client ;
#   - code INSTALLATION_PAUSED  : (appel "scheduled", donc automatique) le client a mis ce Worker en pause : interrupteur d'arret,
#                                 plus aucune mission automatique ; "Executer maintenant" (manuel) reste possible.
# Quand la mission est autorisee, "allowedWorkers" vaut la liste des Workers embauches separee par des virgules (variable
# BK_ALLOWED_WORKERS a transmettre a Submit-Task.ps1), "-" pour aucun, ou null pour "tous". Pour un appel "scheduled", les Workers que le client a
# mis en pause en sont retires (une automatisation de Chloe ne doit jamais appeler un Worker en pause : null devient alors la liste explicite des
# autres Workers) ; si tous sont en pause, la mission est bloquee (INSTALLATION_PAUSED). Pour Chloe, "maxWorkers" = nombre maximal de Workers qu'elle
# peut appeler avec le solde de credits restant (variable BK_MAX_WORKERS) : chaque Worker appele coute le niveau de la mission.
# Les automatisations (missions recurrentes) tournent TOUJOURS au niveau Rapide, 1 credit (server.automation_level) : le quota est controle a
# ce niveau-la, et "level" (« rapide », ou « » quand les niveaux sont coupes par BK_LEVELS=0) est a transmettre a Submit-Task.ps1 via
# BK_MISSION_LEVEL pour que la mission tourne reellement a ce niveau et soit comptee 1 credit.
# En cas d'erreur inattendue : {"blocked": false, "error": "..."} — le quota est
# indicatif (aucun PSP branche), donc on ne bloque JAMAIS une automatisation
# a cause d'un bug du verificateur : on laisse passer et on trace. Ce n'est PAS un verdict sur les droits d'acces : le moteur
# (AUTOMATION-ENGINE.ps1) ignore toute reponse qui porte un champ "error" et applique alors son repli (forfait Solo/Trio : execution sautee).
import sys
import os
import json


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print(json.dumps({"blocked": False, "error": "no_client_id"}))
        return 0
    client_id = sys.argv[1].strip()
    worker_id = sys.argv[2].strip().lower() if len(sys.argv) > 2 else ""
    scheduled = len(sys.argv) > 3 and sys.argv[3].strip().lower() in ("scheduled", "1", "true")
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import server
        block = server.worker_block(client_id, worker_id) if worker_id else None
        if block:
            print(json.dumps({"blocked": True, "code": "WORKER_NOT_INCLUDED", "detail": block["detail"]}, ensure_ascii=False))
            return 0
        level = server.automation_level(client_id)
        msg = server.subscription_blocks_mission(client_id, level)
        if msg:
            print(json.dumps({"blocked": True, "code": "QUOTA_EXCEEDED", "detail": msg}, ensure_ascii=False))
            return 0
        if scheduled and worker_id and server.installation_paused(client_id, worker_id):
            print(json.dumps({"blocked": True, "code": "INSTALLATION_PAUSED",
                              "detail": "L'installation de ce Worker est en pause : aucune mission automatique tant que vous ne la reprenez pas."}, ensure_ascii=False))
            return 0
        allowed = server.allowed_workers_env(client_id)
        if scheduled:
            allowed, none_left = server.scheduled_allowed_workers_env(client_id)
            if none_left:
                print(json.dumps({"blocked": True, "code": "INSTALLATION_PAUSED",
                                  "detail": "Tous vos Workers sont en pause : aucune mission automatique tant que vous n'en reprenez pas un."}, ensure_ascii=False))
                return 0
        verdict = {"blocked": False, "allowedWorkers": allowed, "level": level}
        # Moteur d'IA de la mission recurrente (2026-10-25, dashboard/provider_router.py) : meme plan que pour une mission lancee a la main (essai -> moteur local,
        # cle personnelle, plafond de depense, disjoncteur). Absent tant que le proprietaire n'a rien choisi : le moteur d'automatisation ne pose alors aucune variable.
        try:
            engine_env = server.provider_router.plan_env(server.engine_plan_for(client_id, level))
            if engine_env.get("BK_ENGINE_PLAN"):
                verdict["enginePlan"] = engine_env["BK_ENGINE_PLAN"]
                if engine_env.get("BK_ENGINE_BUDGET_CHF"):
                    verdict["engineBudgetChf"] = engine_env["BK_ENGINE_BUDGET_CHF"]
        except Exception:  # noqa: BLE001 - un souci de reglages ne bloque jamais une automatisation : chemin habituel
            pass
        if worker_id == "chloe":
            cap = server.chloe_worker_cap(client_id, level)
            if cap is not None:
                verdict["maxWorkers"] = cap
        print(json.dumps(verdict))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"blocked": False, "error": repr(exc)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
