# Ce dossier n'est PAS le chemin canonique

Clarifié le 2026-09-14 (brief 18 Workers) : le moteur mémoire réel
(`memory/engine/Memory-Access.ps1`, ligne 23) lit et écrit dans
`memory/data/workers/`, pas ici. Ce dossier (`memory/workers/`, sans "data")
existe mais n'est référencé par aucun code — l'écrire ne fait rien.

Ne pas supprimer sans vérifier qu'aucun script externe n'y fait
référence (aucun trouvé au 2026-09-14, mais prudence).

Chemin réel à utiliser : `memory/data/workers/`
