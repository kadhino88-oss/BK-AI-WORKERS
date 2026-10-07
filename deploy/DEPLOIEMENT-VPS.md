# Déploiement BK-AI-WORKERS sur un VPS Linux (Docker)

Le moteur a été rendu portable (2026-09-21) : chemins relatifs à `BK_ROOT`, séparateurs `/`,
secrets lus via `core/ai/BK-Secret.ps1` (variable d'environnement, fichier ou DPAPI sous Windows),
PowerShell 7 (`pwsh`) appelé par le serveur sous Linux. L'image est `Dockerfile` ; l'orchestration
est `docker-compose.yml` (app + Caddy pour le HTTPS automatique).

> Statut : le moteur a été testé sous Linux réel (Ubuntu 26.04 + PowerShell 7.6 dans WSL) :
> missions Claude, Chloé multi-Workers, porte d'accès, Stripe (mode test), profil. Le seul
> élément non testé est l'image Docker elle-même (Docker n'est pas installé sur le poste).
> Pièges déjà corrigés : PowerShell 7 convertit les dates JSON en objets (le moteur exige
> le texte) -> `ConvertFrom-Json -DateKind String` posé dans les points d'entrée ;
> chemins sensibles à la casse ; accès stricts aux propriétés manquantes.
> PowerShell >= 7.5 obligatoire.

## 1. Le serveur (toi)
- VPS Ubuntu 24.04 (ou 22.04), 2 à 4 vCPU, **8 Go RAM**, 80 Go de disque (ex. Infomaniak, Hostpoint, Hetzner).
- Domaine (ex. `bk-ia-workers.com`) : enregistrement A vers l'IP du VPS.

## 2. Installer Docker (SSH)
```bash
curl -fsSL https://get.docker.com | sh
```

## 3. Copier le projet
```bash
git clone <ton dépôt>   # ou scp -r BK-AI-WORKERS user@ip:~/
cd BK-AI-WORKERS
sudo bash deploy/setup-swap.sh 2      # 2 Go de swap : filet de sécurité, persistant au redémarrage
```

## 4. Configuration et secrets (toi, jamais partagés)
```bash
cp .env.example .env
python3 deploy/make-gate-hash.py      # imprime BK_GATE_HASH=... -> à coller dans .env
nano .env                             # domaine, clé Anthropic, Stripe (live)
chmod 600 .env
```

## 5. Démarrer
```bash
docker compose up -d --build
docker compose logs -f app
```

## Vérifications au premier démarrage
1. `https://ton-domaine/` s'affiche (HTTPS automatique).
2. Connexion avec le mot de passe d'accès, puis une mission avec un Worker : réponse Claude.
3. Si une mission échoue, `docker compose logs app` : les erreurs PowerShell y apparaissent.
   Points à surveiller sous Linux : sensibilité à la casse des chemins et cmdlets Windows.

## Mises à jour
`git pull && docker compose up -d --build` : le code est resynchronisé, l'état (missions, profil,
sécurité, facturation) reste dans le volume `bkdata`.

## Sauvegardes
```bash
bash deploy/backup.sh                                   # test manuel
( crontab -l 2>/dev/null; echo "30 3 * * * cd $HOME/BK-AI-WORKERS && bash deploy/backup.sh >> /var/log/bk-backup.log 2>&1" ) | crontab -
```
Sauvegarde chaque nuit à 3h30, gardée 14 jours (`BK_BACKUP_KEEP`). OVH ajoute sa propre
sauvegarde quotidienne du VPS ; garde aussi une copie de temps en temps hors du serveur
(`scp` vers ton PC) : les sauvegardes du même serveur ne protègent pas d'une perte du serveur.

## Page de statut, sonde et incidents (2026-10-07)
- `https://ton-domaine/status.html` et `/api/status` : mesure réelle toutes les 60 s faite par le serveur lui-même (application, fichiers d'état, joignabilité réseau du fournisseur d'IA, sans appel facturé). Les agrégats quotidiens sont dans `memory/runtime/status/` (volume `bkdata`, 90 jours). Rien n'est reconstitué avant le premier échantillon.
- Sonde de redémarrage automatique (toutes les 5 minutes) : `( crontab -l 2>/dev/null; echo "*/5 * * * * bash $HOME/BK-AI-WORKERS/deploy/healthcheck.sh" ) | crontab -`. Elle essaie `/api/health` puis `/api/workers`.
- Surveillance externe (recommandée, gratuite) : un moniteur « HTTP(s) » UptimeRobot sur `https://ton-domaine/api/health` (répond aussi à `HEAD`). C'est la seule façon d'être prévenu quand tout le serveur est arrêté.
- Publier un incident : `docker compose exec app python3 /data/app/deploy/status-incident.py add --title "..." --impact minor --text "..."` (aussi `update`, `resolve`, `list`).
- Vérifier que les deux tâches planifiées existent : `crontab -l` doit montrer `backup.sh` (3 h 30) et `healthcheck.sh` (toutes les 5 min). La page publique de sécurité dit que le dépôt ne peut pas le prouver.

## Stripe live
- Prix live : 39 / 99 / 139 / 449 CHF/mois (+ annuels 390 / 990 / 1390 / 4490), coupon -30 % 2 mois.
- Renseigner `BK_SECRET_STRIPE` (JSON sur une ligne, voir `.env.example`).

## Libre-service multi-comptes (2026-09-22)
Le site est en libre-service complet : n'importe qui visite toutes les pages sans mot de passe,
puis crée un compte gratuit (email + mot de passe, sans carte) pour utiliser Chloé/les Workers/
les Automatisations, avec facturation/analytics/profil/activité entièrement cloisonnés par
client (`CLI-CUST-xxxxxxxx`). Ton propre accès (`CLI-DASHBOARD`) continue de fonctionner avec ton
mot de passe historique, sans rien changer de ton côté. Les connecteurs restent un catalogue
partagé (mode SIMULATION tant que `liveExecutionEnabled` reste false) — pas encore de
configuration de connecteur par client.
