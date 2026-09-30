$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "CERTIFICATION-EVIDENCE-INTEGRITY-GATE.ps1"

. $Module

Initialize-CertificationEvidenceIntegrity | Out-Null

$script:Total = 0
$script:Pass = 0
$script:Fail = 0

function Run-Test {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [bool]$ExpectThrow
    )

    $script:Total++

    try {
        & $Action | Out-Null

        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:Total,$Name)
            $script:Fail++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$Name)
            $script:Pass++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$Name)
            $script:Pass++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$Name,$_.Exception.Message)
            $script:Fail++
        }
    }
}

# 01
Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

# 02
Run-Test "Stage CERTIFICATION" {
    if ((Get-CertificationEvidenceState).Stage -ne "CERTIFICATION") {
        throw "BAD_STAGE"
    }
} $false

# 03
Run-Test "Initial state fail-closed" {
    $s = Get-CertificationEvidenceState

    if (($s.Decision -ne "BLOCK") -or
        ($s.CertificationEvidenceValid -ne $false) -or
        ($s.LiveExecutionAllowed -ne $false) -or
        ($s.ExternalActionsAllowed -ne $false) -or
        ($s.ProviderLiveAllowed -ne $false) -or
        ($s.ConnectorLiveAllowed -ne $false) -or
        ($s.SecretsAllowed -ne $false)) {
        throw "INITIAL_STATE_INVALID"
    }
} $false

# 04
Run-Test "Certification environment required" {
    Test-CertificationEvidenceIntegrity `
        -Environment "SANDBOX" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 05
Run-Test "Certification mode required" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "SANDBOX" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 06
Run-Test "Sandbox evidence missing produces BLOCK" {
    $r = Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true

    if (($r.Decision -ne "BLOCK") -or
        ($r.CertificationEvidenceValid -ne $false) -or
        ($r.Reason -ne "SANDBOX_GLOBAL_VALIDATION_REQUIRED")) {
        throw "SANDBOX_EVIDENCE_BLOCK_INVALID"
    }
} $false

# 07
Run-Test "Sandbox failure blocks" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 44 `
        -SandboxFail 1 `
        -ReadinessValidated $true
} $true

# 08
Run-Test "Incomplete sandbox evidence blocks" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 44 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 09
Run-Test "Negative result values blocked" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass -1 `
        -SandboxFail 46 `
        -ReadinessValidated $true
} $true

# 10
Run-Test "Pass count above checks blocked" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 46 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 11
Run-Test "Fail count above checks blocked" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 0 `
        -SandboxFail 46 `
        -ReadinessValidated $true
} $true

# 12
Run-Test "Result total mismatch blocked" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 43 `
        -SandboxFail 1 `
        -ReadinessValidated $true
} $true

# 13
Run-Test "Zero checks blocked" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 0 `
        -SandboxPass 0 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 14
Run-Test "Readiness missing produces BLOCK" {
    $r = Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $false

    if (($r.Decision -ne "BLOCK") -or
        ($r.Reason -ne "CERTIFICATION_READINESS_VALIDATION_REQUIRED")) {
        throw "READINESS_BLOCK_INVALID"
    }
} $false

# 15
Run-Test "Valid certification evidence allowed" {
    $r = Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true

    if (($r.Decision -ne "ALLOW") -or
        ($r.Authorized -ne $true) -or
        ($r.CertificationEvidenceValid -ne $true) -or
        ($r.Reason -ne "CERTIFICATION_EVIDENCE_VALID")) {
        throw "VALID_EVIDENCE_ALLOW_INVALID"
    }
} $false

# 16
Run-Test "Valid evidence remains non-live" {
    $r = Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true

    if (($r.LiveExecutionAllowed -ne $false) -or
        ($r.ExternalActionsAllowed -ne $false) -or
        ($r.ProviderLiveAllowed -ne $false) -or
        ($r.ConnectorLiveAllowed -ne $false) -or
        ($r.SecretsAllowed -ne $false)) {
        throw "LIVE_ESCALATION"
    }
} $false

# 17
Run-Test "Valid evidence preserves sandbox result" {
    $r = Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true

    if (($r.SandboxChecks -ne 45) -or
        ($r.SandboxPass -ne 45) -or
        ($r.SandboxFail -ne 0) -or
        ($r.SandboxGlobalValidated -ne $true) -or
        ($r.ReadinessValidated -ne $true)) {
        throw "SANDBOX_RESULT_PRESERVATION_INVALID"
    }
} $false

# 18
Run-Test "Assert blocks without sandbox validation" {
    Assert-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 19
Run-Test "Assert blocks without readiness" {
    Assert-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $false
} $true

# 20
Run-Test "Assert allows valid evidence" {
    $r = Assert-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true

    if (($r.Decision -ne "ALLOW") -or
        ($r.Authorized -ne $true) -or
        ($r.CertificationEvidenceValid -ne $true)) {
        throw "ASSERT_ALLOW_INVALID"
    }
} $false

# 21
Run-Test "Wrong environment LIVE blocked" {
    Test-CertificationEvidenceIntegrity `
        -Environment "LIVE" `
        -Mode "CERTIFICATION" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 22
Run-Test "Wrong mode LIVE blocked" {
    Test-CertificationEvidenceIntegrity `
        -Environment "CERTIFICATION" `
        -Mode "LIVE" `
        -SandboxGlobalValidated $true `
        -SandboxChecks 45 `
        -SandboxPass 45 `
        -SandboxFail 0 `
        -ReadinessValidated $true
} $true

# 23
Run-Test "State file and schema valid" {
    $StateFile = Join-Path $PSScriptRoot "state\certification-evidence-state.json"

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        throw "STATE_MISSING"
    }

    $s = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if (($s.Schema -ne "BK-AI-WORKERS-CERTIFICATION-EVIDENCE-INTEGRITY") -or
        ($s.Version -ne "1.0") -or
        ($s.Stage -ne "CERTIFICATION")) {
        throw "STATE_SCHEMA_INVALID"
    }
} $false

# 24
Run-Test "Human approval is not embedded as automatic authority" {
    $s = Get-CertificationEvidenceState

    if (($null -eq $s.Records) -or
        ($s.LiveExecutionAllowed -ne $false) -or
        ($s.ExternalActionsAllowed -ne $false) -or
        ($s.ProviderLiveAllowed -ne $false) -or
        ($s.ConnectorLiveAllowed -ne $false) -or
        ($s.SecretsAllowed -ne $false)) {
        throw "AUTHORITY_ESCALATION"
    }
} $false

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8C-02"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8C-02 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8C-02 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8C-02 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"