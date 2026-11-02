# -*- coding: utf-8 -*-
"""dashboard/usage.py (fenetres session 4 h, semaine 7 j, mois) : le service seul, sans server.py. Horloge injectee, racine jetable.

Couvre : allocations (tableau de docs/AUTONOMY-ENGINE.md 6b.3), ouverture et fermeture des fenetres, secondes aux bornes, refus (fenetre nommee,
heure de renouvellement), plus grand renouvellement quand plusieurs fenetres refusent, reservation partielle, liberation d'une reservation
inutilisee, concurrence (threads ET processus), changement de forfait en cours de fenetre, essai et comptes exemptes, modes off / shadow / on,
reservations echues, amorcage depuis les traces, reconciliation sur 200 traces, derive d'horloge, interblocage du journal, purge.

    python tests/usage/test_usage_core.py
"""
import json
import os
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import A, B, CYCLE_END, CYCLE_START, PLANS, REPO, T0, Env, check, finish, pv_for, usage  # noqa: E402

H = 3600.0
D = 86400.0
LIM = usage.load_limits(os.path.join(REPO, "core", "usage", "USAGE-LIMITS.json"))


def test_allocations():
    print("\n== allocations : le tableau du contrat (6b.3) ==")
    expected = {"solo": (23, 57), "trio": (46, 115), "equipe": (83, 207), "pro": (115, 287), "scale": (368, 920), "enterprise": (920, 2299),
                "starter": (14, 34), "business": (55, 138)}
    for plan, (session, week) in expected.items():
        a = usage.allowances_for(PLANS[plan], LIM)
        check(f"{plan} : {PLANS[plan]} / mois -> {week} / semaine -> {session} / session", a == {"session": session, "week": week, "month": PLANS[plan]}, a)
    a = usage.allowances_for(1500, LIM)
    check("Pro ancien (1 500 credits) : 345 / semaine, 138 / session", (a["week"], a["session"]) == (345, 138), a)
    check("la session ne depasse jamais la semaine ni la semaine le mois (petit contrat : 40 credits)",
          usage.allowances_for(40, LIM) == {"session": 9, "week": 9, "month": 40}, usage.allowances_for(40, LIM))
    check("un plafond de 0 reste 0 (jamais « tout est permis »)", usage.allowances_for(0, LIM) == {"session": 0, "week": 0, "month": 0})
    check("plancher de session : 12 credits meme pour un petit forfait (Approfondi tient dans une session vide)",
          usage.allowances_for(100, LIM)["session"] == 12, usage.allowances_for(100, LIM))
    a = usage.allowances_for(10000, LIM, {"sessionCredits": 1200, "weekCredits": 3000})
    check("plafonds d'un contrat Enterprise (override)", a == {"session": 1200, "week": 3000, "month": 10000}, a)
    a = usage.allowances_for(500, LIM, {"sessionCredits": 9999, "weekCredits": 9999})
    check("... mais toujours bornes par le niveau du dessus", a == {"session": 500, "week": 500, "month": 500}, a)
    check("valeurs illisibles du fichier : on garde les valeurs par defaut",
          usage.load_limits(None, {"weeklyDivisor": "x", "sessionHours": -3, "minSessionCredits": True})["weeklyDivisor"] == 4.35)


