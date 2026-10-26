# -*- coding: utf-8 -*-
"""Bout en bout : le VRAI dashboard/server.py demarre sur une COPIE jetable du depot (port libre, jamais les vraies donnees), avec un FAUX serveur
OpenAI-compatible local a la place du moteur local (Ollama), trois comptes clients et le proprietaire (porte). On verifie en HTTP :

  - GET /api/engine : le moteur que le compte utilisera, ses capacites, sans adresse ni jeton ; refuse sans compte (401) ;
  - POST /api/admin/engine : proprietaire seulement (un client : 401), validation (adresse publique en http refusee), aucun secret ;
  - essai (forfait Essai) verrouille sur le moteur local, client payant sur Claude, repli visible, disjoncteur, plafond de depense ;
  - cle personnelle (BYOK) : validation par la forme, chiffrement, jamais renvoyee, isolee par client, supprimable, purgee avec le compte ;
  - une VRAIE mission (pipeline PowerShell complet) repond par le faux moteur et porte son etiquette ; sans choix du proprietaire, rien n'a change ;
  - un repli : Claude indisponible (aucune cle dans ce bac a sable -> aucun appel reseau), le moteur de remplacement repond, 0 credit, note visible.

Aucun appel a Anthropic ni a un service tiers : le bac a sable n'a aucune cle, le « moteur local » est un serveur Python de la bibliotheque standard.

Lancer : python tests/providers/e2e_server.py      (Linux/WSL ; python 3 ; PowerShell 7 requis)
"""
import base64
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
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_openai  # noqa: E402

REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
SKIP_TOP = {".git", ".claude", ".secrets", "_archive", "runtime", "node_modules", "__pycache__", "tests", "docs"}
PASSWORD = "e2e-" + os.urandom(6).hex()
GATE_PASSWORD = "gate-" + os.urandom(6).hex()
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
ALICE_KEY = "sk-ant-ALICE-" + os.urandom(12).hex()
BOB_KEY = "sk-ant-BOB-" + os.urandom(12).hex()
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
        skip.add("data")
        skip.add("runs")
    if rel == "core/connectors":
        skip.add("client-credentials")
    if rel == "core/ai":
        skip.add("data")
    if rel == "dashboard":
        skip.add(".gate")
    return skip


class Client:
    def __init__(self, port, ip="198.51.100.1"):
        self.base = f"http://127.0.0.1:{port}"
        self.ip = ip
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method, path, body=None, headers=None, timeout=900):
        data = json.dumps(body).encode() if body is not None else None
        h = {"Content-Type": "application/json", "X-Forwarded-For": self.ip}
        h.update(headers or {})
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=h)
        try:
            with self.opener.open(req, timeout=timeout) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def json(self, method, path, body=None, timeout=900):
        st, raw = self.call(method, path, body, timeout=timeout)
        try:
            return st, json.loads(raw.decode("utf-8"))
        except ValueError:
            return st, {"raw": raw[:200].decode("utf-8", "replace")}

    def get(self, path):
        return self.json("GET", path)

    def post(self, path, body=None, timeout=900):
        return self.json("POST", path, body if body is not None else {}, timeout=timeout)


def gate_hash(password):
    salt = os.urandom(16)
    return f"{salt.hex()}:{hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 1000, dklen=32).hex()}:1000"


