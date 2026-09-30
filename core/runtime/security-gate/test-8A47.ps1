$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Gate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

if (-not (Test-Path -LiteralPath $Gate -PathType Leaf)) {
    throw "GATE 8A-47 introuvable : $Gate"
}

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
    return @{
        TenantId                    = "TEN-01"
        ClientId                    = "CLI-01"
        ProjectId                   = "PROJ-01"
        ExecutionId                 = "EXEC-01"
        UserId                      = "USER-01"

        Environment                 = "SIMULATION"
        Mode                        = "SIMULATION"

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

# ============================================================
# 01 — BASE ALLOW
# ============================================================

Test-Case "01 - Simulation complète autorisée" {
    $P = Get-BaseParams
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

# ============================================================
# 02..15 — CHAÎNE DE SÉCURITÉ OBLIGATOIRE
# ============================================================

Test-Case "02 - Session absente bloque" {
    $P = Get-BaseParams
    $P.SessionValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "03 - RBAC absent bloque" {
    $P = Get-BaseParams
    $P.RBACAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "04 - Scope invalide bloque" {
    $P = Get-BaseParams
    $P.ScopeValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "05 - Authorization invalide bloque" {
    $P = Get-BaseParams
    $P.AuthorizationValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "06 - Capability invalide bloque" {
    $P = Get-BaseParams
    $P.CapabilityAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "07 - Authority invalide bloque" {
    $P = Get-BaseParams
    $P.AuthorityAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "08 - Policy invalide bloque" {
    $P = Get-BaseParams
    $P.PolicyAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "09 - Worker Task Authority invalide bloque" {
    $P = Get-BaseParams
    $P.WorkerTaskAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "10 - Credential Authorization invalide bloque" {
    $P = Get-BaseParams
    $P.CredentialAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "11 - Connector Authorization invalide bloque" {
    $P = Get-BaseParams
    $P.ConnectorAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "12 - Provider Authorization invalide bloque" {
    $P = Get-BaseParams
    $P.ProviderAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "13 - Evidence Authorization invalide bloque" {
    $P = Get-BaseParams
    $P.EvidenceAuthorized = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "14 - Retention invalide bloque" {
    $P = Get-BaseParams
    $P.RetentionValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

Test-Case "15 - Purge/Re-use invalide bloque" {
    $P = Get-BaseParams
    $P.PurgeReuseValid = $false
    $R = Invoke-GlobalSecurityGate @P
    if ($R.Authorized -ne $false) { throw "BLOCK attendu" }
}

# ============================================================
# 16..18 — ANTI-BYPASS / SECRET BOUNDARY
# ============================================================

Test-Case "16 - Execution connecteur directe interdite" {
    $P = Get-BaseParams
    $P.DirectConnectorExecution = $true
    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized -ne $false) {
        throw "BLOCK attendu"
    }

    if ($R.Reason -ne "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

Test-Case "17 - Execution provider directe interdite" {
    $P = Get-BaseParams
    $P.DirectProviderExecution = $true
    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized -ne $false) {
        throw "BLOCK attendu"
    }

    if ($R.Reason -ne "DIRECT_PROVIDER_EXECUTION_FORBIDDEN") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

Test-Case "18 - Secrets dans le gate interdits" {
    $P = Get-BaseParams
    $P.SecretsPresent = $true
    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized -ne $false) {
        throw "BLOCK attendu"
    }

    if ($R.Reason -ne "SECRETS_CANNOT_ENTER_SECURITY_GATE") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

# ============================================================
# 19 — TENANT VIDE
# Le binder peut refuser l'appel avant le corps de fonction.
# Le test vérifie donc que l'autorisation n'est jamais obtenue.
# ============================================================

Test-Case "19 - Tenant vide jamais autorisé" {
    $P = Get-BaseParams
    $P.TenantId = ""

    try {
        $R = Invoke-GlobalSecurityGate @P

        if ($null -ne $R -and $R.Authorized -eq $true) {
            throw "Tenant vide autorisé"
        }
    }
    catch {
        if ($_.Exception.Message -match "TenantId") {
            return
        }

        throw
    }
}

# ============================================================
# 20 — EXECUTION ID VIDE
# ============================================================

Test-Case "20 - ExecutionId vide jamais autorisé" {
    $P = Get-BaseParams
    $P.ExecutionId = ""

    try {
        $R = Invoke-GlobalSecurityGate @P

        if ($null -ne $R -and $R.Authorized -eq $true) {
            throw "ExecutionId vide autorisé"
        }
    }
    catch {
        if ($_.Exception.Message -match "ExecutionId") {
            return
        }

        throw
    }
}

# ============================================================
# 21 — ENVIRONNEMENT INVALIDE
# ============================================================

Test-Case "21 - Environnement invalide bloque" {
    $P = Get-BaseParams
    $P.Environment = "INVALID"

    $R = Invoke-GlobalSecurityGate @P

    if ($null -eq $R) {
        throw "Aucune décision retournée"
    }

    if ($R.Authorized -ne $false) {
        throw "Environnement invalide autorisé"
    }

    if ($R.Decision -ne "BLOCK") {
        throw "Decision BLOCK attendue"
    }

    if ($R.Reason -ne "INVALID_ENVIRONMENT") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

# ============================================================
# 22 — LIVE SANS APPROBATION
# ============================================================

Test-Case "22 - LIVE sans approbation bloque" {
    $P = Get-BaseParams

    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.HumanApproval = $false
    $P.ProductionFlag = $true

    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized -ne $false) {
        throw "BLOCK attendu"
    }

    if ($R.Reason -ne "HUMAN_APPROVAL_REQUIRED") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

# ============================================================
# 23 — LIVE SANS PRODUCTION FLAG
# ============================================================

Test-Case "23 - LIVE sans production flag bloque" {
    $P = Get-BaseParams

    $P.Mode = "LIVE"
    $P.Environment = "LIVE"
    $P.HumanApproval = $true
    $P.ProductionFlag = $false

    $R = Invoke-GlobalSecurityGate @P

    if ($R.Authorized -ne $false) {
        throw "BLOCK attendu"
    }

    if ($R.Reason -ne "PRODUCTION_FLAG_REQUIRED") {
        throw "Mauvaise raison : $($R.Reason)"
    }
}

# ============================================================
# 24 — LIVE COMPLET
# ============================================================

Test-Case "24 - LIVE complet autorisé uniquement avec toutes les preuves" {
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

    if ($R.Bypass -eq $true) {
        throw "Bypass interdit"
    }
}

# ============================================================
# RESULTAT FINAL
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-47 — GLOBAL SECURITY ENFORCEMENT GATE — REVUE FINALE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "TOTAL TESTS : 24"
Write-Host "PASS        : $Passed" -ForegroundColor Green
Write-Host "FAIL        : $Failed" -ForegroundColor Red
Write-Host ""

if ($Failed -eq 0) {
    Write-Host "8A-47 : VALIDEE - 24/0" -ForegroundColor Green
}
else {
    Write-Host "8A-47 : NON VALIDEE" -ForegroundColor Red
}

Read-Host "Appuie sur Entree pour fermer"