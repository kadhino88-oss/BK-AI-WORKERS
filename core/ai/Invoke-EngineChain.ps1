# ============================================================
# BK AI WORKERS
# EXECUTEUR DE CHAINE DE MOTEURS (2026-10-25) : suit le PLAN de moteurs decide par dashboard/provider_router.py (variable BK_ENGINE_PLAN, JSON) pour UNE mission.
# Il se comporte comme un adaptateur (memes entrees que ANTHROPIC-ADAPTER.ps1, memes sorties JSON sur la derniere ligne) et appelle, dans l'ordre de la chaine,
# l'adaptateur de Claude (ANTHROPIC-ADAPTER.ps1) ou l'adaptateur OpenAI-compatible (Ollama, hote suisse, cle du client).
#
# Regles (decision du proprietaire, 2026-10-25) :
#   - Le repli ne se fait QUE le long de la chaine autorisee par le plan (jamais vers un moteur non prevu), et JAMAIS EN SILENCE : le resultat porte
#     engine = { provider, model, local, failedOver, label, ... } ; un repli ajoute en tete de la reponse une phrase qui dit quel moteur a repondu et pourquoi.
#   - Un moteur qui repond « credit epuise », « acces refuse » ou « injoignable » est mis de cote quelques minutes (disjoncteur, runtime/engine/health.json) :
#     les missions suivantes ne l'attendent pas. Une erreur ponctuelle (delai, 429, 5xx) fait seulement passer CETTE mission au moteur suivant.
#   - Plafond de depense Claude (jour / mois, CHF) : verifie AVANT chaque appel a Claude ; atteint, Claude est saute (la chaine gratuite prend le relais, avec
#     mention). Le reste disponible devient le plafond de l'appel (BK_ENGINE_BUDGET_CHF -> ANTHROPIC-ADAPTER.ps1). Le cout reel de chaque mission Claude de la
#     PLATEFORME est ajoute au registre (runtime/engine/spend.json) ; la cle d'un client (BYOK) n'y compte jamais.
#   - Une demande qui exige une capacite que le moteur n'a pas (recherche web, fichiers Office, code) recoit une remarque honnete a la fin de la reponse.
#   - Aucun moteur n'a repondu : erreur « NO_ENGINE_AVAILABLE » (le moteur de secours de la plateforme produit alors la reponse de secours, a 0 credit).
# Sans BK_ENGINE_PLAN, ce script n'est jamais appele : le chemin Claude tourne exactement comme avant.
# ============================================================

param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$WorkerId,
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Objective,
    [Parameter(Mandatory=$false)][string]$Model = "NONE"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off
$ProjectRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $ProjectRoot "core/ai/adapters/Engine-Common.ps1")

function Write-Result($Object) { $Object | ConvertTo-Json -Depth 12 -Compress }

$Plan = $null
try { $Plan = [string]$env:BK_ENGINE_PLAN | ConvertFrom-Json -ErrorAction Stop } catch { $Plan = $null }
if ($null -eq $Plan -or $null -eq $Plan.chain) {
    Write-Result ([ordered]@{ status = "ERROR"; provider = "none"; model = "NONE"; mode = "LLM"; api_call = $false; answer = ""; error = "ENGINE_PLAN_INVALID"; error_class = "config"
                              engine = [ordered]@{ provider = "none"; model = "NONE"; local = $false; failedOver = $false; attempts = @() } })
    exit 1
}

# Echeance de TOUTE la mission, partagee par les moteurs de la chaine (le serveur coupe a 600 s).
$Deadline = [DateTimeOffset]::UtcNow.AddSeconds(540)
$env:BK_ENGINE_DEADLINE_EPOCH = [string]($Deadline.ToUnixTimeMilliseconds() / 1000.0).ToString("F3", [System.Globalization.CultureInfo]::InvariantCulture)

