$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Entry = Join-Path `
    $Root `
    "core\runtime\security-gate\Invoke-Secure-Execution.ps1"

. $Entry

$Passed = 0
$Failed = 0

function Test-Case {
    param(
        [string]$Name,
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

function Get-Base {

    @{
        TenantId                    = "TEN-01"
        ClientId                    = "CLI-01"
        ProjectId                   = "PROJ-01"
        ExecutionId                 = "EXEC-01"
        UserId                      = "USER-01"

        Environment                 = "SIMULATION"
        Mode                        = "SIMULATION"
        Target                      = "ORCHESTRATOR"

        SessionValid                = $true
        RBACAuthorized              = $true
        ScopeValid                  = $true
        AuthorizationValid          = $true
        CapabilityAuthorized        = $true
        AuthorityAuthorized         = $true
        PolicyAuthorized             = $true
        WorkerTaskAuthorized         = $true
        CredentialAuthorized         = $true
        ConnectorAuthorized          = $true
        ProviderAuthorized           = $true
        EvidenceAuthorized           = $true
        RetentionValid               = $true
        PurgeReuseValid              = $true

        DirectConnectorExecution     = $false
        DirectProviderExecution      = $false
        SecretsPresent               = $false

        HumanApproval                = $false
        ProductionFlag               = $false
    }
}

Test-Case "01 - Entrée sécurisée simulation autorisée" {
    $P = Get-Base
    $R = Invoke-SecureExecution @P

    if ($R.Authorized -ne $true) {
        throw $R.Reason
    }

    if ($R.Bypass -ne $false) {
        throw "Bypass interdit"
    }
}

Test-Case "02 - Session absente bloque" {
    $P = Get-Base
    $P.SessionValid = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "03 - RBAC absent bloque" {
    $P = Get-Base
    $P.RBACAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "04 - Scope absent bloque" {
    $P = Get-Base
    $P.ScopeValid = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "05 - Authorization absente bloque" {
    $P = Get-Base
    $P.AuthorizationValid = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "06 - Capability absente bloque" {
    $P = Get-Base
    $P.CapabilityAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "07 - Authority absente bloque" {
    $P = Get-Base
    $P.AuthorityAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "08 - Policy absente bloque" {
    $P = Get-Base
    $P.PolicyAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "09 - Worker task absente bloque" {
    $P = Get-Base
    $P.WorkerTaskAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "10 - Credential absente bloque" {
    $P = Get-Base
    $P.CredentialAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "11 - Connector absent bloque" {
    $P = Get-Base
    $P.ConnectorAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "12 - Provider absent bloque" {
    $P = Get-Base
    $P.ProviderAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "13 - Evidence absente bloque" {
    $P = Get-Base
    $P.EvidenceAuthorized = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "14 - Retention absente bloque" {
    $P = Get-Base
    $P.RetentionValid = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "15 - Purge/Re-use absent bloque" {
    $P = Get-Base
    $P.PurgeReuseValid = $false
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "16 - Connecteur direct bloque" {
    $P = Get-Base
    $P.DirectConnectorExecution = $true
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "17 - Provider direct bloque" {
    $P = Get-Base
    $P.DirectProviderExecution = $true
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "18 - Secrets présents bloquent" {
    $P = Get-Base
    $P.SecretsPresent = $true
    $R = Invoke-SecureExecution @P
    if ($R.Authorized) { throw "BLOCK attendu" }
}

Test-Case "19 - Mauvais environnement bloque" {
    $P = Get-Base
    $P.Environment = "INVALID"
    try {
        $null = Invoke-SecureExecution @P
    }
    catch {
        return
    }
    throw "BLOCK attendu"
}

Test-Case "20 - LIVE sans approbation bloque" {
    $P = Get-Base
    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.ProductionFlag = $true
    $P.HumanApproval = $false

    $R = Invoke-SecureExecution @P

    if ($R.Authorized) {
        throw "BLOCK attendu"
    }
}

Test-Case "21 - LIVE sans production flag bloque" {
    $P = Get-Base
    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.ProductionFlag = $false
    $P.HumanApproval = $true

    $R = Invoke-SecureExecution @P

    if ($R.Authorized) {
        throw "BLOCK attendu"
    }
}

Test-Case "22 - LIVE complet passe la gate" {
    $P = Get-Base
    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.ProductionFlag = $true
    $P.HumanApproval = $true

    $R = Invoke-SecureExecution @P

    if ($R.Authorized -ne $true) {
        throw $R.Reason
    }
}

Test-Case "23 - Handler absent n'exécute rien" {
    $P = Get-Base
    $R = Invoke-SecureExecution @P

    if ($R.Executed -ne $false) {
        throw "Aucune exécution sans handler"
    }

    if ($R.Bypass -ne $false) {
        throw "Bypass interdit"
    }
}

Test-Case "24 - Handler exécuté uniquement après autorisation" {

    $P = Get-Base

    $script:HandlerCalled = $false

    $P.ExecutionHandler = {
        $script:HandlerCalled = $true
        "EXECUTION_OK"
    }

    $R = Invoke-SecureExecution @P

    if (-not $script:HandlerCalled) {
        throw "Handler non exécuté après autorisation"
    }

    if ($R.Authorized -ne $true) {
        throw "Autorisation attendue"
    }

    if ($R.Executed -ne $true) {
        throw "Executed=true attendu"
    }

    if ($R.Bypass -ne $false) {
        throw "Bypass interdit"
    }

    if ($R.Result -ne "EXECUTION_OK") {
        throw "Résultat handler incorrect"
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-48 — SECURE EXECUTION ENTRY POINT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "TOTAL TESTS : 24"
Write-Host "PASS        : $Passed" -ForegroundColor Green
Write-Host "FAIL        : $Failed" -ForegroundColor Red

if ($Failed -eq 0) {
    Write-Host ""
    Write-Host "8A-48 : VALIDEE - 24/0" -ForegroundColor Green
}
else {
    Write-Host ""
    Write-Host "8A-48 : NON VALIDEE" -ForegroundColor Red
}

Read-Host "Appuie sur Entree pour fermer"