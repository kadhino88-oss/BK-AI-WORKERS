# -*- coding: utf-8 -*-
"""Bout en bout de l'atelier de sites : le VRAI dashboard/server.py démarre sur une COPIE jetable du dépôt (port libre, BK_PROJECTS=1), un
faux lanceur sans modèle qui utilise les VRAIS outils site_* (tests/site-factory/site_runner.py) et un faux exécuteur de connecteurs qui note
ses appels. Aucun modèle, aucun réseau, aucun secret.

Parcours HTTP : projet « site vitrine » jusqu'à DONE ; bloc « site » du détail ; lien d'aperçu (création, en-têtes exacts, bandeau, aucun cookie
posé, pages et ressources, corpus de chemins piégés, 404 identiques) ; isolation entre clients ; export zip (dist et source) ; publication
préparée (brouillons WordPress) puis une validation = un appel de connecteur au contenu exact ; révocation ; puis un second serveur SANS
BK_PROJECTS : /preview/ n'est plus servi.

Avec --keep, le serveur reste démarré après les vérifications (pour la recette manuelle dans un navigateur : page hostile /hostile/).

    python tests/site-factory/e2e_site_server.py [--keep]"""
import io
import json
import os
import shutil
import sys
import tempfile
import time
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(REPO, "tests", "projects"))
import e2e_server as E  # noqa: E402  (aides du bout en bout du moteur : copie du dépôt, comptes, client HTTP)
import test_engine_site as T  # noqa: E402  (plan et actions du Worker)

EXPECTED_CSP = ("sandbox allow-scripts allow-popups allow-popups-to-escape-sandbox; default-src 'none'; img-src 'self' data:; "
                "style-src 'self' 'unsafe-inline'; font-src 'self' data:; script-src 'self'; media-src 'self'; connect-src 'none'; frame-src 'none'; "
                "object-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'self'")

WRAPPER = r'''
import json, os, runpy, sys
ROOT = os.environ["BK_ROOT"]
sys.path.insert(0, os.path.join(ROOT, "dashboard"))
import projects_wiring
_orig = projects_wiring.build
RUNNER = os.path.join(ROOT, "tests", "site-factory", "site_runner.py")
CALLS = os.path.join(ROOT, "_e2e", "connector-calls.jsonl")

def fake_connector(conn, op, params, client_id):
    with open(CALLS, "a", encoding="utf-8") as f:
        f.write(json.dumps({"connector": conn, "operation": op, "params": params, "clientId": client_id}, ensure_ascii=False) + "\n")
    return {"Status": "SUCCESS", "Detail": "fake"}

def build(srv, env=None, **ov):
    ov.setdefault("runner_cmd", lambda i, o: [sys.executable, RUNNER, i, o])
    ov.setdefault("run_connector", fake_connector)
    ov.setdefault("tick_sec", 0.3)
    return _orig(srv, env, **ov)

projects_wiring.build = build
runpy.run_path(os.path.join(ROOT, "dashboard", "server.py"), run_name="__main__")
'''

