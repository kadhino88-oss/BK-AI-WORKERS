# -*- coding: utf-8 -*-
"""Outils communs de tests/pricing : le VRAI dashboard/server.py charge sur une racine jetable (aucun reseau, aucun modele, aucun secret)."""
import datetime
import importlib.util
import json
import os
import shutil
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "dashboard"))

A, B, C = "CLI-CUST-AAAAAAAA", "CLI-CUST-BBBBBBBB", "CLI-CUST-CCCCCCCC"
NOW = datetime.datetime(2026, 10, 12, 12, 0, 0)      # date figee : le quota est mensuel, les tests ne doivent jamais dependre du jour de lancement


def load_server(name="bk_server_pricing"):
    """Charge server.py sur une copie minimale du depot ; renvoie (module, racine). Les niveaux sont ceux du fichier livre (core/ai/LEVELS.json)."""
    root = tempfile.mkdtemp(prefix="bkpricing-")
    for rel in ("core/runtime/worker-runtime/WORKER-REGISTRY.json", "core/ai/LEVELS.json", "workers/alex/identity/identity.json",
                "workers/nora/identity/identity.json", "workers/alex/install-profile.json", "workers/nora/install-profile.json",
                "dashboard/phone-agent/CLI-DASHBOARD.json"):
        dst = os.path.join(root, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(os.path.join(REPO, rel), dst)
    os.environ["BK_ROOT"] = root
    os.environ.pop("BK_LEVELS", None)
    os.environ.pop("BK_PILOT_NOTIFY_EMAIL", None)
    spec = importlib.util.spec_from_file_location(name, os.path.join(REPO, "dashboard", "server.py"))
    server = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(server)
    server._utcnow = lambda: NOW
    return server, root


def write_billing(server, client, plan, cycle_start="2026-10-01T00:00:00Z", **extra):
    # gridVersion 2 = etat ecrit avec la grille du 2026-10-12 ; sans lui, un Pro / Scale est un ancien abonne (credits d'origine, niveau Rapide).
    state = {"planId": plan, "gridVersion": 2, "cycleStartUtc": cycle_start, "extraCredits": 0, "history": []}
    state.update(extra)
    os.makedirs(server.BILLING_DATA_DIR, exist_ok=True)
    with open(server._billing_path(client), "w", encoding="utf-8") as f:
        json.dump(state, f)


def write_task(server, client, credits, created="2026-10-05T00:00:00Z", task_id=None):
    os.makedirs(server.TASKS_DIR, exist_ok=True)
    tid = task_id or ("%032X" % (len(os.listdir(server.TASKS_DIR)) + 1))
    with open(os.path.join(server.TASKS_DIR, f"TASK-{tid}.json"), "w", encoding="utf-8") as f:
        json.dump({"TaskId": f"TASK-{tid}", "ClientId": client, "Credits": credits, "CreatedAtUtc": created}, f)


def add_account(server, client, email=None, verified=True):
    accounts = server._load_accounts()
    accounts.append({"accountId": client, "clientId": client, "email": email or client.lower() + "@mail-test.example",
                     "passwordHash": server._hash_password("motdepasse-test"), "companyName": "Test SA", "emailVerified": verified})
    server._save_accounts(accounts)


def reset(server):
    """Etat vierge entre deux tests : facturation, taches, comptes."""
    for d in (server.BILLING_DATA_DIR, server.TASKS_DIR, os.path.join(server.ROOT, "core", "accounts", "data"),
              os.path.join(server.ROOT, "runtime")):
        shutil.rmtree(d, ignore_errors=True)
    os.environ.pop("BK_LEVELS", None)
    server._utcnow = lambda: NOW
