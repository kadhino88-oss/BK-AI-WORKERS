#!/usr/bin/env python3
"""Modele de cout IA par mission pour BK-AI-WORKERS (etude de prix 2026-10-12).

Reproduit tous les chiffres de docs/ETUDE-MARCHE-PRIX-2026-10.md section 3-5.
Usage : python docs/pricing-cost-model.py          (affiche les tableaux)
        python docs/pricing-cost-model.py --json   (JSON complet)

Sources des prix (lues le 2026-10-12) :
- Anthropic : https://platform.claude.com/docs/en/about-claude/pricing (USD par million de jetons)
- Change : BCE via https://api.frankfurter.dev/v1/latest?base=USD&symbols=CHF -> 1 USD = 0,83107 CHF (2026-10-09)
Aucun chiffre de ce fichier n'est une mesure : ce sont des hypotheses de calcul.
A remplacer par les mesures reelles du registre de couts (docs/COST-LEDGER.md) des qu'il existe.
"""
import json
import sys

USD_CHF = 0.83107          # 1 USD en CHF, BCE 2026-10-09
SEARCH_USD = 0.01          # 10 USD / 1000 recherches web
SYS_TOKENS = 9000          # prompt systeme 8-10K jetons, mis en cache

# USD / million de jetons : entree, ecriture cache 5 min (1,25x), lecture cache, sortie
MODELS = {
    "rapide":     {"name": "Haiku 5.5 (effort low)",     "inp": 0.10, "cw": 0.125, "cr": 0.01, "out": 0.50},
    "equilibre":  {"name": "Sonnet 5.5 (effort medium)", "inp": 2.00, "cw": 2.50,  "cr": 0.10, "out": 10.00},
    "approfondi": {"name": "Opus 5.5 (effort high)",     "inp": 4.00, "cw": 5.00,  "cr": 0.20, "out": 20.00},
}
# Plafonds de core/ai/LEVELS.json (branche ws/memory-v2)
CEILINGS = {"rapide": (6, 3), "equilibre": (12, 8), "approfondi": (20, 15)}   # (maxIterations, webMaxUses)
CREDITS = {"rapide": 1, "equilibre": 3, "approfondi": 8}                       # echelle actuellement proposee

# Scenarios : n appels API, sortie totale (jetons), recherches web, jetons par resultat de recherche,
# jetons "frais" de la demande au premier appel (message + profil + memoire + historique)
SCENARIOS = {
    "leger":   {"calls": 2, "out": 1000, "searches": 0, "search_tok": 0,    "u0": 1500},
    "typique": {"calls": 4, "out": 2500, "searches": 1, "search_tok": 4000, "u0": 2000},
    "lourd":   {"calls": 6, "out": 4000, "searches": 3, "search_tok": 5000, "u0": 3000},
}


def mission_cost(model, calls, out, searches, search_tok, u0, cold=True, out_mult=1.0, cache_conversation=False):
    """Cout USD d'une mission. Par defaut seul le prompt systeme est en cache ; tout le reste du
    contexte (demande, sorties precedentes, resultats de recherche) est refacture au tarif d'entree
    a chaque appel (hypothese prudente : pas de cache de la conversation).
    cache_conversation=True : calcul indicatif d'un levier d'economie (le contexte deja envoye a l'appel
    precedent est relu au tarif de lecture du cache, seuls les jetons nouveaux sont payes, en ecriture 1,25x)."""
    p = MODELS[model]
    out_per_call = out * out_mult / calls
    # les recherches ont lieu dans les appels 1..n-1 ; leurs resultats gonflent les appels suivants
    per_call_searches = [0] * calls
    for k in range(searches):
        per_call_searches[k % max(1, calls - 1)] += 1
    total = 0.0
    extra = 0.0          # jetons de contexte accumules par les appels precedents (hors prompt systeme)
    seen = 0.0           # contexte deja envoye a l'appel precedent (pour le calcul avec cache)
    for i in range(calls):
        sys_rate = p["cw"] if (i == 0 and cold) else p["cr"]
        total += SYS_TOKENS * sys_rate / 1e6
        ctx = u0 + extra
        if cache_conversation:
            total += seen * p["cr"] / 1e6 + (ctx - seen) * p["cw"] / 1e6
            seen = ctx
        else:
            total += ctx * p["inp"] / 1e6
        total += out_per_call * p["out"] / 1e6
        extra += out_per_call + per_call_searches[i] * search_tok
    total += searches * SEARCH_USD
    return total


