# -*- coding: utf-8 -*-
"""Bout en bout : le VRAI dashboard/server.py est demarre sur une COPIE jetable du depot (port libre, jamais les vraies donnees).
Une mission de Dario (TASK + fichiers dans runtime/task-files) est posee comme le fait l'adapter, puis on verifie en HTTP :
  - l'historique du Worker renvoie bien `files` (cause du « je ne vois pas le fichier » de Kader)
  - telechargement, apercu JSON (xlsx / docx / pptx), PDF et image servis inline (en-tetes), SVG/HTML jamais inline
  - droits : sans compte 401, autre client 403, traversee de chemin 404, fichier inconnu 404

Lancer : python tests/file-preview/e2e_server.py      (Windows ou Linux/WSL ; python 3 uniquement)
"""
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
import urllib.parse
import urllib.request

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FIX = os.path.join(REPO, "tests", "file-preview", "fixtures")
SKIP_TOP = {".git", ".claude", "_archive", "runtime", "node_modules", "__pycache__", "tests", "docs"}
PASSWORD = "e2e-" + os.urandom(6).hex()
failures = []
PDF = b"%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%EOF\n"
PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082")


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def ignore(directory, names):
    rel = os.path.relpath(directory, REPO).replace("\\", "/")
    skip = {n for n in names if n == "__pycache__" or (rel == "." and n in SKIP_TOP)}
    if rel == "memory":
        skip.add("runtime")
    if rel == "core/accounts":
        skip.add("data")
    if rel == "core/connectors":
        skip.add("client-credentials")
    if rel == "dashboard":
        skip.add(".gate")
    return skip


class Client:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(self.jar))

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with self.opener.open(req, timeout=20) as r:
                return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read()
        except urllib.error.HTTPError as e:
            return e.code, {k.lower(): v for k, v in e.headers.items()}, e.read()

    def json(self, method, path, body=None):
        st, h, raw = self.call(method, path, body)
        try:
            return st, json.loads(raw.decode("utf-8"))
        except ValueError:
            return st, {"raw": raw[:200].decode("utf-8", "replace")}


def signup(port, email, ip):
    c = Client(port)
    data = json.dumps({"email": email, "password": PASSWORD, "companyName": "Test " + email}).encode()
    req = urllib.request.Request(c.base + "/api/account/signup", data=data, method="POST",
                                 headers={"Content-Type": "application/json", "X-Forwarded-For": ip})
    with c.opener.open(req, timeout=20) as r:
        assert r.status == 200
    st, me = c.json("GET", "/api/account/me")
    assert me.get("clientId"), me
    return c, me["clientId"]