def test_window_lifecycle():
    print("\n== fenetres : ouverture a la premiere utilisation, secondes aux bornes, renouvellement ==")
    env = Env()
    svc, clk = env.svc, env.clock
    v = svc.remaining(A)
    check("aucune utilisation : session et semaine non demarrees, pleines", (v.session.opened, v.week.opened, v.session.remaining, v.week.remaining) == (False, False, 23, 57), v)
    check("... le mois est toujours ouvert (cycle de facturation)", v.month.opened and v.month.resetsAtUtc == CYCLE_END and v.month.limit == 250)
    check("... rien ne se renouvelle tant que rien n'a demarre", v.next_renewal_utc() is None or v.binding == "month", v.binding)
    r = svc.reserve(A, 6, "mission", "MSN-1")
    v = svc.remaining(A)
    check("la premiere reservation ouvre la session [T0, T0+4 h) et la semaine [T0, T0+7 j)",
          v.session.opened and v.session.startUtc == usage.iso(T0) and v.session.resetsAtUtc == usage.iso(T0 + 4 * H)
          and v.week.startUtc == usage.iso(T0) and v.week.resetsAtUtc == usage.iso(T0 + 7 * D), v.session)
    check("... 6 credits reserves partout", (v.session.reserved, v.week.reserved, v.month.reserved) == (6, 6, 6), v)
    svc.settle(A, r, 6)
    v = svc.remaining(A)
    check("reglement : consomme, plus reserve", (v.session.used, v.session.reserved, v.week.used, v.month.used) == (6, 0, 6, 6), v)
    clk.t = T0 + 4 * H - 1
    v = svc.remaining(A)
    check("une seconde avant la fin : la meme session (6 credits consommes)", v.session.used == 6 and v.session.opened, v.session)
    clk.t = T0 + 4 * H
    v = svc.remaining(A)
    check("a la seconde exacte de la fin : la session est refermee, la semaine continue", not v.session.opened and v.session.used == 0 and v.week.used == 6, v)
    r2 = svc.reserve(A, 6, "mission", "MSN-2")
    check("... la reservation suivante ouvre UNE NOUVELLE session (identifiant S-<debut>)", svc.snapshot(A)["session"]["id"] == "S-%d" % int(T0 + 4 * H),
          svc.snapshot(A)["session"])
    svc.settle(A, r2, 6)
    clk.t = T0 + 7 * D - 1
    v = svc.remaining(A)
    check("une seconde avant la fin de semaine : toujours 12 credits sur la semaine", v.week.used == 12 and v.week.opened, v.week)
    clk.t = T0 + 7 * D
    v = svc.remaining(A)
    check("a la seconde exacte : la semaine est refermee", not v.week.opened and v.week.used == 0, v.week)
    env.close()


def test_blocks():
    print("\n== refus : fenetre nommee, heure de renouvellement, plus grand renouvellement ==")
    env = Env()
    svc, clk = env.svc, env.clock
    for i in range(3):
        svc.settle(A, svc.reserve(A, 6, "mission", f"m{i}"), 6)
    b = svc.reserve(A, 6, "mission", "m3")          # reste 23 - 18 = 5
    check("Solo : 5 credits restants, 6 demandes -> refus de la SESSION avec l'heure exacte de renouvellement",
          isinstance(b, usage.UsageBlock) and b.limit == "session" and b.remaining == 5 and b.needed == 6 and b.resetsAtUtc == usage.iso(T0 + 4 * H), b)
    check("... un refus est falsy, une reservation est truthy", (not b) and bool(svc.reserve(A, 5, "mission", "m4")))
    check("... et le refus porte la vue (comme GET /api/usage)", b.view.session.remaining == 5 and b.view.binding == "session")
    clk.t = T0 + 4 * H + 1
    r = svc.reserve(A, 6, "mission", "m5")
    check("apres le renouvellement de la session, la mission passe", isinstance(r, usage.Reservation), r)
    svc.settle(A, r, 6)
    # semaine : 57 - 18 - 5(non regle: reservation m4 de 5 jamais reglee) ...
    env.close()

    env = Env()
    svc, clk = env.svc, env.clock
    svc.charge(A, 23, "mission", "s1")                   # session 1 : 23
    clk.t = T0 + 4 * H
    svc.charge(A, 23, "mission", "s2")                   # session 2 : 23 (semaine 46)
    clk.t = T0 + 8 * H
    svc.charge(A, 11, "mission", "s3")                   # session 3 : 11 (semaine 57 = pleine)
    v = svc.remaining(A)
    check("semaine pleine (57/57), session a 11/23", (v.week.remaining, v.session.remaining, v.binding) == (0, 12, "week"), v)
    b = svc.reserve(A, 6, "mission", "x")
    check("la semaine refuse : « week », renouvellement = fin de semaine (T0 + 7 j)", b.limit == "week" and b.resetsAtUtc == usage.iso(T0 + 7 * D), b)
    b = svc.reserve(A, 13, "mission", "y")
    check("session (12 restants) ET semaine refusent : on nomme celle qui se renouvelle le plus tard (la semaine), pas la session",
          b.limit == "week" and b.resetsAtUtc == usage.iso(T0 + 7 * D) and b.remaining == 0, b)
    clk.t = T0 + 7 * D
    check("au renouvellement de la semaine la mission passe", isinstance(svc.reserve(A, 13, "mission", "z"), usage.Reservation))
    env.close()

    env = Env(plans={A: pv_for("essai", 15, renews=None)})
    svc = env.svc
    v = svc.remaining(A)
    check("essai : les fenetres session et semaine ne s'appliquent pas, seul le mois (15 credits)",
          (v.windowsApply, v.session, v.week, v.month.limit, v.binding) == (False, None, None, 15, "month"), v)
    check("... 15 credits passent, le 16e est refuse par le MOIS sans renouvellement",
          isinstance(svc.reserve(A, 15, "mission", "e1"), usage.Reservation))
    b = svc.reserve(A, 1, "mission", "e2")
    check("... refus « month », resetsAtUtc vide (l'essai ne se renouvelle pas)", b.limit == "month" and b.resetsAtUtc is None, b)
    check("... et aucune fenetre de session n'a ete ouverte", svc.snapshot(A)["session"]["id"] is None)
    env.close()


