# -*- coding: utf-8 -*-
"""Branchement des fenetres d'usage sur le VRAI dashboard/server.py (racine jetable, horloge figee, faux sous-processus de mission : aucun modele,
aucun reseau). On verifie :

  - BK_USAGE_WINDOWS=0 (defaut) : rien ne change (aucun grand livre, aucun bloc « usage » dans la facturation, GET /api/usage ne montre que le mois) ;
  - BK_USAGE_WINDOWS=1 : la mission reserve ses credits avant de demarrer et les regle apres, la SESSION puis la SEMAINE refusent avec le message qui nomme
    la limite, l'heure exacte de renouvellement et le forfait du dessus avec ses chiffres ; le refus du mois garde son texte et son code ;
  - une course entre le controle de la route et la reservation (refus dans submit_task) ; les missions en arriere-plan ;
  - Chloe : le nombre de Workers qu'elle appelle suit ce que les fenetres accordent ;
  - changement de forfait en cours de fenetre, forfaits herites (Starter, Pro d'avant la grille), Enterprise sur mesure (usageOverride), essai, proprietaire ;
  - get_billing : creditsUsed vient du grand livre et egale le balayage des traces ; quota-check.py (automatisations) et usage-cli.py ;
  - arret/demarrage (reap), suppression et export de compte.

Lancer : python tests/usage/test_usage_wiring.py
"""
import contextlib
import datetime
import io
import json
import os
import subprocess
import sys
import time
import uuid

import importlib.util  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from common import check, finish  # noqa: E402  (tests/usage/common.py)

_spec = importlib.util.spec_from_file_location("pricing_common", os.path.join(HERE, "..", "pricing", "common.py"))
pricing_common = importlib.util.module_from_spec(_spec)        # tests/pricing/common.py : charge server.py sur une racine jetable
_spec.loader.exec_module(pricing_common)

A, B, C = pricing_common.A, pricing_common.B, pricing_common.C
ENT = "CLI-CUST-EEEEEEEE"
START = datetime.datetime(2026, 10, 20, 8, 12, 0)          # un mardi, 08:12 UTC ; le cycle mensuel des clients ci-dessous demarre le 12


class FakeClock:
    def __init__(self, dt):
        self.dt = dt

    def __call__(self):
        return self.dt

    def advance(self, seconds):
        self.dt += datetime.timedelta(seconds=seconds)


CLOCK = FakeClock(START)
server, ROOT = pricing_common.load_server("bk_server_usage_wiring")
sys.modules["server"] = server            # quota-check.py et usage-cli.py font `import server` : ils doivent trouver CE module
server._utcnow = CLOCK
server.get_worker_ids = lambda: ["alex", "nora", "lucas", "maya", "emma", "seoya", "ines", "lea"]
USAGE = server.USAGE
CYCLE = "2026-10-12T10:11:12Z"
RUNS = []                                  # chaque faux sous-processus de mission : {"client","worker","level","credits","maxWorkers"}


def fake_run(cmd, capture_output=True, timeout=600, env=None):
    """Remplace subprocess.run de submit_task : ecrit le fichier de sortie et les traces TASK-*.json comme Submit-Task.ps1."""
    out = cmd[cmd.index("-OutFile") + 1]
    client = cmd[cmd.index("-ClientId") + 1] if "-ClientId" in cmd else ""
    worker = cmd[cmd.index("-WorkerId") + 1] if "-WorkerId" in cmd else ""
    env = env or {}
    level = env.get("BK_MISSION_LEVEL", "")
    credits = server.level_credits(level) if level else 1
    max_workers = int(env["BK_MAX_WORKERS"]) if env.get("BK_MAX_WORKERS") else None
    count = 1
    if worker.lower() == "chloe":
        count = min(max_workers or 3, 3)
    os.makedirs(server.TASKS_DIR, exist_ok=True)
    items = []
    for _ in range(count):
        tid = "TASK-" + uuid.uuid4().hex.upper()
        with open(os.path.join(server.TASKS_DIR, tid + ".json"), "w", encoding="utf-8") as f:
            json.dump({"TaskId": tid, "ClientId": client, "Credits": credits, "Status": "SUCCESS",
                       "CreatedAtUtc": CLOCK.dt.isoformat() + "Z"}, f)
        items.append({"TaskId": tid, "Status": "SUCCESS"})
    result = {"TaskId": items[0]["TaskId"], "Status": "SUCCESS", "Results": items if worker.lower() == "chloe" else None}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(result, f)
    RUNS.append({"client": client, "worker": worker, "level": level, "credits": credits, "maxWorkers": max_workers, "count": count})
    return subprocess.CompletedProcess(cmd, 0, b"", b"")


