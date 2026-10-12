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
# BK_ALLOWED_WORKERS a transmettre a Submit-Task.ps1), "-" pour aucun, ou null pour "tous".
# En cas d'erreur inattendue : {"blocked": false, "error": "..."} — le quota est
# indicatif (aucun PSP branche), donc on ne bloque JAMAIS une automatisation
# a cause d'un bug du verificateur : on laisse passer et on trace.
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
        msg = server.subscription_blocks_mission(client_id)
        if msg:
            print(json.dumps({"blocked": True, "code": "QUOTA_EXCEEDED", "detail": msg}, ensure_ascii=False))
            return 0
        if scheduled and worker_id and server.installation_paused(client_id, worker_id):
            print(json.dumps({"blocked": True, "code": "INSTALLATION_PAUSED",
                              "detail": "L'installation de ce Worker est en pause : aucune mission automatique tant que vous ne la reprenez pas."}, ensure_ascii=False))
            return 0
        print(json.dumps({"blocked": False, "allowedWorkers": server.allowed_workers_env(client_id)}))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"blocked": False, "error": repr(exc)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