def test_release_and_partial():
    print("\n== liberation, reglement partiel, reservation partielle ==")
    env = Env()
    svc = env.svc
    r = svc.reserve(A, 6, "mission", "m1")
    svc.release(A, r)
    s = svc.snapshot(A)
    check("reservation liberee sans rien consommer : session et semaine refermees (une erreur au premier appel n'ouvre rien)",
          s["session"]["id"] is None and s["week"]["id"] is None and not s["reservations"], s)
    svc.release(A, r)
    check("... liberer deux fois est sans effet (idempotent)", svc.snapshot(A)["reservations"] == {})
    svc.settle(A, "RSV-inconnu", 5)
    check("... un reglement inconnu est sans effet", svc.remaining(A).month.used == 0)
    r = svc.reserve(A, 12, "mission", "m2")
    svc.settle(A, r, 4)
    v = svc.remaining(A)
    check("reservation de 12, 4 consommes : seuls 4 sont debites, le reste est rendu", (v.session.used, v.session.reserved, v.session.remaining) == (4, 0, 19), v.session)
    r1 = svc.reserve(A, 1, "mission", "m3")
    svc.release(A, r1)
    check("... une liberation a 0 ne referme pas une fenetre deja entamee", svc.snapshot(A)["session"]["id"] is not None)
    svc.charge(A, 13, "mission", "m4")                         # session 17 + 0 -> reste 6
    p = svc.reserve(A, 36, "mission", "chloe", allow_partial=True, min_partial=6)
    check("Chloe : 36 credits voulus, 6 disponibles -> reservation partielle de 6 (un Worker)", isinstance(p, usage.Reservation) and p.credits == 6, p)
    b = svc.reserve(A, 36, "mission", "chloe2", allow_partial=True, min_partial=6)
    check("... plus rien : refus (le plancher partiel n'est pas atteint)", isinstance(b, usage.UsageBlock), b)
    env.close()


