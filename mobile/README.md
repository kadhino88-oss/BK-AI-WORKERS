# Coques des applications mobiles

Préparation des applications Android / iOS **sans compte développeur** (le propriétaire les créera plus tard).
Tout le mode d'emploi, les prix, les risques de validation et la liste de contrôle sont dans
[`docs/MOBILE-APPS.md`](../docs/MOBILE-APPS.md).

| Dossier | Contenu | État |
|---|---|---|
| `capacitor/` | Coque iOS (Capacitor) : `capacitor.config.json`, écran « hors connexion » local (`www/offline.html`), page de démarrage (`www/index.html`) | Fichiers de configuration relus et testés (`tests/pwa/test_pwa.py`). **Non compilée** : il faut un Mac avec Xcode, qui n'est pas disponible ici. |
| Android | Aucun dossier : la coque Android (Trusted Web Activity) est **générée par Bubblewrap** à partir de `https://bk-ai-workers.com/manifest.json` (`bubblewrap init`), voir `docs/MOBILE-APPS.md` §3. | Non générée (demande JDK 17 + Android SDK + le compte Google Play). |

Le fichier `capacitor/capacitor.config.json` ajoute `BKAIWorkersApp/1.0` au User-Agent : `dashboard/pwa-install.js`
reconnaît cette marque, ne propose alors jamais « Installer l'application » et ajoute les classes CSS
`is-store-app` / `is-ios-app` sur `<html>` (utile pour masquer ce que les règles des stores interdisent dans l'app).
