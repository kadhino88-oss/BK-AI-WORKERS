$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "CERTIFICATION-SECURITY-INTEGRATION-GATE.ps1"

if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
    throw "MODULE_MISSING"
}

. $Module

if (-not (Get-Command Invoke-GlobalSecurityGate -ErrorAction SilentlyContinue)) {
    throw "GLOBAL_GATE_NOT_LOADED"
}

$script:Total = 0
$script:Pass = 0
$script:Fail = 0

$Base = @{
    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"
    ExecutionId = "EXECUTION-001"
    UserId = "USER-001"
    Environment = "CERTIFICATION"
    Mode = "CERTIFICATION"
}

function Run-Test {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    $script:Total++

    try {
        & $Action | Out-Null
        Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$Name)
        $script:Pass++
    }
    catch {
        Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$Name,$_.Exception.Message)
        $script:Fail++
    }
}

function Assert-GlobalBlock {
    param(
        [hashtable]$Parameters
    )

    $Result = Invoke-CertificationSecurityIntegration @Parameters

    if ($null -eq $Result) {
        throw "NULL_GATE_RESULT"
    }

    if ($Result.Decision -ne "BLOCK") {
        throw "EXPECTED_BLOCK_GOT_$($Result.Decision)"
    }
}

# ============================================================
# 01
# ============================================================

Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
}

# ============================================================
# 02
# ============================================================

Run-Test "Global Security Gate loaded" {
    if (-not (Get-Command Invoke-GlobalSecurityGate -ErrorAction SilentlyContinue)) {
        throw "GLOBAL_GATE_NOT_LOADED"
    }
}

# ============================================================
# 03
# ============================================================

Run-Test "Valid certification context ALLOW" {
    $r = Invoke-CertificationSecurityIntegration @Base

    if ($null -eq $r) {
        throw "NULL_RESULT"
    }

    if ($r.Decision -ne "ALLOW") {
        throw "EXPECTED_ALLOW_GOT_$($r.Decision)"
    }
}

# ============================================================
# 04
# ============================================================

Run-Test "Identity preserved" {
    $r = Invoke-CertificationSecurityIntegration @Base

    if (($r.TenantId -ne $Base.TenantId) -or
        ($r.ClientId -ne $Base.ClientId) -or
        ($r.ProjectId -ne $Base.ProjectId) -or
        ($r.ExecutionId -ne $Base.ExecutionId) -or
        ($r.UserId -ne $Base.UserId)) {
        throw "IDENTITY_NOT_PRESERVED"
    }
}

# ============================================================
# 05
# ============================================================

Run-Test "Session invalid => BLOCK" {
    $p = @{} + $Base
    $p.SessionValid = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 06
# ============================================================

Run-Test "RBAC invalid => BLOCK" {
    $p = @{} + $Base
    $p.RBACAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 07
# ============================================================

Run-Test "Scope invalid => BLOCK" {
    $p = @{} + $Base
    $p.ScopeValid = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 08
# ============================================================

Run-Test "Authorization invalid => BLOCK" {
    $p = @{} + $Base
    $p.AuthorizationValid = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 09
# ============================================================

Run-Test "Capability invalid => BLOCK" {
    $p = @{} + $Base
    $p.CapabilityAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 10
# ============================================================

Run-Test "Authority invalid => BLOCK" {
    $p = @{} + $Base
    $p.AuthorityAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 11
# ============================================================

Run-Test "Policy invalid => BLOCK" {
    $p = @{} + $Base
    $p.PolicyAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 12
# ============================================================

Run-Test "Worker task invalid => BLOCK" {
    $p = @{} + $Base
    $p.WorkerTaskAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 13
# ============================================================

Run-Test "Credential invalid => BLOCK" {
    $p = @{} + $Base
    $p.CredentialAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 14
# ============================================================

Run-Test "Connector authorization invalid => BLOCK" {
    $p = @{} + $Base
    $p.ConnectorAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 15
# ============================================================

Run-Test "Provider authorization invalid => BLOCK" {
    $p = @{} + $Base
    $p.ProviderAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 16
# ============================================================

Run-Test "Evidence authorization invalid => BLOCK" {
    $p = @{} + $Base
    $p.EvidenceAuthorized = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 17
# ============================================================

Run-Test "Retention invalid => BLOCK" {
    $p = @{} + $Base
    $p.RetentionValid = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 18
# ============================================================

Run-Test "Purge reuse invalid => BLOCK" {
    $p = @{} + $Base
    $p.PurgeReuseValid = $false
    Assert-GlobalBlock $p
}

# ============================================================
# 19
# ============================================================

Run-Test "Direct connector execution => BLOCK" {
    $p = @{} + $Base
    $p.DirectConnectorExecution = $true
    Assert-GlobalBlock $p
}

# ============================================================
# 20
# ============================================================

Run-Test "Direct provider execution => BLOCK" {
    $p = @{} + $Base
    $p.DirectProviderExecution = $true
    Assert-GlobalBlock $p
}

# ============================================================
# 21
# ============================================================

Run-Test "Secrets present => BLOCK" {
    $p = @{} + $Base
    $p.SecretsPresent = $true
    Assert-GlobalBlock $p
}

# ============================================================
# 22
# ============================================================

Run-Test "LIVE environment rejected by certification boundary" {
    $p = @{} + $Base
    $p.Environment = "LIVE"

    try {
        Invoke-CertificationSecurityIntegration @p | Out-Null
        throw "EXPECTED_CERTIFICATION_ENVIRONMENT_REJECTION"
    }
    catch {
        if ($_.Exception.Message -notmatch "CERTIFICATION_ENVIRONMENT_REQUIRED") {
            throw
        }
    }
}

# ============================================================
# 23
# ============================================================

Run-Test "LIVE mode rejected by certification boundary" {
    $p = @{} + $Base
    $p.Mode = "LIVE"

    try {
        Invoke-CertificationSecurityIntegration @p | Out-Null
        throw "EXPECTED_CERTIFICATION_MODE_REJECTION"
    }
    catch {
        if ($_.Exception.Message -notmatch "CERTIFICATION_MODE_REQUIRED") {
            throw
        }
    }
}

# ============================================================
# 24
# ============================================================

Run-Test "Certification assertion ALLOW" {
    $r = Assert-CertificationSecurityIntegration @Base

    if ($null -eq $r) {
        throw "NULL_ASSERT_RESULT"
    }

    if ($r.Decision -ne "ALLOW") {
        throw "ASSERT_EXPECTED_ALLOW_GOT_$($r.Decision)"
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8C-03"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and
    ($script:Pass -eq 24) -and
    ($script:Fail -eq 0)) {

    Write-Host "8C-03 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8C-03 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8C-03 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"