def test_concurrency_threads():
    print("\n== concurrence : 16 threads se disputent les 23 credits de la session ==")
    env = Env()
    svc = env.svc
    granted, lock = [], threading.Lock()

    def worker():
        for _ in range(5):
            r = svc.reserve(A, 1, "mission", "t")
            if isinstance(r, usage.Reservation):
                with lock:
                    granted.append(r)
    threads = [threading.Thread(target=worker) for _ in range(16)]
    [t.start() for t in threads]
    [t.join(60) for t in threads]
    s = svc.snapshot(A)
    check("exactement 23 reservations passent (80 tentatives)", len(granted) == 23, len(granted))
    check("... session.reserved = 23, jamais plus ; une seule ecriture par reservation (rev coherent)", s["session"]["reserved"] == 23 and len(s["reservations"]) == 23, s["session"])
    env.close()


CHILD = r"""
import sys, time
sys.path.insert(0, sys.argv[1])
import usage
svc = usage.UsageService(sys.argv[2], plan_view=lambda c: {"planId": "solo", "monthlyCredits": 250, "cycleStartUtc": "2026-10-12T10:11:12Z",
                          "renewsAtUtc": "2999-11-12T10:11:12Z", "exempt": False, "override": None}, now=lambda: float(sys.argv[3]), mode="on")
ok = 0
for _ in range(15):
    if svc.charge("CLI-CUST-AAAAAAAA", 1, "automation", "p") is None:
        ok += 1
print(ok)
"""


def test_concurrency_processes():
    print("\n== concurrence entre PROCESSUS (le serveur et quota-check.py ecrivent le meme grand livre) ==")
    env = Env()
    procs = [subprocess.Popen([sys.executable, "-c", CHILD, os.path.join(REPO, "dashboard"), env.root, str(T0)], stdout=subprocess.PIPE, text=True)
             for _ in range(4)]
    counts = []
    for p in procs:
        out, _ = p.communicate(timeout=120)
        counts.append(int(out.strip().splitlines()[-1]))
    s = env.svc.snapshot(A)
    check("4 processus x 15 tentatives sur 23 credits : 23 passent en tout", sum(counts) == 23, counts)
    check("... le grand livre dit 23 consommes (aucune ecriture perdue)", s["session"]["used"] == 23 and s["month"]["used"] == 23, s)
    check("... un seul fichier de grand livre, aucun fichier temporaire oublie",
          sorted(n for n in os.listdir(os.path.join(env.root, "runtime", "usage")) if not n.endswith(".lock")) == [A + ".json"])
    env.close()


def test_plan_change():
    print("\n== changement de forfait en cours de fenetre ==")
    env = Env()
    svc = env.svc
    svc.charge(A, 20, "mission", "m")
    check("Solo : session 20/23", svc.remaining(A).session.remaining == 3)
    env.plans[A] = pv_for("equipe", 900)
    v = svc.remaining(A)
    check("montee vers Equipe : les trois fenetres s'elargissent AU MEME INSTANT (83 / 207 / 900), les compteurs restent",
          (v.session.limit, v.week.limit, v.month.limit, v.session.used, v.session.remaining) == (83, 207, 900, 20, 63), v)
    check("... la session ouverte n'est pas remise a zero", v.session.startUtc == usage.iso(T0))
    env.plans[A] = pv_for("custom", 40)
    v = svc.remaining(A)
    check("descente vers un petit forfait : le reste ne devient jamais negatif, rien n'est rembourse",
          v.session.remaining == 0 and v.week.remaining == 0 and v.session.used == 20 and v.allowedNow == 0, v)
    b = svc.reserve(A, 1, "mission", "x")
    check("... et la mission est refusee", isinstance(b, usage.UsageBlock))
    env.plans[A] = pv_for("pro", 1500, cycle_start="2026-10-01T00:00:00Z", renews="2026-11-01T00:00:00Z")      # nouveau cycle (changement de forfait)
    v = svc.remaining(A)
    check("nouveau cycle de facturation : le mois repart a zero (traces absentes), session et semaine ne sont PAS remises a zero",
          v.month.used == 0 and v.session.used == 20 and v.session.limit == 138 and v.week.limit == 345, v)
    env.close()


