# =====================================================================
# BK-AI-WORKERS — Dashboard : soumission reelle d'une tache
# Bootstrap une identite/session/token/RBAC de service pour le
# dashboard (reutilisable, memes IDs a chaque appel), puis appelle
# le vrai Invoke-Orchestrator.ps1. Retourne le JSON du resultat sur
# stdout. Utilise par dashboard/server.py (POST /api/workers/{id}/task).
# =====================================================================

param(
    [Parameter(Mandatory=$false)][string]$Request = "",
    [string]$WorkerId = "",
    [string]$Mode = "SIMULATION",
    [string]$Environment = "SIMULATION",
    [switch]$PlanOnly,
    [Parameter(Mandatory=$false)][string]$OutFile = "bridge-output.json",
    [string]$ClientId = "CLI-DASHBOARD",
    
    # --- Ajouts pour accepter le trafic Make (Pont Ngrok) sans planter ---
    [string]$TenantId = "TEN-DASHBOARD",
    [string]$TaskId = "",
    [string]$Objective = "",
    [string]$ClientPlan = "",
    [string]$ComputeMode = "",
    [int]$TasksDoneToday = 0
)

# Adaptation si la requete vient de Make (qui utilise 'Objective' au lieu de 'Request')
if ([string]::IsNullOrWhiteSpace($Request) -and -not [string]::IsNullOrWhiteSpace($Objective)) {
    $Request =$Objective
}

$ErrorActionPreference = "Stop"
# PowerShell 7+ : ne pas convertir les dates ISO en [datetime] (Windows PowerShell 5.1 les laissait en texte ; le moteur compare/hashe ces textes).
if ($PSVersionTable.PSVersion.Major -ge 7) {$PSDefaultParameterValues["ConvertFrom-Json:DateKind"] = "String" }
$Root = if ($env:BK_ROOT) {$env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }

