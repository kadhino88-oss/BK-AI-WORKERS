# -*- coding: utf-8 -*-
"""Bout en bout : le VRAI dashboard/server.py est demarre sur une COPIE jetable du depot (port libre, jamais les vraies donnees), avec des comptes clients et
le proprietaire (porte). On verifie en HTTP la grille de prix et le modele de quota (docs/PRICING.md) :

  - les pages servies : la page Tarifs, l'accueil (plus de phrase comparative), la FAQ et les CGV, l'application (nouvelle grille, aide par activite) ;
  - /api/mission-levels et /api/billing : echelle 1 / 6 / 12, essai verrouille sur Rapide, choix de forfait (Solo, Trio, Equipe, Pro, Scale, Enterprise sur devis),
    date de renouvellement, forfait suivant ;
  - /api/billing/plan : jamais de bascule gratuite vers Solo / Trio / Equipe, Enterprise sur devis, forfaits heritages refuses, essai non selectionnable ;
  - activation par le proprietaire (/api/admin/set-plan) avec plafond contractuel, refusee sans la porte ;
  - quota atteint : HTTP 402 avec le message francais ET la carte de montee en gamme ; le quota est controle au niveau DEMANDE sur toutes les routes de
    mission, et au niveau Rapide (1 credit) pour les automatisations ;
  - la recharge de credits n'existe pas pour un client.

Aucun modele ni reseau n'est appele (les routes testees refusent AVANT toute mission, ou echouent sur un objectif vide APRES le controle du quota).
Lancer : python tests/pricing/e2e_server.py      (Windows ou Linux/WSL ; python 3 ; PowerShell 7 pour l'etat Stripe)
"""
import datetime
import hashlib
import http.cookiejar
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SKIP_TOP = {".git", ".claude", ".secrets", "_archive", "runtime", "node_modules", "__pycache__", "tests", "docs"}
PASSWORD = "e2e-" + os.urandom(6).hex()
GATE_PASSWORD = "gate-" + os.urandom(6).hex()
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
failures = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{str(detail)[:300]}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def ignore(directory, names):
    rel = os.path.relpath(directory, REPO).replace("\\", "/")
    skip = {n for n in names if n == "__pycache__" or (rel == "." and n in SKIP_TOP)}
    if rel == "memory":
        skip.add("runtime")
    if rel == "core/accounts":
        skip.add("data")
    if rel in ("core/billing", "core/automation", "core/profile", "core/leads", "core/hire"):
        skip |= {"data", "runs"}
    if rel == "core/connectors":
        skip.add("client-credentials")
    if rel == "dashboard":
        skip.add(".gate")
    return skip


class Client:
    def __init__(self, port, ip="198.51.100.1"):
        self.base = f"http://127.0.0.1:{port}"
        self.ip = ip
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method, path, body=None, headers=None):
        data = json.dumps(body).encode() if body is not None else None
        h = {"Content-Type": "application/json", "X-Forwarded-For": self.ip}
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=60) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def json(self, method, path, body=None):
        st, raw = self.call(method, path, body)
        try:
            return st, json.loads(raw.decode("utf-8"))
        except ValueError:
            return st, {"raw": raw[:200].decode("utf-8", "replace")}

    def get(self, path):
        return self.json("GET", path)

    def post(self, path, body=None):
        return self.json("POST", path, body if body is not None else {})

    def text(self, path):
        st, raw = self.call("GET", path)
        return st, raw.decode("utf-8", "replace")


def signup(port, email, ip):
    c = Client(port, ip)
    st, out = c.post("/api/account/signup", {"email": email, "password": PASSWORD, "companyName": "Test " + email})
    assert st == 200, (st, out)
    st, me = c.get("/api/account/me")
    assert me.get("clientId"), me
    return c, me["clientId"]