def test_exempt_and_modes():
    print("\n== comptes exemptes et modes off / shadow / on ==")
    env = Env(plans={"CLI-DASHBOARD": pv_for("pro", 1250), A: pv_for("solo", 250)})
    svc = env.svc
    v = svc.remaining("CLI-DASHBOARD")
    r = svc.reserve("CLI-DASHBOARD", 500, "mission", "owner")
    check("proprietaire : exempte (aucune fenetre), reservation sans effet, aucun grand livre cree",
          v.exempt and v.allowedNow == usage.UNBOUNDED and r.exempt and r.id is None
          and not os.path.exists(os.path.join(env.root, "runtime", "usage", "CLI-DASHBOARD.json")), v)
    check("... son ordre de grandeur JSON : exempt vrai, allowedNow vide", v.to_dict()["exempt"] is True and v.to_dict()["allowedNow"] is None)
    env.close()

    env = Env(mode="off")
    r = env.svc.reserve(A, 100, "mission", "x")
    v = env.svc.remaining(A)
    check("mode off (BK_USAGE_WINDOWS=0) : service inerte, rien n'est refuse ni ecrit",
          r.exempt and v.exempt and not os.path.exists(os.path.join(env.root, "runtime", "usage")), (r, v))
    check("... month_used n'est pas fourni : l'appelant garde le balayage d'origine", env.svc.month_used(A) is None)
    env.close()

    env = Env(mode="shadow")
    svc = env.svc
    svc.charge(A, 23, "mission", "a")
    r = svc.reserve(A, 6, "mission", "b")
    check("mode shadow : rien n'est bloque (la session est pleine, la reservation passe)", isinstance(r, usage.Reservation) and r.id, r)
    ev = [f for k, f in env.events if k == "usage_would_block"]
    check("... mais le refus qui aurait eu lieu est journalise (fenetre, forfait, credits, renouvellement)",
          len(ev) == 1 and ev[0]["limit"] == "session" and ev[0]["planId"] == "solo" and ev[0]["needed"] == 6 and ev[0]["clientId"] == A
          and ev[0]["resetsAtUtc"] == usage.iso(T0 + 4 * H), ev)
    check("... la consommation est bien enregistree (le grand livre se calibre pendant la semaine d'observation)",
          svc.snapshot(A)["session"]["used"] == 23 and svc.snapshot(A)["session"]["reserved"] == 6)
    env.close()


def test_expired_reservation():
    print("\n== reservation echue ==")
    env = Env(resolve_expired=lambda client, r: 4 if r.get("ref") == "PRJ-X:S1" else None)
    svc, clk = env.svc, env.clock
    svc.reserve(A, 6, "project_step", "PRJ-X:S1", ttl_s=30)
    svc.reserve(A, 5, "mission", "MSN-lost", ttl_s=30)
    check("avant l'echeance : 11 credits retenus", svc.remaining(A).session.reserved == 11)
    clk.t = T0 + 31
    v = svc.remaining(A)
    check("apres l'echeance : la lecture ne les compte plus (ni reservation fantome qui bloque le client)", v.session.reserved == 0, v.session)
    svc.reserve(A, 1, "mission", "next")
    s = svc.snapshot(A)
    check("a la prochaine ecriture : l'etape de projet est reglee d'apres son cost.json (4), la mission perdue est liberee a 0",
          s["session"]["used"] == 4 and len(s["reservations"]) == 1, s["session"])
    check("... et l'evenement est journalise", sum(1 for k, _ in env.events if k == "usage_reservation_expired") == 2, env.events)
    env.close()