def signup(port, email, ip):
    c = Client(port, ip)
    st, out = c.post("/api/account/signup", {"email": email, "password": PASSWORD, "companyName": "Test " + email})
    assert st == 200, (st, out)
    st, me = c.get("/api/account/me")
    assert me.get("clientId"), me
    return c, me["clientId"]


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def main():
    if not PWSH:
        raise SystemExit("pwsh (PowerShell 7) requis")
    root = tempfile.mkdtemp(prefix="bkprovsrv-")
    server = None
    fake = fake_openai.FakeOpenAI(script=[{"content": "Reponse du faux moteur local pour le test."}])
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=ignore)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = {k: v for k, v in os.environ.items() if not k.startswith("BK_SECRET") and k not in ("BK_REQUIRE_GATE", "BK_SMTP_HOST", "BK_SECRETS_DIR", "BK_AI_PROVIDER",
                                                                                                  "BK_OLLAMA_URL", "BK_ENGINE_PLAN", "BK_CLAUDE_DAILY_CHF", "BK_CLAUDE_MONTHLY_CHF")}
        env.update(BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}", BK_STATUS_DISABLE="1",
                   BK_GATE_HASH=gate_hash(GATE_PASSWORD), BK_PILOT_NOTIFY_EMAIL="owner@mail-test.example", BK_PWSH=PWSH,
                   BK_SECRET_CRED_ENCRYPTION_KEY=base64.b64encode(os.urandom(32)).decode())
        server = subprocess.Popen([sys.executable, "-u", os.path.join(app, "dashboard", "server.py")], cwd=app, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        anon = Client(port, "198.51.100.90")
        end = time.time() + 90
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
        carol, c_id = signup(port, "carol@mail-test.example", "198.51.100.13")
        owner = Client(port, "198.51.100.99")
        st, _ = owner.post("/api/gate/login", {"password": GATE_PASSWORD})
        assert st == 200, "connexion proprietaire"
        engine_dir = os.path.join(app, "runtime", "engine")
        settings_path = os.path.join(app, "core", "ai", "data", "engine-settings.json")
        cred_dir = lambda cid: os.path.join(app, "core", "connectors", "client-credentials", "data", cid)   # noqa: E731
        byok_meta = lambda cid: os.path.join(app, "core", "ai", "data", "byok", cid + ".json")             # noqa: E731

        st, out = owner.post("/api/admin/set-plan", {"clientId": c_id, "planId": "equipe", "paidMonths": 1})
        check("carol passe au forfait Equipe (client payant)", st == 200 and out.get("planId") == "equipe", (st, out))

        # ------------------------------------------------------------------------------------------------ rien n'a change sans choix du proprietaire
        print("\n== sans choix du proprietaire : le chemin Claude d'avant ==")
        st, out = anon.get("/api/engine")
        check("GET /api/engine sans compte : 401", st == 401 and out.get("error") == "ACCOUNT_REQUIRED", (st, out))
        st, out = alice.get("/api/engine")
        check("compte en essai, rien configure : Claude", st == 200 and out["provider"] == "anthropic" and out["summary"] == "Moteur : Claude" and out["explicit"] is False, out)
        check("la matrice liste tous les moteurs, sans adresse ni jeton",
              set(out["matrix"]) == {"anthropic", "ollama", "swiss", "byok-anthropic", "byok-openai_compat"}
              and "http://" not in json.dumps(out) and "bearer" not in json.dumps(out).lower() and "token" not in json.dumps(out).lower(), list(out["matrix"]))
        check("capacites de Claude : recherche web, fichiers Office, code", out["capabilities"]["webSearch"] and out["capabilities"]["officeFiles"] and out["capabilities"]["codeExecution"], out["capabilities"])
        st, out = alice.post("/api/workers/noah/task", {"objective": "Dis bonjour en une phrase."})
        res = out.get("Result") or {}
        check("mission sans plan de moteurs : resultat identique a l'ancien (pas de champ Engine)",
              st == 200 and out.get("Status") == "EXECUTED" and "Engine" not in res and res.get("Provider") == "NONE", (st, list(res)))
        check("aucun fichier d'etat de moteur ecrit (pas de disjoncteur, pas de registre de depense)", not os.path.isdir(engine_dir) or not os.listdir(engine_dir), os.listdir(engine_dir) if os.path.isdir(engine_dir) else "")
        check("aucun reglage de moteur sur le disque", not os.path.isfile(settings_path))

        # ------------------------------------------------------------------------------------------------ reglages du proprietaire
        print("\n== reglages du proprietaire (POST /api/admin/engine) ==")
        good = {"endpoints": {"ollama": {"url": fake.url, "model": "llama3:latest"}}}
        for who, c in (("anonyme", anon), ("cliente Essai", alice), ("cliente Equipe", carol)):
            st, out = c.post("/api/admin/engine", good)
            check(f"{who} : POST /api/admin/engine refuse (401, la session client ne suffit pas)", st == 401, (st, out))
            st, out = c.get("/api/admin/engine")
            check(f"{who} : GET /api/admin/engine refuse", st == 401, (st, out))
        check("rien n'a ete enregistre par ces tentatives", not os.path.isfile(settings_path))
        for bad, label in (({"endpoints": {"ollama": {"url": "http://8.8.8.8:11434", "model": "m"}}}, "http vers Internet"),
                           ({"endpoints": {"ollama": {"url": "http://169.254.169.254/v1", "model": "m"}}}, "adresse de metadonnees"),
                           ({"defaultChain": ["anthropic", "gpt"]}, "moteur inconnu"), ({"ceiling": {"dailyChf": -1}}, "plafond negatif"),
                           ({"token": "x"}, "jeton refuse")):
            st, out = owner.post("/api/admin/engine", bad)
            check(f"proprietaire : reglage invalide refuse ({label})", st == 400 and out.get("error") == "INVALID_SETTINGS" and out.get("errors"), (st, out))
        check("aucun reglage invalide n'est ecrit", not os.path.isfile(settings_path))
        st, out = owner.post("/api/admin/engine", good)
        check("proprietaire : adresse du moteur local enregistree", st == 200 and out.get("ok") and out["engine"]["endpoints"]["ollama"]["model"] == "llama3:latest", (st, out))
        st, out = owner.get("/api/admin/engine")
        check("vue proprietaire : reglages, plafond, sante, jamais de jeton", st == 200 and out["engine"]["endpoints"]["ollama"]["tokenPresent"] is False
              and "ceiling" in out["engine"] and "health" in out["engine"], out)

        # ------------------------------------------------------------------------------------------------ essai -> moteur local
        print("\n== l'essai tourne sur le moteur local, le client payant sur Claude ==")
        st, out = alice.get("/api/engine?level=rapide")
        check("compte en essai : moteur local (Llama 3), libelle en francais simple",
              out["provider"] == "ollama" and out["local"] is True and out["label"] == "Moteur local (Llama 3)"
              and out["summary"] == "Moteur local (Llama 3) : réponses plus simples, pas de recherche web ni de fichiers Office", out)
        check("capacites honnetes du moteur local", out["capabilities"]["webSearch"] is False and out["capabilities"]["officeFiles"] is False
              and out["capabilities"]["codeExecution"] is False and out["capabilities"]["toolUse"] == "weak" and out["capabilities"]["longProjects"] is False, out["capabilities"])
        check("adresse du moteur non divulguee", fake.url not in json.dumps(out), "")
        st, out = carol.get("/api/engine")
        check("client payant : Claude", out["provider"] == "anthropic" and out["summary"] == "Moteur : Claude", out)
        st, out = carol.get("/api/engine/byok")
        check("pas de cle personnelle : configured False", out == {"configured": False}, out)

        before = len(fake.chat_requests())
        st, out = alice.post("/api/workers/noah/task", {"objective": "Dis bonjour en une phrase."})
        res = out.get("Result") or {}
        eng = res.get("Engine") or {}
        check("mission d'essai : reponse du moteur local, etiquetee", st == 200 and out.get("Status") == "EXECUTED" and res.get("Answer") == "Reponse du faux moteur local pour le test."
              and eng.get("provider") == "ollama" and eng.get("local") is True and eng.get("failedOver") is False and eng.get("label") == "Moteur local (Llama 3)", (st, res))
        check("jamais etiquetee Claude", res.get("Provider") == "OLLAMA" and "ANTHROPIC" not in json.dumps(res).upper().replace("ANTHROPIC-ADAPTER", ""), res.get("Provider"))
        check("mission voulue sur le moteur local : le credit du niveau (Rapide = 1)", out.get("Credits") == 1 and out.get("Level") == "rapide", (out.get("Credits"), out.get("Level")))
        check("une seule requete est partie vers le moteur local", len(fake.chat_requests()) == before + 1, len(fake.chat_requests()) - before)
        sent = fake.chat_requests()[-1]
        system = sent["messages"][0]["content"]
        check("le prompt envoye au modele local : regles contre l'injection et limites du moteur", "UNTRUSTED CONTENT" in system and "do NOT have web_search" in system, system[:200])
        check("l'objectif part en dernier message utilisateur", sent["messages"][-1] == {"role": "user", "content": "Dis bonjour en une phrase."}, sent["messages"][-1])
        st, act = alice.get("/api/workers/noah/activity")
        first = (act.get("activity") or [{}])[0]
        check("l'activite du Worker garde le moteur qui a repondu", (first.get("engine") or {}).get("label") == "Moteur local (Llama 3)", first)
        st, out = anon.post("/api/trial/mission", {"workerId": "noah", "objective": "Dis bonjour."})
        check("essai public (visiteur sans compte) : meme moteur local, etiquette dans la reponse",
              st == 200 and out.get("ok") and (out.get("engine") or {}).get("local") is True and out.get("answer", "").startswith("Reponse du faux moteur"), (st, out))

        # ------------------------------------------------------------------------------------------------ repli visible, disjoncteur
        print("\n== repli : Claude indisponible, le moteur local repond ouvertement ==")
        st, out = owner.post("/api/admin/engine", {"defaultChain": ["anthropic", "ollama"]})
        check("proprietaire : chaine Claude puis moteur local", st == 200, (st, out))
        st, out = carol.get("/api/engine")
        check("client payant : Claude d'abord, repli annonce", out["provider"] == "anthropic" and [c["provider"] for c in out["chain"]] == ["anthropic", "ollama"]
              and "Si ce moteur est indisponible" in out["failoverNote"], out)
        st, out = carol.post("/api/workers/noah/task", {"objective": "Dis bonjour en une phrase.", "level": "rapide"})
        res = out.get("Result") or {}
        eng = res.get("Engine") or {}
        check("Claude sans cle : la mission est traitee par le moteur de remplacement, etiquete comme tel",
              st == 200 and eng.get("provider") == "ollama" and eng.get("failedOver") is True and res.get("Provider") == "OLLAMA", (st, eng))
        check("la reponse dit quel moteur a repondu et pourquoi", res.get("Answer", "").startswith("Note : cette réponse vient du moteur « Moteur local (Llama 3) » et non de Claude")
              and "Cette mission ne consomme aucun crédit" in res.get("Answer", ""), res.get("Answer"))
        check("un repli ne coute aucun credit", out.get("Credits") == 0, out.get("Credits"))
        health = read_json(os.path.join(engine_dir, "health.json"), {})
        check("Claude est mis de cote (disjoncteur) apres une erreur d'acces", "anthropic" in health and health["anthropic"]["reason"] == "auth", health)
        st, out = carol.get("/api/engine")
        check("l'etat visible du client le dit : Claude ecarte quelques minutes", out["provider"] == "ollama" and out["skipped"] and out["skipped"][0]["why"].startswith("circuit-open"), out)
        st, out = owner.get("/api/admin/engine")
        check("le proprietaire voit le moteur ecarte", "anthropic" in out["engine"]["health"], out["engine"]["health"])

        # ------------------------------------------------------------------------------------------------ plafond de depense
        print("\n== plafond de depense Claude ==")
        os.remove(os.path.join(engine_dir, "health.json"))
        st, out = owner.post("/api/admin/engine", {"defaultChain": ["anthropic"], "ceiling": {"dailyChf": 1.0, "monthlyChf": 20.0}})
        check("proprietaire : plafond 1 CHF par jour, 20 par mois", st == 200 and out["engine"]["ceiling"]["dailyChf"] == 1.0, (st, out))
        day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        spend = {"days": {day: {"chf": 0.85, "usd": 1.0, "missions": 4}}, "months": {day[:7]: {"chf": 0.85, "usd": 1.0, "missions": 4}}}
        os.makedirs(engine_dir, exist_ok=True)
        with open(os.path.join(engine_dir, "spend.json"), "w", encoding="utf-8") as f:
            json.dump(spend, f)
        st, out = carol.get("/api/engine")
        check("a 85 % du plafond : Claude reste le moteur", out["provider"] == "anthropic", out)
        st, out = owner.get("/api/admin/engine")
        check("le proprietaire voit la depense et le reste", out["engine"]["ceiling"]["dayChf"] == 0.85 and abs(out["engine"]["ceiling"]["remainingChf"] - 0.15) < 0.001, out["engine"]["ceiling"])
        alerts = read_json(os.path.join(engine_dir, "alerts.json"), {})
        check("alerte a 80 % declenchee (une marque, e-mail envoye au proprietaire)", any(k.endswith(":80") for k in alerts), alerts)
        spend["days"][day]["chf"] = 1.05
        with open(os.path.join(engine_dir, "spend.json"), "w", encoding="utf-8") as f:
            json.dump(spend, f)
        st, out = carol.get("/api/engine")
        check("plafond atteint : le client payant est bascule, honnetement, sur le moteur gratuit",
              out["provider"] == "ollama" and out["reason"] == "spending-ceiling" and out["label"] == "Moteur local (Llama 3)" and {"id": "anthropic", "why": "spending-ceiling"} in out["skipped"], out)
        st, out = owner.get("/api/admin/engine")
        check("le proprietaire voit que le plafond est atteint", out["engine"]["ceiling"]["reached"] is True, out["engine"]["ceiling"])
        alerts = read_json(os.path.join(engine_dir, "alerts.json"), {})
        check("deuxieme alerte quand il est atteint", any(k.endswith(":100") for k in alerts), alerts)
        st, out = owner.post("/api/admin/engine", {"ceiling": None})
        st, out = carol.get("/api/engine")
        check("plafond retire : retour a Claude", out["provider"] == "anthropic", out)

        # ------------------------------------------------------------------------------------------------ cle personnelle
        print("\n== cle personnelle (BYOK) ==")
        st, out = anon.post("/api/engine/byok", {"kind": "anthropic", "key": ALICE_KEY})
        check("sans compte : 401", st == 401, (st, out))
        st, out = alice.post("/api/engine/byok", {"kind": "anthropic", "key": "pas-une-cle"})
        check("cle de mauvaise forme : refusee (400 INVALID_FIELD), rien d'enregistre", st == 400 and out.get("error") == "INVALID_FIELD" and out.get("field") == "key"
              and not os.path.isdir(cred_dir(a_id)), (st, out))
        st, out = alice.post("/api/engine/byok", {"kind": "openai_compat", "key": "k" * 24, "endpoint": "http://169.254.169.254/v1", "model": "m"})
        check("adresse interdite : refusee (le serveur ne contactera jamais une adresse choisie par un client)", st == 400 and out.get("field") == "endpoint", (st, out))
        st, out = alice.post("/api/engine/byok", {"kind": "openai_compat", "key": "k" * 24, "endpoint": "https://evil.example/v1", "model": "m"})
        check("hote hors de la liste blanche : refuse", st == 400 and out.get("field") == "endpoint", (st, out))
        st, out = alice.post("/api/engine/byok", {"kind": "anthropic", "key": ALICE_KEY})
        check("cle Anthropic valide : enregistree", st == 200 and out.get("ok") and out["byok"]["configured"] and out["byok"]["kind"] == "anthropic", (st, out))
        check("la reponse ne contient pas la cle", ALICE_KEY not in json.dumps(out), "")
        st, out = alice.get("/api/engine/byok")
        check("GET /api/engine/byok : description sans la cle", st == 200 and out["configured"] and ALICE_KEY not in json.dumps(out) and "key" not in out, out)
        stored = read_text(os.path.join(cred_dir(a_id), "ai_engine.json"))
        check("la cle est chiffree au repos (fichier du coffre, absente en clair)", stored and ALICE_KEY not in stored and "ciphertext" in stored, stored[:120])
        check("la description non secrete ne contient pas la cle", ALICE_KEY not in read_text(byok_meta(a_id)) and "api.anthropic.com" in read_text(byok_meta(a_id)))
        st, out = alice.get("/api/engine")
        check("le moteur de la cliente devient « Votre cle (Claude) »", out["provider"] == "byok" and out["label"] == "Votre clé (Claude)" and out["summary"] == "Moteur : Claude (votre propre clé)"
              and [(c["provider"], c["local"], c["label"]) for c in out["chain"]] == [("byok", False, "Votre clé (Claude)")], out)
        st, out = bob.get("/api/engine")
        check("isolation : bob garde son moteur (essai -> local)", out["provider"] == "ollama" and out["byok"] == {"configured": False}, out)
        st, out = bob.get("/api/engine/byok")
        check("isolation : bob ne voit aucune cle", out == {"configured": False}, out)
        st, out = bob.post("/api/engine/byok", {"kind": "anthropic", "key": BOB_KEY})
        check("bob enregistre SA cle", st == 200 and out["byok"]["configured"], (st, out))
        check("deux fichiers distincts, chacun avec sa propre cle chiffree", os.path.isfile(os.path.join(cred_dir(b_id), "ai_engine.json"))
              and BOB_KEY not in read_text(os.path.join(cred_dir(b_id), "ai_engine.json")) and read_text(os.path.join(cred_dir(a_id), "ai_engine.json")) != read_text(os.path.join(cred_dir(b_id), "ai_engine.json")))
        st, out = alice.post("/api/engine/byok", {"enabled": False})
        st, eng_a = alice.get("/api/engine")
        check("cle desactivee : retour au moteur de la plateforme sans la supprimer", eng_a["provider"] == "ollama" and eng_a["byok"]["configured"] and eng_a["byok"]["enabled"] is False, eng_a)
        alice.post("/api/engine/byok", {"enabled": True})
        st, exp = alice.json("POST", "/api/account/export", {})
        check("export des donnees : l'etat de la cle sans la cle, et pas dans la liste des outils", st == 200 and exp["aiEngineKey"]["configured"] is True and ALICE_KEY not in json.dumps(exp)
              and "ai_engine" not in exp.get("connectedTools", []), exp.get("aiEngineKey"))
        st, out = alice.post("/api/engine/byok/remove")
        check("suppression de la cle : fichier chiffre et description effaces", st == 200 and not os.path.exists(os.path.join(cred_dir(a_id), "ai_engine.json")) and not os.path.exists(byok_meta(a_id)), (st, out))
        check("la cle de bob n'a pas ete touchee", os.path.isfile(os.path.join(cred_dir(b_id), "ai_engine.json")) and os.path.isfile(byok_meta(b_id)))
        alice.post("/api/engine/byok", {"kind": "anthropic", "key": ALICE_KEY})
        st, out = alice.post("/api/account/delete", {"password": PASSWORD})
        check("suppression du compte", st == 200 and out.get("ok"), (st, out))
        check("la suppression du compte efface la cle chiffree ET sa description", not os.path.isdir(cred_dir(a_id)) and not os.path.exists(byok_meta(a_id)))
        check("la cle de bob survit a la suppression du compte d'alice", os.path.isfile(os.path.join(cred_dir(b_id), "ai_engine.json")) and os.path.isfile(byok_meta(b_id)))

        # ------------------------------------------------------------------------------------------------ journaux
        print("\n== aucun secret dans les journaux ni dans les prompts ==")
        out_text = ""
        server.terminate()
        try:
            out_text, _ = server.communicate(timeout=15)
        except Exception:
            server.kill()
        check("les cles personnelles n'apparaissent jamais dans la sortie du serveur", ALICE_KEY not in out_text and BOB_KEY not in out_text)
        check("ni dans un prompt envoye au moteur local", all(ALICE_KEY not in json.dumps(r) and BOB_KEY not in json.dumps(r) for r in fake.requests))
        server = None
    finally:
        if server is not None:
            server.terminate()
        fake.stop()
        shutil.rmtree(root, ignore_errors=True)
    print()
    if failures:
        print(f"{len(failures)} verification(s) en echec :")
        for f in failures:
            print("  -", f)
        return 1
    print("Toutes les verifications passent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