def gate_hash(password):
    salt = os.urandom(16)
    return f"{salt.hex()}:{hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 1000, dklen=32).hex()}:1000"


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def main():
    root = tempfile.mkdtemp(prefix="bkpricing-e2e-")
    server = None
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=ignore)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR", "BK_LEVELS")}
        env.update(BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}", BK_STATUS_DISABLE="1",
                   BK_GATE_HASH=gate_hash(GATE_PASSWORD))
        if PWSH:
            env["BK_PWSH"] = PWSH
        server = subprocess.Popen([sys.executable, "-u", os.path.join(app, "dashboard", "server.py")], cwd=app, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        anon = Client(port, "198.51.100.90")
        end = time.time() + 60
        while time.time() < end:
            try:
                if anon.call("GET", "/api/health")[0] == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            raise SystemExit("serveur non demarre")

        alice, a_id = signup(port, "alice@mail-test.example", "198.51.100.11")
        bob, b_id = signup(port, "bob@mail-test.example", "198.51.100.12")
        owner = Client(port, "198.51.100.99")
        st, _ = owner.post("/api/gate/login", {"password": GATE_PASSWORD})
        assert st == 200, "connexion proprietaire"
        tasks_dir = os.path.join(app, "runtime", "tasks")
        billing_dir = os.path.join(app, "core", "billing", "data")

        def seed_usage(client, credits, created="2999-01-01T00:00:00Z", n=[0]):
            n[0] += 1
            os.makedirs(tasks_dir, exist_ok=True)
            tid = "%032X" % (0xE2E0000 + n[0])
            with open(os.path.join(tasks_dir, f"TASK-{tid}.json"), "w", encoding="utf-8") as f:
                json.dump({"TaskId": f"TASK-{tid}", "ClientId": client, "Credits": credits, "CreatedAtUtc": created}, f)

        def now_iso():
            return datetime.datetime.utcnow().isoformat() + "Z"

        def clear_usage():
            shutil.rmtree(tasks_dir, ignore_errors=True)

        # ------------------------------------------------------------------------------------------------ pages servies
        print("\n== pages servies ==")
        st, tarifs = anon.text("/tarifs.html")
        check("/tarifs.html : la nouvelle grille et l'echelle de credits",
              st == 200 and all(x in tarifs for x in ("29 CHF", "59 CHF", "99 CHF", "139 CHF", "449 CHF", "Choisissez le Worker de votre activité", "6 crédits par mission",
                                                     "Plafond de crédits mensuel fixé par contrat")), tarifs[:200])
        check("/tarifs.html : ni Starter, ni Business, ni ancien prix, ni forfait illimite",
              not any(x in tarifs for x in ("Starter", "Business")) and not re.search(r"39 CHF|390 CHF", tarifs)
              and "illimité" not in tarifs.replace("ni missions illimitées", ""))
        st, home = anon.text("/")
        check("accueil : plus de phrase comparative, message neutre a la place",
              st == 200 and "moins cher" not in home and "au moins 5" not in home and "Dès <span data-chf=\"29\">CHF 29</span> par mois, sans engagement" in home)
        check("accueil : l'aide « Quel Worker pour mon activite ? » est dans la page Tarifs", 'id="activity-helper"' in home and "Quel Worker pour mon activité ?" in home)
        st, appjs = anon.text("/app.js")
        check("app.js : nouvelle grille, aide par activite, aucun prix en dur dans le billing",
              all(x in appjs for x in ('id: "solo"', "ACTIVITY_WORKERS", "const PRICING_PLANS")) and "BILLING_PLAN_PRICES" not in appjs and "rechargeBillingCredits" not in appjs)
        st, faq = anon.text("/faq.html")
        st2, cgv = anon.text("/cgv.html")
        check("FAQ et CGV : quota mensuel fixe, ni recharge ni forfait illimite",
              "quota mensuel fixe" in faq and "quota de crédits mensuel fixe" in cgv and "Le client peut recharger" not in cgv and "recharge de crédits et annulation" not in faq)

        # ------------------------------------------------------------------------------------------------ niveaux et forfaits
        print("\n== niveaux de travail et choix de forfait ==")
        st, lv = anon.get("/api/mission-levels")
        check("niveaux : actifs par defaut, echelle 1 / 6 / 12, defaut equilibre",
              st == 200 and [(l["id"], l["credits"]) for l in lv["levels"]] == [("rapide", 1), ("equilibre", 6), ("approfondi", 12)] and lv["default"] == "equilibre", lv)
        st, lv = alice.get("/api/mission-levels")
        check("compte a l'essai : seul Rapide est propose (verrouille)", [l["id"] for l in lv["levels"]] == ["rapide"] and lv["locked"] is True, lv)
        st, lv = alice.get("/api/mission-levels?scale=public")
        check("... mais la page Tarifs lit l'echelle publique complete (1 / 6 / 12), meme connecte a l'essai",
              st == 200 and [(l["id"], l["credits"]) for l in lv["levels"]] == [("rapide", 1), ("equilibre", 6), ("approfondi", 12)], lv)
        st, bill = alice.get("/api/billing")
        check("essai : 15 credits, pas de renouvellement, jamais illimite, niveaux verrouilles",
              st == 200 and bill["planId"] == "essai" and bill["creditsTotal"] == 15 and bill["renewsAtUtc"] is None and bill["unlimited"] is False
              and bill["missionLevels"]["locked"] is True, bill)
        check("choix de forfait : Solo, Trio, Equipe, Pro, Scale, Enterprise (ni l'essai, ni les forfaits heritages)",
              [p["planId"] for p in bill["availablePlans"]] == ["solo", "trio", "equipe", "pro", "scale", "enterprise"], bill["availablePlans"])
        by_id = {p["planId"]: p for p in bill["availablePlans"]}
        check("prix et credits du choix de forfait = la grille validee",
              [(by_id[p]["credits"], by_id[p]["priceChf"]["month"], by_id[p]["priceChf"]["year"]) for p in ("solo", "trio", "equipe", "pro", "scale")]
              == [(250, 29, 290), (500, 59, 590), (900, 99, 990), (1250, 139, 1390), (4000, 449, 4490)] and by_id["enterprise"]["onQuote"] is True, by_id)
        check("le forfait suivant de l'essai est Solo (250 credits, CHF 29)", bill["upgrade"]["next"]["planId"] == "solo" and bill["upgrade"]["next"]["priceChf"]["month"] == 29, bill["upgrade"])

        print("\n== POST /api/billing/plan : aucune bascule gratuite ==")
        for plan, status, code in (("solo", 403, "PLAN_BY_INVOICE"), ("trio", 403, "PLAN_BY_INVOICE"), ("equipe", 403, "PLAN_BY_INVOICE"),
                                   ("pro", 403, "PLAN_BY_INVOICE"), ("scale", 403, "PLAN_BY_INVOICE"),       # revue du 2026-10-13 : plus de simulation gratuite
                                   ("enterprise", 403, "PLAN_ON_QUOTE"), ("starter", 403, "PLAN_NOT_SOLD"), ("business", 403, "PLAN_NOT_SOLD"),
                                   ("essai", 403, "PLAN_NOT_SELECTABLE"), ("gratuit", 400, "UNKNOWN_PLAN")):
            st, out = alice.post("/api/billing/plan", {"planId": plan})
            check(f"alice -> {plan} : {status} {code}", st == status and out.get("error") == code, (st, out))
        st, out = anon.post("/api/billing/plan", {"planId": "solo"})
        check("sans compte : 401", st == 401, (st, out))
        st, bill = alice.get("/api/billing")
        check("rien n'a change : toujours a l'essai", bill["planId"] == "essai" and bill["creditsTotal"] == 15, bill["planId"])
        st, out = alice.post("/api/billing/recharge", {"amount": 500})
        check("recharge de credits : refusee pour un client (403), aucun credit ajoute", st == 403 and out.get("error") == "RECHARGE_NOT_AVAILABLE", (st, out))
        st, bill = alice.get("/api/billing")
        check("... le total reste 15", bill["creditsTotal"] == 15, bill["creditsTotal"])
        st, out = alice.post("/api/billing/cancel")
        check("« annuler » a l'essai ne redonne rien", st == 200 and out["planId"] == "essai" and out["creditsTotal"] == 15, out)

        # ------------------------------------------------------------------------------------------------ activation par le proprietaire
        print("\n== activation par le proprietaire (/api/admin/set-plan) ==")
        body = {"clientId": a_id, "planId": "equipe"}
        st, out = anon.post("/api/admin/set-plan", body)
        check("sans porte : 401 GATE_REQUIRED", st == 401 and out.get("error") == "GATE_REQUIRED", (st, out))
        st, out = alice.post("/api/admin/set-plan", body)
        check("un client ne peut pas s'attribuer un forfait (la session client ne suffit pas)", st == 401, (st, out))
        check("... rien n'a ete accorde", read_json(os.path.join(billing_dir, a_id + ".json"), {}).get("planId") == "essai")
        for payload, status, code in (({"clientId": a_id, "planId": "solo"}, 400, "INVALID_PLAN"), ({"clientId": a_id, "planId": "essai"}, 400, "INVALID_PLAN"),
                                      ({"clientId": a_id, "planId": "pro", "contractCredits": 5000}, 400, "CAP_NOT_ALLOWED"),
                                      ({"clientId": a_id, "planId": "enterprise", "contractCredits": 0}, 400, "INVALID_CAP"),
                                      ({"clientId": a_id, "planId": "enterprise", "contractCredits": 99999999}, 400, "INVALID_CAP"),
                                      ({"clientId": a_id, "planId": "enterprise", "contractCredits": "illimite"}, 400, "INVALID_CAP"),
                                      ({"clientId": "CLI-CUST-00000000", "planId": "pro"}, 404, "CLIENT_NOT_FOUND")):
            st, out = owner.post("/api/admin/set-plan", payload)
            check(f"set-plan invalide {json.dumps(payload)[:70]} -> {code}", st == status and out.get("error") == code, (st, out))
        st, out = owner.post("/api/admin/set-plan", body)
        check("proprietaire : Equipe accordee a alice (900 credits, renouvellement date, periode payee d'un mois)",
              st == 200 and out["credits"] == 900 and out["renewsAtUtc"] and out["paidUntilUtc"], (st, out))
        st, out = owner.post("/api/admin/set-plan", {"clientId": a_id, "planId": "equipe", "paidMonths": 0})
        check("mois factures invalides : 400 INVALID_PERIOD, rien ne change", st == 400 and out.get("error") == "INVALID_PERIOD", (st, out))
        st, bill = alice.get("/api/billing")
        check("alice voit Equipe, 900 credits, le forfait suivant Pro (1250 credits, CHF 139), niveaux libres",
              bill["planId"] == "equipe" and bill["creditsTotal"] == 900 and bill["upgrade"]["next"]["planId"] == "pro" and bill["upgrade"]["next"]["credits"] == 1250
              and bill["missionLevels"]["locked"] is False and len(bill["missionLevels"]["levels"]) == 3, bill)
        st, out = alice.post("/api/billing/plan", {"planId": "equipe"})
        check("redemander le forfait actuel : aucun effet", st == 200 and out["planId"] == "equipe", (st, out))
        st, lv = alice.get("/api/mission-levels")
        check("... et les trois niveaux sont proposes", len(lv["levels"]) == 3 and lv["locked"] is False, lv)

        # ------------------------------------------------------------------------------------------------ quota atteint
        print("\n== quota atteint : message, carte de montee en gamme, niveau controle ==")
        seed_usage(a_id, 895)                                          # il reste 5 credits sur 900
        st, bill = alice.get("/api/billing")
        check("95 % consommes : le bouton « Passer a la formule superieure » est propose", bill["upgradeSuggested"] is True and bill["percentUsed"] >= 80, bill["percentUsed"])
        for path in ("/api/workers/alex/task", "/api/workers/alex/task/async", "/api/chloe/task", "/api/chloe/task/async"):
            st, out = alice.post(path, {"objective": "Un bref resume", "level": "equilibre"})
            check(f"{path} au niveau Equilibre (6 credits, il en reste 5) : 402 + carte de montee en gamme",
                  st == 402 and out.get("error") == "SUBSCRIPTION_REQUIRED" and "Il vous reste 5 crédit(s), ce niveau en demande 6" in out["detail"]
                  and out["upgrade"]["next"]["planId"] == "pro", (st, out))
        for path in ("/api/workers/alex/task", "/api/workers/alex/task/async"):
            st, out = alice.post(path, {"objective": "", "level": "rapide"})
            check(f"{path} au niveau Rapide (1 credit) : le quota passe (400 OBJECTIVE_REQUIRED apres le controle)", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        st, out = alice.post("/api/workers/alex/task", {"objective": "", "level": "approfondi"})
        check("... Approfondi (12 credits) est refuse sur la route synchrone aussi (avant : controle au niveau par defaut)", st == 402, (st, out))
        st, out = alice.post("/api/automations", {"workerId": "alex", "objective": "Rapport hebdo", "frequencyMinutes": 1})
        check("automatisation : controlee a 1 credit (Rapide) -> passe le quota, refuse la frequence (400)", st == 400 and out.get("error") == "INVALID_FREQUENCY", (st, out))
        seed_usage(a_id, 5)                                            # plus aucun credit
        st, out = alice.post("/api/workers/alex/task", {"objective": "bonjour", "level": "rapide"})
        check("quota epuise : message avec credits inclus, date de renouvellement et forfait suivant",
              st == 402 and "le forfait Équipe inclut 900 crédits par mois, valable jusqu'au" in out["detail"]      # active sur facture : rien ne se renouvelle avant le reglement suivant
              and "il se reconduit à la réception du règlement de la facture suivante" in out["detail"]
              and "passez au forfait Pro (1 250 crédits par mois, CHF 139 par mois)" in out["detail"], (st, out))
        card = out["upgrade"]
        check("... et la carte : forfait actuel, credits inclus, renouvellement, forfait suivant avec son prix",
              card["planId"] == "equipe" and card["creditsIncluded"] == 900 and card["renewsAtUtc"] and card["next"]["priceChf"] == {"month": 139, "year": 1390}
              and card["next"]["selfService"] is True, card)
        st, out = alice.post("/api/automations", {"workerId": "alex", "objective": "Rapport hebdo", "frequencyMinutes": 60})
        check("automatisation sans credit : 402 aussi (le quota est mensuel et fixe)", st == 402 and out.get("upgrade", {}).get("next", {}).get("planId") == "pro", (st, out))
        st, bill = alice.get("/api/billing")
        check("jamais de depassement : 900 credits, 900 utilises, 0 restant", bill["creditsTotal"] == 900 and bill["creditsUsed"] == 900 and bill["creditsRemaining"] == 0, bill)

        # ------------------------------------------------------------------------------------------------ Enterprise : plafond contractuel
        print("\n== Enterprise : plafond contractuel, jamais illimite ==")
        clear_usage()
        st, out = owner.post("/api/admin/set-plan", {"clientId": b_id, "planId": "enterprise", "contractCredits": 12000})
        check("proprietaire : Enterprise avec un plafond de 12 000 credits", st == 200 and out["credits"] == 12000, (st, out))
        st, bill = bob.get("/api/billing")
        check("bob : 12 000 credits par mois, pas d'illimite, aucun forfait suivant", bill["creditsTotal"] == 12000 and bill["unlimited"] is False and bill["upgrade"]["next"] is None, bill)
        seed_usage(b_id, 12000)
        st, out = bob.post("/api/workers/alex/task", {"objective": "bonjour", "level": "rapide"})
        check("plafond atteint : 402 et « ecrivez-nous pour relever le plafond de votre contrat »",
              st == 402 and "relever le plafond de votre contrat" in out["detail"] and out["upgrade"]["next"] is None, (st, out))
        st, out = owner.post("/api/admin/set-plan", {"clientId": b_id, "planId": "enterprise"})
        check("Enterprise reconduit sans repeter le plafond : celui du contrat (12 000) est garde, jamais ramene a 10 000 (2e revue)", st == 200 and out["credits"] == 12000, (st, out))
        st, out = owner.post("/api/admin/set-plan", {"clientId": b_id, "planId": "scale"})
        st, out = owner.post("/api/admin/set-plan", {"clientId": b_id, "planId": "enterprise"})
        check("Enterprise active pour la premiere fois sans plafond saisi : le plafond par defaut documente (10 000), jamais illimite", st == 200 and out["credits"] == 10000, (st, out))
        clear_usage()
        seed_usage(a_id, 900, created=now_iso())                       # alice (Equipe) a tout consomme
        st, out = alice.post("/api/workers/alex/task", {"objective": "", "level": "rapide"})
        check("alice a epuise son quota Equipe : 402", st == 402, (st, out))
        time.sleep(0.05)
        st, out = owner.post("/api/admin/set-plan", {"clientId": a_id, "planId": "scale"})
        check("proprietaire : Scale accorde (facture reglee), nouveau cycle", st == 200 and out["credits"] == 4000, (st, out))
        st, bill = alice.get("/api/billing")
        check("... alice repart avec tout son quota Scale ; le forfait suivant est Enterprise, sur devis",
              bill["creditsTotal"] == 4000 and bill["creditsUsed"] == 0 and bill["upgrade"]["next"]["planId"] == "enterprise"
              and bill["upgrade"]["next"]["onQuote"] is True and bill["upgrade"]["next"]["selfService"] is False, bill)
        st, out = alice.post("/api/workers/alex/task", {"objective": "", "level": "rapide"})
        check("... et repasse le controle du quota (400 OBJECTIVE_REQUIRED)", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except Exception:
                server.kill()
        shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} echec(s) :")
        for f in failures:
            print("  - " + f)
        sys.exit(1)
    print("Tout est vert.")


if __name__ == "__main__":
    main()
