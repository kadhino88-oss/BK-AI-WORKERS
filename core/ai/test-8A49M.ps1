$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$AiDir = Join-Path $Root "core\ai"

$Gateway = Join-Path $AiDir "AI-GATEWAY.ps1"
$Provider = Join-Path $AiDir "AI-PROVIDER-ENGINE.ps1"
$Gate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

$script:Index = 0
$script:Pass = 0
$script:Fail = 0

function Invoke-Test {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [Parameter(Mandatory=$true)]
        [scriptblock]$Action,

        [Parameter(Mandatory=$true)]
        [bool]$ShouldThrow
    )

    $script:Index++

    try {
        & $Action | Out-Null

        if ($ShouldThrow) {
            Write-Host ("[{0:00}] [FAIL] {1} :: EXECUTION NON BLOQUEE" -f $script:Index,$Name) -ForegroundColor Red
            $script:Fail++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Index,$Name) -ForegroundColor Green
            $script:Pass++
        }
    }
    catch {
        if ($ShouldThrow) {
            Write-Host ("[{0:00}] [PASS] {1} :: BLOQUE -> {2}" -f $script:Index,$Name,$_.Exception.Message) -ForegroundColor Green
            $script:Pass++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} :: {2}" -f $script:Index,$Name,$_.Exception.Message) -ForegroundColor Red
            $script:Fail++
        }
    }
}

function New-Context {
    return @{
        TenantId                 = "TEN-01"
        ClientId                 = "CLI-01"
        ProjectId                = "PROJ-01"
        ExecutionId              = "8A49M-" + [guid]::NewGuid().ToString("N")
        UserId                   = "SECURITY-TEST"
        Environment              = "SIMULATION"
        Mode                     = "SIMULATION"
        SessionValid             = $true
        RBACAuthorized           = $true
        ScopeValid               = $true
        AuthorizationValid       = $true
        CapabilityAuthorized     = $true
        AuthorityAuthorized      = $true
        PolicyAuthorized         = $true
        WorkerTaskAuthorized     = $true
        CredentialAuthorized     = $true
        ConnectorAuthorized      = $true
        ProviderAuthorized       = $true
        EvidenceAuthorized       = $true
        RetentionValid           = $true
        PurgeReuseValid          = $true
        DirectConnectorExecution = $false
        DirectProviderExecution  = $false
        SecretsPresent           = $false
        HumanApproval            = $false
        ProductionFlag           = $false
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-49M - RUNTIME SECURITY VALIDATION - 24 TESTS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($path in @($Gateway,$Provider,$Gate)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "FICHIER_MANQUANT:$path"
    }
}

Remove-Item Function:\Invoke-GlobalSecurityGate -ErrorAction SilentlyContinue
. $Gate

# ============================================================
# 01-08 : FAIL CLOSED
# ============================================================

Invoke-Test "Provider sans SessionValid bloque" {
    $a = New-Context
    $a.SessionValid = $false
    & $Provider @a
} $true

Invoke-Test "Gateway sans SessionValid bloque" {
    $a = New-Context
    $a.SessionValid = $false
    & $Gateway @a
} $true

Invoke-Test "Provider direct execution bloque" {
    $a = New-Context
    $a.DirectProviderExecution = $true
    & $Provider @a
} $true

Invoke-Test "Gateway direct Provider bloque" {
    $a = New-Context
    $a.DirectProviderExecution = $true
    & $Gateway @a
} $true

Invoke-Test "Provider direct Connector bloque" {
    $a = New-Context
    $a.DirectConnectorExecution = $true
    & $Provider @a
} $true

Invoke-Test "Gateway direct Connector bloque" {
    $a = New-Context
    $a.DirectConnectorExecution = $true
    & $Gateway @a
} $true

Invoke-Test "Provider avec secrets bloque" {
    $a = New-Context
    $a.SecretsPresent = $true
    & $Provider @a
} $true

Invoke-Test "Gateway avec secrets bloque" {
    $a = New-Context
    $a.SecretsPresent = $true
    & $Gateway @a
} $true

# ============================================================
# 09-18 : CHAIN
# ============================================================

Invoke-Test "RBAC non autorise bloque" {
    $a = New-Context
    $a.RBACAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "Scope invalide bloque" {
    $a = New-Context
    $a.ScopeValid = $false
    & $Provider @a
} $true

Invoke-Test "Authorization invalide bloque" {
    $a = New-Context
    $a.AuthorizationValid = $false
    & $Provider @a
} $true

Invoke-Test "Capability non autorisee bloque" {
    $a = New-Context
    $a.CapabilityAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "Authority non autorisee bloque" {
    $a = New-Context
    $a.AuthorityAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "Policy non autorisee bloque" {
    $a = New-Context
    $a.PolicyAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "WorkerTask non autorisee bloque" {
    $a = New-Context
    $a.WorkerTaskAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "Credential non autorisee bloque" {
    $a = New-Context
    $a.CredentialAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "Connector non autorise bloque" {
    $a = New-Context
    $a.ConnectorAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "Provider non autorise bloque" {
    $a = New-Context
    $a.ProviderAuthorized = $false
    & $Provider @a
} $true

# ============================================================
# 19-24 : EVIDENCE / RETENTION / LIVE / GATE
# ============================================================

Invoke-Test "Evidence non autorisee bloque" {
    $a = New-Context
    $a.EvidenceAuthorized = $false
    & $Provider @a
} $true

Invoke-Test "Retention invalide bloque" {
    $a = New-Context
    $a.RetentionValid = $false
    & $Provider @a
} $true

Invoke-Test "PurgeReuse invalide bloque" {
    $a = New-Context
    $a.PurgeReuseValid = $false
    & $Provider @a
} $true

Invoke-Test "LIVE sans HumanApproval bloque" {
    $a = New-Context
    $a.Environment = "LIVE"
    $a.Mode = "LIVE"
    $a.HumanApproval = $false
    $a.ProductionFlag = $false
    & $Provider @a
} $true

Invoke-Test "LIVE sans ProductionFlag bloque" {
    $a = New-Context
    $a.Environment = "LIVE"
    $a.Mode = "LIVE"
    $a.HumanApproval = $true
    $a.ProductionFlag = $false
    & $Provider @a
} $true

Invoke-Test "Contexte SIMULATION complet accepte par le Gate" {
    $a = New-Context

    $r = Invoke-GlobalSecurityGate @a

    if ($null -eq $r) {
        throw "GATE_NO_RESULT"
    }

    if ($r.Decision -ne "ALLOW") {
        throw "GATE_DECISION:$($r.Decision)"
    }

    if ($r.Authorized -ne $true) {
        throw "GATE_AUTHORIZED_FALSE"
    }

    if ($r.SecurityIntegrity -ne $true) {
        throw "GATE_SECURITY_INTEGRITY_FALSE"
    }

    if ($r.DirectProvider -ne $false) {
        throw "GATE_DIRECT_PROVIDER_TRUE"
    }

    if ($r.DirectConnector -ne $false) {
        throw "GATE_DIRECT_CONNECTOR_TRUE"
    }

    if ($r.SecretsPresent -ne $false) {
        throw "GATE_SECRETS_TRUE"
    }
} $false

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-49M" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL TESTS : {0}" -f $script:Index)
Write-Host ("PASS        : {0}" -f $script:Pass) -ForegroundColor Green
Write-Host ("FAIL        : {0}" -f $script:Fail) -ForegroundColor Red
Write-Host ""

if (($script:Index -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8A-49M : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8A-49M : NON VALIDEE" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-49M - FIN" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"