def main():
    root = tempfile.mkdtemp(prefix="bkpreview-")
    server = None
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=ignore)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        env = dict(os.environ, BK_ROOT=app, BK_PORT=str(port), BK_LISTEN_HOST="127.0.0.1", BK_PUBLIC_URL=f"http://127.0.0.1:{port}",
                   BK_STATUS_DISABLE="1")
        for k in ("BK_REQUIRE_GATE", "BK_SECRET_ANTHROPIC"):
            env.pop(k, None)
        server = subprocess.Popen([sys.executable, "-u", os.path.join(app, "dashboard", "server.py")], cwd=app, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding="utf-8", errors="replace")
        anon = Client(port)
        end = time.time() + 40
        while time.time() < end:
            try:
                if anon.call("GET", "/api/health")[0] == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            raise SystemExit("serveur non demarre")

        a, a_id = signup(port, "alice@mail-test.example", "198.51.100.11")
        b, _ = signup(port, "bob@mail-test.example", "198.51.100.12")

        # Mission de Dario posee comme l'adapter la laisse : TASK-*.json + runtime/task-files/<TaskId>/<fichier>
        task_id = "TASK-" + "7F144CF804AD4647A73666E21E34A536"
        tdir = os.path.join(app, "runtime", "task-files", task_id)
        os.makedirs(tdir, exist_ok=True)
        os.makedirs(os.path.join(app, "runtime", "tasks"), exist_ok=True)
        files = {
            "tarif_produits_test.xlsx": open(os.path.join(FIX, "real-worker-generated.xlsx"), "rb").read(),
            "offre.docx": open(os.path.join(FIX, "real-worker-generated.docx"), "rb").read(),
            "deck.pptx": open(os.path.join(FIX, "real-worker-generated.pptx"), "rb").read(),
            "note.pdf": PDF, "logo.png": PNG,
            "vecteur.svg": b'<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>',
            "page.html": b"<html><script>alert(1)</script></html>",
            "cassé.xlsx": b"pas un classeur",
        }
        for name, data in files.items():
            with open(os.path.join(tdir, name), "wb") as f:
                f.write(data)
        record = {"TaskId": task_id, "Worker": "DARIO", "ClientId": a_id, "Request": "Cree un tarif", "Status": "SUCCESS",
                  "Authorized": True, "CreatedAtUtc": "2026-10-12T06:30:00Z",
                  "Result": {"Answer": "Voici le tarif.", "Files": [{"filename": n, "sizeBytes": len(d), "mime": "application/octet-stream"} for n, d in files.items()]}}
        with open(os.path.join(app, "runtime", "tasks", task_id + ".json"), "w", encoding="utf-8") as f:
            json.dump(record, f)
        base = f"/api/missions/{task_id}/files/"
        # Action preparee par le Worker, pas encore confirmee (comme l'ecrit ANTHROPIC-ADAPTER.ps1)
        os.makedirs(os.path.join(app, "memory", "runtime"), exist_ok=True)
        with open(os.path.join(app, "memory", "runtime", f"PENDING-ACTION-{task_id}.json"), "w", encoding="utf-8") as f:
            json.dump({"taskId": task_id, "connectorId": "gmail", "operation": "DRAFT_MESSAGE", "reason": "brouillon a valider",
                       "params": {"to": "client@example.com", "subject": "Offre", "body": "Bonjour", "access_token": "ya29.SECRET-TOKEN-VALUE"}}, f)

        print("\n== historique : l'action en attente revient (carte Confirmer / Annuler apres rechargement) ==")
        st, out = a.json("GET", "/api/workers/dario/activity")
        pa = ((out.get("activity") or [{}])[0]).get("pendingAction") or {}
        check("l'historique renvoie l'action en attente avec le contenu exact (destinataire, objet)",
              pa.get("connectorId") == "gmail" and pa.get("operation") == "DRAFT_MESSAGE" and (pa.get("params") or {}).get("to") == "client@example.com", pa)
        check("les secrets de l'action en attente sont masques dans l'historique", "SECRET-TOKEN-VALUE" not in json.dumps(out), out)
        st, out = b.json("GET", "/api/workers/dario/activity")
        check("un autre client ne voit pas l'action en attente", st == 200 and out.get("activity") == [], out)
        os.remove(os.path.join(app, "memory", "runtime", f"PENDING-ACTION-{task_id}.json"))
        st, out = a.json("GET", "/api/workers/dario/activity")
        check("une fois l'action confirmee/annulee (fichier supprime), la carte ne revient plus", "pendingAction" not in (out.get("activity") or [{}])[0], out)

        print("\n== historique : les fichiers de la mission reviennent ==")
        st, out = a.json("GET", "/api/workers/dario/activity")
        item = (out.get("activity") or [{}])[0]
        names = sorted(f["filename"] for f in item.get("files", []))
        check("l'activite de Dario renvoie les fichiers de la mission (cause du « je ne vois pas le fichier »)",
              st == 200 and "tarif_produits_test.xlsx" in names and len(names) == len(files), (st, names))
        st, out = b.json("GET", "/api/workers/dario/activity")
        check("un autre client ne voit ni la mission ni ses fichiers", st == 200 and out.get("activity") == [], out)

        print("\n== telechargement ==")
        st, h, raw = a.call("GET", base + "tarif_produits_test.xlsx")
        check("telechargement : 200, octets identiques, Content-Disposition attachment",
              st == 200 and raw == files["tarif_produits_test.xlsx"] and h.get("content-disposition", "").startswith("attachment"), (st, h.get("content-disposition")))
        st, h, raw = a.call("GET", base + "note.pdf")
        check("PDF sans ?inline=1 : toujours en piece jointe", st == 200 and h.get("content-disposition", "").startswith("attachment"), h)

        print("\n== apercu JSON ==")
        st, out = a.json("GET", base + "tarif_produits_test.xlsx/preview")
        sheets = (out.get("preview") or {}).get("sheets") or []
        check("apercu xlsx : ok, feuille « Devis », formules calculees", st == 200 and out.get("ok") is True and sheets and sheets[0]["name"] == "Devis"
              and sheets[0]["rows"][1][3] == "107.019" and sheets[0]["rows"][4][1] == "699", (st, str(out)[:300]))
        st, out = a.json("GET", base + "offre.docx/preview")
        check("apercu docx : blocs titre / paragraphe / tableau", out.get("ok") is True and {"h", "p", "table"} <= {b_["type"] for b_ in out["preview"]["blocks"]}, str(out)[:200])
        st, out = a.json("GET", base + "deck.pptx/preview")
        check("apercu pptx : diapositives", out.get("ok") is True and out["preview"]["kind"] == "slides" and out["preview"]["slides"], str(out)[:200])
        st, out = a.json("GET", base + "note.pdf/preview")
        check("apercu pdf : kind=pdf (le navigateur l'affiche)", out.get("ok") is True and out["preview"]["kind"] == "pdf", out)
        st, out = a.json("GET", base + "logo.png/preview")
        check("apercu image : kind=image", out.get("ok") is True and out["preview"]["kind"] == "image", out)
        st, out = a.json("GET", base + urllib.parse.quote("cassé.xlsx") + "/preview")
        check("fichier abime : ok=false + message, jamais d'erreur 500", st == 200 and out.get("ok") is False and out.get("error"), (st, out))
        st, out = a.json("GET", base + "vecteur.svg/preview")
        check("svg : aucun apercu actif (kind=none)", out.get("ok") is True and out["preview"]["kind"] == "none", out)

        print("\n== affichage en ligne (?inline=1) ==")
        st, h, raw = a.call("GET", base + "note.pdf?inline=1")
        check("PDF inline : application/pdf, Content-Disposition inline, nosniff",
              st == 200 and h.get("content-type") == "application/pdf" and h.get("content-disposition", "").startswith("inline")
              and h.get("x-content-type-options") == "nosniff" and raw == PDF, h)
        st, h, raw = a.call("GET", base + "logo.png?inline=1")
        check("image inline : image/png + CSP sandbox", st == 200 and h.get("content-type") == "image/png" and "sandbox" in h.get("content-security-policy", ""), h)
        for bad in ("vecteur.svg", "page.html", "tarif_produits_test.xlsx"):
            st, h, raw = a.call("GET", base + bad + "?inline=1")
            check(f"{bad} avec ?inline=1 : JAMAIS servi en ligne (reste en piece jointe)",
                  st == 200 and h.get("content-disposition", "").startswith("attachment") and h.get("x-content-type-options") == "nosniff", h)

        print("\n== droits et chemins ==")
        st, _ = anon.json("GET", base + "tarif_produits_test.xlsx/preview")
        check("sans compte : apercu refuse (401)", st == 401, st)
        st, _, _ = anon.call("GET", base + "tarif_produits_test.xlsx")
        check("sans compte : telechargement refuse (401)", st == 401, st)
        st, out = b.json("GET", base + "tarif_produits_test.xlsx/preview")
        check("autre client : apercu refuse (403)", st == 403, (st, out))
        st, _, _ = b.call("GET", base + "tarif_produits_test.xlsx?inline=1")
        check("autre client : telechargement refuse (403)", st == 403, st)
        for evil in ("..%2F..%2Ftasks%2F" + task_id + ".json", "..%5C..%5Cx", "%2e%2e", "inconnu.xlsx"):
            st, _ = a.json("GET", base + evil + "/preview")
            st2, _, _ = a.call("GET", base + evil)
            check(f"chemin « {evil} » : 404", st == 404 and st2 == 404, (st, st2))
        st, _ = a.json("GET", "/api/missions/TASK-ZZZ/files/x.xlsx/preview")
        check("identifiant de mission invalide : 404", st == 404, st)
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(10)
            except Exception:
                server.kill()
        shutil.rmtree(root, ignore_errors=True)

    print()
    if failures:
        print(f"{len(failures)} ECHEC(S) :")
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("TOUT PASSE")


if __name__ == "__main__":
    main()
