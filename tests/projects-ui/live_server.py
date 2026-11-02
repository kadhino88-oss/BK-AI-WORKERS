# -*- coding: utf-8 -*-
"""Serveur de demonstration JETABLE pour verifier l'interface des projets dans un vrai navigateur.

Le VRAI dashboard/server.py (avec la VRAIE interface de ce depot) est demarre sur une COPIE du depot (port libre, jamais les vraies donnees),
BK_PROJECTS=1, faux lanceur d'etapes (aucun modele, aucun reseau, aucun cout), faux connecteurs. Deux comptes de test sont crees (mots de passe
generes) et des projets sont amenes dans chaque etat que l'interface doit savoir montrer. Les identifiants vont dans un fichier, jamais a l'ecran.

    python tests/projects-ui/live_server.py <fichier-de-sortie.json>        (reste en vie jusqu'a Ctrl+C ou jusqu'a la suppression du fichier)

Sortie : { "base": "http://127.0.0.1:PORT", "team": {"email","password","clientId","projects":{etat: id}}, "solo": {...} }
"""
import json
import os
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "projects"))
import e2e_server as E  # noqa: E402
import fake_runner as fr  # noqa: E402


def main():
    out_path = os.path.abspath(sys.argv[1])
    root = tempfile.mkdtemp(prefix="bkproj-ui-")
    procs = []
    try:
        app = os.path.join(root, "app")
        shutil.copytree(E.REPO, app, ignore=E.ignore)
        os.makedirs(os.path.join(app, "tests", "projects"), exist_ok=True)
        shutil.copy2(os.path.join(E.HERE, "fake_runner.py"), os.path.join(app, "tests", "projects", "fake_runner.py"))
        os.makedirs(os.path.join(app, "_e2e"), exist_ok=True)
        with open(os.path.join(app, "_e2e", "wrapper.py"), "w", encoding="utf-8") as f:
            f.write(E.WRAPPER)
        E.put_scenario(app, {})
        proc, port = E.start_server(app, True)
        procs.append(proc)
        team, team_id = E.signup(port, "equipe@mail-test.example", "198.51.100.21")
        owner = E.Client(port, "198.51.100.99")
        assert owner.post("/api/gate/login", {"password": E.GATE_PASSWORD})[0] == 200
        assert owner.post("/api/admin/set-plan", {"clientId": team_id, "planId": "equipe", "paidMonths": 1})[0] == 200
        os.makedirs(os.path.join(app, "core", "connectors", "data"), exist_ok=True)
        with open(os.path.join(app, "core", "connectors", "data", team_id + ".json"), "w", encoding="utf-8") as f:
            json.dump(["slack"], f)
        origin = {"Origin": f"http://127.0.0.1:{port}"}
        projects = {}

        def status_of(pid):
            st, o = team.get(f"/api/projects/{pid}/progress")
            return (o.get("status"), o.get("waitingFor")) if st == 200 else (None, None)

        # 1. projet termine (parcours complet par defaut)
        st, o = team.post("/api/projects", {"goal": "Creer le site vitrine de mon cabinet de physiotherapie a Lausanne", "workerId": "chloe", "autoStart": True}, headers=origin)
        projects["done"] = o["projectId"]
        E.poll(lambda: status_of(projects["done"])[0] == "DONE", timeout=150)
        # 2. plan a valider
        st, o = team.post("/api/projects", {"goal": "Preparer une liste de 30 prospects qualifies dans le secteur de la comptabilite", "workerId": "chloe", "autoStart": False}, headers=origin)
        projects["plan"] = o["projectId"]
        E.poll(lambda: status_of(projects["plan"])[1] == "PLAN_VALIDATION", timeout=90)
        # 3. validations en attente (messages, action manuelle, action a risque eleve)
        plan = fr.default_plan({})
        plan["steps"][2]["requiresApprovalsFrom"] = ["S2"]
        asks = [{"tool": "request_approval", "input": {"connectorId": "slack", "operation": "POST_MESSAGE", "title": f"Message {i}", "what": "Envoie un message a l'equipe",
                                                       "params": {"channel": "#general", "text": f"Bonjour {i}"}}} for i in range(3)]
        asks.append({"tool": "request_approval", "input": {"kind": "manual", "title": "Ajouter le DNS", "details": "Chez votre hebergeur, ajoutez l'enregistrement A"}})
        asks.append({"tool": "request_approval", "input": {"connectorId": "slack", "operation": "POST_MESSAGE", "title": "Envoi a 30 personnes", "what": "Envoie un message",
                                                           "recipients": 30, "params": {"channel": "#vip", "text": "Annonce"}}})
        E.put_scenario(app, {"plan": {"actions": [{"tool": "project_plan", "input": {"action": "set", "plan": plan}}], "complete": {"status": "DONE", "summary": "Plan pret."}},
                             "S2": {"actions": [{"tool": "workspace_write", "input": {"path": "site/about.html", "mode": "overwrite", "content": "<h1>A propos</h1> contenu"}},
                                                {"tool": "deliverable_register", "input": {"path": "site/about.html", "title": "A propos"}}] + asks}})
        st, o = team.post("/api/projects", {"goal": "Lancer la newsletter de ma boulangerie avec trois messages prets a partir", "workerId": "chloe", "autoStart": True}, headers=origin)
        projects["approval"] = o["projectId"]
        E.poll(lambda: status_of(projects["approval"])[0] == "WAITING_APPROVAL", timeout=120)
        # 4. en cours (une etape longue), plafond atteint (plafond minimal)
        E.put_scenario(app, {"S1": {"sleep": 900}})
        st, o = team.post("/api/projects", {"goal": "Preparer le calendrier editorial de 30 jours pour trois reseaux sociaux", "workerId": "chloe", "autoStart": True}, headers=origin)
        projects["running"] = o["projectId"]
        E.poll(lambda: status_of(projects["running"])[0] == "RUNNING", timeout=90)
        E.put_scenario(app, {"_defaults": {"chf": 0.5}})
        st, o = team.post("/api/projects", {"goal": "Auditer le referencement de mon site et proposer les corrections", "workerId": "chloe", "autoStart": True, "creditsCap": 12}, headers=origin)
        projects["budget"] = o["projectId"] if st == 201 else None
        if projects["budget"]:
            E.poll(lambda: status_of(projects["budget"])[0] in ("BUDGET_REACHED", "DONE", "FAILED", "WAITING_INPUT"), timeout=120)
        E.put_scenario(app, {"S1": {"sleep": 900}})
        info = {"base": f"http://127.0.0.1:{port}", "team": {"email": "equipe@mail-test.example", "password": E.PASSWORD, "clientId": team_id, "projects": projects},
                "states": {k: status_of(v) for k, v in projects.items() if v}}
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(info, f, indent=1)
        print("pret", info["base"], info["states"], flush=True)
        while os.path.exists(out_path):
            time.sleep(1)
            if proc.poll() is not None:
                break
    finally:
        for p in procs:
            try:
                p.kill()
            except Exception:
                pass
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
