\# MEMORY CONTRACT — BK AI WORKERS



\## 1. OBJECTIF



La mémoire permet aux Workers de conserver et retrouver le contexte nécessaire

à l'exécution des tâches.



La mémoire doit être :



\- structurée

\- traçable

\- isolée

\- limitée au périmètre autorisé

\- exploitable par l'Orchestrateur

\- compatible multi-client

\- compatible multi-projet



\---



\## 2. HIÉRARCHIE



La mémoire suit cette hiérarchie :



KADER

&#x20; ↓

CLIENT

&#x20; ↓

PROJET

&#x20; ↓

WORKER

&#x20; ↓

TÂCHE

&#x20; ↓

EXÉCUTION



\---



\## 3. NIVEAUX DE MÉMOIRE



\### GLOBAL



Informations générales du système.



Exemples :



\- règles d'architecture

\- identité BK Entreprise

\- règles de sécurité

\- contrats Workers

\- politiques globales



\### CLIENT



Informations propres à un client.



Exemples :



\- entreprise

\- secteur

\- coordonnées professionnelles

\- préférences

\- identité de marque

\- objectifs

\- historique de collaboration



\### PROJET



Informations propres à un projet.



Exemples :



\- objectif

\- statut

\- deadline

\- livrables

\- décisions

\- historique

\- contraintes

\- résultats



\### WORKER



Informations nécessaires au fonctionnement d'un Worker.



Exemples :



\- compétences

\- méthodes

\- préférences opérationnelles

\- KPI

\- historique des tâches



\### TÂCHE



Contexte temporaire nécessaire à une tâche.



Exemples :



\- demande utilisateur

\- contexte transmis

\- dépendances

\- résultat

\- erreurs

\- prochaine action



\---



\## 4. ISOLATION



Un Worker ne doit jamais accéder à la mémoire d'un autre client

sans autorisation explicite du contexte actif.



CLIENT\_A ≠ CLIENT\_B



PROJET\_A ≠ PROJET\_B



Les données doivent toujours être filtrées par :



\- client\_id

\- project\_id

\- worker\_id

\- task\_id



\---



\## 5. CONTEXTE ACTIF



Toute tâche doit posséder un contexte actif.



Format minimal :



CLIENT

PROJECT

WORKER

TASK

OBJECTIVE



\---



\## 6. ÉCRITURE



Avant d'écrire dans la mémoire :



1\. identifier le client

2\. identifier le projet

3\. identifier le Worker

4\. identifier la tâche

5\. vérifier les permissions

6\. écrire

7\. journaliser



\---



\## 7. LECTURE



Avant toute lecture :



1\. identifier le contexte

2\. vérifier le périmètre

3\. récupérer uniquement les informations nécessaires

4\. ne jamais récupérer des données d'un autre client par défaut



\---



\## 8. MÉMOIRE FINANCIÈRE



Les Workers peuvent consulter et préparer des informations financières

dans le cadre autorisé.



Toute opération financière réelle reste sous l'autorité de KADER.



\---



\## 9. SECRET



Les mots de passe, tokens, clés API et secrets ne doivent jamais être

stockés dans la mémoire métier.



Ils doivent utiliser le système sécurisé prévu par l'architecture.



\---



\## 10. TRAÇABILITÉ



Toute écriture importante doit pouvoir être reliée à :



\- client

\- projet

\- Worker

\- tâche

\- timestamp

\- action



\---



\## 11. RÈGLE PRINCIPALE



LA MÉMOIRE SERT LE CONTEXTE.



LE CONTEXTE NE DOIT JAMAIS DÉPASSER LE PÉRIMÈTRE AUTORISÉ.

