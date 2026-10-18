# -*- coding: utf-8 -*-
"""Moteur de projets (« Projet ») : projets durables, étapes, vérification, approbations, budget, reprise.

Contrat : docs/AUTONOMY-ENGINE.md. Tout est DORMANT derrière BK_PROJECTS (défaut 0, voir projects_wiring.py).

Ce module est le point d'entrée public ; la logique est répartie en modules cohérents (un propriétaire, aucun import du serveur) :
  project_paths.py       chemins sûrs de l'espace de travail
  projects_plan.py       validation du plan (validate_plan, utilisé aussi par Chloé)
  projects_store.py      disque, verrous, journal d'événements, machine à états (ProjectStore.transition)
  projects_approvals.py  file d'approbations (articles, risque, lots, exécution, expiration)
  projects_context.py    contexte d'étape (context.md), résumé roulant, index de l'espace
  projects_verify.py     preuves résolues par le moteur, tours de vérification, rapport final
"""
from projects_plan import (PlanResult, validate_plan, register_check_type, known_check_types,    # noqa: F401  (interface publique)
                           topological_order, critical_path_lengths, needs_consistency_review, percent_done)