def test_seed_and_reconcile():
    print("\n== amorcage depuis les traces, reconciliation (200 traces) ==")
    env = Env()
    env.write_task(A, 10, T0 - 2 * H)
    env.write_task(A, 5, T0 - 10 * D)                         # avant le cycle (12 octobre) : hors du mois
    env.write_task(A, 0, T0 - H, Status="SECURITY_BLOCKED")
    env.write_task(B, 99, T0 - H)                             # un autre client : jamais compte pour A
    v = env.svc.remaining(A)
    check("premier acces : le mois est amorce depuis les traces du cycle (10, pas 15 ni 109)", v.month.used == 10, v.month)
    check("... la session et la semaine sont reconstruites (une session ouverte il y a 2 h, 10 credits)",
          v.session.opened and v.session.used == 10 and v.session.resetsAtUtc == usage.iso(T0 + 2 * H) and v.week.used == 10, v.session)
    env.close()

    env = Env()
    import random
    rnd = random.Random(7)
    total = 0
    cycle_start = usage.parse_iso(CYCLE_START)
    for i in range(200):
        c = rnd.randint(1, 3)
        total += c
        env.write_task(A, c, cycle_start + 60 + i * 3000)       # etale sur le cycle, tout avant T0 + 1 j
    env.clock.t = cycle_start + 60 + 199 * 3000 + 100
    v = env.svc.remaining(A)
    check("200 traces : le grand livre amorce egale le balayage independant", v.month.used == total, (v.month.used, total))
    for i in range(20):
        env.write_task(A, 2, env.clock.t - 600 + i)                 # 20 missions dont le reglement s'est perdu (crash)
    rep = env.svc.reconcile(A)
    check("reconciliation : l'ecart (40 credits) est releve et corrige", rep["corrected"] and rep["drift"]["month"] == -40, rep)
    check("... le mois egale a nouveau le balayage (tasks jamais modifiees)", env.svc.remaining(A).month.used == total + 40, env.svc.remaining(A).month)
    check("... la derive est consignee dans le grand livre et dans le journal", env.svc.snapshot(A)["drift"] >= 40
          and any(k == "usage_drift_corrected" for k, _ in env.events))
    rep2 = env.svc.reconcile(A)
    check("... une seconde reconciliation ne trouve plus d'ecart", not rep2["corrected"], rep2)
    check("get_billing-like : month_used = grand livre", env.svc.month_used(A) == total + 40)
    env.close()

    env = Env()
    env.svc.charge(A, 7, "mission", "x")                       # le grand livre dit 7, aucune trace
    rep = env.svc.reconcile(A)
    check("sans trace, un credit « fantome » du grand livre (automatisation sans mission livree) est corrige a 0 (les traces font foi)",
          rep["corrected"] and env.svc.remaining(A).month.used == 0, rep)
    env.close()


def test_project_credits_survive_reconcile():
    print("\n== credits de projet : jamais effaces par la reconciliation ==")
    env = Env()
    env.svc.charge(A, 10, "project_step", "PRJ-1:S1")
    env.svc.charge(A, 3, "mission", "m")
    env.write_task(A, 3, T0)
    rep = env.svc.reconcile(A)
    v = env.svc.remaining(A)
    check("aucun cost-ledger.jsonl : les 10 credits d'etapes de projet restent (seule la part « missions » est recomptee d'apres les traces)",
          v.month.used == 13 and v.session.used == 13 and not rep["drift"].get("month"), (v.month, rep))
    d = os.path.join(env.root, "runtime", "projects", A, "PRJ-1")
    os.makedirs(d)
    with open(os.path.join(d, "cost-ledger.jsonl"), "w", encoding="utf-8") as f:
        f.write(json.dumps({"ts": usage.iso(T0), "credits": 12}) + "\n" + "pas du json\n" + json.dumps({"ts": usage.iso(T0 + 5), "credits": 4}) + "\n")
    rep = env.svc.reconcile(A)
    check("avec un cost-ledger.jsonl plus complet (16 credits), la reconciliation releve vers les traces (16 + 3 = 19)",
          env.svc.remaining(A).month.used == 19 and rep["drift"]["month"] == -6, (env.svc.remaining(A).month, rep))
    env.close()


