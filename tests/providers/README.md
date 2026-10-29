# Tests du choix du moteur d'IA (`docs/PROVIDERS.md`)

Aucun de ces tests n'appelle Anthropic ni un service tiers : le « moteur » est un faux serveur OpenAI-compatible de la bibliothèque standard (`fake_openai.py`)
et Claude est simulé (`shim_anthropic.ps1`). Un seul fichier parle à un vrai moteur : `real_ollama_check.py` (manuel, votre Ollama local, gratuit).

## Lancer

Les tests **Python seuls** tournent partout (Windows compris) :

```
python -m unittest tests.providers.test_net_policy_fetch tests.providers.test_router tests.providers.test_server_engine tests.providers.test_check_engine
```

Les tests qui lancent **PowerShell 7** (`pwsh`) tournent sous Linux ou WSL, **l'un après l'autre** (la machine est lente) :

```
python3 -m unittest tests.providers.test_engine_common_ps
python3 -m unittest tests.providers.test_openai_adapter
python3 -m unittest tests.providers.test_engine_chain
python3 -m unittest tests.providers.test_chloe_routing
python3 -m unittest tests.providers.test_automation_engine
python3 tests/providers/e2e_server.py        # bout en bout : vrai serveur, copie jetable du dépôt, quelques minutes
```

L'interface (étiquette, ligne « Moteur : … », détail des limites) a son test Node, sans page ni serveur : `node tests/providers/test_engine_ui.js`.

Sous Windows, passer par WSL (`wsl -e bash -c "cd /mnt/c/.../BK-AI-WORKERS && python3 -m unittest ..."`) ; sous Git Bash, préfixer par `MSYS_NO_PATHCONV=1`.
Lire le dépôt sur le disque Windows depuis WSL est lent : la première racine jetable d'un processus (copie de `core/`) prend plusieurs minutes, les suivantes
sont des copies locales.

## Essai réel (manuel, gratuit)

```
python tests/providers/real_ollama_check.py --model qwen2.5:1.5b      # PowerShell 7 requis (variable BK_PWSH si pwsh n'est pas dans le PATH)
```

Une réponse simple et un appel d'outil contre l'Ollama de cette machine ; sur un PC sans carte graphique, un modèle de 8 milliards de paramètres met plusieurs
minutes par réponse (mesures dans `docs/PROVIDERS.md` §11).

## Contenu

Voir le tableau de `docs/PROVIDERS.md` §11.