$AdapterDir = Join-Path $ProjectRoot "core/ai/adapters"
$Attempts = @()
$ReasonText = @{
    billing = "le crédit de ce fournisseur est épuisé"; auth = "l'accès à ce fournisseur est refusé (clé absente ou invalide)"; connection = "il est injoignable"
    rate_limit = "il a refusé la requête (trop de demandes)"; timeout = "il a mis trop de temps à répondre"; server = "il a eu une panne"
    bad_request = "il a refusé la requête"; config = "son adresse n'est pas valide"; other = "il a renvoyé une erreur"
    "circuit-open" = "il est indisponible depuis quelques minutes"; "spending-ceiling" = "le plafond de dépense Claude fixé par le propriétaire est atteint"
    "out-of-time" = "il ne restait plus assez de temps pour la mission"
}

function Get-LastJson {
    param($Output)
    $Lines = @(@($Output) | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith("{") })
    if ($Lines.Count -eq 0) { return $null }
    try { return ($Lines[-1] | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-ChainEntry {
    # Appelle l'adaptateur de CE moteur. Renvoie { Exit, Result }.
    param($Entry)
    $Common = @{ ClientId = $ClientId; ProjectId = $ProjectId; WorkerId = $WorkerId; TaskId = $TaskId; Objective = $Objective }
    $SavedAnthropicKey = $env:BK_SECRET_ANTHROPIC
    $SavedBudget = $env:BK_ENGINE_BUDGET_CHF
    try {
        if ($Entry.adapter -eq "anthropic" -or ($Entry.id -eq "byok" -and $Entry.kind -eq "anthropic")) {
            if ($Entry.id -eq "byok") {
                # Cle personnelle du client : lue dans le coffre chiffre, posee dans l'environnement DE CE PROCESSUS le temps de l'appel, puis restauree.
                . (Join-Path $ProjectRoot "core/connectors/Client-Credential-Store.ps1")
                $Raw = Get-BKClientCredentialValue -ClientId $ClientId -Provider "ai_engine"
                $Info = if ($Raw) { $Raw | ConvertFrom-Json } else { $null }
                if ($null -eq $Info -or [string]::IsNullOrWhiteSpace([string]$Info.key)) {
                    return [pscustomobject]@{ Exit = 1; Result = [pscustomobject]@{ status = "ERROR"; error = "CREDENTIAL_NOT_CONFIGURED : aucune cle personnelle valide."; error_class = "auth" } }
                }
                $env:BK_SECRET_ANTHROPIC = [string]$Info.key
                $env:BK_ENGINE_BUDGET_CHF = $null                 # la cle du client paie son propre compte : pas de plafond de la plateforme
            }
            elseif ($Plan.budgetChf -ne $null) {
                $Remaining = Get-BKClaudeBudget
                $env:BK_ENGINE_BUDGET_CHF = if ($Remaining.Configured -and $null -ne $Remaining.RemainingChf) { ([double]$Remaining.RemainingChf).ToString("F4", [System.Globalization.CultureInfo]::InvariantCulture) } else { $null }
            }
            $Out = & (Join-Path $AdapterDir "ANTHROPIC-ADAPTER.ps1") @Common -Model $(if ($Model -and $Model -ne "NONE") { $Model } else { "NONE" }) 2>&1
            return [pscustomobject]@{ Exit = $LASTEXITCODE; Result = (Get-LastJson -Output $Out) }
        }
        $Splat = @{ EngineId = [string]$Entry.id; ToolMode = $(if ($Entry.toolMode) { [string]$Entry.toolMode } else { "auto" }) }
        if ($Entry.url) { $Splat["EndpointUrl"] = [string]$Entry.url }
        if ($Entry.timeoutSec) { $Splat["TimeoutSec"] = [int]$Entry.timeoutSec }
        if ($Entry.secret) { $Splat["SecretName"] = [string]$Entry.secret }
        if ($Entry.allowedHosts) { $Splat["AllowedHosts"] = (@($Entry.allowedHosts) -join ",") }
        $Out = & (Join-Path $AdapterDir "OPENAI-COMPAT-ADAPTER.ps1") @Common -Model $(if ($Entry.model) { [string]$Entry.model } else { "NONE" }) @Splat 2>&1
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Result = (Get-LastJson -Output $Out) }
    }
    finally {
        $env:BK_SECRET_ANTHROPIC = $SavedAnthropicKey
        $env:BK_ENGINE_BUDGET_CHF = $SavedBudget
    }
}

function Get-GapNote {
    # Remarque honnete quand la demande semble exiger une capacite que CE moteur n'a pas (miroir de provider_router.gap_note).
    param($Entry)
    $Missing = @()
    foreach ($N in @($Plan.needs)) {
        if ($N -and $Entry.caps -and $Entry.caps.PSObject.Properties[[string]$N] -and -not [bool]$Entry.caps.PSObject.Properties[[string]$N].Value) { $Missing += [string]$N }
    }
    if ($Missing.Count -eq 0) { return "" }
    $Names = @{ webSearch = "la recherche sur le web"; officeFiles = "des fichiers Office (Excel, Word, PowerPoint, PDF)"; codeExecution = "l'exécution de code" }
    $Items = ($Missing | Where-Object { $Names.ContainsKey($_) } | ForEach-Object { $Names[$_] }) -join " et "
    return "Remarque sur le moteur utilisé (" + [string]$Entry.label + ") : votre demande semble avoir besoin de " + $Items + ", que ce moteur ne sait pas faire. Cette partie n'a PAS été réalisée ; ce qui précède vient uniquement de ce que le modèle sait déjà."
}

$Chain = @($Plan.chain)
$PreferredId = [string]$Plan.preferred
$Answered = $null
foreach ($Entry in $Chain) {
    $Id = [string]$Entry.id
    if ($Id -ne "byok" -and -not (Test-BKEngineHealthy -Provider $Id)) {
        $Attempts += [ordered]@{ provider = $Id; outcome = "skipped"; reason = "circuit-open" }
        continue
    }
    if ($Id -eq "anthropic" -and $Plan.budgetChf -ne $null) {
        $Budget = Get-BKClaudeBudget
        if ($Budget.Configured -and $Budget.Reached) {
            $Attempts += [ordered]@{ provider = $Id; outcome = "skipped"; reason = "spending-ceiling" }
            continue
        }
    }
    if (([DateTimeOffset]::UtcNow).AddSeconds(20) -gt $Deadline) {
        $Attempts += [ordered]@{ provider = $Id; outcome = "skipped"; reason = "out-of-time" }
        continue
    }
    $Call = Invoke-ChainEntry -Entry $Entry
    $R = $Call.Result
    if ($Call.Exit -eq 0 -and $null -ne $R -and [string]$R.status -eq "SUCCESS" -and -not [string]::IsNullOrWhiteSpace([string]$R.answer)) {
        $Answered = [pscustomobject]@{ Entry = $Entry; Result = $R }
        $Attempts += [ordered]@{ provider = $Id; outcome = "answered"; reason = "" }
        if ($Id -ne "byok") { Clear-BKEngineUnhealthy -Provider $Id }
        break
    }
    # Echec : on le classe (credit, authentification, connexion... entrent au disjoncteur ; le reste ne concerne que cette mission).
    $Status = 0; $Text = ""
    if ($null -ne $R) {
        try { $Status = [int]$R.http_status } catch { }
        $Text = ([string]$R.error + " " + [string]$R.error_body)
    }
    $Class = if ($null -ne $R -and $R.error_class) { [string]$R.error_class } else { Get-BKErrorClass -Status $Status -Text $Text }
    if ($Class -eq "other" -and $null -ne $R) { $Class = Get-BKErrorClass -Status $Status -Text $Text }
    if ($Id -ne "byok" -and $Script:BKBreakerClasses -contains $Class) { Set-BKEngineUnhealthy -Provider $Id -Reason $Class }
    $Attempts += [ordered]@{ provider = $Id; outcome = "failed"; reason = $Class }
}

if ($null -eq $Answered) {
    $Reasons = (@($Attempts | ForEach-Object { $_.provider + ":" + $_.reason }) -join ",")
    $Names = @{ anthropic = "Claude"; ollama = "le moteur local"; swiss = "le moteur hébergé en Suisse"; byok = "votre clé personnelle" }
    $Parts = @($Attempts | ForEach-Object {
        $WhyFr = $ReasonText[[string]$_.reason]; if (-not $WhyFr) { $WhyFr = "indisponible" }
        $Who = $Names[[string]$_.provider]; if (-not $Who) { $Who = [string]$_.provider }
        "$Who ($WhyFr)"
    })
    $UserMessage = "Aucun moteur d'IA n'a pu répondre pour le moment" + $(if ($Parts.Count -gt 0) { " : " + ($Parts -join " ; ") } else { "" }) + ". Votre mission n'a pas été traitée et ne consomme aucun crédit. Réessayez dans quelques minutes."
    Write-Result ([ordered]@{ status = "ERROR"; provider = "none"; model = "NONE"; mode = "LLM"; api_call = ($Attempts | Where-Object { $_.outcome -ne "skipped" } | Measure-Object).Count -gt 0
                              answer = ""; error = "NO_ENGINE_AVAILABLE : " + $Reasons; error_class = "unavailable"; user_message = $UserMessage
                              engine = [ordered]@{ provider = "none"; model = "NONE"; local = $false; failedOver = $true; label = "Réponse de secours"; attempts = $Attempts } })
    exit 1
}

# --- succes : on etiquette honnetement le moteur qui a repondu ---
$E = $Answered.Entry
$R = $Answered.Result
$FailedOver = ([string]$E.id -ne $PreferredId)
$Label = [string]$E.label
$AnswerText = [string]$R.answer
if ($FailedOver) {
    $WhyList = @($Attempts | Where-Object { $_.outcome -ne "answered" } | ForEach-Object { $_.reason })
    if ($Plan.reason -eq "spending-ceiling" -and $WhyList.Count -eq 0) { $WhyList = @("spending-ceiling") }
    $Why = if ($WhyList.Count -gt 0) { $ReasonText[[string]$WhyList[0]] } else { "le moteur prévu n'était pas disponible" }
    if (-not $Why) { $Why = "le moteur prévu n'était pas disponible" }
    $Intended = if ($PreferredId -eq "anthropic") { "Claude" } elseif ($PreferredId -eq "ollama") { "le moteur local" } elseif ($PreferredId -eq "swiss") { "le moteur hébergé en Suisse" } else { "le moteur prévu" }
    $Free = if ($Plan.creditsFreeOnFailover) { " Cette mission ne consomme aucun credit." } else { "" }
    $Note = "Note : cette réponse vient du moteur « " + $Label + " » et non de " + $Intended + " (" + $Why + "). Elle peut être plus simple.$Free"
    $AnswerText = $Note + "`n`n" + $AnswerText
}
$Gap = Get-GapNote -Entry $E
if ($Gap) { $AnswerText = $AnswerText.TrimEnd() + "`n`n" + $Gap }
$R.answer = $AnswerText

$EngineOut = [ordered]@{
    provider = [string]$E.id; model = [string]$R.model; local = [bool]$E.local; failedOver = $FailedOver; label = $Label
    byok = ([string]$E.id -eq "byok"); free = [bool]$E.free; creditsFree = ($FailedOver -and [bool]$Plan.creditsFreeOnFailover)
    reason = [string]$Plan.reason; summary = [string]$E.summary; attempts = $Attempts
}
if ($R.engine) { foreach ($P in $R.engine.PSObject.Properties) { if (-not $EngineOut.Contains($P.Name)) { $EngineOut[$P.Name] = $P.Value } } }
if ($R.PSObject.Properties["engine"]) { $R.engine = [pscustomobject]$EngineOut } else { $R | Add-Member -NotePropertyName engine -NotePropertyValue ([pscustomobject]$EngineOut) }
if ($E.byok -or [string]$E.id -eq "byok") { $R.provider = "byok" }

# Depense de la PLATEFORME sur Claude (pas la cle d'un client, pas un moteur gratuit) : registre du jour et du mois (plafond du proprietaire).
if ([string]$E.id -eq "anthropic") {
    try {
        $Chf = [double]$R.usage.estimated_cost_chf; $Usd = [double]$R.usage.estimated_cost_usd
        if ($Chf -gt 0 -or $Usd -gt 0) { Add-BKEngineSpend -Chf $Chf -Usd $Usd }
    } catch { }
}

Write-Result $R
exit 0
