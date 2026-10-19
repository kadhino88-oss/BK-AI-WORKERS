# -*- coding: utf-8 -*-
"""Bout en bout des limites d'usage : le VRAI dashboard/server.py est demarre sur une COPIE jetable du depot (port libre, jamais les vraies donnees) avec
BK_USAGE_WINDOWS=1, deux comptes clients (alice : Equipe, bob : Pro), le proprietaire (porte) et un FAUX Submit-Task.ps1 (une mission = des traces
TASK-*.json comme le vrai script, aucun modele, aucun reseau, aucun secret). On verifie en HTTP :

  - GET /api/usage-limits (public) et GET /api/usage (compte) : les trois fenetres, le proprietaire exempt, le refus sans compte ;
  - la mission passe par la porte, reserve puis regle : la session s'ouvre a la premiere mission, les credits se comptent ;
  - session epuisee : HTTP 402 USAGE_LIMIT_REACHED qui nomme la fenetre, l'heure exacte du renouvellement (4 h apres la premiere mission) et le forfait
    du dessus avec ses chiffres ; la route asynchrone refuse de la meme facon et AUCUN sous-processus de mission n'est lance ;
  - isolation : les missions d'alice ne consomment rien chez bob ; le proprietaire n'est jamais limite ;
  - get_billing : bloc usage, limites par forfait, creditsUsed du grand livre ; pages Tarifs, FAQ et Facturation, anglais, interface (pastille, jauges) ;
  - automatisations : quota-check.py (autre processus) debite et saute sans erreur quand la session est pleine ;
  - export et suppression du compte.

Lancer : python tests/usage/e2e_server.py      (Windows ou Linux/WSL ; python 3 ; PowerShell present pour le faux Submit-Task)
"""
import datetime
import hashlib
import http.cookiejar
import json
import os
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

STUB = r'''param([string]$Request = "", [string]$WorkerId = "", [switch]$PlanOnly, [string]$ClientId = "", [string]$OutFile = "")
# Faux Submit-Task.ps1 (tests/usage/e2e_server.py) : ecrit les traces TASK-*.json et le fichier de sortie comme le vrai script. Aucun modele.
$level = $env:BK_MISSION_LEVEL
$credits = 1
if ($level -eq "equilibre") { $credits = 6 }
if ($level -eq "approfondi") { $credits = 12 }
$tasks = Join-Path $PSScriptRoot "..\runtime\tasks"
New-Item -ItemType Directory -Force -Path $tasks | Out-Null
$n = 1
if ($WorkerId -eq "chloe") { $n = 3; if ($env:BK_MAX_WORKERS) { $n = [Math]::Min(3, [int]$env:BK_MAX_WORKERS) } }
$items = @()
for ($i = 0; $i -lt $n; $i++) {
  $tid = "TASK-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
  $rec = [ordered]@{ TaskId = $tid; ClientId = $ClientId; Credits = $credits; Status = "SUCCESS"; CreatedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
  ($rec | ConvertTo-Json) | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $tasks ($tid + ".json"))
  $items += [ordered]@{ TaskId = $tid; Status = "SUCCESS" }
}
$result = [ordered]@{ TaskId = $items[0].TaskId; Status = "SUCCESS"; FinalSynthesis = "ok (faux pipeline)" }
if ($WorkerId -eq "chloe") { $result["Results"] = $items }
($result | ConvertTo-Json -Depth 5) | Set-Content -Encoding UTF8 -LiteralPath $OutFile
Add-Content -LiteralPath (Join-Path $PSScriptRoot "stub-calls.log") -Value ($ClientId + "|" + $WorkerId + "|" + $level + "|" + $n)
'''


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{str(detail)[:400]}]" if detail and not cond else ""))
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
            with self.opener.open(req, timeout=120) as r:
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


