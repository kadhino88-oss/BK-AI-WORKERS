# -*- coding: utf-8 -*-
"""Contexte d'une étape de projet (context.md) et fichier d'entrée du lanceur (input.json) : docs/AUTONOMY-ENGINE.md, sections 3.6 et 7.7.

Jamais l'historique de la boucle précédente : un contexte FRAIS à chaque étape, budget cible <= 60 000 jetons, ordre fixe, chaque section a son
plafond (au-delà, on garde le plus récent ou le plus lié à l'étape). Tout contenu qui vient du client, du web, d'un fichier ou d'une autre
étape est une DONNÉE : il est encadré par <data ...> et ne peut pas refermer son cadre (barrière contre l'injection d'instructions). Seules la
section « Étape » (mission) et le prompt système donnent des ordres au Worker.

Module PUR : aucun accès au serveur.
"""
import json
import os
import re

import project_paths as pp
import projects_store as ps

CHARS_PER_TOKEN = 3.5
SECTION_TOKENS = {"brief": 1500, "plan": 1500, "summary": 1500, "decisions": 1000, "deps": 6000, "messages": 1500, "index": 2000, "step": 800,
                  "inputs": 12000}
SUMMARY_MAX_CHARS = 6000


def tokens_to_chars(n):
    return int(n * CHARS_PER_TOKEN)


def clip(text, limit_chars, tail=False, note="…[tronqué]"):
    text = str(text or "")
    if len(text) <= limit_chars:
        return text
    if tail:
        return note + text[-limit_chars:]
    return text[:limit_chars] + note


_FENCE_BREAK = re.compile(r"<\s*/\s*data", re.IGNORECASE)


def fence(label, text, **attrs):
    """Encadre une DONNÉE (jamais une instruction). Le texte ne peut pas refermer le cadre : « </data » est neutralisé."""
    body = _FENCE_BREAK.sub("<\\/data", str(text or ""))
    a = "".join(f' {k}="{re.sub(r"[^A-Za-z0-9_./ :@-]", "", str(v))[:120]}"' for k, v in attrs.items())
    return f'<data kind="{label}"{a}>\n{body}\n</data>'


def read_text(path, limit=200000):
    try:
        with open(path, "rb") as f:
            raw = f.read(limit)
    except OSError:
        return ""
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="replace")


def merge_summary(old, update, step_id, limit=SUMMARY_MAX_CHARS):
    """Résumé roulant (<= 6 000 caractères) : on ajoute la mise à jour de l'étape, puis on retire les lignes les plus anciennes."""
    update = re.sub(r"\s+", " ", str(update or "")).strip()
    lines = [l for l in str(old or "").splitlines() if l.strip()]
    if update:
        lines.append(f"- [{step_id}] {update[:2400]}")
    while lines and sum(len(l) + 1 for l in lines) > limit:
        lines.pop(0)
    return "\n".join(lines) + ("\n" if lines else "")


def workspace_index(workspace, deliverables, limit=120):
    reg = {d.get("path"): d for d in deliverables or []}
    lines = []
    for rel, size, _mt in pp.walk_files(workspace, limit=limit):
        d = reg.get(rel)
        lines.append(f"{rel} ({size} o)" + (f" — {d.get('title')}" if d and d.get("title") else ""))
    return lines


def decisions_section(decisions, step_files, step_id):
    rows = list(decisions or [])
    last = rows[-15:]
    related = [d for d in rows[:-15] if d.get("stepId") == step_id or any(f and f in json.dumps(d, ensure_ascii=False) for f in step_files)]
    out = []
    for d in related + last:
        out.append(f"- ({d.get('stepId') or '?'}) {str(d.get('decision') or '')[:300]} — {str(d.get('why') or '')[:200]}")
    return out