server.subprocess.run = fake_run
server.dispatch_webhook_if_configured = lambda *a, **k: None


def set_mode(mode):
    os.environ["BK_USAGE_WINDOWS"] = mode


def fresh_client(client, plan, **extra):
    """Compte client neuf au forfait donne (cycle du 12 octobre) ; grand livre et traces effaces."""
    for p in (os.path.join(ROOT, "runtime", "usage", client + ".json"), os.path.join(ROOT, "runtime", "usage", client + ".lock")):
        with contextlib.suppress(OSError):
            os.remove(p)
    if os.path.isdir(server.TASKS_DIR):
        for name in os.listdir(server.TASKS_DIR):
            path = os.path.join(server.TASKS_DIR, name)
            try:
                with open(path, encoding="utf-8") as f:
                    mine = json.load(f).get("ClientId") == client
                if mine:
                    os.remove(path)               # apres la fermeture du fichier : Windows refuse de supprimer un fichier ouvert
            except (OSError, ValueError):
                pass
    USAGE._scan_cache = (None, None, None)
    pricing_common.write_billing(server, client, plan, cycle_start=CYCLE, **extra)
    if not any(a.get("clientId") == client for a in server._load_accounts()):
        pricing_common.add_account(server, client)


def mission(client, worker="alex", level="equilibre"):
    return server.submit_task("Prepare un plan de relance", worker_id=worker, client_id=client, level=level)


def block_of(client, level):
    return server.subscription_blocks_mission(client, level)


def ledger(client):
    return USAGE.snapshot(client)


def main():
    try:
        run()
    finally:
        import shutil
        shutil.rmtree(ROOT, ignore_errors=True)
    return finish("tests/usage/test_usage_wiring.py")