def parse_utc(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()


def main():
    root = tempfile.mkdtemp(prefix="bkusage-e2e-")
    server = None
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=ignore)
        with open(os.path.join(app, "dashboard", "Submit-Task.ps1"), "w", encoding="utf-8-sig") as f:
            f.write(STUB)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR", "BK_LEVELS")}
        env.update(BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}", BK_STATUS_DISABLE="1",
                   BK_GATE_HASH=gate_hash(GATE_PASSWORD), BK_USAGE_WINDOWS="1")
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
        st, out = owner.post("/api/admin/set-plan", {"clientId": a_id, "planId": "equipe"})
        assert st == 200, out
        st, out = owner.post("/api/admin/set-plan", {"clientId": b_id, "planId": "pro"})
        assert st == 200, out
        stub_log = os.path.join(app, "dashboard", "stub-calls.log")

        def stub_calls():
            try:
                with open(stub_log, encoding="utf-8-sig") as f:
                    return [ln.strip() for ln in f if ln.strip()]
            except OSError:
                return []

        def ledger(client):
            try:
                with open(os.path.join(app, "runtime", "usage", client + ".json"), encoding="utf-8") as f:
                    return json.load(f)
            except (OSError, ValueError):
                return None

        # ------------------------------------------------------------------------------------------------ limites publiques et compteurs
        print("\n== GET /api/usage-limits et GET /api/usage ==")
        st, pub = anon.get("/api/usage-limits")
        check("usage-limits (sans compte) : actif, plafonds par forfait", st == 200 and pub["enforced"] is True and pub["sessionHours"] == 4
              and pub["plans"]["equipe"] == {"session": 83, "week": 207, "month": 900, "name": "Équipe"} and pub["plans"]["solo"]["session"] == 23
              and pub["plans"]["pro"]["week"] == 287 and "essai" not in pub["plans"] and "enterprise" not in pub["plans"], pub)
        st, out = anon.get("/api/usage")
        check("usage sans compte : 401 ACCOUNT_REQUIRED", st == 401 and out.get("error") == "ACCOUNT_REQUIRED", (st, out))
        st, u = alice.get("/api/usage")
        check("alice (Equipe) : 83 / 207 / 900, session non ouverte, jamais illimite",
              st == 200 and u["ok"] and u["enforced"] and u["planId"] == "equipe" and u["exempt"] is False and u["session"]["limit"] == 83 and u["week"]["limit"] == 207
              and u["month"]["limit"] == 900 and u["session"]["opened"] is False and u["session"]["used"] == 0 and u["nextRenewalUtc"] is None, u)
        check("... avec le forfait du dessus et ses limites (Pro : 115 / 287 / 1250, CHF 139)", u["upgrade"]["planId"] == "pro"
              and u["upgrade"]["limits"] == {"session": 115, "week": 287, "month": 1250} and u["upgrade"]["priceChf"]["month"] == 139 and u["upgrade"]["selfService"] is True, u["upgrade"])
        st, u = owner.get("/api/usage")
        check("proprietaire : exempt, aucune fenetre", st == 200 and u["exempt"] is True and u["session"] is None and u["week"] is None and u["allowedNow"] is None, u)

        # ------------------------------------------------------------------------------------------------ missions
        print("\n== missions : reservation, reglement, ouverture de la session ==")
        t0 = time.time()
        st, out = alice.post("/api/workers/alex/task", {"objective": "Prepare un plan", "level": "approfondi"})
        check("alice : mission Approfondi (12 credits) acceptee", st == 200 and out.get("Status") == "SUCCESS", (st, out))
        st, u = alice.get("/api/usage")
        check("... session ouverte a la premiere mission, 12 / 83, renouvellement 4 h plus tard",
              u["session"]["opened"] and u["session"]["used"] == 12 and u["session"]["reserved"] == 0 and u["week"]["used"] == 12 and u["month"]["used"] == 12
              and abs(parse_utc(u["session"]["resetsAtUtc"]) - (t0 + 4 * 3600)) < 90 and abs(parse_utc(u["week"]["resetsAtUtc"]) - (t0 + 7 * 86400)) < 90
              and u["nextRenewalUtc"] == u["session"]["resetsAtUtc"] and u["binding"] == "session", u)
        led = ledger(a_id)
        check("grand livre : un fichier, aucune reservation restante", led and led["schema"] == "BK-USAGE-LEDGER-V1" and not led["reservations"] and led["session"]["used"] == 12, led)
        st, bill = alice.get("/api/billing")
        check("get_billing : creditsUsed (grand livre) = 12, bloc usage et limites du forfait suivant",
              bill["creditsUsed"] == 12 and bill["usage"]["session"]["used"] == 12 and bill["upgrade"]["limits"]["session"] == 83
              and bill["upgrade"]["next"]["limits"] == {"session": 115, "week": 287, "month": 1250}, bill.get("usage"))
        by_id = {p["planId"]: p for p in bill["availablePlans"]}
        check("... les cartes de forfait portent leurs limites (Solo 23 / 57, Scale 368 / 920) ; Enterprise (sur contrat) n'en porte pas",
              by_id["solo"]["limits"]["session"] == 23 and by_id["scale"]["limits"]["week"] == 920 and "limits" not in by_id["enterprise"], by_id["enterprise"])
        for _ in range(5):
            st, out = alice.post("/api/workers/alex/task", {"objective": "Prepare un plan", "level": "approfondi"})
            assert st == 200, (st, out)
        check("alice : 6 missions Approfondi = 72 / 83", alice.get("/api/usage")[1]["session"]["used"] == 72)
        calls = len(stub_calls())
        st, out = alice.post("/api/workers/alex/task", {"objective": "Prepare un plan", "level": "equilibre"})
        check("Equilibre (6) passe encore (reste 11)", st == 200, (st, out))

        # ------------------------------------------------------------------------------------------------ refus
        print("\n== session epuisee : 402 USAGE_LIMIT_REACHED ==")
        check("reste 5 : Approfondi (12) est refuse", alice.get("/api/usage")[1]["session"]["remaining"] == 5)
        calls = len(stub_calls())
        refused = {}
        for path in ("/api/workers/alex/task", "/api/workers/alex/task/async", "/api/chloe/task", "/api/chloe/task/async"):
            st, out = alice.post(path, {"objective": "Un bref resume", "level": "approfondi"})
            refused[path] = out
            check(f"{path} : 402 USAGE_LIMIT_REACHED, limite nommee, renouvellement exact, forfait du dessus",
                  st == 402 and out.get("error") == "USAGE_LIMIT_REACHED" and out["limit"] == "session" and out["needed"] == 12 and out["remaining"] == 5
                  and abs(parse_utc(out["resetsAtUtc"]) - (t0 + 4 * 3600)) < 90 and out["upgrade"]["planId"] == "pro"
                  and out["upgrade"]["limits"] == {"session": 115, "week": 287, "month": 1250}, (st, out))
        d = refused["/api/workers/alex/task"]["detail"]
        check("le message dit : quota de session, combien il reste, l'heure, la duree, Pro et ses 115 credits par session",
              "Il vous reste 5 crédit(s) dans votre quota de session, ce niveau en demande 12." in d and "Il se renouvelle" in d and ("(dans 3 h" in d or "(dans 4 h" in d)
              and "forfait Pro (115 crédits par session)" in d and "attendez le renouvellement" in d, d)
        check("... et la reponse porte le bloc usage complet (memes chiffres que GET /api/usage)", refused["/api/chloe/task"]["usage"]["session"]["remaining"] == 5
              and refused["/api/chloe/task"]["usage"]["planId"] == "equipe")
        check("aucun sous-processus de mission lance pour les 4 refus", len(stub_calls()) == calls, (len(stub_calls()), calls))
        st, out = alice.post("/api/workers/alex/task", {"objective": "", "level": "rapide"})
        check("niveau Rapide (1 credit) : la porte laisse passer (400 OBJECTIVE_REQUIRED apres le controle)", st == 400 and out.get("error") == "OBJECTIVE_REQUIRED", (st, out))
        st, out = alice.post("/api/chloe/task", {"objective": "Plan complet", "level": "equilibre"})
        check("Chloe a l'Equilibre (6 credits, il en reste 5) : 402 USAGE_LIMIT_REACHED aussi", st == 402 and out.get("error") == "USAGE_LIMIT_REACHED" and out["remaining"] == 5, (st, out))
        st, out = alice.post("/api/workers/alex/task", {"objective": "Tout petit resume", "level": "rapide"})
        check("Rapide (1 credit) s'execute et se compte", st == 200, (st, out))

        # ------------------------------------------------------------------------------------------------ isolation
        print("\n== isolation entre clients et proprietaire ==")
        st, ub = bob.get("/api/usage")
        check("bob (Pro, 115 / 287 / 1250) n'a rien consomme : alice ne lui coute rien", ub["planId"] == "pro" and ub["session"]["limit"] == 115 and ub["session"]["used"] == 0
              and ub["session"]["opened"] is False, ub)
        st, out = bob.post("/api/workers/alex/task", {"objective": "Prepare un plan", "level": "approfondi"})
        check("bob : sa mission Approfondi passe pendant qu'alice est bloquee", st == 200, (st, out))
        ub = bob.get("/api/usage")[1]
        ua = alice.get("/api/usage")[1]
        check("... bob 12 / 115, alice inchangee", ub["session"]["used"] == 12 and ua["session"]["used"] >= 78, (ub["session"], ua["session"]))
        led_b = ledger(b_id)
        check("grands livres separes : le fichier de bob ne contient que bob", led_b and led_b["clientId"] == b_id and "alice" not in json.dumps(led_b) and led_b["session"]["used"] == 12)
        for n in range(3):
            st, out = owner.post("/api/workers/alex/task", {"objective": "Prepare un plan", "level": "approfondi"})
            assert st == 200, (st, out)
        check("proprietaire : 3 missions Approfondi d'affilee, jamais limite, aucun grand livre",
              ledger("CLI-DASHBOARD") is None and owner.get("/api/usage")[1]["exempt"] is True)
        st, out = anon.post("/api/workers/alex/task", {"objective": "x"})
        check("sans compte : 401, pas de fuite d'usage", st == 401, (st, out))

        # ------------------------------------------------------------------------------------------------ automatisations (autre processus)
        print("\n== automatisations : quota-check.py (autre processus) ==")
        qenv = dict(env)
        qenv["BK_ROOT"] = app

        def quota_check(client, worker="alex"):
            out = subprocess.run([sys.executable, os.path.join(app, "dashboard", "quota-check.py"), client, worker, "scheduled"], cwd=app, env=qenv,
                                 capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
            return json.loads(out.stdout.strip().splitlines()[-1])

        before = bob.get("/api/usage")[1]["session"]["used"]
        v = quota_check(b_id)
        check("quota-check (bob) : autorise et debite 1 credit dans le grand livre du serveur",
              v.get("blocked") is False and v.get("level") == "rapide" and bob.get("/api/usage")[1]["session"]["used"] == before + 1, v)
        for _ in range(4):
            quota_check(a_id)
        ua = alice.get("/api/usage")[1]
        left = ua["session"]["remaining"]
        for _ in range(left):
            quota_check(a_id)
        v = quota_check(a_id)
        check("quota-check (alice, session pleine) : sautee SANS erreur, code USAGE_LIMIT_REACHED + limite + heure",
              v.get("blocked") is True and v.get("code") == "USAGE_LIMIT_REACHED" and v.get("limit") == "session" and v.get("resetsAtUtc") and "error" not in v, v)
        check("... et la session d'alice est exactement pleine (83 / 83)", alice.get("/api/usage")[1]["session"]["remaining"] == 0)
        st, out = alice.post("/api/workers/alex/task", {"objective": "Tout petit resume", "level": "rapide"})
        check("... plus aucune mission, meme Rapide : 402 USAGE_LIMIT_REACHED (remaining 0)", st == 402 and out["error"] == "USAGE_LIMIT_REACHED" and out["remaining"] == 0
              and "Vous avez utilisé votre quota de session (83 crédits)." in out["detail"] and "Pour continuer sans attendre, passez au forfait Pro" in out["detail"], (st, out))

        # ------------------------------------------------------------------------------------------------ pages et interface
        print("\n== pages servies, interface, anglais ==")
        st, tarifs = anon.text("/tarifs.html")
        check("/tarifs.html : limites par forfait (Equipe 83 par session de 4 h, 207 par semaine) et « aucun forfait n'est illimite »",
              st == 200 and "<strong>83</strong> crédits par session de 4 h · <strong>207</strong> par semaine" in tarifs and "Aucun forfait n'est illimité" in tarifs
              and "Les limites d'usage de votre forfait" in tarifs, tarifs[:200])
        st, faq = anon.text("/faq.html")
        check("/faq.html : la question sur les limites d'usage", st == 200 and "Que se passe-t-il quand j'atteins une limite d'usage ?" in faq)
        st, fact = anon.text("/facturation.html")
        check("/facturation.html : session de 4 heures et semaine", st == 200 and "un quota par session de 4 heures" in fact)
        st, html = anon.text("/")
        check("index.html : pastille (bouton) et jauges (progressbar) presentes", 'id="usage-chip"' in html and 'id="usage-windows"' in html and 'id="usage-meters"' in html
              and 'id="pricing-usage"' in html and 'aria-labelledby="usage-windows-title"' in html)
        st, js = anon.text("/app.js")
        check("app.js : jauges, pastille, refus USAGE_LIMIT_REACHED, compte a rebours", all(x in js for x in ("function renderUsageMeters", "function renderUsageChip", "USAGE_LIMIT_REACHED",
              "usageTick", 'role="progressbar"', "aria-valuetext", "isQuotaRefusal")))
        check("aucune page ni texte d'interface n'annonce de projet qui se met en pause (le moteur de projets n'est pas livre : rien n'est annonce avant d'etre construit)",
              all("projet en cours" not in t.lower() and "reprend tout seul" not in t for t in (tarifs, faq, fact)) and "Un projet en cours ne se perd pas" not in js)
        st, en = anon.text("/i18n-en-app.js")
        check("i18n-en-app.js : textes anglais des limites", "Your usage limits" in en and "Session quota reached" in en and "You have used your session quota (" in en)
        st, css = anon.text("/style.css")
        check("style.css : jauges, pastille, 375 px, mouvement reduit", ".usage-meter-fill" in css and ".usage-chip" in css and "max-width: 520px" in css and "prefers-reduced-motion" in css)

        # ------------------------------------------------------------------------------------------------ export et suppression
        print("\n== export et suppression du compte ==")
        st, raw = bob.call("POST", "/api/account/export", {})
        if st in (404, 405):
            st, raw = bob.call("GET", "/api/account/export")
        exp = json.loads(raw.decode("utf-8")) if st == 200 else {}
        check("export : le grand livre du client y figure", st == 200 and exp.get("usage", {}).get("clientId") == b_id, (st, str(exp)[:200]))
        st, out = bob.post("/api/account/delete", {"password": PASSWORD})
        check("suppression du compte : acceptee", st == 200 and out.get("ok") is True, (st, out))
        check("... et le grand livre de bob a disparu", not os.path.exists(os.path.join(app, "runtime", "usage", b_id + ".json")))
        check("... celui d'alice est intact", ledger(a_id) is not None)
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