def ceiling_cost(model, out_mult=1.0):
    """Plafond theorique : la boucle va jusqu'a maxIterations, avec webMaxUses recherches de 5K jetons
    et 1K jetons de sortie par appel. Pas un cas normal : sert a dimensionner un plafond de cout par mission."""
    n, w = CEILINGS[model]
    return mission_cost(model, n, 1000 * n, w, 5000, 3000, cold=True, out_mult=out_mult)


def build():
    res = {"usd_chf": USD_CHF, "missions": {}, "ceiling": {}, "sensitivity_output_x2": {}, "warm_cache_typique": {},
           "conversation_cache_lourd": {}}
    for lvl in MODELS:
        res["missions"][lvl] = {}
        for sc, a in SCENARIOS.items():
            usd = mission_cost(lvl, a["calls"], a["out"], a["searches"], a["search_tok"], a["u0"])
            res["missions"][lvl][sc] = {"usd": round(usd, 4), "chf": round(usd * USD_CHF, 4),
                                        "chf_per_credit": round(usd * USD_CHF / CREDITS[lvl], 4)}
        c = ceiling_cost(lvl)
        res["ceiling"][lvl] = {"usd": round(c, 3), "chf": round(c * USD_CHF, 3), "maxIterations": CEILINGS[lvl][0],
                               "webMaxUses": CEILINGS[lvl][1]}
        a = SCENARIOS["lourd"]
        x2 = mission_cost(lvl, a["calls"], a["out"], a["searches"], a["search_tok"], a["u0"], out_mult=2.0)
        res["sensitivity_output_x2"][lvl] = {"usd": round(x2, 4), "chf": round(x2 * USD_CHF, 4)}
        a = SCENARIOS["lourd"]
        cc = mission_cost(lvl, a["calls"], a["out"], a["searches"], a["search_tok"], a["u0"], cache_conversation=True)
        res["conversation_cache_lourd"][lvl] = {"usd": round(cc, 4), "chf": round(cc * USD_CHF, 4)}
        a = SCENARIOS["typique"]
        w = mission_cost(lvl, a["calls"], a["out"], a["searches"], a["search_tok"], a["u0"], cold=False)
        res["warm_cache_typique"][lvl] = {"usd": round(w, 4), "chf": round(w * USD_CHF, 4)}
    return res


def table():
    r = build()
    print(f"Taux : 1 USD = {USD_CHF} CHF (BCE 2026-10-09)\n")
    print(f"{'niveau':<11}{'scenario':<9}{'USD':>9}{'CHF':>9}{'credits':>8}{'CHF/credit':>12}")
    for lvl in MODELS:
        for sc in SCENARIOS:
            m = r["missions"][lvl][sc]
            print(f"{lvl:<11}{sc:<9}{m['usd']:>9.4f}{m['chf']:>9.4f}{CREDITS[lvl]:>8}{m['chf_per_credit']:>12.4f}")
    print("\nPlafond theorique (maxIterations / webMaxUses de LEVELS.json) :")
    for lvl, c in r["ceiling"].items():
        print(f"  {lvl:<11} {c['usd']:>7.3f} USD = {c['chf']:>7.3f} CHF  ({c['maxIterations']} appels, {c['webMaxUses']} recherches)")
    print("\nSensibilite : sortie x2 sur le scenario lourd (reflexion plus longue aux niveaux eleves) :")
    for lvl, c in r["sensitivity_output_x2"].items():
        print(f"  {lvl:<11} {c['usd']:>7.4f} USD = {c['chf']:>7.4f} CHF")
    print("\nLevier d'economie : cache de la conversation (scenario lourd, indicatif) :")
    for lvl, c in r["conversation_cache_lourd"].items():
        print(f"  {lvl:<11} {c['usd']:>7.4f} USD = {c['chf']:>7.4f} CHF  (au lieu de {r['missions'][lvl]['lourd']['usd']:.4f} USD)")
    print("\nCache chaud (scenario typique, prompt systeme deja en cache) :")
    for lvl, c in r["warm_cache_typique"].items():
        print(f"  {lvl:<11} {c['usd']:>7.4f} USD = {c['chf']:>7.4f} CHF")


if __name__ == "__main__":
    if "--json" in sys.argv:
        print(json.dumps(build(), indent=2, ensure_ascii=False))
    else:
        table()
