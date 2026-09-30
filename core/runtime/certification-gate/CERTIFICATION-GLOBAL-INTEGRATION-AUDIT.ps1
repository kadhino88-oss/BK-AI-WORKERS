$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$C01 = Join-Path $Root "core\runtime\certification-gate\CERTIFICATION-READINESS-GATE.ps1"
$T01 = Join-Path $Root "core\runtime\certification-gate\test-8C01.ps1"

$C02 = Join-Path $Root "core\runtime\certification-gate\CERTIFICATION-EVIDENCE-INTEGRITY-GATE.ps1"
$T02 = Join-Path $Root "core\runtime\certification-gate\test-8C02.ps1"

$C03 = Join-Path $Root "core\runtime\certification-gate\CERTIFICATION-SECURITY-INTEGRATION-GATE.ps1"
$T03 = Join-Path $Root "core\runtime\certification-gate\test-8C03.ps1"

$GlobalGate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

$Total = 0
$Pass = 0
$Fail = 0

function Check {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Reason
    )

    $script:Total++

    if ($Condition) {
        Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$Name)
        $script:Pass++
    }
    else {
        Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$Name,$Reason)
        $script:Fail++
    }
}

function Read-JsonState {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "STATE_MISSING:$Path"
    }

    $Raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "STATE_EMPTY:$Path"
    }

    return ($Raw | ConvertFrom-Json)
}

Write-Host ""
Write-Host "============================================================"
Write-Host "8C GLOBAL CERTIFICATION INTEGRATION AUDIT"
Write-Host "============================================================"

# 01-06 : artefacts

Check "8C-01 module present" (Test-Path -LiteralPath $C01 -PathType Leaf) "MISSING"
Check "8C-01 test present"   (Test-Path -LiteralPath $T01 -PathType Leaf) "MISSING"
Check "8C-02 module present" (Test-Path -LiteralPath $C02 -PathType Leaf) "MISSING"
Check "8C-02 test present"   (Test-Path -LiteralPath $T02 -PathType Leaf) "MISSING"
Check "8C-03 module present" (Test-Path -LiteralPath $C03 -PathType Leaf) "MISSING"
Check "Global Security Gate present" (Test-Path -LiteralPath $GlobalGate -PathType Leaf) "MISSING"

# 07-10 : certification states

try {
    . $C01
    $S1 = Get-CertificationReadinessState

    Check "8C-01 stage CERTIFICATION" ($S1.Stage -eq "CERTIFICATION") "BAD_STAGE"
    Check "8C-01 fail-closed" (
        ($S1.LiveExecutionAllowed -eq $false) -and
        ($S1.ExternalActionsAllowed -eq $false) -and
        ($S1.ProviderLiveAllowed -eq $false) -and
        ($S1.ConnectorLiveAllowed -eq $false) -and
        ($S1.SecretsAllowed -eq $false)
    ) "CERTIFICATION_NOT_FAIL_CLOSED"

    . $C02
    $S2 = Get-CertificationEvidenceState

    Check "8C-02 stage CERTIFICATION" ($S2.Stage -eq "CERTIFICATION") "BAD_STAGE"
    Check "8C-02 initial decision BLOCK" ($S2.Decision -eq "BLOCK") "BAD_INITIAL_DECISION"
}
catch {
    Check "Certification state loading" $false $_.Exception.Message
    Check "Certification state safety" $false "STATE_NOT_AVAILABLE"
    Check "Certification evidence state" $false "STATE_NOT_AVAILABLE"
    Check "Certification evidence fail-closed" $false "STATE_NOT_AVAILABLE"
}

# 11-14 : source integration

try {
    $C03Content = Get-Content -LiteralPath $C03 -Raw -Encoding UTF8

    Check "8C-03 imports Global Security Gate" (
        $C03Content -match "Global-Security-Enforcement-Gate\.ps1"
    ) "GLOBAL_GATE_REFERENCE_MISSING"

    Check "8C-03 invokes Global Security Gate" (
        $C03Content -match "Invoke-GlobalSecurityGate"
    ) "GLOBAL_GATE_INVOCATION_MISSING"

    Check "8C-03 blocks LIVE boundary" (
        ($C03Content -match "CERTIFICATION_ENVIRONMENT_REQUIRED") -and
        ($C03Content -match "CERTIFICATION_MODE_REQUIRED")
    ) "LIVE_BOUNDARY_MISSING"

    Check "8C-03 prevents direct execution paths" (
        ($C03Content -match "DirectConnectorExecution") -and
        ($C03Content -match "DirectProviderExecution") -and
        ($C03Content -match "SecretsPresent")
    ) "DIRECT_PATH_CONTROLS_MISSING"
}
catch {
    Check "8C-03 integration source audit" $false $_.Exception.Message
    Check "8C-03 gate invocation audit" $false "SOURCE_UNAVAILABLE"
    Check "8C-03 LIVE boundary audit" $false "SOURCE_UNAVAILABLE"
    Check "8C-03 direct path audit" $false "SOURCE_UNAVAILABLE"
}

# 15-18 : Global Gate contract

