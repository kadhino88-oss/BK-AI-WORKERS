"""Tient le journal d'incidents affiche sur /status.html (a la main, sans toucher au code).

Sur le serveur, depuis le dossier du projet :
    docker compose exec app python3 /data/app/deploy/status-incident.py list
    docker compose exec app python3 /data/app/deploy/status-incident.py add --title "Lenteur sur les missions" --impact minor --text "Nous enquetons."
    docker compose exec app python3 /data/app/deploy/status-incident.py update INC-20261007-1 --status identified --text "Cause identifiee, correctif en cours."
    docker compose exec app python3 /data/app/deploy/status-incident.py resolve INC-20261007-1 --text "Retour a la normale."
    docker compose exec app python3 /data/app/deploy/status-incident.py delete INC-20261007-1      (erreur de saisie seulement)

Statuts : investigating, identified, monitoring, resolved.   Impacts : none, minor, major, critical, maintenance.
La page publique se met a jour tout de suite. Le fichier est un JSON simple (memory/runtime/status/incidents.json)
que tu peux aussi corriger a la main : une faute de frappe ne fait pas disparaitre les incidents deja affiches.
Ecrire ici ce qui s'est PASSE, factuellement : la page n'affiche que ce qui est vrai.
"""
import argparse
import json
import os
import sys

ROOT = os.environ.get("BK_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "dashboard"))
import status_monitor as sm  # noqa: E402

path = os.path.join(os.environ.get("BK_STATUS_DIR") or os.path.join(ROOT, "memory", "runtime", "status"), "incidents.json")
log = sm.IncidentLog(path)

ap = argparse.ArgumentParser(description="Journal d'incidents de la page /status.html")
sub = ap.add_subparsers(dest="cmd", required=True)
sub.add_parser("list")
a = sub.add_parser("add")
a.add_argument("--title", required=True)
a.add_argument("--status", default="investigating", choices=sm.INCIDENT_STATUSES)
a.add_argument("--impact", default="minor", choices=sm.INCIDENT_IMPACTS)
a.add_argument("--text", default="")
a.add_argument("--started-at", default=None, help="AAAA-MM-JJTHH:MM:SSZ (UTC), par defaut maintenant")
u = sub.add_parser("update")
u.add_argument("id")
u.add_argument("--status", choices=sm.INCIDENT_STATUSES)
u.add_argument("--impact", choices=sm.INCIDENT_IMPACTS)
u.add_argument("--text")
r = sub.add_parser("resolve")
r.add_argument("id")
r.add_argument("--text", default="")
d = sub.add_parser("delete")
d.add_argument("id")
args = ap.parse_args()

try:
    if args.cmd == "list":
        out = log.list_all()
    elif args.cmd == "add":
        out = log.add(args.title, status=args.status, impact=args.impact, text=args.text, started_at=args.started_at)
    elif args.cmd == "update":
        out = log.update(args.id, status=args.status, text=args.text, impact=args.impact)
    elif args.cmd == "resolve":
        out = log.resolve(args.id, args.text)
    else:
        log.delete(args.id)
        out = {"deleted": args.id}
except KeyError:
    sys.exit("Incident introuvable : " + args.id)
except ValueError as e:
    sys.exit("Refuse : " + str(e))
print(json.dumps(out, ensure_ascii=False, indent=2))
