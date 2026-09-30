$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Gate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

. $Gate

$Passed = 0
$Failed = 0

function Test-Case {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:Passed++
    }
    catch {
        Write-Host "[FAIL] $Name :: $($_.Exception.Message)" -ForegroundColor Red
        $script:Failed++
    }
}

function Get-BaseParams {

    @{
        TenantId                 = "TEN-01"
        ClientId                 = "CLI-01"
        ProjectId                = "PROJ-01"
        ExecutionId              = "EXEC-01"
        UserId                   = "USER-01"
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

        HumanApproval             = $false
        ProductionFlag            = $false
    }
}

# ============================================================
# 24 TESTS
# ============================================================

Test-Case "01 - Allow simulation complète" {
    $P = Get-BaseParams
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $true) { throw "ALLOW attendu : $($R.Reason)" }
}

Test-Case "02 - Session absente bloque" {
    $P = Get-BaseParams
    $P.SessionValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "03 - RBAC absent bloque" {
    $P = Get-BaseParams
    $P.RBACAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "04 - Scope invalide bloque" {
    $P = Get-BaseParams
    $P.ScopeValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "05 - Authorization invalide bloque" {
    $P = Get-BaseParams
    $P.AuthorizationValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "06 - Capability absente bloque" {
    $P = Get-BaseParams
    $P.CapabilityAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "07 - Authority absente bloque" {
    $P = Get-BaseParams
    $P.AuthorityAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "08 - Policy absente bloque" {
    $P = Get-BaseParams
    $P.PolicyAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "09 - Worker Task Authority absente bloque" {
    $P = Get-BaseParams
    $P.WorkerTaskAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "10 - Credential authorization absente bloque" {
    $P = Get-BaseParams
    $P.CredentialAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "11 - Connector authorization absente bloque" {
    $P = Get-BaseParams
    $P.ConnectorAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "12 - Provider authorization absente bloque" {
    $P = Get-BaseParams
    $P.ProviderAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "13 - Evidence authorization absente bloque" {
    $P = Get-BaseParams
    $P.EvidenceAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "14 - Retention invalide bloque" {
    $P = Get-BaseParams
    $P.RetentionValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "15 - Purge/Re-use invalide bloque" {
    $P = Get-BaseParams
    $P.PurgeReuseValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "16 - Execution connecteur directe interdite" {
    $P = Get-BaseParams
    $P.DirectConnectorExecution = $true
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "17 - Execution provider directe interdite" {
    $P = Get-BaseParams
    $P.DirectProviderExecution = $true
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "18 - Secrets dans le gate interdits" {
    $P = Get-BaseParams
    $P.SecretsPresent = $true
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "19 - Tenant vide bloque" {
    $P = Get-BaseParams
    $P.TenantId = ""
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
    if ($R.Reason -ne "IDENTITY_CONTEXT_REQUIRED") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

Test-Case "20 - ExecutionId vide bloque" {
    $P = Get-BaseParams
    $P.ExecutionId = ""
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
    if ($R.Reason -ne "IDENTITY_CONTEXT_REQUIRED") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

Test-Case "21 - Environnement invalide bloque" {
    $P = Get-BaseParams
    $P.Environment = "UNKNOWN"
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized) { throw "BLOCK attendu" }
    if ($R.Reason -ne "INVALID_ENVIRONMENT") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

Test-Case "22 - LIVE sans approbation bloque" {
    $P = Get-BaseParams
    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.HumanApproval = $false
    $P.ProductionFlag = $true

    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized) { throw "BLOCK attendu" }
    if ($R.Reason -ne "HUMAN_APPROVAL_REQUIRED") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

Test-Case "23 - LIVE sans production flag bloque" {
    $P = Get-BaseParams
    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.HumanApproval = $true
    $P.ProductionFlag = $false

    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized) { throw "BLOCK attendu" }
    if ($R.Reason -ne "PRODUCTION_FLAG_REQUIRED") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

Test-Case "24 - LIVE complet autorisé par la gate" {
    $P = Get-BaseParams
    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.HumanApproval = $true
    $P.ProductionFlag = $true

    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized -ne $true) {
        throw "ALLOW attendu : $($R.Reason)"
    }

    if ($R.Decision -ne "ALLOW") {
        throw "Decision ALLOW attendue"
    }

    if ($R.SecurityIntegrity -ne $true) {
        throw "SecurityIntegrity=true attendu"
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-47 — GLOBAL SECURITY ENFORCEMENT GATE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "TOTAL TESTS : 24"
Write-Host "PASS        : $Passed" -ForegroundColor Green
Write-Host "FAIL        : $Failed" -ForegroundColor Red

if ($Failed -eq 0) {
    Write-Host ""
    Write-Host "8A-47 : VALIDEE - 24/0" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "8A-47 : NON VALIDEE" -ForegroundColor Red
}

Read-Host "Appuie sur Entree pour fermer"