HOSTILE_HTML = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Page hostile de test</title>
<script src="../assets/hostile.js" defer></script></head>
<body><main id="main"><h1>Page hostile (test d'isolation)</h1><pre id="out">en attente</pre>
<form action="/api/projects" method="post"><input name="goal" value="injection"><button id="go">envoyer</button></form>
<script>document.getElementById('out').textContent = 'SCRIPT EN LIGNE EXECUTE';</script></main></body></html>
"""

HOSTILE_JS = r"""
(function () {
  var r = {};
  function t(name, fn) { try { r[name] = 'LU:' + String(fn()).slice(0, 80); } catch (e) { r[name] = 'BLOQUE:' + (e && e.name); } }
  t('cookie', function () { return document.cookie; });
  t('localStorage', function () { return window.localStorage.getItem('x'); });
  t('sessionStorage', function () { return window.sessionStorage.length; });
  t('parentDocument', function () { return window.parent.document.cookie; });
  t('topLocation', function () { return window.top.location.href; });
  t('origin', function () { return window.origin; });
  r.fetch = 'en cours';
  r.inline = document.getElementById('out').textContent;
  function show() { document.getElementById('out').textContent = JSON.stringify(r); try { window.parent.postMessage({bkHostile: r}, '*'); } catch (e) {} }
  try {
    fetch('/api/projects', {credentials: 'include'}).then(function (x) { return x.text(); }).then(function (b) { r.fetch = 'LU:' + b.slice(0, 80); show(); },
      function (e) { r.fetch = 'BLOQUE:' + (e && e.name); show(); });
  } catch (e) { r.fetch = 'BLOQUE:' + (e && e.name); }
  show();
})();
"""


def main():
    keep = "--keep" in sys.argv
    root = tempfile.mkdtemp(prefix="bksite-e2e-")
    procs = []
    try:
        app = os.path.join(root, "app")
        shutil.copytree(REPO, app, ignore=E.ignore)
        for rel in ("tests/projects/fake_runner.py", "tests/site-factory/site_runner.py"):
            os.makedirs(os.path.dirname(os.path.join(app, *rel.split("/"))), exist_ok=True)
            shutil.copy2(os.path.join(REPO, *rel.split("/")), os.path.join(app, *rel.split("/")))
        os.makedirs(os.path.join(app, "_e2e"), exist_ok=True)
        with open(os.path.join(app, "_e2e", "wrapper.py"), "w", encoding="utf-8") as f:
            f.write(WRAPPER)
        E.put_scenario(app, T.scenario())
        proc, port = E.start_server(app, True)
        procs.append(proc)
        check = E.check
        alice, a_id = E.signup(port, "alice@mail-test.example", "198.51.100.31")
        bob, b_id = E.signup(port, "bob@mail-test.example", "198.51.100.32")
        anon = E.Client(port, "198.51.100.33")
        owner = E.Client(port, "198.51.100.99")
        assert owner.post("/api/gate/login", {"password": E.GATE_PASSWORD})[0] == 200
        for cid in (a_id, b_id):
            st, out = owner.post("/api/admin/set-plan", {"clientId": cid, "planId": "equipe", "paidMonths": 1})
            assert st == 200, (st, out)
        os.makedirs(os.path.join(app, "core", "connectors", "data"), exist_ok=True)
        with open(os.path.join(app, "core", "connectors", "data", a_id + ".json"), "w", encoding="utf-8") as f:
            json.dump(["wordpress"], f)
        origin = {"Origin": f"http://127.0.0.1:{port}"}

        print("\n== un projet « site vitrine » jusqu'au bout ==")
        st, out = alice.post("/api/projects", {"goal": "Créer le site vitrine de mon cabinet de physiothérapie à Lausanne", "workerId": "lucas", "autoStart": True}, headers=origin)
        pid = out.get("projectId")
        check("création : 201", st == 201 and pid, (st, out))
        done = E.poll(lambda: (alice.get(f"/api/projects/{pid}/progress")[1].get("status") in ("DONE", "FAILED", "WAITING_INPUT")) and alice.get(f"/api/projects/{pid}/progress")[1].get("status"), timeout=240)
        check("le projet se termine : DONE", done == "DONE", done)
        st, d = alice.get(f"/api/projects/{pid}")
        site = d.get("site") or {}
        check("détail : bloc site (construit, 12 pages, à jour, WordPress disponible, aucun aperçu encore)",
              site.get("built") and site.get("pages") == 12 and site.get("stale") is False and site.get("canPublishWordpress") and site.get("preview", {}).get("active") is False, site)
        st, dl = alice.get(f"/api/projects/{pid}/deliverables")
        paths = [x["path"] for x in dl.get("deliverables", [])]
        check("livrables : zip et guide de mise en ligne", "deliverables/site-atelier-lumen.zip" in paths and "deliverables/MISE-EN-LIGNE.md" in paths, paths)

        print("\n== aperçu privé ==")
        st, out = alice.post(f"/api/projects/{pid}/site/preview", {}, headers={"Origin": "https://evil.example"})
        check("création d'aperçu depuis une autre origine : 403", st == 403 and out.get("error") == "BAD_ORIGIN", (st, out))
        st, out = bob.post(f"/api/projects/{pid}/site/preview", {}, headers=origin)
        check("un autre client : 404", st == 404, (st, out))
        st, out = anon.post(f"/api/projects/{pid}/site/preview", {}, headers=origin)
        check("sans compte : 401", st == 401, (st, out))
        st, out = alice.post(f"/api/projects/{pid}/site/preview", {"hours": 24}, headers=origin)
        url = out.get("url") or ""
        check("aperçu créé : URL à jeton, pas de jeton brut dans la réponse, iframe sandbox indiquée",
              st == 200 and url.startswith("/preview/") and len(url.split("/")[2]) == 32 and "token" not in out and out.get("sandbox") == "allow-scripts allow-popups allow-popups-to-escape-sandbox", (st, out))
        token = url.split("/")[2] if url else ""
        st, d = alice.get(f"/api/projects/{pid}")
        check("détail : aperçu actif", (d.get("site") or {}).get("preview", {}).get("url") == url, d.get("site"))
        ev = json.dumps(alice.get(f"/api/projects/{pid}/progress?since=0")[1])
        check("le jeton n'apparaît dans aucun événement", token and token not in ev)
        for who, cli in (("anonyme sans cookie", anon), ("cliente connectée", alice)):
            st, raw, hd = cli.call("GET", url)
            h = {k.lower(): v for k, v in hd.items()}
            check(f"aperçu ({who}) : 200, CSP exacte, sans allow-same-origin, aucun cookie posé",
                  st == 200 and h.get("content-security-policy") == EXPECTED_CSP and "allow-same-origin" not in h.get("content-security-policy", "") and "set-cookie" not in h
                  and h.get("x-robots-tag") == "noindex, nofollow, noarchive" and h.get("referrer-policy") == "no-referrer" and h.get("cache-control") == "private, no-store"
                  and h.get("x-content-type-options") == "nosniff" and h.get("cross-origin-opener-policy") == "same-origin" and "access-control-allow-origin" not in h, (st, h))
            check(f"aperçu ({who}) : bandeau « non publié » et contenu du site", "Aperçu privé BK-AI-WORKERS — non publié".encode("utf-8") in raw and b"Retrouver le plaisir" in raw)
        for p, ctype in (("en/about/", "text/html"), ("assets/style.css", "text/css"), ("assets/img/og.png", "image/png"), ("sitemap.xml", "application/xml")):
            st, raw, hd = anon.call("GET", url + p)
            check(f"aperçu : {p} -> 200 {ctype}", st == 200 and {k.lower(): v for k, v in hd.items()}.get("content-type", "").startswith(ctype), st)
        st0, raw0, _ = anon.call("GET", f"/preview/{'Q' * 32}/")
        same = []
        for bad in ("../state.json", "..%2f..%2fstate.json", "%2e%2e/%2e%2e/state.json", "%252e%252e/state.json", "..%5c..%5cstate.json", ".hidden.css",
                    "assets%2f..%2f..%2f..%2fstate.json", "index.html%00.png", "site.json", "assets/"):
            st, raw, hd = anon.call("GET", url + bad)
            same.append((bad, st, raw == raw0))
        check("chemins piégés : tous 404, réponse identique à un jeton inconnu", st0 == 404 and all(s == 404 and eq for _b, s, eq in same), same)
        st, raw, hd = anon.call("GET", "/preview/" + token)
        check("sans barre finale : redirection vers l'aperçu", st == 302 and hd.get("Location") == f"/preview/{token}/", (st, hd.get("Location")))

        # page hostile (recette manuelle dans un navigateur avec --keep) : en HTTP, ses en-têtes suffisent à prouver la politique
        dist = os.path.join(app, "runtime", "projects", a_id, pid, "workspace", "site", "dist")
        os.makedirs(os.path.join(dist, "hostile"), exist_ok=True)
        with open(os.path.join(dist, "hostile", "index.html"), "w", encoding="utf-8") as f:
            f.write(HOSTILE_HTML)
        with open(os.path.join(dist, "assets", "hostile.js"), "w", encoding="utf-8") as f:
            f.write(HOSTILE_JS)
        st, raw, hd = alice.call("GET", url + "hostile/")
        check("page hostile servie sous la même CSP sandbox (script en ligne interdit, connect-src 'none', form-action 'none')",
              st == 200 and {k.lower(): v for k, v in hd.items()}.get("content-security-policy") == EXPECTED_CSP, st)

        print("\n== export ==")
        st, raw, hd = alice.call("GET", f"/api/projects/{pid}/site/export.zip")
        h = {k.lower(): v for k, v in hd.items()}
        names = zipfile.ZipFile(io.BytesIO(raw)).namelist() if st == 200 else []
        check("zip du site : pièce jointe nommée, nosniff, dist + guide", st == 200 and 'filename="site-atelier-lumen.zip"' in h.get("content-disposition", "")
              and h.get("x-content-type-options") == "nosniff" and "site/index.html" in names and "MISE-EN-LIGNE.md" in names, (st, h, names[:4]))
        st2, raw2, _ = alice.call("GET", f"/api/projects/{pid}/site/export.zip")
        check("zip reproductible (mêmes octets, hors fichiers de test ajoutés)", raw2 == raw)
        st, raw, hd = alice.call("GET", f"/api/projects/{pid}/site/export.zip?scope=source")
        names = zipfile.ZipFile(io.BytesIO(raw)).namelist() if st == 200 else []
        check("zip source : src/ et site.json en plus", st == 200 and "source/site.json" in names, names[-3:])
        check("export d'un autre client : 404", bob.call("GET", f"/api/projects/{pid}/site/export.zip")[0] == 404)

        print("\n== publication préparée, validée par le client ==")
        os.remove(os.path.join(dist, "hostile", "index.html"))
        os.rmdir(os.path.join(dist, "hostile"))
        os.remove(os.path.join(dist, "assets", "hostile.js"))
        st, out = bob.post(f"/api/projects/{pid}/site/publish", {"target": "wordpress"}, headers=origin)
        check("publication par un autre client : 404", st == 404, (st, out))
        st, out = alice.post(f"/api/projects/{pid}/site/publish", {"target": "ftp"}, headers=origin)
        check("cible inconnue : 400", st == 400, (st, out))
        st, out = alice.post(f"/api/projects/{pid}/site/publish", {"target": "wordpress"}, headers=origin)
        check("publication préparée : 6 brouillons de pages en attente", st == 200 and out.get("queued") == 6 and out.get("connector") == "wordpress", (st, out))
        calls_path = os.path.join(app, "_e2e", "connector-calls.jsonl")
        check("rien n'est sorti avant la validation", not os.path.exists(calls_path))
        st, ap = alice.get(f"/api/projects/{pid}/approvals?status=PENDING")
        items = ap.get("approvals") or ap.get("items") or []
        wp = [i for i in items if i.get("operation") == "CREATE_PAGE_DRAFT"]
        check("articles : connecteur WordPress, risque moyen, réversibles, texte « BROUILLON »", len(wp) == 6 and all(i["risk"] == "medium" and i["reversible"] and "BROUILLON" in i["display"]["what"] for i in wp), items[:1])
        st, out = alice.post(f"/api/projects/{pid}/site/publish", {"target": "wordpress"}, headers=origin)
        st, ap2 = alice.get(f"/api/projects/{pid}/approvals?status=PENDING")
        check("rejouer la préparation ne duplique rien", len(ap2.get("approvals") or ap2.get("items") or []) == len(items), (st, out))
        if wp:
            first = wp[0]
            st, out = alice.post(f"/api/projects/{pid}/approvals/{first['id']}/approve", {}, headers=origin)
            check("validation d'une page : 200", st == 200, (st, out))
            calls = E.poll(lambda: os.path.exists(calls_path) and [json.loads(l) for l in open(calls_path, encoding="utf-8")], timeout=30)
            check("une validation = UN appel CREATE_PAGE_DRAFT, pour ce client", calls and len(calls) == 1 and calls[0]["operation"] == "CREATE_PAGE_DRAFT" and calls[0]["clientId"] == a_id, calls)
            check("le contenu envoyé est exactement celui affiché", calls and calls[0]["params"].get("Title") == first["params"].get("Title")
                  and "wp:html" in calls[0]["params"].get("Content", ""), calls[:1])

        print("\n== révocation ==")
        st, out = bob.delete(f"/api/projects/{pid}/site/preview")
        check("révocation par un autre client : 404", st == 404, (st, out))
        if keep:
            print(f"\n  SERVEUR CONSERVÉ : http://127.0.0.1:{port}{url}hostile/ (page hostile recréée). Ctrl+C pour arrêter.")
            os.makedirs(os.path.join(dist, "hostile"), exist_ok=True)
            with open(os.path.join(dist, "hostile", "index.html"), "w", encoding="utf-8") as f:
                f.write(HOSTILE_HTML)
            with open(os.path.join(dist, "assets", "hostile.js"), "w", encoding="utf-8") as f:
                f.write(HOSTILE_JS)
            with open(os.path.join(root, "KEEP.json"), "w", encoding="utf-8") as f:
                json.dump({"port": port, "preview": url, "email": "alice@mail-test.example", "password": E.PASSWORD}, f)
            print(f"  informations de connexion de test : {os.path.join(root, 'KEEP.json')}")
            try:
                while True:
                    time.sleep(5)
            except KeyboardInterrupt:
                pass
        st, out = alice.delete(f"/api/projects/{pid}/site/preview")
        check("révocation : 200", st == 200 and out.get("revoked") == 1, (st, out))
        st, raw, _ = anon.call("GET", url)
        check("lien révoqué : même 404 qu'un jeton inconnu", st == 404 and raw == raw0, st)

        tail = ""
        procs[0].terminate()
        procs[0].wait(timeout=15)
        with open(procs[0].log_path, encoding="utf-8", errors="replace") as f:
            tail = f.read()
        bad = [l for l in tail.splitlines() if "Traceback" in l or "[projects-api]" in l or "site_routes" in l]
        check("aucune trace d'erreur interne dans le journal du serveur", not bad, bad[:3])

        print("\n== second serveur, projets désactivés : l'aperçu n'est plus servi ==")
        proc2, port2 = E.start_server(app, False)
        procs.append(proc2)
        st, raw, hd = E.Client(port2).call("GET", url)
        check("BK_PROJECTS=0 : /preview/ ne sert aucun fichier du site", b"Retrouver le plaisir" not in raw and "sandbox" not in {k.lower(): v for k, v in hd.items()}.get("content-security-policy", ""), st)
        check("BK_PROJECTS=0 : /api/health inchangé", E.Client(port2).get("/api/health")[0] == 200)
        proc2.terminate()
    except BaseException:
        for p in procs:
            try:
                with open(p.log_path, encoding="utf-8", errors="replace") as f:
                    print("---- fin du journal du serveur ----")
                    print("".join(f.readlines()[-40:]))
            except Exception:
                pass
        raise
    finally:
        for p in procs:
            try:
                p.kill()
            except Exception:
                pass
        shutil.rmtree(root, ignore_errors=True)
    print()
    if E.failures:
        print(f"{len(E.failures)} vérification(s) en échec :")
        for f in E.failures:
            print("  -", f)
        return 1
    print("OK : toutes les vérifications passent.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
