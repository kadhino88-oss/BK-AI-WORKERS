#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Verifie le point de recherche web SearXNG configure sans appeler de modele IA.

    docker compose exec app python3 /data/app/deploy/check-search.py

Envoie une requete generique (« maintenance CVC Genève »), sans donnee client ni cout de modele. Ne suit aucune redirection,
ne divulgue jamais le jeton et refuse les adresses bloquees par la politique reseau de l'application.
Code de sortie : 0 si l'API renvoie des resultats JSON avec au moins un lien http(s), 1 sinon.
"""
import http.client
import json
import os
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("BK_ROOT") or os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "dashboard"))
sys.path.insert(0, os.path.join(HERE, "..", "dashboard"))
import net_policy  # noqa: E402
import provider_router  # noqa: E402


def token_for_search():
    value = os.environ.get("BK_SECRET_SEARCH", "").strip()
    if value:
        return value
    directory = os.environ.get("BK_SECRETS_DIR", "")
    if directory:
        try:
            with open(os.path.join(directory, "search.secret"), encoding="utf-8") as stream:
                return stream.read().strip()
        except OSError:
            pass
    return ""


def main():
    settings = provider_router.load_settings(ROOT)
    url = provider_router.search_url(settings, os.environ)
    token = token_for_search()
    print("Recherche web : " + (url or "non configuree"))
    if not url:
        print("ECHEC : configurez une URL SearXNG compatible et, pour HTTPS, son jeton Bearer.")
        return 1

    ok, code, message, _ = net_policy.check_endpoint(url, kind="owner", has_token=bool(token))
    if not ok:
        print(f"ECHEC : adresse refusee [{code}] {message}")
        return 1

    parts = urllib.parse.urlsplit(url.rstrip("/"))
    query = urllib.parse.urlencode({"q": "maintenance CVC Genève", "format": "json"})
    path = (parts.path.rstrip("/") + "/search?" + query) if parts.path.rstrip("/") else ("/search?" + query)
    headers = {"Accept": "application/json", "User-Agent": "bk-check-search/1.0"}
    if token:
        headers["Authorization"] = "Bearer " + token
    connection_type = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
    connection = connection_type(parts.hostname, parts.port, timeout=20)
    try:
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        raw = response.read(2_000_000)
        if response.status != 200:
            if response.status == 403:
                print("ECHEC : HTTP 403. Verifiez que le format JSON est active dans search.formats sur SearXNG.")
            else:
                print(f"ECHEC : le point de recherche repond HTTP {response.status}.")
            return 1
    except (OSError, TimeoutError, http.client.HTTPException) as error:
        print(f"ECHEC : point de recherche injoignable ({type(error).__name__}).")
        return 1
    finally:
        connection.close()

    try:
        body = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        print("ECHEC : la reponse n'est pas du JSON valide.")
        return 1
    results = body.get("results") if isinstance(body, dict) else None
    if not isinstance(results, list):
        print("ECHEC : le JSON ne contient pas de liste 'results'.")
        return 1
    links = []
    for item in results:
        if not isinstance(item, dict):
            continue
        link = str(item.get("url") or "").strip()
        parsed = urllib.parse.urlsplit(link)
        if parsed.scheme in ("http", "https") and parsed.hostname:
            links.append(link)
    if not links:
        print(f"ECHEC : JSON valide, mais aucun lien trouve ({len(results)} resultat(s)).")
        return 1
    hosts = sorted({urllib.parse.urlsplit(link).hostname for link in links})
    print(f"OK : {len(results)} resultat(s) JSON, {len(links)} lien(s) utilisable(s).")
    print("Domaines retournes : " + ", ".join(hosts[:8]))
    print("Le test n'a appele aucun modele IA et n'a expose aucune donnee client.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
