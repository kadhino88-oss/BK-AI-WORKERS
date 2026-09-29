# =====================================================================
# BK-AI-WORKERS — Dashboard : soumission reelle d'une tache
# Bootstrap une identite/session/token/RBAC de service pour le
# dashboard (reutilisable, memes IDs a chaque appel), puis appelle
# le vrai Invoke-Orchestrator.ps1. Retourne le JSON du resultat sur
# stdout. Utilise par dashboard/server.py (POST /api/workers/{id}/task).
# =====================================================================

param(
    [Parameter(Mandatory=$true)][string]$Request,
    [string]$WorkerId = "",
    [string]$Mode = "SIMULATION",
    [string]$Environment = "SIMULATION",
    [switch]$PlanOnly,
    [Parameter(Mandatory=$true)][string]$OutFile,
    # Isole les missions d'essai public (voir /api/trial/mission) du profil
    # d'entreprise reel de Kader : sans fichier core/profile/data/<ClientId>.json,
    # Build-WorkerSystemPrompt.ps1 saute simplement le bloc entreprise (deja
    # tolerant a un profil absent). Ne change rien au comportement existant :
    # la valeur par defaut est strictement celle d'avant.
    [string]$ClientId = "CLI-DASHBOARD"
)

$ErrorActionPreference = "Stop"
# PowerShell 7+ : ne pas convertir les dates ISO en [datetime] (Windows PowerShell 5.1 les laissait en texte ; le moteur compare/hashe ces textes).
if ($PSVersionTable.PSVersion.Major -ge 7) { $PSDefaultParameterValues["ConvertFrom-Json:DateKind"] = "String" }
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }

. (Join-Path $Root "core/security/identity-auth/runtime.ps1")
. (Join-Path $Root "core/security/session-token-security/runtime.ps1")
. (Join-Path $Root "core/security/rbac/RBAC.ps1")
. (Join-Path $Root "core/ai/Get-DefaultProvider.ps1")

$TenantId  = "TEN-DASHBOARD"
$ProjectId = "PROJ-DASHBOARD"
# L'identite service est liee a un seul ClientId (CLIENT_MISMATCH sinon) :
# un UserId distinct par ClientId, pas seulement pour CLI-DASHBOARD.
$UserId    = if ($ClientId -eq "CLI-DASHBOARD") { "USER-DASHBOARD-SERVICE" } else { "USER-SERVICE-" + ($ClientId -replace '[^A-Za-z0-9]', '-').ToUpperInvariant() }
# Le Username doit lui aussi etre distinct par ClientId : New-IdentityUser
# rejette silencieusement (USERNAME_ALREADY_EXISTS_IN_TENANT, resultat
# jamais lu ci-dessous) une creation avec le meme (Username, TenantId)
# qu'un utilisateur existant, meme si le UserId differe.
$Username  = if ($ClientId -eq "CLI-DASHBOARD") { "dashboard-service" } else { "service-" + ($ClientId -replace '[^A-Za-z0-9]', '-').ToLowerInvariant() }

# Idempotent : cree l'identite seulement si elle n'existe pas deja.
$ExistingUsers = @(Get-IdentityUsers | Where-Object { $_.UserId -eq $UserId })
if ($ExistingUsers.Count -eq 0) {
    $null = New-IdentityUser -UserId $UserId -Username $Username -TenantId $TenantId -ClientId $ClientId -ProjectId $ProjectId -AccountStatus "ACTIVE"
}

$ExistingBindings = @(Get-RBACBindings | Where-Object { $_.PrincipalId -eq $UserId })
if ($ExistingBindings.Count -eq 0) {
    $null = New-RBACBinding -PrincipalId $UserId -RoleId "ROLE-OPERATOR" -ScopeType "TENANT" -ScopeId $TenantId
}

# Nouvelle session + token a chaque appel (courte duree de vie,
# comportement normal — pas de secret longue duree stocke sur disque).
$Session = New-IdentitySession -UserId $UserId -TenantId $TenantId -ClientId $ClientId -ProjectId $ProjectId
if ($Session.Success -ne $true) {
    throw "DASHBOARD_SESSION_FAILED:$($Session.Reason)"
}