def test_reconcile_never_double_counts():
    print("\n== reconciliation periodique : jamais pendant une mission en cours ; mission perdue recomptee d'apres ses traces ==")
    env = Env(limits={"reconcileIntervalSec": 60})
    svc, clk = env.svc, env.clock
    first = svc.reserve(A, 6, "mission", "MSN-1")                 # Chloe, deux Workers : la mission court
    clk.advance(300)                                               # la reconciliation periodique est due (la reservation, 12 min, court encore)
    env.write_task(A, 3, clk.t - 60)                               # le premier Worker a deja ecrit sa trace
    second = svc.reserve(A, 6, "mission", "MSN-2")               # une autre mission demarre PENDANT la premiere
    check("reservation pendant une mission en cours : aucune reconciliation (la trace partielle n'est pas comptee en plus du reglement)",
          svc.snapshot(A)["session"]["used"] == 0 and svc.snapshot(A)["lastReconcileUtc"] == usage.iso(T0), svc.snapshot(A)["session"])
    svc.settle(A, first, 3)
    svc.release(A, second)
    svc.reserve(A, 1, "mission", "MSN-3")                          # plus rien ne court : la reconciliation passe
    s = svc.snapshot(A)
    check("... puis, plus rien ne courant, la reconciliation passe et trouve 3 credits (pas 6)",
          s["session"]["used"] == 3 and s["month"]["used"] == 3 and s["lastReconcileUtc"] == usage.iso(clk.t), s["session"])
    env.close()

    env = Env()                                                    # reconciliation periodique lointaine : seule l'echeance la declenche
    svc, clk = env.svc, env.clock
    svc.reserve(A, 6, "mission", "MSN-lost", ttl_s=30)            # le processus meurt apres avoir livre
    env.write_task(A, 6, T0 + 10)
    clk.advance(31)
    svc.reserve(A, 1, "mission", "MSN-next")
    s = svc.snapshot(A)
    check("mission a reservation echue : liberee a 0 puis recomptee d'apres sa trace TASK-*.json (6 credits)",
          s["session"]["used"] == 6 and s["month"]["used"] == 6 and s["session"]["reserved"] == 1, s["session"])
    svc.reserve(A, 2, "mission", "MSN-boot")
    env.write_task(A, 2, clk.t)
    svc2 = usage.UsageService(env.root, plan_view=lambda c: dict(env.plans[c]), now=clk, mode="on", limits={"reconcileIntervalSec": 10 ** 7})
    svc2.reap(boot=True)
    check("reap(boot) : les missions orphelines sont liberees", svc2.snapshot(A)["reservations"] == {} and svc2.snapshot(A)["session"]["used"] == 6)
    svc2.reserve(A, 1, "mission", "after-boot")
    s = svc2.snapshot(A)
    check("... et leurs credits deja traces sont recomptes a la premiere ecriture (6 + 2 = 8, la mission livree avant l'arret n'est pas offerte)",
          s["session"]["used"] == 8 and s["month"]["used"] == 8, s["session"])
    env.close()


def test_clock_skew():
    print("\n== derive d'horloge ==")
    env = Env()
    svc, clk = env.svc, env.clock
    svc.charge(A, 20, "mission", "a")
    clk.t = T0 - 3600                                         # l'horloge recule d'une heure
    v = svc.remaining(A)
    check("horloge en arriere : la session ouverte continue de compter (20/23), aucune erreur", v.session.used == 20 and v.session.opened, v.session)
    check("... et un nouvel appel ne rouvre pas une seconde session", isinstance(svc.reserve(A, 3, "mission", "b"), usage.Reservation)
          and svc.snapshot(A)["session"]["startUtc"] == usage.iso(T0))
    clk.t = T0 + 30 * D
    v = svc.remaining(A)
    check("saut en avant d'un mois : session et semaine refermees (le mois aussi est ecoule : traces absentes)", not v.session.opened and not v.week.opened and v.session.used == 0, v)
    env.close()


