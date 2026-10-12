"""ANTHROPIC-ADAPTER.ps1 apres la revue d'integration du 2026-10-11 : prompt mis en cache, auto-approve limite aux
vrais brouillons, fichiers generes (tous les tours, plafonds, suppression chez Anthropic), repli d'outil cible.

PowerShell 7 requis (pwsh). Aucun reseau, aucun cout : l'API est simulee par tests/adapter-review/fake_api.ps1.
    python3 -m unittest tests/adapter-review/test_adapter_review.py -v
"""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
PWSH = os.environ.get("BK_PWSH") or shutil.which("pwsh")
FAKE_KEY = "FAKE-ANTHROPIC-KEY-FOR-TESTS-ONLY"
TASK = "TASK-" + "A" * 32
CLIENT = "CLI-ADAPTER-TEST"

DRIVER = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "_test/fake_api.ps1")
$Out = & (Join-Path $env:BK_ROOT "core/ai/adapters/ANTHROPIC-ADAPTER.ps1") `
    -ClientId $env:T_CLIENT -ProjectId "PROJ-T" -WorkerId "noah" -TaskId $env:T_TASK `
    -Objective "Prepare le brouillon et publie le post" -Model "claude-sonnet-5-5"
$Exit = $LASTEXITCODE
[ordered]@{ exit = $Exit; stdout = (($Out | Out-String).Trim()) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
'''


def text_block(text):
    return {"type": "text", "text": text}


def usage(i=1000, o=100, cache_write=None, cache_read=None, web=None):
    """Champ usage d'une reponse de l'API Messages ; les champs de cache et de recherche web n'y figurent que s'ils sont donnes."""
    u = {"input_tokens": i, "output_tokens": o}
    if cache_write is not None or cache_read is not None:
        u["cache_creation_input_tokens"] = cache_write or 0
        u["cache_read_input_tokens"] = cache_read or 0
    if web is not None:
        u["server_tool_use"] = {"web_search_requests": web}
    return u


def tool_use(i, connector, operation, params=None):
    return {"type": "tool_use", "id": f"toolu_{i}", "name": "use_connector",
            "input": {"connectorId": connector, "operation": operation, "reason": "test", "params": params or {}}}


def code_result(*file_ids):
    return {"type": "bash_code_execution_tool_result", "tool_use_id": "srvtoolu_1",
            "content": {"type": "bash_code_execution_result", "stdout": "", "stderr": "", "return_code": 0,
                        "content": [{"type": "bash_code_execution_output", "file_id": fid} for fid in file_ids]}}


def msg(content, stop="end_turn", u=None):
    return {"body": {"id": "msg_1", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5",
                     "content": content, "stop_reason": stop, "usage": u or usage()}}


class Run:
    def __init__(self, cassette, files=None, env=None, activated=("gmail", "linkedin"), auto_approve=True, level=None, edit=None):
        self.root = tempfile.mkdtemp(prefix="bkadrev-")
        shutil.copytree(os.path.join(REPO, "core"), os.path.join(self.root, "core"),
                        ignore=shutil.ignore_patterns("client-credentials", "accounts", "__pycache__", "*.pyc"))
        for sub in ("_test", "memory/runtime", "runtime/tasks", "core/connectors/data"):
            os.makedirs(os.path.join(self.root, sub), exist_ok=True)
        if edit:
            edit(self.root)   # retouche la COPIE de core/ (jamais le depot) : tarifs, niveaux...
        shutil.copy2(os.path.join(HERE, "fake_api.ps1"), os.path.join(self.root, "_test", "fake_api.ps1"))
        with open(os.path.join(self.root, "core/connectors/data", CLIENT + ".json"), "w", encoding="utf-8") as f:
            json.dump(list(activated), f)
        if auto_approve:
            with open(os.path.join(self.root, "core/connectors/data", CLIENT + ".autoapprove.json"), "w", encoding="utf-8") as f:
                json.dump({"autoApprove": True}, f)
        cassette_path = os.path.join(self.root, "_test", "cassette.json")
        with open(cassette_path, "w", encoding="utf-8") as f:
            json.dump({"responses": cassette}, f)
        driver = os.path.join(self.root, "_test", "driver.ps1")
        with open(driver, "w", encoding="utf-8") as f:
            f.write(DRIVER)
        self.out_file = os.path.join(self.root, "_test", "out.json")
        self.log_file = os.path.join(self.root, "_test", "requests.jsonl")
        self.cassette_path = cassette_path
        self.driver = driver
        self.env = dict(os.environ, BK_ROOT=self.root, OUT_FILE=self.out_file, FAKE_CASSETTE=cassette_path, FAKE_LOG=self.log_file,
                        FAKE_KEY=FAKE_KEY, BK_SECRET_ANTHROPIC=FAKE_KEY, T_CLIENT=CLIENT, T_TASK=TASK, BK_REPLY_LANG="")
        if files:
            self.env["FAKE_FILES"] = json.dumps(files)
        if level:
            self.env["BK_MISSION_LEVEL"] = level   # comme le serveur quand les niveaux sont actifs (core/ai/LEVELS.json)
        self.env.update(env or {})
        self._execute()

    def rerun(self, cassette, task=None):
        """Seconde mission dans le MEME dossier (meme client, memes fils de conversation)."""
        with open(self.cassette_path, "w", encoding="utf-8") as f:
            json.dump({"responses": cassette}, f)
        if os.path.isfile(self.log_file):
            os.remove(self.log_file)
        if task:
            self.env["T_TASK"] = task
        self._execute()

    def _execute(self):
        self.proc = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", self.driver], capture_output=True, text=True,
                                   encoding="utf-8", errors="replace", env=self.env, timeout=300, cwd=self.root)
        assert os.path.isfile(self.out_file), f"driver produced nothing\nSTDOUT:\n{self.proc.stdout}\nSTDERR:\n{self.proc.stderr}"
        with open(self.out_file, encoding="utf-8-sig") as f:
            out = json.load(f)
        self.exit = out["exit"]
        self.result = json.loads(out["stdout"]) if out["stdout"].startswith("{") else {"raw": out["stdout"]}
        self.log = []
        if os.path.isfile(self.log_file):
            with open(self.log_file, encoding="utf-8") as f:
                self.log = [json.loads(line) for line in f if line.strip()]

    def of_kind(self, kind):
        return [r for r in self.log if r["kind"] == kind]

    def task_files(self):
        d = os.path.join(self.root, "runtime", "task-files", TASK)
        return {n: os.path.getsize(os.path.join(d, n)) for n in os.listdir(d)} if os.path.isdir(d) else {}

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class AdapterReview(unittest.TestCase):
    def run_case(self, *a, **k):
        r = Run(*a, **k)
        self.addCleanup(r.cleanup)
        return r

    def test_system_prompt_is_a_cacheable_block_on_every_call(self):
        r = self.run_case([msg([tool_use(1, "gmail", "READ_MESSAGE", {"Id": "1"})], "tool_use"), msg([text_block("ok")])])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        calls = r.of_kind("messages")
        self.assertEqual(len(calls), 2)
        self.assertTrue(all(c["systemIsArray"] and c["systemCacheControl"] for c in calls), calls)

    def test_auto_approve_executes_only_true_drafts(self):
        r = self.run_case([
            msg([tool_use(1, "gmail", "DRAFT_MESSAGE", {"To": "a@b.ch", "Subject": "s", "Body": "b"}),
                 tool_use(2, "linkedin", "CREATE_DRAFT_POST", {"Text": "salut"})], "tool_use"),
            msg([text_block("fait")]),
        ])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        by = {a["connectorId"] + "|" + a["operation"]: a for a in r.result["connector_actions"]}
        self.assertTrue(by["gmail|DRAFT_MESSAGE"]["executed"])                      # vrai brouillon : auto-execute
        self.assertTrue(by["gmail|DRAFT_MESSAGE"]["autoApproved"])
        self.assertFalse(by["linkedin|CREATE_DRAFT_POST"]["executed"])              # PUBLIE pour de vrai : carte de confirmation
        self.assertEqual(by["linkedin|CREATE_DRAFT_POST"]["status"], "PENDING_CONFIRMATION")
        self.assertTrue(os.path.isfile(os.path.join(r.root, "memory", "runtime", f"PENDING-ACTION-{TASK}.json")))

    def test_old_behaviour_comes_back_with_the_switch_off(self):
        r = self.run_case([
            msg([tool_use(1, "linkedin", "CREATE_DRAFT_POST", {"Text": "salut"})], "tool_use"),
            msg([text_block("fait")]),
        ], env={"BK_AUTOAPPROVE_DRAFTS_ONLY": "0"})
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertTrue(r.result["connector_actions"][0]["executed"])

    def test_without_auto_approve_every_write_waits_for_the_client(self):
        r = self.run_case([
            msg([tool_use(1, "gmail", "DRAFT_MESSAGE", {"To": "a@b.ch"})], "tool_use"),
            msg([text_block("ok")]),
        ], auto_approve=False)
        self.assertFalse(r.result["connector_actions"][0]["executed"])
        self.assertEqual(r.result["connector_actions"][0]["status"], "PENDING_CONFIRMATION")

    def test_files_from_every_turn_are_captured_capped_and_deleted_remotely(self):
        files = {
            "file_early": {"filename": "devis.pdf", "mime_type": "application/pdf", "size_bytes": 4000},
            "file_late": {"filename": "../../evil name.xlsx", "mime_type": "application/vnd.ms-excel", "size_bytes": 9000},
            "file_huge": {"filename": "gros.zip", "mime_type": "application/zip", "size_bytes": 30 * 1024 * 1024},
        }
        r = self.run_case([
            # tour 1 : un fichier est produit ET un connecteur (lecture) est appele -> ce fichier ne doit pas etre perdu
            msg([code_result("file_early"), tool_use(1, "gmail", "READ_MESSAGE", {"Id": "1"})], "tool_use"),
            msg([code_result("file_late", "file_huge"), text_block("Voici vos documents.")]),
        ], files=files)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        got = r.task_files()
        self.assertEqual(sorted(got), ["devis.pdf", "evil_name.xlsx"], got)          # noms assainis, tour 1 inclus
        self.assertEqual({f["filename"] for f in r.result["files"]}, {"devis.pdf", "evil_name.xlsx"})
        self.assertNotIn("gros.zip", got)                                            # > 25 Mo : ignore
        self.assertIn("non joint", r.result["answer"])
        self.assertIn("gros.zip", r.result["answer"])
        deleted = {x["fileId"] for x in r.of_kind("file") if x["method"] == "Delete"}
        self.assertEqual(deleted, {"file_early", "file_late", "file_huge"})          # plus rien chez Anthropic
        downloaded = {x["fileId"] for x in r.of_kind("download")}
        self.assertNotIn("file_huge", downloaded)                                    # jamais telecharge

    def test_at_most_ten_files_per_mission(self):
        ids = [f"f{i:02d}" for i in range(13)]
        files = {i: {"filename": f"{i}.csv", "mime_type": "text/csv", "size_bytes": 100} for i in ids}
        r = self.run_case([msg([code_result(*ids), text_block("ok")])], files=files)
        self.assertEqual(len(r.task_files()), 10)
        self.assertEqual({x["fileId"] for x in r.of_kind("file") if x["method"] == "Delete"}, set(ids))

    def test_tool_version_fallback_only_on_http_400_about_tools(self):
        r = self.run_case([{"throw400": "400 invalid_request_error: tool type code_execution_20250825 is not supported"},
                           msg([text_block("repli ok")])])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        calls = r.of_kind("messages")
        self.assertEqual(len(calls), 2)
        self.assertIn("code_execution_20250825:code_execution", calls[0]["toolTypes"])
        self.assertIn("code_execution_20250522:code_execution", calls[1]["toolTypes"])
        self.assertEqual(calls[1]["betaHeader"], "code-execution-2025-05-22")

    def test_timeout_or_server_error_is_not_retried_with_the_legacy_tool(self):
        r = self.run_case([{"throw": "The operation was canceled: timeout after 240 seconds"}, msg([text_block("ne doit pas arriver")])])
        self.assertEqual(r.exit, 1)
        self.assertEqual(len(r.of_kind("messages")), 1)                              # une seule requete : pas de double generation


def tool_step(i, u, *extra):
    """Un tour du faux modele : un appel de lecture (use_connector) qui oblige la boucle a continuer."""
    return msg(list(extra) + [tool_use(i, "gmail", "READ_MESSAGE", {"Id": str(i)})], "tool_use", u)


HELPERS_SCRIPT = r'''
$ErrorActionPreference = "Stop"
. (Join-Path $env:BK_ROOT "core/ai/adapters/Mission-Cost.ps1")
$P = Get-BKPricing -Root $env:BK_ROOT
function Rnd($v) { [Math]::Round([double]$v, 6) }
$o = [ordered]@{}
# resolution du modele (comme price_for_model du serveur)
$o.dated   = (Get-BKModelPrice -Pricing $P -Model "claude-haiku-4-5-20251001").Input
$o.prefix  = (Get-BKModelPrice -Pricing $P -Model "claude-opus-5-5-20261001").Output
$o.unknown = ($null -eq (Get-BKModelPrice -Pricing $P -Model "claude-mystery-9"))
# cout d'un appel : base, recherches web (10 USD / 1000), cache, Haiku 5.5 x5 au-dela de 100 000 jetons de prompt
$S = Get-BKModelPrice -Pricing $P -Model "claude-sonnet-5-5"
$o.base       = Rnd (Get-BKCallCostUsd -Price $S -InputTokens 1000 -OutputTokens 500)
$o.web3       = Rnd (Get-BKCallCostUsd -Price $S -InputTokens 1000 -OutputTokens 500 -WebSearches 3)
$o.cacheRead  = Rnd (Get-BKCallCostUsd -Price $S -CacheReadTokens 1000000)
$o.cacheWrite = Rnd (Get-BKCallCostUsd -Price $S -CacheWriteTokens 1000000)
$H = Get-BKModelPrice -Pricing $P -Model "claude-haiku-5-5"
$o.haiku100k  = Rnd (Get-BKCallCostUsd -Price $H -InputTokens 100000)
$o.haikuAbove = Rnd (Get-BKCallCostUsd -Price $H -InputTokens 100001)
$o.cacheDefaultRead = (Get-BKModelPrice -Pricing $P -Model "claude-sonnet-4-6").CacheRead
# suivi + garde-fou
$NoCap = New-BKMissionCost -Pricing $P -Model "claude-sonnet-5-5" -CeilingChf $null
Add-BKCallCost -Cost $NoCap -Response ([pscustomobject]@{ usage = [pscustomobject]@{ input_tokens = 5000000; output_tokens = 1 } })
$o.noCeilingStops = (Test-BKCostGate -Cost $NoCap -NewChars 90000000).Stop
$C = New-BKMissionCost -Pricing $P -Model "claude-sonnet-5-5" -CeilingChf 0.5
Add-BKCallCost -Cost $C -Response ([pscustomobject]@{ usage = [pscustomobject]@{ input_tokens = 10000; output_tokens = 1000 } })
$G1 = Test-BKCostGate -Cost $C -NewChars 0
$G2 = Test-BKCostGate -Cost $C -NewChars 3000000
$o.smallStops = $G1.Stop
$o.hugeToolResultStops = $G2.Stop
$o.hugeToolResultReason = $G2.Reason
Add-BKCallCost -Cost $C -Response ([pscustomobject]@{ usage = [pscustomobject]@{ input_tokens = 10000; output_tokens = 80000 } })
$G3 = Test-BKCostGate -Cost $C -NewChars 0
$o.reachedStops = $G3.Stop
$o.reachedReason = $G3.Reason
# une reponse sans usage ne fait jamais echouer le suivi : l'estimation est marquee incomplete
$Bad = New-BKMissionCost -Pricing $P -Model "claude-sonnet-5-5" -CeilingChf 0.5
Add-BKCallCost -Cost $Bad -Response ([pscustomobject]@{ stop_reason = "end_turn" })
$o.noUsageComplete = (Get-BKCostUsageFields -Cost $Bad).cost_complete
# modele inconnu : ni cout ni plafond
$Unp = New-BKMissionCost -Pricing $P -Model "claude-mystery-9" -CeilingChf 0.5
Add-BKCallCost -Cost $Unp -Response ([pscustomobject]@{ usage = [pscustomobject]@{ input_tokens = 9000000; output_tokens = 9000000 } })
$o.unpricedStops = (Test-BKCostGate -Cost $Unp -NewChars 0).Stop
$o.unpricedCost = (Get-BKCostUsageFields -Cost $Unp).estimated_cost_chf
$o.unpricedFlag = (Get-BKCostUsageFields -Cost $Unp).cost_priced
$o | ConvertTo-Json -Compress
'''


@unittest.skipUnless(PWSH, "pwsh (PowerShell 7) not installed")
class CostCeiling(unittest.TestCase):
    """Plafond de cout par mission (core/ai/LEVELS.json maxCostChf, core/ai/adapters/Mission-Cost.ps1, tarifs core/ai/AI-PRICING.json).
    Les montants attendus sont calcules a la main avec les tarifs publies (Sonnet 5.5 : 2 / 10 USD par million de jetons, ecriture du
    cache 2,5, lecture 0,1 ; Opus 5.5 : 4 / 20 ; Haiku 5.5 : 0,1 / 0,5 ; recherche web 0,01 USD ; 1 USD = 0,83107 CHF), pas relus du fichier."""
    FX = 0.83107

    def run_case(self, *a, **k):
        r = Run(*a, **k)
        self.addCleanup(r.cleanup)
        return r

    def test_equilibre_stops_before_the_call_that_would_cross_its_ceiling(self):
        # 0,13 USD par appel (50 000 entree + 3 000 sortie). Plafond 0,50 CHF = 0,6016 USD. Apres 4 appels (0,52 USD), le 5e est
        # estime a 0,136 USD : 0,656 > 0,6016 -> on s'arrete. Sans pre-controle il y aurait eu un 5e appel (0,65 USD, plafond depasse).
        files = {"file_early": {"filename": "devis.pdf", "mime_type": "application/pdf", "size_bytes": 4000}}
        u = usage(50000, 3000)
        r = self.run_case([tool_step(1, u), tool_step(2, u, code_result("file_early")), tool_step(3, u),
                           tool_step(4, u, text_block("Premiers resultats : 3 clients identifies.")),
                           tool_step(5, u), tool_step(6, u), tool_step(7, u), msg([text_block("fin")], "end_turn", u)],
                          level="equilibre", files=files)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 4)                              # pas un appel de plus
        self.assertTrue(r.result["cost_capped"])                                     # drapeau lisible par le serveur
        us = r.result["usage"]
        self.assertTrue(us["cost_capped"])
        self.assertEqual(us["cost_cap_reason"], "next-call-would-exceed")
        self.assertEqual(us["cost_ceiling_chf"], 0.5)
        self.assertAlmostEqual(us["estimated_cost_usd"], 0.52, places=6)
        self.assertAlmostEqual(us["estimated_cost_chf"], 0.52 * self.FX, places=4)
        self.assertLessEqual(us["estimated_cost_chf"], 0.5)                          # le plafond n'est pas depasse
        self.assertEqual((us["api_calls"], us["input_tokens"], us["output_tokens"]), (4, 200000, 12000))   # jetons CUMULES
        answer = r.result["answer"]
        self.assertTrue(answer.startswith("Premiers resultats : 3 clients identifies."), answer)   # la meilleure reponse obtenue
        self.assertIn("plafond de co", answer)                                       # note en francais
        self.assertIn("continue", answer)
        self.assertNotIn("CHF", answer)                                              # le plafond est un cout interne : jamais montre au client
        self.assertIn("fichiers joints", answer)                                     # un fichier produit en route : prevenu qu'il peut etre incomplet
        self.assertIn("incomplets", answer)
        self.assertEqual(sorted(r.task_files()), ["devis.pdf"])                      # le fichier est quand meme livre, rien de silencieux

    def test_approfondi_has_its_own_ceiling_and_opus_prices(self):
        # 0,22 USD par appel (40 000 x 4 + 3 000 x 20 par million). Plafond 1,00 CHF = 1,2033 USD : 4 appels = 0,88 + 0,2326 estime
        # -> on continue ; 5 appels = 1,10 + 0,2326 = 1,33 > 1,2033 -> arret. 5 appels, 1,10 USD = 0,914 CHF.
        u = usage(40000, 3000)
        r = self.run_case([msg([text_block("Je commence par lire vos messages."), tool_use(1, "gmail", "READ_MESSAGE", {"Id": "1"})], "tool_use", u)]
                          + [tool_step(i, u) for i in range(2, 9)] + [msg([text_block("fin")], "end_turn", u)], level="approfondi")
        self.assertEqual(r.exit, 0, r.proc.stderr)
        calls = r.of_kind("messages")
        self.assertEqual(len(calls), 5)
        self.assertTrue(all(c["model"] == "claude-opus-5-5" for c in calls))
        us = r.result["usage"]
        self.assertTrue(r.result["cost_capped"])
        self.assertEqual(us["cost_ceiling_chf"], 1.0)
        self.assertAlmostEqual(us["estimated_cost_usd"], 1.10, places=6)
        self.assertAlmostEqual(us["estimated_cost_chf"], 1.10 * self.FX, places=4)
        self.assertLessEqual(us["estimated_cost_chf"], 1.0)
        # le dernier tour n'avait aucun texte : on rend la derniere reponse non vide, suivie de la note
        self.assertTrue(r.result["answer"].startswith("Je commence par lire vos messages."), r.result["answer"])
        self.assertIn("plafond de co", r.result["answer"])
        self.assertNotIn("fichiers joints", r.result["answer"])                      # aucun fichier : pas d'avertissement

    def test_rapide_has_no_ceiling_and_haiku_long_prompts_cost_five_times_more(self):
        # 0,0725 USD par appel : 120 000 jetons d'entree x 0,10 x 5 + 5 000 de sortie x 0,50 x 5 (Haiku 5.5, plus de 100 000 jetons de prompt).
        u = usage(120000, 5000)
        r = self.run_case([tool_step(i, u) for i in range(1, 10)], level="rapide")
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 7)                              # 1 + maxIterations (6) : seule la limite d'etapes joue
        self.assertFalse(r.result["cost_capped"])
        us = r.result["usage"]
        self.assertIsNone(us["cost_ceiling_chf"])
        self.assertAlmostEqual(us["estimated_cost_usd"], 7 * 0.0725, places=5)
        self.assertIn("nombre d'etapes maximum", r.result["answer"])
        self.assertNotIn("plafond de co", r.result["answer"])

    def test_a_normal_heavy_mission_is_not_touched_and_cache_and_web_searches_are_counted(self):
        # Mission « lourde » de l'etude (6 appels, 3 recherches web) au niveau Equilibre. Prise a la main :
        #   entree 101 000 x 2 = 0,202 | ecriture cache 9 000 x 2,5 = 0,0225 | lecture cache 45 000 x 0,1 = 0,0045
        #   sortie 7 700 x 10 = 0,077  | 3 recherches x 0,01 = 0,03   ->  0,336 USD = 0,2792 CHF (plafond : 0,50 CHF)
        steps = [(3000, 600, 9000, 0, 0), (8000, 700, 0, 9000, 1), (14000, 700, 0, 9000, 1),
                 (20000, 800, 0, 9000, 1), (26000, 900, 0, 9000, 0), (30000, 4000, 0, 9000, 0)]
        cassette = [tool_step(n + 1, usage(i, o, cw, cr, w)) for n, (i, o, cw, cr, w) in enumerate(steps[:-1])]
        i, o, cw, cr, w = steps[-1]
        cassette.append(msg([text_block("Voici votre analyse complete.")], "end_turn", usage(i, o, cw, cr, w)))
        r = self.run_case(cassette, level="equilibre")
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 6)
        self.assertFalse(r.result["cost_capped"])
        self.assertEqual(r.result["answer"], "Voici votre analyse complete.")        # aucune note, aucun texte ajoute
        us = r.result["usage"]
        self.assertEqual((us["api_calls"], us["input_tokens"], us["output_tokens"]), (6, 101000, 7700))
        self.assertEqual((us["cache_creation_input_tokens"], us["cache_read_input_tokens"], us["web_search_requests"]), (9000, 45000, 3))
        self.assertAlmostEqual(us["estimated_cost_usd"], 0.336, places=6)
        self.assertAlmostEqual(us["estimated_cost_chf"], 0.336 * self.FX, places=4)
        self.assertEqual(us["fx_chf_per_usd"], self.FX)
        self.assertTrue(us["cost_priced"] and us["cost_complete"] and not us["cost_capped"])

    def test_one_huge_prompt_is_caught_by_the_pre_check_before_the_call(self):
        # Apres le 1er appel : 0,51 USD = 0,424 CHF, SOUS le plafond (0,50 CHF). Mais le prompt est de 250 000 jetons : le prochain appel
        # couterait au moins 0,50 USD de plus. On ne le lance pas.
        r = self.run_case([tool_step(1, usage(250000, 1000)), msg([text_block("ne doit pas arriver")])], level="equilibre")
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 1)
        us = r.result["usage"]
        self.assertTrue(r.result["cost_capped"])
        self.assertEqual(us["cost_cap_reason"], "next-call-would-exceed")
        self.assertAlmostEqual(us["estimated_cost_usd"], 0.51, places=6)
        self.assertLess(us["estimated_cost_chf"], 0.5)
        self.assertIn("plafond de co", r.result["answer"])

    def test_an_action_prepared_before_the_cap_stays_valid_and_is_listed(self):
        # Le 1er appel coute deja 0,77 USD (> plafond) et propose DEUX choses : une lecture et la publication d'un post (action qui
        # attend la confirmation du client). L'action en attente est preparee comme d'habitude, aucun appel de plus n'est lance.
        r = self.run_case([
            msg([text_block("Voici le brouillon."), tool_use(1, "gmail", "READ_MESSAGE", {"Id": "1"}),
                 tool_use(2, "linkedin", "CREATE_DRAFT_POST", {"Text": "salut"})], "tool_use", usage(10000, 75000)),
            msg([text_block("ne doit pas arriver")]),
        ], level="equilibre")
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 1)
        self.assertTrue(r.result["cost_capped"])
        self.assertEqual(r.result["usage"]["cost_cap_reason"], "ceiling-reached")
        by = {a["connectorId"] + "|" + a["operation"]: a for a in r.result["connector_actions"]}
        self.assertEqual(by["linkedin|CREATE_DRAFT_POST"]["status"], "PENDING_CONFIRMATION")
        self.assertFalse(by["linkedin|CREATE_DRAFT_POST"]["executed"])
        pending = os.path.join(r.root, "memory", "runtime", f"PENDING-ACTION-{TASK}.json")
        self.assertTrue(os.path.isfile(pending))
        with open(pending, encoding="utf-8-sig") as f:
            p = json.load(f)
        self.assertEqual((p["taskId"], p["connectorId"], p["operation"]), (TASK, "linkedin", "CREATE_DRAFT_POST"))
        answer = r.result["answer"]
        self.assertTrue(answer.startswith("Voici le brouillon."), answer)
        self.assertIn("linkedin", answer)                                            # l'action a confirmer est rappelee dans la note
        self.assertIn("CREATE_DRAFT_POST", answer)
        self.assertIn("consultation", answer)                                        # la lecture faite mais pas exploitee aussi

    def test_a_model_without_a_price_is_never_blocked_and_shows_no_cost(self):
        def unknown_model(root):
            path = os.path.join(root, "core", "ai", "LEVELS.json")
            with open(path, encoding="utf-8-sig") as f:
                data = json.load(f)
            data["levels"]["equilibre"]["model"] = "claude-mystery-9-1"
            with open(path, "w", encoding="utf-8") as f:
                json.dump(data, f)
        u = usage(50000, 3000)
        r = self.run_case([tool_step(i, u) for i in range(1, 6)] + [msg([text_block("termine")], "end_turn", u)], level="equilibre", edit=unknown_model)
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 6)                              # jamais devine : pas de plafond sans tarif
        us = r.result["usage"]
        self.assertFalse(r.result["cost_capped"])
        self.assertFalse(us["cost_priced"])
        self.assertIsNone(us["estimated_cost_chf"])
        self.assertIsNone(us["estimated_cost_usd"])
        self.assertEqual(us["input_tokens"], 300000)                                 # les jetons sont quand meme releves
        self.assertEqual(r.result["answer"], "termine")

    def test_without_a_level_there_is_no_ceiling_but_the_cost_is_recorded(self):
        # BK_LEVELS=0 / pas de niveau : ancien comportement (aucun plafond), meme avec 0,78 USD depenses en 6 appels.
        u = usage(50000, 3000)
        r = self.run_case([tool_step(i, u) for i in range(1, 6)] + [msg([text_block("termine")], "end_turn", u)])
        self.assertEqual(r.exit, 0, r.proc.stderr)
        self.assertEqual(len(r.of_kind("messages")), 6)
        us = r.result["usage"]
        self.assertFalse(r.result["cost_capped"])
        self.assertIsNone(us["cost_ceiling_chf"])
        self.assertAlmostEqual(us["estimated_cost_usd"], 0.78, places=6)
        self.assertEqual(r.result["answer"], "termine")

    def test_cost_helpers(self):
        """Mission-Cost.ps1 seul : resolution du modele, cout d'un appel (recherches web, cache, Haiku x5), garde-fou et pannes."""
        work = tempfile.mkdtemp(prefix="bkcost-")
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        script = os.path.join(work, "helpers.ps1")
        with open(script, "w", encoding="utf-8") as f:
            f.write(HELPERS_SCRIPT)
        p = subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", script], capture_output=True, text=True, encoding="utf-8",
                           errors="replace", env=dict(os.environ, BK_ROOT=REPO), timeout=120)
        lines = [l for l in p.stdout.splitlines() if l.startswith("{")]
        self.assertTrue(lines, f"no JSON output\nSTDOUT:\n{p.stdout}\nSTDERR:\n{p.stderr}")
        o = json.loads(lines[-1])
        self.assertEqual(o["dated"], 1.0)                                            # claude-haiku-4-5-20251001 -> claude-haiku-4-5
        self.assertEqual(o["prefix"], 20.0)                                          # claude-opus-5-5-2026... -> claude-opus-5-5
        self.assertTrue(o["unknown"])
        self.assertAlmostEqual(o["base"], 0.007, places=6)                           # 1 000 x 2 + 500 x 10
        self.assertAlmostEqual(o["web3"] - o["base"], 0.03, places=6)                # 3 recherches x 10 USD / 1 000
        self.assertAlmostEqual(o["cacheRead"], 0.10, places=6)                       # 5 % de l'entree sur Sonnet 5.5
        self.assertAlmostEqual(o["cacheWrite"], 2.50, places=6)
        self.assertAlmostEqual(o["haiku100k"], 0.01, places=6)
        self.assertAlmostEqual(o["haikuAbove"], 0.05, places=5)                      # x5 des que le prompt depasse 100 000 jetons
        self.assertAlmostEqual(o["cacheDefaultRead"], 0.3, places=6)                 # modele sans prix de cache : 0,1 x 3 USD
        self.assertFalse(o["noCeilingStops"])                                        # sans plafond, jamais d'arret, quel que soit le cout
        self.assertFalse(o["smallStops"])
        self.assertTrue(o["hugeToolResultStops"])                                    # 3 millions de caracteres de resultat d'outil
        self.assertEqual(o["hugeToolResultReason"], "next-call-would-exceed")
        self.assertTrue(o["reachedStops"])
        self.assertEqual(o["reachedReason"], "ceiling-reached")
        self.assertFalse(o["noUsageComplete"])                                       # reponse sans usage : suivi marque incomplet, aucune exception
        self.assertFalse(o["unpricedStops"])
        self.assertIsNone(o["unpricedCost"])
        self.assertFalse(o["unpricedFlag"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
