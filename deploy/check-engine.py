#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verifie, depuis le serveur, que le moteur d'IA configure (Ollama sur le PC du proprietaire, hote suisse) repond : adresse permise, port joignable, liste
des modeles, modele choisi present, delai de reponse. A lancer par le PROPRIETAIRE, sur le serveur :

    docker compose exec app python3 /data/app/deploy/check-engine.py                  # moteur local (Ollama), reglages enregistres ou variables du .env
    docker compose exec app python3 /data/app/deploy/check-engine.py --engine swiss   # hote suisse
    docker compose exec app python3 /data/app/deploy/check-engine.py --url http://100.101.102.103:11434 --chat   # test ponctuel + une vraie reponse courte

Ne divulgue JAMAIS un jeton : il est lu dans l'environnement du serveur (BK_SECRET_OLLAMA, BK_SECRET_SWISS) ou dans BK_SECRETS_DIR, envoye en en-tete
Authorization, et seule sa PRESENCE est affichee. Aucun appel a Anthropic ni a un service tiers : uniquement l'adresse du moteur.
--chat envoie une seule petite requete (quelques mots) : gratuit sur Ollama, quelques centimes au plus chez un hote payant.
Code de sortie : 0 si le moteur repond et que le modele est present, 1 sinon.
"""
import argparse
import http.client
import json
import os
import socket
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("BK_ROOT") or os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "dashboard"))
sys.path.insert(0, os.path.join(HERE, "..", "dashboard"))
import net_policy  # noqa: E402
import provider_router  # noqa: E402


def say(ok, text):
    print(("  OK    " if ok else "  ECHEC ") + text)
    return ok


def token_for(name):
    """Jeton du moteur (jamais affiche) : BK_SECRET_<NOM> puis BK_SECRETS_DIR/<nom>.secret."""
    value = os.environ.get("BK_SECRET_" + name.upper(), "").strip()
    if value:
        return value
    d = os.environ.get("BK_SECRETS_DIR", "")
    if d:
        try:
            with open(os.path.join(d, name + ".secret"), encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            pass
    return ""


def http_call(method, url, token, body=None, timeout=20):
    """Un appel HTTP sans suivre les redirections. Renvoie (statut, corps, secondes)."""
    parts = urllib.parse.urlsplit(url)
    conn_cls = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
    conn = conn_cls(parts.hostname, parts.port, timeout=timeout)
    headers = {"Accept": "application/json", "User-Agent": "bk-check-engine/1.0"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    started = time.monotonic()
    try:
        conn.request(method, (parts.path or "/") + (("?" + parts.query) if parts.query else ""), body=data, headers=headers)
        resp = conn.getresponse()
        raw = resp.read(2_000_000)
        return resp.status, raw, time.monotonic() - started
    finally:
        conn.close()


def main():
    ap = argparse.ArgumentParser(description="Verifie le moteur d'IA configure (Ollama, hote suisse).")
    ap.add_argument("--engine", choices=("ollama", "swiss"), default="ollama")
    ap.add_argument("--url", help="adresse a tester (sinon : reglages du proprietaire, puis variables du .env)")
    ap.add_argument("--model", help="modele a chercher (sinon : celui des reglages)")
    ap.add_argument("--chat", action="store_true", help="envoie une petite requete reelle pour mesurer le delai de reponse")
    args = ap.parse_args()

    settings = provider_router.load_settings(ROOT)
    cfg = provider_router.endpoint_config(args.engine, settings, os.environ) or {}
    url = (args.url or cfg.get("url") or "").strip()
    model = (args.model or cfg.get("model") or "").strip()
    token = token_for(args.engine)
    print(f"Moteur : {args.engine}")
    if not url:
        say(False, "aucune adresse configuree (reglages du proprietaire ou variable BK_%s_URL du .env)" % args.engine.upper())
        return 1
    parts = net_policy.split_url(url)
    print(f"Adresse : {url}")
    print(f"Modele : {model or '(non precise)'}")
    print(f"Jeton : {'present' if token else 'absent'} (jamais affiche)")
    good = True

    ok, code, message, info = net_policy.check_endpoint(url, kind="local" if args.engine == "ollama" else "owner", has_token=bool(token))
    good &= say(ok, "adresse permise" + (f" ({', '.join(info.get('classes', []))})" if ok else f" : {message} [{code}]"))
    if not ok:
        return 1
    port = parts["port"] or (443 if parts["scheme"] == "https" else 80)
    started = time.monotonic()
    try:
        with socket.create_connection((parts["host"], port), timeout=5):
            pass
        say(True, f"port {port} joignable en {1000 * (time.monotonic() - started):.0f} ms")
    except OSError as e:
        say(False, f"port {port} injoignable ({type(e).__name__}) : machine eteinte, VPN (Tailscale) coupe ou pare-feu ?")
        return 1

    base = url.rstrip("/")
    if not urllib.parse.urlsplit(base).path.strip("/"):
        base += "/v1"
    models = []
    try:
        status, raw, secs = http_call("GET", base + "/models", token)
        if status == 200:
            data = json.loads(raw.decode("utf-8", "replace"))
            models = [m.get("id") for m in (data.get("data") or []) if isinstance(m, dict) and m.get("id")]
            good &= say(True, f"liste des modeles lue en {1000 * secs:.0f} ms : {len(models)} modele(s)")
            for m in models[:30]:
                print("          -", m)
        else:
            good &= say(False, f"liste des modeles : HTTP {status} ({'jeton refuse' if status in (401, 403) else 'reponse inattendue'})")
    except (OSError, ValueError, http.client.HTTPException) as e:
        good &= say(False, f"liste des modeles illisible ({type(e).__name__})")

    if model:
        present = model in models or (":" not in model and any(m.split(":")[0] == model for m in models))
        good &= say(present, f"modele « {model} » " + ("present" if present else "ABSENT de la liste : il faut le telecharger sur la machine du moteur (ollama pull %s)" % model))

    # Ollama : le modele sait-il appeler des outils ? (/api/show, facultatif ; absent chez un hote qui n'est pas Ollama)
    if args.engine == "ollama" and model:
        root = base[:-3] if base.endswith("/v1") else base
        try:
            status, raw, _ = http_call("POST", root + "/api/show", token, {"model": model})
            if status == 200:
                caps = json.loads(raw.decode("utf-8", "replace")).get("capabilities") or []
                tools = "tools" in caps
                say(True, "appel d'outils natif : " + ("OUI" if tools else "NON (les outils passent par du JSON ecrit dans le texte : plus fragile). Meilleurs choix : llama3.1:8b, qwen2.5:7b"))
        except (OSError, ValueError, http.client.HTTPException):
            pass

    if args.chat:
        if not model:
            good &= say(False, "--chat demande un modele (--model ou reglage)")
        else:
            try:
                status, raw, secs = http_call("POST", base + "/chat/completions", token,
                                              {"model": model, "messages": [{"role": "user", "content": "Reponds par un seul mot : ok"}], "max_tokens": 8, "stream": False,
                                               "temperature": 0}, timeout=300)
                if status == 200:
                    data = json.loads(raw.decode("utf-8", "replace"))
                    text = ((data.get("choices") or [{}])[0].get("message") or {}).get("content") or ""
                    good &= say(True, f"reponse reelle en {secs:.1f} s : « {text.strip()[:60]} »")
                else:
                    good &= say(False, f"requete reelle : HTTP {status}")
            except (OSError, ValueError, http.client.HTTPException) as e:
                good &= say(False, f"requete reelle impossible ({type(e).__name__})")
    print()
    print("Resultat : " + ("le moteur est pret." if good else "a corriger (voir les lignes ECHEC)."))
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