def test_events_do_not_deadlock():
    print("\n== le journal est ecrit APRES la liberation du verrou (le journal du serveur prend le verrou global) ==")
    env = Env(mode="shadow")
    svc = env.svc
    done = []

    def log_calls_back(kind, **fields):
        svc.remaining(A)                                      # reprend le verrou du client si l'evenement etait emis sous verrou
        done.append(kind)
    svc._log = log_calls_back
    svc.charge(A, 23, "mission", "a")

    def run():
        svc.reserve(A, 6, "mission", "b")
    t = threading.Thread(target=run)
    t.start()
    t.join(20)
    check("reserve en shadow avec un journal qui rappelle le service : termine, evenement livre", not t.is_alive() and "usage_would_block" in done, done)
    env.close()


def test_boot_reap_purge_ids():
    print("\n== reprise au demarrage, suppression de compte, identifiants ==")
    env = Env()
    env.svc.reserve(A, 6, "mission", "orph")
    env.svc.reserve(A, 6, "project_step", "PRJ:S1", ttl_s=900)
    svc2 = usage.UsageService(env.root, plan_view=lambda c: dict(env.plans[c]), now=env.clock, mode="on")
    freed = svc2.reap(boot=True)
    s = svc2.snapshot(A)
    check("reap(boot) : la mission orpheline est liberee, l'etape de projet (delai non echu) est conservee", freed == 1 and len(s["reservations"]) == 1, (freed, s["reservations"]))
    svc2.purge(A)
    check("purge : le grand livre du compte disparait", svc2.snapshot(A) is None)
    ok = False
    try:
        svc2.snapshot("../evil")
    except ValueError:
        ok = True
    check("identifiant client hors motif : refuse (aucun acces hors de runtime/usage)", ok)
    env.close()


def test_serialisation():
    print("\n== grand livre et JSON de l'API ==")
    env = Env()
    env.svc.settle(A, env.svc.reserve(A, 6, "mission", "t"), 6)
    s = env.svc.snapshot(A)
    check("grand livre BK-USAGE-LIMITS : schema, rev, trois fenetres, reservations, recent",
          s["schema"] == "BK-USAGE-LEDGER-V1" and s["rev"] >= 2 and all(k in s for k in ("session", "week", "month", "reservations", "recent", "lastReconcileUtc", "drift"))
          and s["recent"][-1]["credits"] == 6, s)
    d = env.svc.remaining(A).to_dict()
    check("GET /api/usage : session {limit, used, reserved, remaining, opened, startUtc, resetsAtUtc, windowHours:4}",
          d["session"]["windowHours"] == 4 and set(("limit", "used", "reserved", "remaining", "opened", "startUtc", "resetsAtUtc")) <= set(d["session"]) and d["week"]["windowDays"] == 7, d)
    check("... binding, allowedNow, nextRenewalUtc", d["binding"] == "session" and d["allowedNow"] == 17 and d["nextRenewalUtc"] == usage.iso(T0 + 4 * H), d)
    json.dumps(d)
    check("fr_duration / fr_when : « dans 1 h 12 », « demain a … », « le lundi … »",
          usage.fr_duration(72 * 60) == "1 h 12" and usage.fr_duration(35 * 60 - 5) == "35 min" and usage.fr_duration(6 * D + 21 * H) == "6 j 21 h"
          and usage.fr_when(T0 + 4 * H, T0, "UTC").startswith("à ") and usage.fr_when(T0 + D, T0, "UTC").startswith("demain à ")
          and usage.fr_when(T0 + 3 * D, T0, "UTC").startswith("le vendredi 23 octobre à "), usage.fr_when(T0 + 3 * D, T0, "UTC"))
    env.close()


def main():
    for fn in (test_allocations, test_window_lifecycle, test_blocks, test_release_and_partial, test_concurrency_threads, test_concurrency_processes,
               test_plan_change, test_exempt_and_modes, test_expired_reservation, test_seed_and_reconcile, test_project_credits_survive_reconcile, test_reconcile_never_double_counts, test_clock_skew,
               test_events_do_not_deadlock, test_boot_reap_purge_ids, test_serialisation):
        fn()
    return finish("tests/usage/test_usage_core.py")


if __name__ == "__main__":
    sys.exit(main())