def run():
    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("== BK_USAGE_WINDOWS=0 (defaut) : rien ne change ==")
    set_mode("0")
    fresh_client(B, "equipe")
    check("service inerte", not USAGE.enabled and not USAGE.enforced)
    check("aucune mission refusee", block_of(B, "approfondi") is None)
    mission(B, level="approfondi")
    check("aucun grand livre ecrit", not os.path.exists(os.path.join(ROOT, "runtime", "usage", B + ".json")))
    bill = server.get_billing(B)
    check("get_billing : pas de bloc usage, creditsUsed = balayage des traces", "usage" not in bill and bill["creditsUsed"] == 12, bill.get("creditsUsed"))
    check("upgrade_payload : pas de limites annoncees", "limits" not in bill["upgrade"] and "limits" not in bill["upgrade"]["next"])
    pay = USAGE.payload(B)
    check("GET /api/usage : enforced false, mois seul", pay["ok"] and pay["enforced"] is False and pay["session"] is None and pay["month"]["limit"] == 900
          and pay["month"]["used"] == 12 and pay["windowsApply"] is False, pay)
    pub = USAGE.public_limits()
    check("GET /api/usage-limits : enforced false, plafonds par forfait", pub["enforced"] is False and pub["plans"]["equipe"]["session"] == 83
          and pub["plans"]["solo"]["week"] == 57 and "essai" not in pub["plans"] and "starter" not in pub["plans"], pub)

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== shadow : le grand livre tourne, rien n'est refuse ==")
    set_mode("shadow")
    fresh_client(A, "solo", hiredWorkers=["alex"])
    for _ in range(5):
        mission(A, "alex", "approfondi")                         # 5 x 12 = 60 > session de 23
    check("shadow : tout passe", block_of(A, "approfondi") is None)
    led = ledger(A)
    check("shadow : le grand livre a compte (session 60 sur 23)", led and led["session"]["used"] == 60 and led["week"]["used"] == 60, led and led["session"])
    check("shadow : enforced false dans l'API", USAGE.payload(A)["enforced"] is False)

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== actif : reservation, reglement, refus de session ==")
    set_mode("1")
    fresh_client(B, "equipe")                                      # 900 / 207 / 83
    RUNS.clear()
    check("equipe : limites 83 / 207 / 900", (lambda p: (p["session"]["limit"], p["week"]["limit"], p["month"]["limit"]))(USAGE.payload(B)) == (83, 207, 900))
    check("avant toute utilisation : session non ouverte", USAGE.payload(B)["session"]["opened"] is False and USAGE.payload(B)["nextRenewalUtc"] is None)
    r = mission(B, "alex", "approfondi")
    led = ledger(B)
    check("mission Approfondi : 12 credits regles, plus de reservation", r.get("Status") == "SUCCESS" and led["session"]["used"] == 12 and led["week"]["used"] == 12
          and led["month"]["used"] == 12 and not led["reservations"] and led["session"]["reserved"] == 0, led)
    check("la session s'est ouverte a la premiere utilisation (08:12, fin 12:12)", led["session"]["startUtc"] == "2026-10-20T08:12:00Z"
          and led["session"]["endUtc"] == "2026-10-20T12:12:00Z" and led["week"]["endUtc"] == "2026-10-27T08:12:00Z")
    check("get_billing : creditsUsed du grand livre = balayage des traces", server.get_billing(B)["creditsUsed"] == 12)
    for _ in range(5):
        mission(B, "alex", "approfondi")                           # 6 x 12 = 72 sur 83
    check("72 / 83 utilises, reste 11", USAGE.payload(B)["session"]["remaining"] == 11)
    check("Equilibre (6) passe encore", block_of(B, "equilibre") is None)
    msg = block_of(B, "approfondi")
    check("Approfondi (12) refuse : message de SESSION", isinstance(msg, str) and "quota de session" in msg, msg)
    check("le message dit combien il reste et ce que le niveau demande", "Il vous reste 11 crédit(s)" in str(msg) and "12" in str(msg), msg)
    check("... l'heure exacte du renouvellement (12:12 UTC = 14:12 a Zurich, l'heure d'ete finit le 25 octobre)", "14:12" in str(msg) and "dans 4 h" in str(msg), msg)
    check("... et le forfait du dessus avec ses chiffres", "forfait Pro (115 crédits par session)" in str(msg), msg)
    payload = server.subscription_required_payload(B, msg)
    check("402 USAGE_LIMIT_REACHED : limit, needed, remaining, resetsAtUtc", payload["error"] == "USAGE_LIMIT_REACHED" and payload["limit"] == "session"
          and payload["needed"] == 12 and payload["remaining"] == 11 and payload["resetsAtUtc"] == "2026-10-20T12:12:00Z", payload)
    check("... avec usage et upgrade (Pro : 115 / 287 / 1250)", payload["usage"]["session"]["remaining"] == 11
          and payload["upgrade"]["planId"] == "pro" and payload["upgrade"]["limits"] == {"session": 115, "week": 287, "month": 1250}, payload.get("upgrade"))
    CLOCK.advance(4 * 3600 - 1)
    check("une seconde avant la fin de la session : toujours refuse", block_of(B, "approfondi") is not None)
    CLOCK.advance(1)
    check("a la seconde exacte du renouvellement : la mission passe", block_of(B, "approfondi") is None)
    r = mission(B, "alex", "approfondi")
    led = ledger(B)
    check("nouvelle session ouverte a 12:12, semaine inchangee", r.get("Status") == "SUCCESS" and led["session"]["startUtc"] == "2026-10-20T12:12:00Z"
          and led["session"]["used"] == 12 and led["week"]["used"] == 84, led["session"])

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== la SEMAINE refuse, le mois reste le troisieme plafond ==")
    # semaine 207 : on consomme session apres session (72 chacune) jusqu'a 207, la semaine borne alors avant le mois (900)
    for _ in range(2):
        CLOCK.advance(4 * 3600)
        for _ in range(6):
            if block_of(B, "approfondi") is None:
                mission(B, "alex", "approfondi")
    msg = block_of(B, "approfondi")
    led = ledger(B)
    check("la semaine a ete atteinte (>= 195 / 207)", led["week"]["used"] >= 195, led["week"])
    check("... le refus nomme la SEMAINE", isinstance(msg, str) and "quota de la semaine" in msg, msg)
    p2 = server.subscription_required_payload(B, msg)
    check("... limit=week, renouvellement = fin de la semaine (27 octobre 08:12)", p2["limit"] == "week" and p2["resetsAtUtc"] == "2026-10-27T08:12:00Z", p2)
    check("... et le texte dit le jour (le mardi 27 octobre)", "le mardi 27 octobre à 09:12" in str(msg) or "27 octobre" in str(msg), msg)
    check("... le mois reste loin du compte", ledger(B)["month"]["used"] < 900)
    CLOCK.dt = datetime.datetime(2026, 10, 27, 8, 12, 0)
    check("a la fin de la semaine, tout repart (session et semaine neuves)", block_of(B, "approfondi") is None)

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== refus du MOIS : texte et code d'origine ==")
    CLOCK.dt = START
    fresh_client(C, "pro", paidUntilUtc="2027-10-12T00:00:00Z", stripeSubscriptionId="sub_test")
    pricing_common.write_billing(server, C, "pro", cycle_start=CYCLE, extraCredits=0)
    USAGE._scan_cache = (None, None, None)
    pricing_common.write_task(server, C, 1249, created="2026-10-13T00:00:00Z")
    USAGE._scan_cache = (None, None, None)
    # le mois (1250) n'a plus que 1 credit : la route d'origine refuse AVANT les fenetres
    msg = block_of(C, "equilibre")
    check("mois : message d'origine (credits restants), pas une limite de session", isinstance(msg, str) and "Il vous reste 1 crédit" in msg
          and getattr(msg, "usage_block", None) is None, msg)
    check("... code SUBSCRIPTION_REQUIRED", server.subscription_required_payload(C, msg)["error"] == "SUBSCRIPTION_REQUIRED")

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== course : refus dans submit_task (reservation) ==")
    fresh_client(B, "equipe")
    mission(B, "alex", "approfondi")
    for _ in range(5):
        mission(B, "alex", "approfondi")
    res = mission(B, "alex", "approfondi")                         # le controle de la route aurait laisse passer, la reservation refuse
    check("submit_task renvoie le corps du 402", server.refused_for_usage(res) is not None and res["error"] == "USAGE_LIMIT_REACHED"
          and res["limit"] == "session", res)
    n_runs = len(RUNS)
    mission(B, "alex", "approfondi")
    check("... et aucun sous-processus n'est lance", len(RUNS) == n_runs)
    check("... la place de mission asynchrone n'a pas fui", server._ASYNC_ACTIVE.get(B, 0) == 0)
    job = server.submit_task_async("Prepare un plan", worker_id="alex", client_id=B, level="approfondi")
    end = time.time() + 10
    rec = server.read_async_job(job["jobId"])
    while rec and rec["status"] == "RUNNING" and time.time() < end:
        time.sleep(0.05)
        rec = server.read_async_job(job["jobId"])
    check("mission en arriere-plan : job ERROR / USAGE_LIMIT_REACHED, avec le message et le corps", rec["status"] == "ERROR"
          and rec["errorCode"] == "USAGE_LIMIT_REACHED" and "quota de session" in rec["error"] and rec["errorPayload"]["resetsAtUtc"], rec)

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== Chloe : le nombre de Workers suit ce que la session accorde ==")
    fresh_client(B, "equipe")
    RUNS.clear()
    mission(B, "chloe", "equilibre")                                # 6 credits par Worker ; reservation = 6 x min(cap, 8 Workers) = 48 sur 83
    run = RUNS[-1]
    led = ledger(B)
    check("Chloe appelle 3 Workers (faux pipeline) : 18 credits regles", run["count"] == 3 and led["session"]["used"] == 18 and not led["reservations"], led["session"])
    for _ in range(3):
        mission(B, "chloe", "equilibre")                            # 4 x 18 = 72 ; reste 11 dans la session
    RUNS.clear()
    mission(B, "chloe", "equilibre")
    check("reste 11 : Chloe n'a droit qu'a 1 Worker (6 credits)", RUNS and RUNS[-1]["maxWorkers"] == 1 and RUNS[-1]["count"] == 1, RUNS[-1:] if RUNS else None)

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== changement de forfait en cours de fenetre ==")
    fresh_client(B, "equipe")
    for _ in range(6):
        mission(B, "alex", "approfondi")
    check("equipe : 72 / 83", USAGE.payload(B)["session"]["used"] == 72)
    CLOCK.advance(60)                                              # une minute plus tard (le nouveau cycle ne reprend pas les missions de la meme seconde)
    server.set_billing_plan("pro", client_id=B)                    # montee en gamme : set_billing_plan repart sur un nouveau cycle, la session reste
    pay = USAGE.payload(B)
    check("montee a Pro : la session passe a 115, l'utilise (72) reste", pay["session"]["limit"] == 115 and pay["session"]["used"] == 72
          and pay["session"]["remaining"] == 43 and pay["week"]["limit"] == 287, pay["session"])
    check("... la mission refusee juste avant passe maintenant", block_of(B, "approfondi") is None)
    check("... le mois repart avec un cycle neuf", pay["month"]["limit"] == 1250 and pay["month"]["used"] == 0)

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== forfaits herites, Enterprise sur mesure, essai, proprietaire ==")
    fresh_client(C, "starter")
    check("Starter (150) : 34 / 14", (lambda p: (p["week"]["limit"], p["session"]["limit"]))(USAGE.payload(C)) == (34, 14), USAGE.payload(C)["session"])
    fresh_client(C, "business")
    check("Business (600) : 138 / 55", (lambda p: (p["week"]["limit"], p["session"]["limit"]))(USAGE.payload(C)) == (138, 55))
    # Pro d'avant la grille : pas de gridVersion + preuve de paiement -> 1500 credits
    fresh_client(C, "pro", stripeSubscriptionId="sub_old")
    st = server._billing_load(C)
    st.pop("gridVersion", None)
    server._billing_save(st, C)
    pay = USAGE.payload(C)
    check("Pro herite (1 500 credits) : 345 / 138", (pay["month"]["limit"], pay["week"]["limit"], pay["session"]["limit"]) == (1500, 345, 138), pay["month"])
    fresh_client(C, "essai")
    pay = USAGE.payload(C)
    check("essai : fenetres session et semaine sans objet, le mois borne", pay["windowsApply"] is False and pay["session"] is None and pay["month"]["limit"] == 15, pay)
    check("... une mission d'essai passe (Rapide, 1 credit) et est comptee dans le mois", block_of(C, "rapide") is None
          and (mission(C, "alex", "rapide") or True) and USAGE.payload(C)["month"]["used"] == 1)
    own = USAGE.payload(server.DASHBOARD_CLIENT_ID)
    check("proprietaire : exempt, aucune limite", own["exempt"] is True and own["session"] is None and own["allowedNow"] is None)
    check("essai public : exempt", USAGE.payload(server.TRIAL_CLIENT_ID)["exempt"] is True)
    check("... et jamais de reservation pour eux", USAGE.mission_begin(server.DASHBOARD_CLIENT_ID, "alex", "approfondi", False).reservation is None)

    fresh_client(ENT, "enterprise", contractCredits=20000)
    pay = USAGE.payload(ENT)
    check("Enterprise 20 000 : 4 598 / 1 839", (pay["week"]["limit"], pay["session"]["limit"]) == (4598, 1839), pay["session"])
    body, status = server.set_client_plan(ENT, "enterprise", contract_credits=20000, usage_override={"sessionCredits": 3000, "weekCredits": 9000})
    pay = USAGE.payload(ENT)
    check("set_client_plan : plafonds sur mesure 3 000 / 9 000", status == 200 and (pay["session"]["limit"], pay["week"]["limit"]) == (3000, 9000), (status, body))
    body, status = server.set_client_plan(ENT, "enterprise", usage_override={"sessionCredits": 9000, "weekCredits": 3000})
    check("... session > semaine refusee (400 INVALID_USAGE_OVERRIDE)", status == 400 and body["error"] == "INVALID_USAGE_OVERRIDE", body)
    body, status = server.set_client_plan(ENT, "enterprise", usage_override={"sessionCredits": 50000})
    check("... session > credits du mois refusee", status == 400 and body["error"] == "INVALID_USAGE_OVERRIDE", body)
    body, status = server.set_client_plan(ENT, "enterprise")
    pay = USAGE.payload(ENT)
    check("... reconduit sans nouveaux plafonds : ceux du contrat sont gardes", status == 200 and (pay["session"]["limit"], pay["week"]["limit"]) == (3000, 9000), pay["session"])
    body, status = server.set_client_plan(A, "pro", usage_override={"sessionCredits": 5})
    check("plafonds sur mesure refuses hors Enterprise", status in (400, 404) and body["error"] in ("USAGE_OVERRIDE_NOT_ALLOWED", "CLIENT_NOT_FOUND"), body)
    server.set_billing_plan("pro", client_id=ENT)
    check("changer de forfait efface les plafonds du contrat", "usageOverride" not in server._billing_load(ENT))

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== automatisations : quota-check.py et usage-cli.py ==")
    fresh_client(B, "equipe")
    spec = importlib.util.spec_from_file_location("quota_check", os.path.join(HERE, "..", "..", "dashboard", "quota-check.py"))
    qc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(qc)

    def run_cli(module, *argv):
        buf = io.StringIO()
        old = sys.argv
        sys.argv = ["x"] + list(argv)
        try:
            with contextlib.redirect_stdout(buf):
                module.main(*([sys.argv] if module.__name__.startswith("usage_cli") else []))
        finally:
            sys.argv = old
        return json.loads(buf.getvalue().strip().splitlines()[-1])

    v = run_cli(qc, B, "alex", "scheduled")
    check("quota-check : l'automatisation passe et est debitee (1 credit, Rapide)", v["blocked"] is False and v["level"] == "rapide"
          and ledger(B)["session"]["used"] == 1 and ledger(B)["month"]["used"] == 1, v)
    for _ in range(82):
        run_cli(qc, B, "alex", "scheduled")
    check("83 automatisations : session pleine", USAGE.payload(B)["session"]["remaining"] == 0, USAGE.payload(B)["session"])
    v = run_cli(qc, B, "alex", "scheduled")
    check("la 84e est sautee, sans erreur, code USAGE_LIMIT_REACHED + fenetre + heure", v["blocked"] is True and v["code"] == "USAGE_LIMIT_REACHED"
          and v["limit"] == "session" and v["resetsAtUtc"] == "2026-10-20T12:12:00Z" and "error" not in v, v)
    check("... et rien n'est debite", ledger(B)["session"]["used"] == 83)
    spec2 = importlib.util.spec_from_file_location("usage_cli", os.path.join(HERE, "..", "..", "dashboard", "usage-cli.py"))
    cli = importlib.util.module_from_spec(spec2)
    spec2.loader.exec_module(cli)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cli.main(["usage-cli.py", "charge", B, "1", "automation", "t"])
    out = json.loads(buf.getvalue())
    check("usage-cli charge : refus {ok:false, limit, resetsAtUtc}", out["ok"] is False and out["limit"] == "session" and out["resetsAtUtc"] == "2026-10-20T12:12:00Z", out)
    fresh_client(B, "equipe")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cli.main(["usage-cli.py", "charge", B, "2", "automation", "t"])
    check("usage-cli charge : {ok:true} et debit", json.loads(buf.getvalue()) == {"ok": True} and ledger(B)["session"]["used"] == 2)
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        cli.main(["usage-cli.py", "charge", B, "abc"])
    check("usage-cli : argument illisible -> ok:true + error (jamais de blocage)", json.loads(buf.getvalue()).get("ok") is True)
    set_mode("0")
    fresh_client(B, "equipe")
    v = run_cli(qc, B, "alex", "scheduled")
    check("BK_USAGE_WINDOWS=0 : quota-check ne debite rien", v["blocked"] is False and not os.path.exists(os.path.join(ROOT, "runtime", "usage", B + ".json")), v)
    set_mode("1")

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== get_billing : bloc usage, non-regression balayage / grand livre ==")
    fresh_client(B, "equipe")
    for i in range(20):
        pricing_common.write_task(server, B, [1, 6, 12][i % 3], created="2026-10-1%dT0%d:00:00Z" % (3 + i % 6, i % 9))
    pricing_common.write_task(server, A, 7, created="2026-10-15T00:00:00Z")          # un autre client : jamais melange
    pricing_common.write_task(server, B, 5, created="2026-09-01T00:00:00Z")          # cycle precedent : exclu
    USAGE._scan_cache = (None, None, None)
    sweep = 0
    for name in os.listdir(server.TASKS_DIR):
        d = server.load_json(os.path.join(server.TASKS_DIR, name))
        if d.get("ClientId") == B and d["CreatedAtUtc"] >= CYCLE:
            sweep += server.task_credits(d)
    bill = server.get_billing(B)
    check("creditsUsed (grand livre) == balayage des 20 traces du cycle", bill["creditsUsed"] == sweep and sweep > 0, (bill["creditsUsed"], sweep))
    check("bloc usage dans la facturation, comme GET /api/usage", bill["usage"]["month"]["used"] == sweep and bill["usage"]["session"]["limit"] == 83)
    check("limites du forfait ACTUEL et du forfait suivant dans la carte de montee en gamme", bill["upgrade"]["limits"]["session"] == 83
          and bill["upgrade"]["next"]["limits"] == {"session": 115, "week": 287, "month": 1250}, bill["upgrade"])

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== arret / demarrage, suppression et export de compte ==")
    fresh_client(B, "equipe")
    rsv = USAGE.reserve(B, 12, "mission", "MSN-ORPHELIN")
    check("reservation en cours (mission)", rsv.id and ledger(B)["session"]["reserved"] == 12 and USAGE.payload(B)["activeReservations"])
    freed = USAGE.reap(boot=True)
    check("reap(boot) : la reservation orpheline est liberee, la session refermee", freed >= 1 and not ledger(B)["reservations"] and ledger(B)["session"]["id"] is None)
    exp = server.export_account_data(B)
    check("export du compte : le grand livre est inclus", exp["usage"] and exp["usage"]["clientId"] == B and exp["usage"]["schema"] == "BK-USAGE-LEDGER-V1")
    server._purge_client_mission_artifacts(B, [])
    check("suppression du compte : le grand livre disparait", not os.path.exists(os.path.join(ROOT, "runtime", "usage", B + ".json")))
    set_mode("0")
    check("BK_USAGE_WINDOWS=0 : export sans grand livre", server.export_account_data(A)["usage"] is None)

    # ----------------------------------------------------------------------------------------------------------------------------------------
    print("\n== grand livre illisible : le service reste ouvert (quota du mois seul) ==")
    set_mode("1")
    fresh_client(B, "equipe")
    USAGE.remaining(B)
    with open(os.path.join(ROOT, "runtime", "usage", B + ".json"), "w", encoding="utf-8") as f:
        f.write("{pas du json")
    check("fichier corrompu : la porte laisse passer", block_of(B, "approfondi") is None)
    r = mission(B, "alex", "approfondi")
    check("... la mission s'execute", r.get("Status") == "SUCCESS")
    check("... GET /api/usage repond (le grand livre est reamorce depuis les traces)", USAGE.payload(B)["ok"] is True)


if __name__ == "__main__":
    sys.exit(main())