def dependency_reports(project_dir, plan_steps, state_steps, depends_on, budget_chars):
    """handoff/<StepId>.md complet pour les étapes dont celle-ci dépend ; une ligne pour les autres étapes terminées."""
    parts = []
    used = 0
    for sid in depends_on:
        p = os.path.join(project_dir, "workspace", "handoff", sid + ".md")
        txt = read_text(p, 60000).strip()
        if not txt:
            txt = "(aucun rapport écrit pour cette étape)"
        room = max(600, budget_chars - used)
        chunk = clip(txt, room)
        used += len(chunk)
        parts.append(fence("handoff", chunk, step=sid))
    others = []
    for s in plan_steps:
        sid = s["id"]
        if sid in depends_on:
            continue
        st = (state_steps.get(sid) or {})
        if st.get("status") in ("DONE", "PARTIAL") and st.get("summary"):
            others.append(f"- {sid} ({s.get('worker')}) : {str(st['summary'])[:220]}")
    return parts, others


def build_context(*, state, plan, step, step_state, project_dir, kind, attempt, decisions, inbox_unprocessed, deliverables, resume_note,
                  budget_left, shrink=False, worker_catalog=None, verification_block=None, extra_blocks=None):
    """Assemble context.md. Renvoie le texte. `shrink` : sections divisées par deux (relance après « contexte trop long »)."""
    div = 2 if shrink else 1

    def cap(name):
        return tokens_to_chars(SECTION_TOKENS[name] // div)

    workspace = os.path.join(project_dir, "workspace")
    plan = plan or {}
    steps = plan.get("steps") or []
    out = []
    # ---- 1. Brief
    crit_by_id = {c["id"]: c for c in plan.get("criteria") or []}
    brief = [f"Objectif du projet (langue : {state.get('language') or 'fr'}) :", fence("project_goal", clip(state.get("goal"), cap("brief") // 2)),
             "Hypothèses retenues :"]
    for a in plan.get("assumptions") or []:
        brief.append(f"- {a.get('id')}: {clip(a.get('text'), 300)}")
    answers = [m for m in inbox_unprocessed if m.get("kind") == "answer"]
    if state.get("answers"):
        brief.append("Réponses déjà données par le client :")
        for q, a in list((state.get("answers") or {}).items())[-8:]:
            brief.append(f"- {q}: {clip(a, 300)}")
    targeted = [crit_by_id[c] for c in (step.get("criteriaIds") or []) if c in crit_by_id]
    if targeted:
        brief.append("Critères visés par CETTE étape :")
        for c in targeted:
            brief.append(f"- {c['id']} ({c['kind']}): {clip(c.get('text'), 300)}" + (f" | grille : {clip(c.get('rubric'), 400)}" if c.get("rubric") else ""))
    out.append("## 1. Brief\n" + clip("\n".join(brief), cap("brief")))
    # ---- 2. Plan
    sstate = state.get("steps") or {}
    plan_lines = []
    for s in steps:
        ss = sstate.get(s["id"]) or {}
        plan_lines.append(f"{s['id']} [{ss.get('status', 'PENDING')}] {s.get('worker')} — {clip(s.get('title'), 90)}"
                          + (f" (après {', '.join(s.get('dependsOn'))})" if s.get("dependsOn") else ""))
    if worker_catalog:
        out.append("## 2. Plan\n" + clip("\n".join(plan_lines) or "(plan à écrire)", cap("plan")) + "\n\n" + clip(worker_catalog, 6000))
    else:
        out.append("## 2. Plan\n" + clip("\n".join(plan_lines) or "(plan à écrire)", cap("plan")))
    # ---- 3. Résumé roulant
    summary = read_text(os.path.join(project_dir, "summary.md"), 20000).strip()
    out.append("## 3. Résumé roulant du projet\n" + (fence("summary", clip(summary, cap("summary"), tail=True)) if summary else "(vide : première étape)"))
    # ---- 4. Décisions
    step_files = list(step.get("expectedOutputs") or [])
    dl = decisions_section(decisions, step_files, step.get("id"))
    out.append("## 4. Décisions prises\n" + (fence("decisions", clip("\n".join(dl), cap("decisions"), tail=True)) if dl else "(aucune)"))
    # ---- 5. Rapports des dépendances
    dep_ids = [d for d in (step.get("dependsOn") or [])]
    if kind in ("fix",):
        dep_ids = [d for d in dep_ids]
    reports, others = dependency_reports(project_dir, steps, sstate, dep_ids, cap("deps"))
    dep_text = "\n".join(reports) if reports else "(aucune dépendance)"
    if others:
        dep_text += "\nAutres étapes terminées (une ligne) :\n" + fence("other_steps", clip("\n".join(others), 1800))
    out.append("## 5. Rapports des étapes dont celle-ci dépend\n" + dep_text)
    # ---- 6. Messages du client
    msgs = [m for m in inbox_unprocessed if m.get("kind") in ("note", "change", "approval_feedback", "answer", "question")]
    if msgs:
        lines = []
        for m in msgs[-15:]:
            lines.append(f"- ({m.get('kind')}{' ' + m.get('stepId') if m.get('stepId') else ''}) {clip(m.get('text'), 600)}")
        out.append("## 6. Messages du client (à prendre en compte)\n" + fence("client_messages", clip("\n".join(lines), cap("messages"))))
    else:
        out.append("## 6. Messages du client\n(aucun nouveau message)")
    # ---- 7. Index de l'espace de travail
    idx = workspace_index(workspace, deliverables)
    out.append("## 7. Espace de travail (fichiers actuels)\n" + (fence("workspace_index", clip("\n".join(idx), cap("index"))) if idx else "(vide)"))
    # ---- verification : bloc propre au vérificateur
    if verification_block:
        out.append("## Dossier de vérification\n" + verification_block)
    for b in extra_blocks or []:
        out.append(b)
    # ---- 8. Étape (la mission : seule section qui donne des ordres)
    st = [f"Identifiant : {step.get('id')} — sorte : {kind} — Worker : {step.get('worker')} — tentative : {attempt}",
          f"Titre : {clip(step.get('title'), 160)}", f"Objectif de l'étape : {clip(step.get('goal'), 1500)}"]
    if step.get("expectedOutputs"):
        st.append("Sorties attendues : " + ", ".join(step["expectedOutputs"]))
    if step.get("inputs"):
        st.append("Fichiers d'entrée choisis : " + ", ".join(step["inputs"]))
    if step.get("connectors"):
        st.append("Connecteurs prévus : " + ", ".join(step["connectors"]))
    st.append(f"Budget restant : {budget_left.get('seconds')} s, {budget_left.get('iterations')} tours de boucle, environ {budget_left.get('chf')} CHF.")
    if step_state.get("fixHint"):
        st.append("À CORRIGER (relevé par le contrôleur qualité) : " + clip(step_state["fixHint"], 1500))
    if resume_note:
        st.append("NOTE DE REPRISE : " + clip(resume_note, 1500))
    out.append("## 8. Étape (ta mission)\n" + clip("\n".join(st), cap("step") * 3))
    # ---- 9. Contenus choisis
    chosen = []
    room = cap("inputs")
    for rel in (step.get("inputs") or [])[:8]:
        try:
            full = pp.resolve(workspace, rel, kind="file", must_exist=True)
        except pp.PathError:
            continue
        ext = pp.ext_of(rel)
        if ext not in pp.WRITE_EXT:
            chosen.append(f"- {rel} : fichier {ext} (utilise workspace_read pour l'ouvrir)")
            continue
        txt = read_text(full, 400000)
        piece = clip(txt, max(500, room // max(1, len(step["inputs"]))), note=f"…[tronqué : lire la suite avec workspace_read offset=N]")
        room -= len(piece)
        chosen.append(fence("workspace_file", piece, path=rel))
    if chosen:
        out.append("## 9. Contenus des fichiers d'entrée\n" + "\n".join(chosen))
    return "\n\n".join(out) + "\n"


def estimate_tokens(text):
    return int(len(text) / CHARS_PER_TOKEN)
