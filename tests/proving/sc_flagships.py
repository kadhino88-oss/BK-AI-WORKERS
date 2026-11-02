# -*- coding: utf-8 -*-
"""Scénarios des quatre projets flagship (site, SEO, prospects, publicités) : chacun va au bout par le vrai serveur HTTP ; les contrôles sont faits sur les FICHIERS écrits,
les verdicts du moteur et la file d'approbations, jamais sur le texte d'un modèle."""
import os
import re
import time

import harness as H
import scenarios as SC
import fl_ads
import fl_prospects
import fl_seo
import fl_site


def ws_read(lab, cid, pid, rel):
    try:
        with open(os.path.join(lab.project_dir(cid, pid), "workspace", *rel.split("/")), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def step_ids(snap):
    return [s.get("id") for s in (snap["detail"].get("plan") or {}).get("steps") or []]


def verdicts(snap):
    return {c["id"]: c.get("verdict") for c in (snap["detail"].get("plan") or {}).get("criteria") or []}


def summary_of(lab, snap, t0, pid):
    d = snap["detail"]
    ap = SC._approvals(snap)
    return {"status": d.get("status"), "statusReason": d.get("statusReason"), "seconds": round(time.time() - t0, 1), "creditsCharged": d.get("creditsCharged"), "creditsCap": d.get("creditsCap"),
            "steps": [{"id": s.get("id"), "worker": s.get("worker"), "kind": s.get("kind"), "status": s.get("status")} for s in (d.get("plan") or {}).get("steps") or []],
            "criteria": verdicts(snap), "fixSteps": [i for i in step_ids(snap) if str(i).startswith("FIX")],
            "deliverables": [x.get("path") for x in (snap["deliverables"].get("deliverables") or [])],
            "approvals": [{"id": a.get("id"), "connector": a.get("connectorId"), "operation": a.get("operation"), "kind": a.get("kind"), "risk": a.get("risk"), "status": a.get("status"),
                           "title": (a.get("display") or {}).get("title")} for a in ap],
            "questions": d.get("questions"), "pid": pid}


def common(lab, check, key, snap, t0, pid, expect_fix=False, min_approvals=0):
    d = snap["detail"]
    v = verdicts(snap)
    check("%s : le projet va au bout tout seul (DONE)" % key, d.get("status") == "DONE", (d.get("status"), d.get("statusReason")))
    check("%s : tous les critères sont PASS avec preuve" % key, v and set(v.values()) == {"PASS"}, v)
    out = summary_of(lab, snap, t0, pid)
    if expect_fix:
        check("%s : la vérification a échoué sur un critère et forcé une correction (%s)" % (key, ",".join(out["fixSteps"]) or "aucune"), bool(out["fixSteps"]), step_ids(snap))
    ap = SC._approvals(snap)
    if min_approvals:
        check("%s : %d article(s) d'approbation préparés (au moins %d)" % (key, len(ap), min_approvals), len(ap) >= min_approvals, len(ap))
    check("%s : rien n'est exécuté sans le client (aucun appel de connecteur de plus)" % key, len(lab.connector_calls()) == lab.expected_calls, lab.connector_calls()[lab.expected_calls:][:2])
    check("%s : les articles d'approbation sont tous en attente" % key, all(a.get("status") == "PENDING" for a in ap), [a.get("status") for a in ap][:5])
    check("%s : le rapport final existe" % key, d.get("hasFinalReport"), d.get("hasFinalReport"))
    return out


def sc_site(lab, check):
    c, cid, pid, snap, t0, p = SC.flagship(lab, check, "site", fl_site, "lucas", ["wordpress"])
    out = common(lab, check, "site", snap, t0, pid, min_approvals=5)
    d = snap["detail"]
    for rel in ("deliverables/MISE-EN-LIGNE.md", "deliverables/rapport-site.md", "site/dist/index.html", "site/dist/en/index.html", "site/dist/sitemap.xml"):
        check("site : %s existe" % rel, bool(ws_read(lab, cid, pid, rel)))
    zips = [x for x in out["deliverables"] if str(x).endswith(".zip")]
    check("site : le zip prêt à mettre en ligne est un livrable (%s)" % (zips[:1],), bool(zips), out["deliverables"])
    st, raw, hd = c.call("GET", "/api/projects/%s/site/export.zip" % pid)
    check("site : l'export zip du site se télécharge", st == 200 and raw[:2] == b"PK", st)
    dist = (ws_read(lab, cid, pid, "site/dist/index.html") or "") + (ws_read(lab, cid, pid, "site/dist/en/index.html") or "")
    check("site : aucun avis, note ni chiffre client inventé dans le site construit", not re.search(r"(★|⭐|\d[,.]\d ?/ ?5|patients? satisfaits|témoignage|\+ ?\d+ ?(patients|clients))", dist, re.I), dist[:200])
    check("site : les faits manquants restent « [À COMPLÉTER] » (rien d'inventé)", "[À COMPLÉTER" in (ws_read(lab, cid, pid, "site/dist/a-propos/index.html") or "") or "[À COMPLÉTER" in (ws_read(lab, cid, pid, "site/dist/tarifs/index.html") or ""))
    check("site : la question pour le client est posée, non bloquante", "adresse" in str(d.get("questions")), d.get("questions"))
    check("site : le rapport dit qu'aucun faux avis n'a été écrit", "Aucun avis de patient" in (ws_read(lab, cid, pid, "deliverables/rapport-site.md") or ""))
    st, pv = c.post("/api/projects/%s/site/preview" % pid, {"hours": 2}, headers=SC.ORIGIN)
    pv.pop("_headers", None)
    out["preview"] = pv
    url = pv.get("url") or ""
    check("site : le lien d'aperçu privé est créé", st == 200 and bool(url), (st, pv))
    if url:
        path = url if url.startswith("/") else "/" + url.split("/", 3)[-1]
        st, raw, hd = c.call("GET", path)
        lh = {k.lower(): v for k, v in hd.items()}
        check("site : l'aperçu s'ouvre sous CSP sandbox", st == 200 and "sandbox" in lh.get("content-security-policy", ""), (st, lh.get("content-security-policy")))
        out["previewPath"] = path
    wp = [a for a in SC._approvals(snap) if a.get("connectorId") == "wordpress"]
    if wp:
        st, r = c.post("/api/projects/%s/approvals/%s/approve" % (pid, wp[0]["id"]), {}, headers=SC.ORIGIN)
        end = time.time() + 25
        while time.time() < end and len(lab.connector_calls()) < 1:
            time.sleep(0.5)
        calls = lab.connector_calls()
        check("site : valider UN article = exactement UN appel de connecteur au contenu exact", len(calls) == 1 and calls[0]["operation"] == wp[0]["operation"] and calls[0]["params"] == wp[0]["params"], calls[:1])
        out["connectorCallsAfterOneApproval"] = len(calls)
        lab.expected_calls = len(calls)
        if len(calls) != 1 or calls[0]["params"] != wp[0]["params"]:
            out["approvalDebug"] = {"call": calls[:1], "item": {k: wp[0].get(k) for k in ("operation", "params", "editedParams", "status")}}
    out["cid"] = cid
    return out


def sc_seo(lab, check):
    c, cid, pid, snap, t0, p = SC.flagship(lab, check, "seo", fl_seo, "seoya", ["wordpress"])
    out = common(lab, check, "seo", snap, t0, pid, expect_fix=True, min_approvals=2)
    audit = ws_read(lab, cid, pid, "deliverables/audit.csv") or ""
    check("seo : le blocage robots.txt est détecté et classé priorité absolue", "Disallow: /" in audit and "Priorité absolue" in (ws_read(lab, cid, pid, "deliverables/audit.md") or ""))
    check("seo : les briefs finaux ne contiennent aucun volume inventé", not re.search(r"\d\s*recherches/mois", ws_read(lab, cid, pid, "deliverables/briefs.md") or ""))
    out["note"] = "Pages auditées = instantanés FICTIFS déposés par le banc ; l'audit d'un vrai site public reste dû (moteur avec web_fetch)."
    return out


def sc_prospects(lab, check):
    c, cid, pid, snap, t0, p = SC.flagship(lab, check, "prospects", fl_prospects, "alex", ["gmail", "hubspot"])
    out = common(lab, check, "prospects", snap, t0, pid, expect_fix=True, min_approvals=30)
    ap = SC._approvals(snap)
    check("prospects : 15 brouillons Gmail + 15 tâches CRM en approbation", sum(1 for a in ap if a.get("connectorId") == "gmail") == 15 and sum(1 for a in ap if a.get("connectorId") == "hubspot") == 15, [a.get("connectorId") for a in ap][:6])
    csvt = ws_read(lab, cid, pid, "deliverables/prospects.csv") or ""
    check("prospects : aucune adresse privée dans la liste finale", "gmail.com" not in csvt, csvt[:100])
    check("prospects : 15 lignes de données", csvt.count("\n") == 16, csvt.count("\n"))
    return out


def sc_ads(lab, check):
    c, cid, pid, snap, t0, p = SC.flagship(lab, check, "ads", fl_ads, "maya", ["meta_ads"])
    out = common(lab, check, "ads", snap, t0, pid, expect_fix=True, min_approvals=2)
    ap = SC._approvals(snap)
    launch = [a for a in ap if "Lancer la campagne" in str((a.get("display") or {}).get("title"))]
    check("ads : le lancement est un article d'approbation à risque élevé, jamais un appel de connecteur", bool(launch) and launch[0].get("risk") == "high" and len(lab.connector_calls()) == lab.expected_calls, launch[:1])
    rows = (ws_read(lab, cid, pid, "deliverables/copies.csv") or "").splitlines()[1:]
    check("ads : 27 textes, tous sous la limite de leur emplacement après correction", len(rows) == 27, len(rows))
    return out
