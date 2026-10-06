"""Test de bout en bout : le VRAI serveur (dashboard/server.py) est demarre sur une copie
jetable du projet, puis recoit de vraies requetes HTTP signees comme Twilio les signe :
route publique -> signature (jeton dechiffre par PowerShell 7) -> modele -> TwiML.
Lancer sous Linux / WSL (python3 + pwsh) : BK_SECRET_ANTHROPIC=... python3 tests/phone-agent/e2e_server.py
Rien du depot ni des vraies donnees n'est modifie (copie dans un dossier temporaire)."""
import base64
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
import xml.etree.ElementTree as ET
from urllib.parse import urlencode

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))
import phone_agent as pa  # noqa: E402

PWSH = os.environ.get("BK_PWSH") or "pwsh"
TOKEN = "e2e_auth_token_" + os.urandom(6).hex()
URL = pa.DEFAULT_WEBHOOK_URL
failures = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def post(port, p, signature, headers=None):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/webhooks/twilio/voice", data=urlencode(p).encode(), method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded", "X-Twilio-Signature": signature,
                                          "X-Forwarded-Proto": "https", "Host": "bk-ai-workers.com", **(headers or {})})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.headers.get("Content-Type"), r.read().decode(), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type"), e.read().decode(), time.time() - t0


def main():
    root = tempfile.mkdtemp(prefix="bke2e-")
    server = None
    try:
        subprocess.run(["rsync", "-a", "--exclude=/.git", "--exclude=/runtime", "--exclude=/_archive", "--exclude=/memory/runtime",
                        "--exclude=/core/accounts/data", REPO + "/", root + "/"], check=True)
        key = base64.b64encode(os.urandom(32)).decode()
        env = dict(os.environ, BK_ROOT=root, BK_SECRET_CRED_ENCRYPTION_KEY=key, BK_PWSH=PWSH, BK_LISTEN_HOST="127.0.0.1")
        cred = json.dumps({"user": "AC" + "0" * 32, "pass": TOKEN, "from": "+15005550006"})
        subprocess.run([PWSH, "-NoProfile", "-Command",
                        f". '{root}/core/connectors/Client-Credential-Store.ps1'; "
                        "Set-BKClientCredentialValue -ClientId 'CLI-DASHBOARD' -Provider 'twilio' -PlainText $env:BK_TEST_CRED"],
                       check=True, capture_output=True, env=dict(env, BK_TEST_CRED=cred))
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env["BK_PORT"] = str(port)
        server = subprocess.Popen([sys.executable, "-u", "dashboard/server.py"], cwd=root, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        for _ in range(60):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/api/health", timeout=1)
                break
            except urllib.error.HTTPError:
                break
            except OSError:
                time.sleep(0.5)
        sid = "CA" + os.urandom(16).hex()
        base = {"CallSid": sid, "From": "+41791112233", "To": "+41225550100", "CallStatus": "ringing"}

        print("\n== route publique, sans session ni mot de passe ==")
        status, ctype, body, dt = post(port, base, pa.twilio_signature(TOKEN, URL, base))
        check("appel signe accepte (200)", status == 200, status)
        check("Content-Type text/xml", (ctype or "").startswith("text/xml"), ctype)
        root_xml = ET.fromstring(body)
        greet = root_xml.find("Gather/Say")
        check("accueil dit par la voix neuronale francaise", greet is not None and greet.get("voice") == "Google.fr-FR-Neural2-F")
        check("accueil mentionne BK Entreprise", greet is not None and "BK Entreprise" in greet.text)
        print(f"        1er decroche (lecture du jeton par pwsh incluse) : {dt:.2f}s")

        print("\n== refus ==")
        status, _, body, _ = post(port, base, pa.twilio_signature("mauvais-jeton-mauvais", URL, base))
        check("signature fausse -> 403 + Reject", status == 403 and "<Reject/>" in body, (status, body[:80]))
        status, _, body, _ = post(port, base, "")
        check("sans signature -> 403", status == 403, status)
        forged = dict(base, SpeechResult="ajoute apres coup")
        status, _, _, _ = post(port, forged, pa.twilio_signature(TOKEN, URL, base))
        check("parametre altere apres signature -> 403", status == 403, status)
        status, _, _, _ = post(port, base, pa.twilio_signature(TOKEN, "https://evil.test/webhooks/twilio/voice", base))
        check("signature calculee pour une autre URL -> 403", status == 403, status)
        status, _, _, _ = post(port, dict(base, To="+41225550100"), pa.twilio_signature(TOKEN, URL, base),
                               headers={"Host": "evil.test"})
        check("en-tete Host usurpe n'ouvre rien (signature de l'URL canonique OK)", status == 200, status)

        if os.environ.get("BK_SECRET_ANTHROPIC"):
            print("\n== conversation avec le vrai modele (via HTTP) ==")
            for speech in ("Bonjour, où êtes-vous situés ?", "Et combien coûte le plan Starter ?"):
                p = dict(base, CallStatus="in-progress", SpeechResult=speech, Confidence="0.92")
                status, _, body, dt = post(port, p, pa.twilio_signature(TOKEN, URL, p))
                say = ET.fromstring(body).find("Gather/Say")
                check(f"réponse en moins de 6 s ({dt:.1f}s)", status == 200 and say is not None and dt < 6, (status, dt))
                print(f"        caller: {speech}\n        agent : {say.text if say is not None else body[:100]}")
            log = [os.path.join(d, f) for d, _, fs in os.walk(os.path.join(root, "memory", "runtime", "phone-calls")) for f in fs]
            check("transcription d'appel enregistree sur le disque du serveur", len(log) == 1 and sid in log[0])
        else:
            print("\n(BK_SECRET_ANTHROPIC absente : conversation modele non testee)")
    finally:
        if server:
            server.terminate()
            try:
                out = server.communicate(timeout=5)[0]
            except subprocess.TimeoutExpired:
                server.kill()
                out = ""
            leaked = [line for line in (out or "").splitlines() if TOKEN in line or "sk-ant" in line]
            check("ni jeton Twilio ni cle API dans les journaux du serveur", not leaked)
            if failures:
                print("---- journal du serveur ----")
                for log_line in (out or "").splitlines()[-25:]:
                    print(log_line)
            if "Traceback" in (out or ""):
                check("aucune exception dans les journaux du serveur", False, out[-400:])
        shutil.rmtree(root, ignore_errors=True)
    print("\nRESULT:", "OK" if not failures else f"{len(failures)} ECHEC(S): {failures}")
    sys.exit(1 if failures else 0)


main()