try {
    . $GlobalGate

    Check "Global Gate command available" (
        $null -ne (Get-Command Invoke-GlobalSecurityGate -ErrorAction SilentlyContinue)
    ) "COMMAND_MISSING"

    $Base = @{
        TenantId = "TENANT-001"
        ClientId = "CLIENT-001"
        ProjectId = "PROJECT-001"
        ExecutionId = "EXECUTION-001"
        UserId = "USER-001"
        Environment = "CERTIFICATION"
        Mode = "CERTIFICATION"
        SessionValid = $true
        RBACAuthorized = $true
        ScopeValid = $true
        AuthorizationValid = $true
        CapabilityAuthorized = $true
        AuthorityAuthorized = $true
        PolicyAuthorized = $true
        WorkerTaskAuthorized = $true
        CredentialAuthorized = $true
        ConnectorAuthorized = $true
        ProviderAuthorized = $true
        EvidenceAuthorized = $true
        RetentionValid = $true
        PurgeReuseValid = $true
        DirectConnectorExecution = $false
        DirectProviderExecution = $false
        SecretsPresent = $false
        HumanApproval = $false
        ProductionFlag = $false
    }

    $Valid = Invoke-GlobalSecurityGate @Base

    Check "Global Gate accepts valid Certification chain" (
        $Valid.Decision -eq "ALLOW"
    ) "VALID_CHAIN_BLOCKED"

    Check "Global Gate returns Authorized true" (
        $Valid.Authorized -eq $true
    ) "AUTHORIZED_FALSE"

    $Bad = @{} + $Base
    $Bad.SessionValid = $false
    $Blocked = Invoke-GlobalSecurityGate @Bad

    Check "Global Gate blocks invalid session" (
        ($Blocked.Decision -eq "BLOCK") -and
        ($Blocked.Authorized -eq $false)
    ) "SESSION_NOT_BLOCKED"
}
catch {
    Check "Global Gate runtime contract" $false $_.Exception.Message
    Check "Global Gate valid-chain runtime" $false "RUNTIME_FAILURE"
    Check "Global Gate authorization contract" $false "RUNTIME_FAILURE"
}

# 19-22 : runtime isolation invariants

try {
    $SandboxModules = @(
        "core\runtime\sandbox-execution\SANDBOX-EXECUTION-RUNTIME.ps1",
        "core\runtime\sandbox-isolation\SANDBOX-LIVE-ISOLATION-GUARD.ps1",
        "core\runtime\sandbox-network-guard\SANDBOX-NETWORK-EXTERNAL-IO-GUARD.ps1",
        "core\runtime\sandbox-output-guard\SANDBOX-OUTPUT-DATA-EXFILTRATION-GUARD.ps1"
    )

    $AllPresent = $true

    foreach ($Relative in $SandboxModules) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $Relative) -PathType Leaf)) {
            $AllPresent = $false
        }
    }

    Check "Sandbox critical runtime modules remain present" $AllPresent "SANDBOX_RUNTIME_MISSING"

    $S1 = Get-CertificationReadinessState
    $S2 = Get-CertificationEvidenceState

    Check "Certification readiness remains non-live" (
        $S1.LiveExecutionAllowed -eq $false
    ) "LIVE_ESCALATION"

    Check "Certification evidence remains non-live" (
        $S2.LiveExecutionAllowed -eq $false
    ) "LIVE_ESCALATION"

    Check "Certification external actions disabled" (
        $S1.ExternalActionsAllowed -eq $false -and
        $S2.ExternalActionsAllowed -eq $false
    ) "EXTERNAL_ACTION_ESCALATION"
}
catch {
    Check "Certification isolation audit" $false $_.Exception.Message
    Check "Certification non-live audit" $false "RUNTIME_FAILURE"
    Check "Certification evidence isolation audit" $false "RUNTIME_FAILURE"
}

# 23-24 : final integrity

try {
    $S2 = Get-CertificationEvidenceState

    Check "Certification evidence starts fail-closed" (
        ($S2.Decision -eq "BLOCK") -and
        ($S2.CertificationEvidenceValid -eq $false)
    ) "FAIL_OPEN_DETECTED"

    Check "Certification chain has no automatic LIVE authority" (
        ($S1.LiveExecutionAllowed -eq $false) -and
        ($S2.LiveExecutionAllowed -eq $false)
    ) "AUTOMATIC_LIVE_AUTHORITY_DETECTED"
}
catch {
    Check "Final certification integrity" $false $_.Exception.Message
    Check "Final certification LIVE authority audit" $false "RUNTIME_FAILURE"
}

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8C GLOBAL"
Write-Host "============================================================"
Write-Host ("TOTAL CHECKS : {0}" -f $Total)
Write-Host ("PASS         : {0}" -f $Pass)
Write-Host ("FAIL         : {0}" -f $Fail)
Write-Host ""

if (($Total -eq 24) -and ($Pass -eq 24) -and ($Fail -eq 0)) {
    Write-Host "8C GLOBAL : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8C GLOBAL : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8C GLOBAL AUDIT - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"