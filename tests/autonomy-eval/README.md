# Banc d'évaluation de l'autonomie

Voir `docs/AUTONOMY-EVAL.md` (conception, preuves, ce qui reste dû).

```
python tests/autonomy-eval/run_eval.py list            # les 15 scénarios
python tests/autonomy-eval/run_eval.py validate
python tests/autonomy-eval/run_eval.py selftest        # les contrôles détectent-ils tous les défauts semés ?
python tests/autonomy-eval/run_eval.py run --dry-run --arms baseline,project,reference --scenarios all --out <dossier>
python tests/autonomy-eval/run_eval.py run --arms reference --provider ollama --scenarios S13 --judge none --out <dossier>   # modèle local gratuit
python tests/autonomy-eval/run_eval.py report --in <dossier>/<run> --out rapport.md
python tests/autonomy-eval/test_eval_harness.py        # tests du banc (30 s, sans dépense)
```

- `--dry-run` : fausse API Anthropic (cassette), faux lanceur d'étape, juge simulé : prouve la plomberie, **ne mesure aucun moteur**.
- Les scénarios sont écrits par `scenarios_src.py` (sources) vers `scenarios/*.json` ; relancer `python tests/autonomy-eval/scenarios_src.py` après modification.
- Aucun appel Anthropic sans `--allow-anthropic` + `--max-usd > 0` + `ANTHROPIC_API_KEY` (clé jamais affichée, jamais écrite).
- Bras `baseline` : exige `pwsh` (variable BK_PWSH). Bras `project` réel : exige l'API Anthropic (dû).
