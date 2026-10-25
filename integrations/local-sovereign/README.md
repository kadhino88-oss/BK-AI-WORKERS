# Mode « souverain local » (essai du 2026-10-21/22) : copie de référence

Ces trois fichiers `.txt` sont les versions poussées sur `main` le 22 octobre 2026 (commits `c41c971`, `8c98c4e`, `69bbc9f`) :

| Fichier | Rôle dans l'essai |
|---|---|
| `Get-DefaultProvider.ps1.txt` | fournisseur « LocalSovereign » : `http://localhost:11434/v1`, modèle `llama3:latest` |
| `Invoke-Worker-AI.ps1.txt` | lanceur de Worker qui appelle ce moteur local (Ollama) avec quotas jour / semaine / session et modes FLASH / PRO / ARGON |
| `Submit-Task.ps1.txt` | entrée des missions adaptée au trafic Make (pont Ngrok) |

## Pourquoi ils ne sont plus les fichiers actifs
Sur le serveur de production, ces versions rendaient **toutes les missions impossibles** :

1. `dashboard/Submit-Task.ps1` contenait des caractères de copie parasites (`\vert{}` à la place de `|`, lignes collées) : **29 erreurs de syntaxe PowerShell**, donc aucune mission ne démarrait.
2. Le serveur n'héberge **aucun moteur Ollama** (`localhost:11434` n'existe pas) : même sans l'erreur ci-dessus, chaque mission aurait répondu par une erreur de connexion.
3. Le lanceur de Workers n'appelait plus l'adaptateur de Claude : plus de fichiers produits (Excel, Word, PDF), plus de mode dégradé, plus d'outils, plus de niveaux ni de crédits par niveau, plus d'installation par client ni de plafond de coût.

Les versions actives (`dashboard/Submit-Task.ps1`, `core/runtime/worker-runtime/Invoke-Worker-AI.ps1`, `core/ai/Get-DefaultProvider.ps1`) sont celles de la PR #12, avec une seule reprise de ton essai : `Submit-Task.ps1` accepte maintenant les paramètres du flux Make (`-Objective`, `-TaskId`, `-TenantId`, `-ClientPlan`, `-ComputeMode`, `-TasksDoneToday`, `-OutFile` facultatif) sans erreur. Ces paramètres ne servent jamais à contourner les droits ni les crédits.

## Pour faire de ce mode un vrai mode optionnel
Il faudrait : un serveur d'inférence local réellement installé et sécurisé, un sélecteur explicite (`BK_AI_PROVIDER=local`) au lieu d'un remplacement global, un lanceur qui garde les contrôles de la plateforme (droits par Worker, crédits, validation humaine des actions externes), et des tests. Les quotas jour / semaine / session de `Invoke-Worker-AI.ps1.txt` existent déjà côté serveur (limites d'usage, branche `ws/chantier-limits`).
