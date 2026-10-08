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
# Sortie : une ligne JSON sur stdout. {"blocked": false} si la mission est
# autorisee, sinon {"blocked": true, "detail": "<message>"}. En cas
# d'erreur inattendue : {"blocked": false, "error": "..."} — le quota est
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
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import server
        msg = server.subscription_blocks_mission(client_id)
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"blocked": False, "error": repr(exc)}))
        return 0
    if msg:
        print(json.dumps({"blocked": True, "detail": msg}, ensure_ascii=False))
    else:
        print(json.dumps({"blocked": False}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
