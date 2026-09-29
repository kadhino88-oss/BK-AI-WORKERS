# WORKER REGISTRY

| ID | Nom | Spécialité | Type |
|---|---|---|---|
| lea | LÉA | Design & Créatif | Business |
| noah | NOAH | Administration | Business |
| alex | ALEX | Sales & Prospection | Business |
| maya | MAYA | Marketing & Growth | Business |
| lucas | LUCAS | Développement Web & Digital | Technical |
| seoya | SEOYA | SEO & Search Intelligence | Technical |
| emma | EMMA | Contenu & Social | Business |
| sam | SAM | IT & Cybersécurité | Technical |
| nora | NORA | Customer Support | Business |
| sophie | SOPHIE | RH & Recrutement — Agent ATS IA | Business |
| dario | DARIO | Finance & Contrôle de gestion | Business |
| ines | INÈS | Data & Analytics | Technical |
| yanis | YANIS | Project Management / PMO | Business |
| clara | CLARA | Juridique & Contrats | Business |
| amina | AMINA | Research & Intelligence | Business |
| thomas | THOMAS | E-commerce & Marketplace | Business |
| rayan | RAYAN | Automation & Integrations | Technical |
| atlas | ATLAS | Trading & Risk | Specialized (hors catalogue commercial) |

CHLOÉ

Interface principale de la plateforme (accueil, compréhension,
planification, orchestration, délégation, suivi, synthèse,
coordination des Workers). Intégrée dans BK-AI-WORKERS le 2026-09-14 :
chloe/identity/identity.json, chloe/CHLOE.md, chloe/Invoke-Chloe-Orchestration.ps1
(sélection multi-Workers + délégation via le chemin d'autorisation réel
à 14 étapes, aucun raccourci). Persona et règles de sécurité absolues
reprises à l'identique depuis la source réelle
Desktop\chloe-assistant\chloe.py (toujours active pour la voix —
non remplacée). Enregistrée dans core/runtime/worker-runtime/WORKER-REGISTRY.json
sous le type "orchestrator-interface" (exclue du catalogue commercial
au même titre qu'ATLAS, mais pour une raison différente : elle n'est
pas un Worker à louer, elle est l'interface).

ORCHESTRATEUR

Coordination centrale. Routage dynamique via
orchestrator/worker-routing.json (corrigé le 2026-09-14).

PLANNED (roadmap 18 Workers commerciaux, brief du 2026-09-14)

| ID | Nom | Spécialité |
|---|---|---|
| nora | NORA | Customer Support |
| sophie | SOPHIE | RH & Recrutement — Agent ATS IA |
| dario | DARIO | Finance & Contrôle de gestion |
| ines | INÈS | Data & Analytics |
| yanis | YANIS | Project Management / PMO |
| clara | CLARA | Juridique & Contrats |
| amina | AMINA | Research & Intelligence |
| thomas | THOMAS | E-commerce & Marketplace |
| rayan | RAYAN | Automation & Integrations |

Non construits — spécifications à créer un par un, en suivant le
même modèle que SEOYA (identity/, skills/contracts/,
SKILLS-REGISTRY.json, WORKER.md), puis enregistrement dans ce
fichier + orchestrator/worker-routing.json + capability-matrix +
MASTER-WORKER-FRAMEWORK.json + core/runtime/worker-runtime/WORKER-REGISTRY.json.