# Offre "Worker a l'unite" (2026-10-12), SECOND verrou (le premier est dans dashboard/server.py)
$AllowedRaw = [string]$env:BK_ALLOWED_WORKERS
if (-not [string]::IsNullOrWhiteSpace($AllowedRaw)) {$AllowedList = @($AllowedRaw.ToLowerInvariant().Split(",") \vert{} ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[a-z]{2,20}$' })
    $WantedWorker =$WorkerId.Trim().ToLowerInvariant()
    if ($WantedWorker -ne "chloe" -and ([string]::IsNullOrWhiteSpace($WantedWorker) -or$AllowedList -notcontains $WantedWorker)) {$RefusedText = "Ce Worker ne fait pas partie de vos Workers embauchés : aucune mission n'a été lancée et aucun crédit n'a été consommé."
        $Refused = [ordered]@{
            TaskId = $null
            Request = $Request
            Worker = $WorkerId.ToUpper()
            Status = "WORKER_NOT_INCLUDED"
            Authorized = $false
            Reason = $RefusedText
            FinalSynthesis = $RefusedText
            ClientId = $ClientId
            CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
        }
        [System.IO.File]::WriteAllText($OutFile, ($Refused \vert{} ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
        exit 0
    }
}

# Niveau de la mission et son cout en credits
$MissionLevelName = [string]$env:BK_MISSION_LEVEL$MissionCredits = 1
if ($MissionLevelName -match '^[a-z]{3,20}$') {
    try {
        $LvProp = (Get-Content -LiteralPath (Join-Path$Root "core/ai/LEVELS.json") -Raw -Encoding UTF8 | ConvertFrom-Json).levels.PSObject.Properties[$MissionLevelName]
        if ($LvProp -and [int]$LvProp.Value.credits -gt 0) { $MissionCredits = [int]$LvProp.Value.credits }
    } catch { }
}

function Get-BKMissionCredits {
    # Credits a facturer pour UNE trace de mission
    param([int]$LevelCost, $WorkerResult, [bool]$Succeeded)
    if (-not $Succeeded -or $null -eq$WorkerResult) { return 0 }
    $DegradedProp =$WorkerResult.PSObject.Properties["Degraded"]
    if ($null -ne $DegradedProp -and [bool]$DegradedProp.Value) { return 0 }
    return $LevelCost
}

. (Join-Path $Root "core/security/identity-auth/runtime.ps1")
. (Join-Path $Root "core/security/session-token-security/runtime.ps1")
. (Join-Path $Root "core/security/rbac/RBAC.ps1")
. (Join-Path $Root "core/ai/Get-DefaultProvider.ps1")

# $TenantId est désormais un paramètre, on ne le force plus manuellement ici.
$ProjectId = "PROJ-DASHBOARD"

# L'identite service est liee a un seul ClientId
$UserId    = if ($ClientId -eq "CLI-DASHBOARD") { "USER-DASHBOARD-SERVICE" } else { "USER-SERVICE-" + ($ClientId -replace '[^A-Za-z0-9]', '-').ToUpperInvariant() }$Username  = if ($ClientId -eq "CLI-DASHBOARD") { "dashboard-service" } else { "service-" + ($ClientId -replace '[^A-Za-z0-9]', '-').ToLowerInvariant() }

# Idempotent : cree l'identite seulement si elle n'existe pas deja.
$ExistingUsers = @(Get-IdentityUsers | Where-Object { $_.UserId -eq$UserId })
if ($ExistingUsers.Count -eq 0) {
    $null = New-IdentityUser -UserId$UserId -Username $Username -TenantId$TenantId -ClientId $ClientId -ProjectId$ProjectId -AccountStatus "ACTIVE"
}

$ExistingBindings = @(Get-RBACBindings | Where-Object { $_.PrincipalId -eq$UserId })
if ($ExistingBindings.Count -eq 0) {$null = New-RBACBinding -PrincipalId $UserId -RoleId "ROLE-OPERATOR" -ScopeType "TENANT" -ScopeId $TenantId
}

# Nouvelle session + token a chaque appel
$Session = New-IdentitySession -UserId $UserId -TenantId$TenantId -ClientId $ClientId -ProjectId$ProjectId
if ($Session.Success -ne$true) {
    throw "DASHBOARD_SESSION_FAILED:$($Session.Reason)"
}

$TokenIdInput = [guid]::NewGuid().ToString()$Token = New-SessionSecurityToken -TokenId $TokenIdInput -SessionId$Session.SessionId -UserId $UserId -TenantId$TenantId -ClientId $ClientId -ProjectId$ProjectId
if ($Token.Success -ne$true) {
    throw "DASHBOARD_TOKEN_FAILED:$($Token.Reason)"
}

$ExecutionId = "EXEC-DASHBOARD-" + [guid]::NewGuid().ToString("N").Substring(0,12)

if ($WorkerId.ToLowerInvariant() -eq "chloe") {
    $ChloePath = Join-Path$Root "chloe/Invoke-Chloe-Orchestration.ps1"
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
    $Result = &$ChloePath @ChloeArgs

    if (-not $PlanOnly -and $null -ne$Result -and $null -ne$Result.Results) {
        $ChloeRuntimeDir = Join-Path$Root "runtime/tasks"
        if (-not (Test-Path -LiteralPath $ChloeRuntimeDir -PathType Container)) {
            New-Item -ItemType Directory -Path $ChloeRuntimeDir -Force | Out-Null
        }
        foreach ($Item in @($Result.Results)) {
            if ($null -eq$Item.Result -or [string]::IsNullOrWhiteSpace([string]$Item.TaskId)) { continue }$Record = [ordered]@{
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
                Level = $MissionLevelName
                Credits = (Get-BKMissionCredits -LevelCost $MissionCredits -WorkerResult $Item.Result -Succeeded ($Item.Status -eq "SUCCESS"))
            }
            [System.IO.File]::WriteAllText(
                (Join-Path $ChloeRuntimeDir ("$($Item.TaskId).json")),
                ($Record \vert{} ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false)
            )
        }
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($WorkerId)) {
    $WorkerLower =$WorkerId.ToLowerInvariant()
    $ReqLower =$Request.ToLowerInvariant()
    $DetectedAction =$null
    if ($ReqLower -match '(?<![a-z0-9])(envoie\vert{}envoyer\vert{}envoi)s?(?![a-z0-9])') {$DetectedAction = "SEND" }
    elseif ($ReqLower -match '(?<![a-z0-9])(publie\vert{}publier\vert{}publication)s?(?![a-z0-9])') {$DetectedAction = "PUBLISH" }
    elseif ($ReqLower -match '(?<![a-z0-9])(supprime\vert{}supprimer\vert{}efface\vert{}effacer)s?(?![a-z0-9])') {$DetectedAction = "DELETE" }
    elseif ($ReqLower -match '(?<![a-z0-9])(execute\vert{}executer\vert{}lance\vert{}lancer)s?(?![a-z0-9])') {$DetectedAction = "EXECUTE" }

    $NeedsChloe =$false
    if ($null -ne $DetectedAction) {$ContractPath = Join-Path $Root ("workers/" + $WorkerLower + "/contract.json")
        if (Test-Path -LiteralPath $ContractPath -PathType Leaf) {
            $Contract = Get-Content -LiteralPath$ContractPath -Raw | ConvertFrom-Json
            $VerifList = @($Contract.execution.chloeVerificationRequired)
            $NeedsChloe = [bool]($VerifList | Where-Object { $_ -like "*.$DetectedAction" })
        }
    }

    if ($NeedsChloe) {$Result = [ordered]@{
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
        $WorkerAIPath = Join-Path$Root "core/runtime/worker-runtime/Invoke-Worker-AI.ps1"
        $FinalTaskId = if ([string]::IsNullOrWhiteSpace($TaskId)) { "TASK-" + [guid]::NewGuid().ToString("N").ToUpperInvariant() } else { $TaskId }

        $WorkerJson = &$WorkerAIPath `
            -WorkerId $WorkerId.ToUpper() `
            -TaskId $FinalTaskId `
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
            TaskId = $FinalTaskId
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
            Level = $MissionLevelName
            Credits = (Get-BKMissionCredits -LevelCost $MissionCredits -WorkerResult $WorkerResult -Succeeded ($null -ne $WorkerResult -and $WorkerResult.Status -eq "SUCCESS"))
        }

        $RuntimeDir = Join-Path $Root "runtime/tasks"
        if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
            New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText(
            (Join-Path $RuntimeDir "$FinalTaskId.json"),
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

[System.IO.File]::WriteAllText(
    $OutFile,
    ($Result \vert{} ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false)
)