$TokenIdInput = [guid]::NewGuid().ToString()
$Token = New-SessionSecurityToken -TokenId $TokenIdInput -SessionId $Session.SessionId -UserId $UserId -TenantId $TenantId -ClientId $ClientId -ProjectId $ProjectId
if ($Token.Success -ne $true) {
    throw "DASHBOARD_TOKEN_FAILED:$($Token.Reason)"
}

$ExecutionId = "EXEC-DASHBOARD-" + [guid]::NewGuid().ToString("N").Substring(0,12)

if ($WorkerId.ToLowerInvariant() -eq "chloe") {
    # Chat avec Chloe elle-meme : passe par sa propre orchestration
    # (selection multi-Workers + REVIEW + synthese + LEARN), jamais par
    # Invoke-Worker-AI.ps1 directement.
    $ChloePath = Join-Path $Root "chloe/Invoke-Chloe-Orchestration.ps1"
    $ChloeArgs = @{
        Request           = $Request
        TenantId          = $TenantId
        ClientId          = $ClientId
        ProjectId         = $ProjectId
        ExecutionId       = $ExecutionId
        UserId            = $UserId
        SessionId         = $Session.SessionId
        TokenId           = $Token.TokenId
        Token             = $Token.Token
        Mode              = $Mode
        Environment       = $Environment
        CollaborationMode = "PARALLEL"
    }
    if ($PlanOnly) { $ChloeArgs["PlanOnly"] = $true }
    $Result = & $ChloePath @ChloeArgs

    # Trace de chaque appel Worker execute par Chloe (meme format que les
    # missions directes) : sans cela, ces missions n'apparaissaient ni dans
    # les analytics, ni dans le quota de credits, ni dans le suivi de cout.
    if (-not $PlanOnly -and $null -ne $Result -and $null -ne $Result.Results) {
        $ChloeRuntimeDir = Join-Path $Root "runtime/tasks"
        if (-not (Test-Path -LiteralPath $ChloeRuntimeDir -PathType Container)) {
            New-Item -ItemType Directory -Path $ChloeRuntimeDir -Force | Out-Null
        }
        foreach ($Item in @($Result.Results)) {
            if ($null -eq $Item.Result -or [string]::IsNullOrWhiteSpace([string]$Item.TaskId)) { continue }
            $Record = [ordered]@{
                TaskId = $Item.TaskId
                Request = $Request
                Worker = ([string]$Item.Worker).ToUpper()
                Status = if ($Item.Status -eq "SUCCESS") { "EXECUTED" } else { "SECURITY_BLOCKED" }
                Authorized = ($Item.Status -eq "SUCCESS")
                Origin = "CHLOE"
                TenantId = $TenantId
                ClientId = $ClientId
                ProjectId = $ProjectId
                ExecutionId = $ExecutionId
                UserId = $UserId
                Environment = $Environment
                Mode = $Mode
                Result = $Item.Result
                CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
            }
            [System.IO.File]::WriteAllText(
                (Join-Path $ChloeRuntimeDir ("$($Item.TaskId).json")),
                ($Record | ConvertTo-Json -Depth 20),
                [System.Text.UTF8Encoding]::new($false)
            )
        }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($WorkerId)) {
    # Mission confiee depuis la fiche d'UN Worker precis : on l'appelle
    # directement plutot que de repasser par le routage par mots-cles de
    # l'Orchestrateur, qui pourrait renvoyer vers un autre Worker.
    #
    # Politique d'autonomie (2026-09-15) appliquee ICI AUSSI : ce chemin
    # contourne Invoke-Orchestrator.ps1 (et son garde-fou), donc une
    # demande "envoie un email" depuis la fiche de NOAH serait sinon
    # executee sans passer par la revue de Chloe. Meme detection que
    # dans Invoke-Orchestrator.ps1.
    $WorkerLower = $WorkerId.ToLowerInvariant()
    $ReqLower = $Request.ToLowerInvariant()
    $DetectedAction = $null
    if ($ReqLower -match '(?<![a-z0-9])(envoie|envoyer|envoi)s?(?![a-z0-9])') { $DetectedAction = "SEND" }
    elseif ($ReqLower -match '(?<![a-z0-9])(publie|publier|publication)s?(?![a-z0-9])') { $DetectedAction = "PUBLISH" }
    elseif ($ReqLower -match '(?<![a-z0-9])(supprime|supprimer|efface|effacer)s?(?![a-z0-9])') { $DetectedAction = "DELETE" }
    elseif ($ReqLower -match '(?<![a-z0-9])(execute|executer|lance|lancer)s?(?![a-z0-9])') { $DetectedAction = "EXECUTE" }

    $NeedsChloe = $false
    if ($null -ne $DetectedAction) {
        $ContractPath = Join-Path $Root ("workers/" + $WorkerLower + "/contract.json")
        if (Test-Path -LiteralPath $ContractPath -PathType Leaf) {
            $Contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
            $VerifList = @($Contract.execution.chloeVerificationRequired)
            $NeedsChloe = [bool]($VerifList | Where-Object { $_ -like "*.$DetectedAction" })
        }
    }

    if ($NeedsChloe) {
        $Result = [ordered]@{
            TaskId = $null
            Request = $Request
            Worker = $WorkerId.ToUpper()
            Status = "NEEDS_CHLOE_VERIFICATION"
            Authorized = $false
            Reason = "Action a risque ($DetectedAction) — passe par le chat avec Chloe, pas par une mission directe a ce Worker. Voir core/config/AUTONOMY-POLICY.md."
            TenantId = $TenantId
            ClientId = $ClientId
            ProjectId = $ProjectId
            ExecutionId = $ExecutionId
            UserId = $UserId
            Environment = $Environment
            Mode = $Mode
            CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
    else {

    $WorkerAIPath = Join-Path $Root "core/runtime/worker-runtime/Invoke-Worker-AI.ps1"
    $TaskId = "TASK-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()

    $WorkerJson = & $WorkerAIPath `
        -WorkerId $WorkerId.ToUpper() `
        -TaskId $TaskId `
        -Objective $Request `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ExecutionId $ExecutionId `
        -UserId $UserId `
        -SessionId $Session.SessionId `
        -TokenId $Token.TokenId `
        -Token $Token.Token `
        -Environment $Environment `
        -Mode $Mode `
        -Provider (Get-DefaultAIProvider) `
        -Model "NONE"

    $WorkerResult = ($WorkerJson | Select-Object -Last 1) | ConvertFrom-Json -ErrorAction SilentlyContinue

    $Result = [ordered]@{
        TaskId = $TaskId
        Request = $Request
        Worker = $WorkerId.ToUpper()
        Status = if ($null -ne $WorkerResult -and $WorkerResult.Status -eq "SUCCESS") { "EXECUTED" } else { "SECURITY_BLOCKED" }
        Authorized = ($null -ne $WorkerResult -and $WorkerResult.Status -eq "SUCCESS")
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        ExecutionId = $ExecutionId
        UserId = $UserId
        Environment = $Environment
        Mode = $Mode
        Result = $WorkerResult
        CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    # Enregistre aussi une trace dans runtime/tasks/ pour que ce Worker
    # apparaisse dans son propre fil d'activite (meme convention que
    # Invoke-Orchestrator.ps1).
    $RuntimeDir = Join-Path $Root "runtime/tasks"
    if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
        New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $RuntimeDir "$TaskId.json"),
        ($Result | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )
    }
}
else {
    $OrchestratorPath = Join-Path $Root "orchestrator/runtime/Invoke-Orchestrator.ps1"

    $Result = & $OrchestratorPath `
        -Request $Request `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ExecutionId $ExecutionId `
        -UserId $UserId `
        -SessionId $Session.SessionId `
        -TokenId $Token.TokenId `
        -Token $Token.Token `
        -Mode $Mode `
        -Environment $Environment
}

# Ecrit sur disque plutot que sur stdout : les scripts imbriques
# (Invoke-Orchestrator -> Invoke-Worker-AI -> AI-PROVIDER-ENGINE ->
# moteur local) impriment des bannieres Write-Host qui se melangent
# au flux stdout du processus PowerShell, rendant peu fiable un
# parsing JSON base sur stdout seul depuis un appelant externe (Python).
[System.IO.File]::WriteAllText(
    $OutFile,
    ($Result | ConvertTo-Json -Depth 20),
    [System.Text.UTF8Encoding]::new($false)
)
