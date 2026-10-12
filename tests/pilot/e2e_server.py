"""Test de bout en bout du programme pilote : le VRAI serveur (dashboard/server.py) est demarre sur une
COPIE jetable du projet (dossier temporaire, port libre choisi par le systeme, mot de passe de porte et
comptes factices), puis recoit de vraies requetes HTTP.

Rien du depot ni des vraies donnees n'est touche. Aucun email reel n'est envoye : un petit lanceur
(e2e_boot.py, ecrit dans la copie) remplace mailer.send_email par une fonction qui ecrit l'email dans
un fichier, ce qui permet de verifier son contenu et le journal "[pilot] email au proprietaire".

Lancer : python tests/pilot/e2e_server.py          (Windows, Linux, WSL ; python 3.9+)
"""
import hashlib
import http.client
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
failures = []
GATE_PASSWORD = "gate-" + os.urandom(8).hex()          # factice, vit le temps du test
ACCOUNT_PASSWORD = "acct-" + os.urandom(8).hex()       # factice

BOOT = '''import json, os, runpy, sys
root = os.environ["BK_ROOT"]
sys.path.insert(0, os.path.join(root, "dashboard"))
import mailer
OUT = os.environ["BK_E2E_MAIL_OUT"]
FAIL = os.environ.get("BK_E2E_MAIL_FAIL") == "1"
def fake_send(to, subject, html, text=None, gmail_bridge=None):
    with open(OUT, "a", encoding="utf-8") as f:
        f.write(json.dumps({"to": to, "subject": subject, "html": html, "text": text}, ensure_ascii=False) + "\\n")
    return (False, "SMTP_TEST_FAILURE") if FAIL else (True, None)
mailer.send_email = fake_send
runpy.run_path(os.path.join(root, "dashboard", "server.py"), run_name="__main__")
'''


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"   [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def gate_hash(password):
    salt = os.urandom(16)
    return f"{salt.hex()}:{hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 1000, dklen=32).hex()}:1000"


