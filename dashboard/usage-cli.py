#!/usr/bin/env python3
# BK-AI-WORKERS - interface en ligne de commande du grand livre d'usage (fenetres de session, de semaine et de mois), pour PowerShell et les scripts
# qui consomment des credits sans passer par server.submit_task (moteur des automatisations, lanceur d'etapes de projet).
#
# Usage :
#   usage-cli.py charge <ClientId> <credits> <kind> <ref>   debite <credits> (reservation + reglement immediats). kind : automation | mission | project_step.
#   usage-cli.py remaining <ClientId>                       lit l'etat des trois fenetres, sans rien consommer (meme corps que GET /api/usage).
#
# Sortie : UNE ligne JSON sur stdout, code de sortie 0.
#   charge    -> {"ok": true}                                                           la consommation est passee (ou les fenetres ne sont pas actives) ;
#                {"ok": false, "limit": "session"|"week"|"month", "resetsAtUtc": "...", "remaining": n, "needed": n, "detail": "..."}   refusee ;
#   remaining -> {"ok": true, ...}
# En cas d'erreur inattendue : {"ok": true, "error": "..."}  - comme quota-check.py, un bug du verificateur ne coupe JAMAIS un travail : on laisse
# passer et on trace (le quota du mois, lui, reste applique par les routes).
import json
import os
import sys


def emit(obj):
    print(json.dumps(obj, ensure_ascii=False))
    return 0


def main(argv):
    if len(argv) < 3 or argv[1] not in ("charge", "remaining") or not argv[2].strip():
        return emit({"ok": True, "error": "usage: usage-cli.py charge <ClientId> <credits> <kind> <ref> | remaining <ClientId>"})
    action, client_id = argv[1], argv[2].strip()
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    try:
        import server
        if action == "remaining":
            return emit(server.USAGE.payload(client_id))
        try:
            credits = int(argv[3])
        except (IndexError, ValueError):
            return emit({"ok": True, "error": "credits_invalid"})
        kind = (argv[4] if len(argv) > 4 else "automation").strip() or "automation"
        ref = (argv[5] if len(argv) > 5 else "").strip()
        if kind not in ("automation", "mission", "project_step") or credits < 0:
            return emit({"ok": True, "error": "kind_or_credits_invalid"})
        block = server.USAGE.charge(client_id, credits, kind, ref)
        if block is None:
            return emit({"ok": True})
        return emit({"ok": False, "limit": block.limit, "resetsAtUtc": block.resetsAtUtc, "remaining": block.remaining, "needed": block.needed,
                     "detail": str(server.USAGE.block_message(client_id, block))})
    except Exception as exc:  # noqa: BLE001
        return emit({"ok": True, "error": repr(exc)})


if __name__ == "__main__":
    sys.exit(main(sys.argv))
