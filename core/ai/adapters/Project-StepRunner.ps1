# =====================================================================
# BK-AI-WORKERS - Lanceur d'UNE ETAPE DE PROJET (docs/AUTONOMY-ENGINE.md, section 7.7).
#
#   pwsh -NoProfile -File core/ai/adapters/Project-StepRunner.ps1 -InFile <steps/S4/1/input.json> -OutFile <steps/S4/1/result.json>
#
# Environnement : BK_ROOT (racine du depot), BK_PYTHON (interpreteur des outils de l'espace de travail), BK_REPLY_LANG (deja gere). La cle
# Anthropic est lue EN MEMOIRE (Get-BKSecretValue), jamais ecrite : AUCUN secret dans input.json, result.json, cost.json, runner.log ni spool/.
# Codes de sortie : 0 = result.json ecrit (lire son champ status) ; 10 = entree invalide ; 11 = cle API non configuree ;
#                   12 = API indisponible apres reessais (result.json status RETRY_LATER) ; 20 = erreur interne.
# Le lanceur n'ecrit JAMAIS state.json (un seul ecrivain : Python) : seulement workspace/, spool/ (via les outils Python), result.json,
# cost.json, files-api.json et runner.log de SON etape. Un sous-processus par etape : il se termine toujours, pas de processus long.
# =====================================================================
param(
    [Parameter(Mandatory = $true)][string]$InFile,
    [Parameter(Mandatory = $true)][string]$OutFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off
$ProjectRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path }
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

function Write-StepResult {
    param($Object)
    $Tmp = $OutFile + ".tmp-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    [System.IO.File]::WriteAllText($Tmp, ($Object | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Tmp -Destination $OutFile -Force
}

function Write-EarlyResult {
    # Resultat minimal quand la boucle n'a pas pu demarrer (entree invalide, cle absente, erreur interne).
    param([string]$Status, [string]$ExitReason, [string]$ErrorCode)
    try {
        $Now = (Get-Date).ToUniversalTime().ToString("o")
        Write-StepResult ([ordered]@{
            schema = "BK-STEP-RESULT-V1"; status = $Status; exitReason = $ExitReason; report = [ordered]@{}; answerText = ""
            usage = [ordered]@{ input_tokens = 0; output_tokens = 0; estimated_cost_usd = 0.0; estimated_cost_chf = 0.0; cost_capped = $false; api_calls = 0 }
            model = $null; iterations = 0; filesImported = @(); error = $ErrorCode; retryAfterSec = $null; startedUtc = $Now; finishedUtc = $Now })
    } catch { }
}

# ---- entree : lecture et validation de input.json
$In = $null
try {
    if (-not (Test-Path -LiteralPath $InFile -PathType Leaf)) { throw "INPUT_MISSING" }
    $In = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$In.schema -ne "BK-STEP-INPUT-V1") { throw "INPUT_SCHEMA" }
    if ([string]$In.projectId -notmatch '^PRJ-[A-F0-9]{32}$') { throw "INPUT_PROJECT" }
    if ([string]$In.clientId -notmatch '^(CLI-CUST-[A-F0-9]{8}|CLI-DASHBOARD)$') { throw "INPUT_CLIENT" }
    if ([string]$In.stepId -notmatch '^[A-Za-z][A-Za-z0-9-]{0,20}$') { throw "INPUT_STEP" }
    if ([string]$In.kind -notin @("plan", "execute", "fix", "verify", "replan", "consolidate", "answer")) { throw "INPUT_KIND" }
    if ([string]$In.worker -notmatch '^[a-z]{2,20}$') { throw "INPUT_WORKER" }
    if ([string]$In.model -notmatch '^[a-z0-9][a-z0-9._-]{2,60}$') { throw "INPUT_MODEL" }
    foreach ($P in @("projectDir", "workspace", "stepDir", "spool", "context")) { if ([string]::IsNullOrWhiteSpace([string]$In.paths.$P)) { throw "INPUT_PATHS" } }
    if (-not (Test-Path -LiteralPath ([string]$In.paths.stepDir) -PathType Container)) { throw "INPUT_STEPDIR" }
    [void][DateTimeOffset]::Parse([string]$In.deadlineUtc); [void][DateTimeOffset]::Parse([string]$In.hardDeadlineUtc)
}
catch {
    Write-Host ("Project-StepRunner : entree invalide (" + $_.Exception.Message + ")")
    Write-EarlyResult -Status "FAILED" -ExitReason "invalid_input" -ErrorCode "INPUT_INVALID"
    exit 10
}

. (Join-Path $ProjectRoot "core/ai/BK-Secret.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Build-WorkerSystemPrompt.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Client-Memory.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Client-Installation.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Mission-Cost.ps1")
. (Join-Path $ProjectRoot "core/integrations/Connector-Dispatch.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Adapter-Common.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Project-Prompt.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Project-Loop.ps1")

Write-Host "PROJECT STEP RUNNER | worker=$($In.worker) | kind=$($In.kind) | step=$($In.stepId) | model=$($In.model)"

if (-not (Test-BKSecret -Name "anthropic")) {
    Write-BKStepLog -In $In -Message "cle API non configuree"
    Write-EarlyResult -Status "FAILED" -ExitReason "invalid_input" -ErrorCode "CREDENTIAL_NOT_CONFIGURED"
    exit 11
}

$PlainKey = $null
$Exit = 20
try {
    $PlainKey = Get-BKSecretValue -Name "anthropic"
    if ([string]::IsNullOrWhiteSpace($PlainKey)) { throw "CREDENTIAL_EMPTY" }
    $Result = Invoke-BKProjectStepLoop -In $In -PlainKey $PlainKey -Root $ProjectRoot
    Write-StepResult $Result
    Write-BKStepLog -In $In -Message ("fin : status=" + $Result.status + " exitReason=" + $Result.exitReason + " tours=" + $Result.iterations)
    $Exit = if ($Result.status -eq "RETRY_LATER") { 12 } else { 0 }
}
catch {
    Write-BKStepLog -In $In -Message ("erreur interne : " + $_.Exception.GetType().Name + " : " + $_.Exception.Message)
    Write-EarlyResult -Status "FAILED" -ExitReason "invalid_input" -ErrorCode "RUNNER_INTERNAL"
    $Exit = 20
}
finally {
    $PlainKey = $null
}
exit $Exit