def request(port, method, path, body=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        r = conn.getresponse()
        return r.status, {k.lower(): v for k, v in r.getheaders()}, r.read()
    finally:
        conn.close()


def post_json(port, path, obj, ip=None, cookie=None, raw=None, ctype="application/json"):
    data = raw if raw is not None else json.dumps(obj, ensure_ascii=False).encode("utf-8")
    h = {"Content-Type": ctype, "Content-Length": str(len(data))}
    if ip:
        h["X-Forwarded-For"] = ip
    if cookie:
        h["Cookie"] = cookie
    st, hd, b = request(port, "POST", path, data, h)
    try:
        return st, json.loads(b.decode("utf-8")), hd
    except ValueError:
        return st, {"_raw": b[:200].decode("utf-8", "replace")}, hd


def get_json(port, path, cookie=None):
    st, hd, b = request(port, "GET", path, None, {"Cookie": cookie} if cookie else {})
    try:
        return st, json.loads(b.decode("utf-8"))
    except ValueError:
        return st, {"_raw": b[:200].decode("utf-8", "replace")}


def valid(**kw):
    base = {"name": "Marie Dupont", "email": "marie@atelier-dupont.example", "company": "Atelier Dupont SA",
            "website": "atelier-dupont.example", "tools": ["gmail", "slack"], "otherTools": "logiciel de caisse",
            "useCase": "Répondre plus vite aux demandes de devis reçues par email.", "consent": True, "lang": "fr"}
    base.update(kw)
    return base


class Server:
    def __init__(self, root, env_extra=None, tag="server"):
        self.root, self.port, self.tag = root, free_port(), tag
        self.mail_out = os.path.join(root, f"mail-{tag}.jsonl")
        self.log_path = os.path.join(root, f"log-{tag}.txt")
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("BK_", "OAUTH_", "ANTHROPIC", "STRIPE", "OPENAI"))}
        env.update(BK_ROOT=root, BK_PORT=str(self.port), BK_LISTEN_HOST="127.0.0.1", BK_GATE_HASH=gate_hash(GATE_PASSWORD),
                   BK_PUBLIC_URL=f"http://127.0.0.1:{self.port}", BK_E2E_MAIL_OUT=self.mail_out,
                   BK_PILOT_NOTIFY_EMAIL="owner-test@example.com", PYTHONUNBUFFERED="1", PYTHONIOENCODING="utf-8")
        env.update(env_extra or {})
        self.log = open(self.log_path, "wb")
        self.proc = subprocess.Popen([sys.executable, "-u", os.path.join(root, "e2e_boot.py")], cwd=root, env=env,
                                     stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(120):
            try:
                if request(self.port, "GET", "/api/gate/status")[0] == 200:
                    return
            except OSError:
                pass
            if self.proc.poll() is not None:
                break
            time.sleep(0.5)
        raise SystemExit("le serveur n'a pas demarre : " + self.logs()[-1500:])

    def logs(self):
        self.log.flush()
        with open(self.log_path, encoding="utf-8", errors="replace") as f:
            return f.read()

    def mails(self, wait_for=0, timeout=8):
        end = time.time() + timeout
        while True:
            rows = []
            if os.path.exists(self.mail_out):
                with open(self.mail_out, encoding="utf-8") as f:
                    rows = [json.loads(line) for line in f if line.strip()]
            if len(rows) >= wait_for or time.time() > end:
                return rows
            time.sleep(0.2)

    def operator_cookie(self):
        data = json.dumps({"password": GATE_PASSWORD}).encode()
        st, hd, _ = request(self.port, "POST", "/api/gate/login", data, {"Content-Type": "application/json", "Content-Length": str(len(data))})
        return hd["set-cookie"].split(";")[0] if st == 200 and "set-cookie" in hd else None

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.log.close()


def copy_repo(dst):
    skip_names = {".git", "_archive", "__pycache__", ".claude", "backups"}

    def ignore(d, names):
        out = {n for n in names if n in skip_names or n.endswith(".pyc")}
        rel = os.path.relpath(d, REPO).replace("\\", "/")
        if rel == ".":                                   # donnees d'execution du depot : jamais copiees
            out.add("runtime")
        if rel == "memory":
            out.add("runtime")
        if rel == "core/accounts":
            out.add("data")
        return out

    shutil.copytree(REPO, dst, ignore=ignore)
    # Pas de fiche du standard telephonique dans la copie : evite de lancer PowerShell au demarrage.
    phone_cfg = os.path.join(dst, "dashboard", "phone-agent", "CLI-DASHBOARD.json")
    if os.path.exists(phone_cfg):
        os.remove(phone_cfg)
    with open(os.path.join(dst, "e2e_boot.py"), "w", encoding="utf-8") as f:
        f.write(BOOT)


def main():
    work = tempfile.mkdtemp(prefix="bk-pilot-e2e-")
    root = os.path.join(work, "app")
    srv = srv2 = srv3 = None
    try:
        copy_repo(root)
        store = os.path.join(root, "core", "accounts", "data", "pilot-applications.json")
        srv = Server(root, tag="a")
        port = srv.port
        print(f"(serveur de test sur 127.0.0.1:{port}, copie dans {root})")

        print("\n== pages et fichiers publics ==")
        st, hd, body = request(port, "GET", "/pilote.html")
        page = body.decode("utf-8")
        check("GET /pilote.html -> 200 HTML", st == 200 and hd["content-type"].startswith("text/html"), st)
        check("CSP stricte + anti-cadre + nosniff", "script-src 'self'" in hd.get("content-security-policy", "")
              and "frame-ancestors 'none'" in hd.get("content-security-policy", "") and hd.get("x-content-type-options") == "nosniff")
        check("formulaire, consentement et champ piege presents", all(s in page for s in ('id="pilot-form"', 'name="consent"', 'name="contact_me_by_fax_only"')))
        check("38 outils du vrai catalogue proposes en cases a cocher", page.count('name="tools"') == 38, page.count('name="tools"'))
        check("conditions : aucune condition commerciale annoncee", "ne sont pas encore définies" in page)
        check("page en francais avec lien vers essai gratuit", "/#nav-onboarding" in page)
        st, _, b = request(port, "GET", "/i18n-en-pilot.js")
        check("dictionnaire anglais servi", st == 200 and b"Pilot programme" in b)
        st, _, b = request(port, "GET", "/pilot-form.js")
        check("pilot-form.js servi avec l'en-tete anglais", st == 200 and b.startswith(b"window.BK_EN_HEAD = "))
        st, _, b = request(port, "GET", "/pilot-admin.js")
        check("pilot-admin.js servi", st == 200 and b"loadAdminPilot" in b)
        st, _, b = request(port, "GET", "/sitemap.xml")
        check("plan du site contient /pilote.html", st == 200 and f"http://127.0.0.1:{port}/pilote.html".encode() in b)
        st, _, b = request(port, "GET", "/")
        home = b.decode("utf-8")
        check("accueil : lien visible vers le programme pilote (pied de page + bandeau)", home.count('href="/pilote.html"') >= 2)
        check("accueil : section admin et scripts du programme pilote", "admin-pilot-list" in home and "/pilot-admin.js" in home and "/i18n-en-pilot.js" in home)
        st, _, b = request(port, "GET", "/tarifs.html")
        check("pages statiques : lien dans le pied de page", st == 200 and b'href="/pilote.html"' in b)
        st, _, _ = request(port, "GET", "/api/pilot/apply")
        check("GET /api/pilot/apply n'existe pas (404)", st == 404, st)

        print("\n== candidature valide ==")
        st, out, _ = post_json(port, "/api/pilot/apply", valid(), ip="198.51.100.10")
        check("POST valide -> 200 {ok, id}", st == 200 and out.get("ok") is True and str(out.get("id", "")).startswith("PIL-"), (st, out))
        first_id = out.get("id")
        check("fichier de candidatures cree dans core/accounts/data/", os.path.isfile(store))
        saved = json.load(open(store, encoding="utf-8"))["applications"] if os.path.isfile(store) else []
        check("enregistrement complet (consentement, version, outils)", len(saved) == 1 and saved[0]["email"] == "marie@atelier-dupont.example"
              and saved[0]["consent"] is True and saved[0]["tools"] == ["gmail", "slack"] and saved[0]["website"] == "https://atelier-dupont.example"
              and saved[0]["consentVersion"].startswith("pilot-"), saved[:1])
        mails = srv.mails(wait_for=1)
        check("email envoye au proprietaire", len(mails) == 1 and mails[0]["to"] == "owner-test@example.com", mails)
        check("sujet = candidature + nom", mails and "Marie Dupont" in mails[0]["subject"] and "pilote" in mails[0]["subject"])
        check("journal : email envoye", "[pilot] email au proprietaire : envoye" in srv.logs())
        check("journal : candidature enregistree sans donnee personnelle", f"id={first_id}" in srv.logs() and "marie@" not in srv.logs())

        print("\n== refus (requetes mal formees) ==")
        st, out, _ = post_json(port, "/api/pilot/apply", valid(email="pas-un-email"), ip="198.51.100.11")
        check("email invalide -> 400 EMAIL_INVALID + champ", st == 400 and out == {"error": "EMAIL_INVALID", "field": "email"}, out)
        st, out, _ = post_json(port, "/api/pilot/apply", valid(consent=False), ip="198.51.100.11")
        check("sans consentement -> 400 CONSENT_REQUIRED", st == 400 and out.get("error") == "CONSENT_REQUIRED", out)
        st, out, _ = post_json(port, "/api/pilot/apply", valid(tools=["gmail", "pas-un-outil"]), ip="198.51.100.11")
        check("outil hors catalogue -> 400 TOOLS_INVALID", st == 400 and out.get("error") == "TOOLS_INVALID", out)
        st, out, _ = post_json(port, "/api/pilot/apply", None, ip="198.51.100.11", raw=b"{pas du json", ctype="application/json")
        check("JSON casse -> 400 BODY_INVALID", st == 400 and out.get("error") == "BODY_INVALID", out)
        st, out, _ = post_json(port, "/api/pilot/apply", None, ip="198.51.100.11", raw=b'["liste"]')
        check("corps JSON qui n'est pas un objet -> 400", st == 400 and out.get("error") == "BODY_INVALID", out)
        st, out, _ = post_json(port, "/api/pilot/apply", valid(), ip="198.51.100.11", ctype="text/plain")
        check("Content-Type non JSON -> 415", st == 415, (st, out))
        st, out, _ = post_json(port, "/api/pilot/apply", valid(), ip="198.51.100.11", ctype="application/x-www-form-urlencoded")
        check("formulaire classique (CSRF) -> 415", st == 415, (st, out))
        big = json.dumps(valid(useCase="x" * 20000)).encode()
        try:
            st, out, _ = post_json(port, "/api/pilot/apply", None, ip="198.51.100.11", raw=big)
        except OSError as e:
            st, out = 0, {"_raw": repr(e)}
        check("corps de 20 Ko -> 413 (plafond 16 Ko)", st == 413, (st, out))
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        conn.putrequest("POST", "/api/pilot/apply")
        conn.putheader("Content-Type", "application/json")
        conn.putheader("X-Forwarded-For", "198.51.100.11")
        conn.endheaders()
        r = conn.getresponse()
        check("sans Content-Length -> 411", r.status == 411, r.status)
        conn.close()
        check("rien n'a ete stocke par ces refus", len(json.load(open(store, encoding="utf-8"))["applications"]) == 1)

        print("\n== champ piege ==")
        n_mails = len(srv.mails())
        st, out, _ = post_json(port, "/api/pilot/apply", dict(valid(email="robot@example.com"), contact_me_by_fax_only="+41 00 000"), ip="198.51.100.12")
        check("robot : reponse 200 {ok} identique", st == 200 and out == {"ok": True}, (st, out))
        time.sleep(0.6)
        check("robot : rien de stocke, aucun email", len(json.load(open(store, encoding="utf-8"))["applications"]) == 1 and len(srv.mails()) == n_mails)

        print("\n== XSS : charges hostiles dans chaque champ ==")
        xss = '"><script>alert(1)</script><img src=x onerror=alert(2)>'
        st, out, _ = post_json(port, "/api/pilot/apply", valid(name="A" + xss, company="B" + xss, email="xss.user@example.com",
                                                                  useCase="C" + xss + " et un peu de texte", otherTools="D" + xss[:150]), ip="198.51.100.13")
        check("texte libre hostile : accepte comme donnee", st == 200, (st, out))
        for field, value in (("email", xss + "@example.com"), ("website", "javascript:alert(1)"), ("website", 'https://x.example/"><script>'),
                             ("tools", ["<script>"]), ("lang", "<script>")):
            st, out, _ = post_json(port, "/api/pilot/apply", valid(**{field: value}), ip="198.51.100.14")
            check(f"{field} hostile : refuse (400)", st == 400 and out.get("field") == field, (st, out))
        m = srv.mails(wait_for=2)
        evil = [x for x in m if "xss.user" in x["html"]]
        check("email : les charges sont echappees (&lt;script&gt; visible comme texte)", len(evil) == 1 and "&lt;script&gt;" in evil[0]["html"], evil[:1])
        check("email : aucune balise <img> ni <script> injectee", len(evil) == 1 and "<img" not in evil[0]["html"] and "<script" not in evil[0]["html"])

        print("\n== plafonds ==")
        codes = []
        for i in range(6):
            st, out, _ = post_json(port, "/api/pilot/apply", valid(email=f"limit{i}@ip-test.example", name=f"Test {i}"), ip="198.51.100.50")
            codes.append(st)
        check("par IP : 5 candidatures par heure, la 6e est refusee (429)", codes == [200, 200, 200, 200, 200, 429], codes)
        codes = []
        for i in range(3):
            st, out, _ = post_json(port, "/api/pilot/apply", valid(email=f"same+{i}@mail-test.example", name=f"Meme {i}"), ip=f"198.51.100.6{i}")
            codes.append(st)
        check("par email (alias +tag compris) : 2 par jour, la 3e est refusee (429)", codes == [200, 200, 429], codes)
        codes = []
        for i in range(31):
            st, _, _ = post_json(port, "/api/pilot/apply", None, ip="198.51.100.70", raw=b"{}")
            codes.append(st)
        check("tentatives : 30 par heure et par IP puis 429", codes[:30] == [400] * 30 and codes[30] == 429, (codes[:3], codes[28:]))

        print("\n== porte operateur ==")
        st, out = get_json(port, "/api/pilot/applications")
        check("sans session : 403", st == 403 and out.get("error") == "FORBIDDEN", (st, out))
        data = json.dumps({"email": "client@example.com", "password": ACCOUNT_PASSWORD, "companyName": "Client Test"}).encode()
        st, hd, _ = request(port, "POST", "/api/account/signup", data, {"Content-Type": "application/json", "Content-Length": str(len(data)), "X-Forwarded-For": "198.51.100.80"})
        client_cookie = hd.get("set-cookie", "").split(";")[0]
        check("compte client factice cree", st == 200 and client_cookie.startswith("bk_account="), st)
        st, out = get_json(port, "/api/pilot/applications", cookie=client_cookie)
        check("compte CLIENT (non operateur) : 403", st == 403 and out.get("error") == "FORBIDDEN", (st, out))
        st, out, _ = post_json(port, "/api/pilot/applications/delete", {"id": first_id}, cookie=client_cookie)
        check("compte client : suppression refusee (403)", st == 403, (st, out))
        st, out, _ = post_json(port, "/api/pilot/applications/delete", {"id": first_id})
        check("sans session : suppression refusee (403)", st == 403, (st, out))
        check("la candidature est toujours la", any(r["id"] == first_id for r in json.load(open(store, encoding="utf-8"))["applications"]))
        bad = srv.operator_cookie()
        check("connexion operateur (mot de passe de porte factice)", bool(bad))
        st, out = get_json(port, "/api/pilot/applications", cookie=bad)
        apps = out.get("applications", [])
        check("operateur : 200 + liste (plus recente d'abord)", st == 200 and out.get("count", 0) >= 8 and apps and apps[0]["atUtc"] >= apps[-1]["atUtc"], (st, out.get("count")))
        mine = next((a for a in apps if a["id"] == first_id), {})
        check("operateur : noms d'outils lisibles", [t["name"] for t in mine.get("tools", [])] == ["Gmail", "Slack"], mine.get("tools"))
        hostile = next((a for a in apps if a["name"].startswith("A\"><script>")), None)
        check("operateur : la charge hostile est rendue telle quelle (donnee JSON, echappee par la vue)", hostile is not None and hostile["company"].startswith("B\"><script>"))
        st, out, _ = post_json(port, "/api/pilot/applications/delete", {"id": "../../etc/passwd"}, cookie=bad)
        check("suppression : identifiant invalide -> 400", st == 400 and out.get("error") == "ID_INVALID", (st, out))
        st, out, _ = post_json(port, "/api/pilot/applications/delete", {"id": "PIL-00000000"}, cookie=bad)
        check("suppression : inconnu -> 404", st == 404, (st, out))
        st, out, _ = post_json(port, "/api/pilot/applications/delete", {"id": first_id}, cookie=bad)
        check("suppression par l'operateur -> 200", st == 200 and out.get("ok") is True, (st, out))
        st, out = get_json(port, "/api/pilot/applications", cookie=bad)
        check("la candidature supprimee a disparu", all(a["id"] != first_id for a in out.get("applications", [])))
        leftovers = [n for n in os.listdir(os.path.dirname(store)) if n.startswith(".tmp-")]
        check("aucun fichier temporaire d'ecriture atomique laisse", not leftovers, leftovers)

        print("\n== survie a un redemarrage et aux deploiements ==")
        count_before = json.load(open(store, encoding="utf-8")) and len(json.load(open(store, encoding="utf-8"))["applications"])
        srv.stop()
        srv2 = Server(root, tag="b")
        ck = srv2.operator_cookie()
        st, out = get_json(srv2.port, "/api/pilot/applications", cookie=ck)
        check("apres redemarrage : les candidatures sont toujours la", st == 200 and out.get("count") == count_before, (st, out.get("count"), count_before))
        entry = open(os.path.join(REPO, "deploy", "entrypoint.sh"), encoding="utf-8").read()
        check("entrypoint.sh exclut data/ de la synchronisation du code (le fichier survit aux deploiements)",
              "--exclude='data/'" in entry and os.path.basename(os.path.dirname(store)) == "data")
        st, out, _ = post_json(srv2.port, "/api/pilot/apply", valid(email="after.restart@example.com"), ip="198.51.100.90")
        check("apres redemarrage : nouvelle candidature acceptee", st == 200, (st, out))
        srv2.stop()

        print("\n== echec d'envoi de l'email : la candidature n'est pas perdue ==")
        srv3 = Server(root, env_extra={"BK_E2E_MAIL_FAIL": "1"}, tag="c")
        st, out, _ = post_json(srv3.port, "/api/pilot/apply", valid(email="mailfail@example.com"), ip="198.51.100.91")
        check("echec d'email : la candidature est quand meme acceptee", st == 200 and out.get("ok") is True, (st, out))
        srv3.mails(wait_for=1)
        time.sleep(0.5)
        check("journal : ECHEC de l'email, avec la cause", "[pilot] email au proprietaire : ECHEC (SMTP_TEST_FAILURE)" in srv3.logs(), srv3.logs()[-400:])
        check("candidature stockee malgre l'echec", any(r["email"] == "mailfail@example.com" for r in json.load(open(store, encoding="utf-8"))["applications"]))
        srv3.stop()
    finally:
        for s in (srv, srv2, srv3):
            if s and s.proc.poll() is None:
                s.stop()
        shutil.rmtree(work, ignore_errors=True)
    print("\n" + ("ECHEC : " + ", ".join(failures) if failures else "OK : tous les controles sont passes"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
