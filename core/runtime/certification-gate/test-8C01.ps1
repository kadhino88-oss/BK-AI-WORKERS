$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "CERTIFICATION-READINESS-GATE.ps1"

. $Module

Initialize-CertificationReadiness | Out-Null

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

Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

Run-Test "Stage CERTIFICATION" {
    if ((Get-CertificationReadinessState).Stage -ne "CERTIFICATION") {
        throw "BAD_STAGE"
    }
} $false

Run-Test "Live execution disabled" {
    if ((Get-CertificationReadinessState).LiveExecutionAllowed) {
        throw "LIVE_ENABLED"
    }
} $false

Run-Test "External actions disabled" {
    if ((Get-CertificationReadinessState).ExternalActionsAllowed) {
        throw "EXTERNAL_ENABLED"
    }
} $false

Run-Test "Provider live disabled" {
    if ((Get-CertificationReadinessState).ProviderLiveAllowed) {
        throw "PROVIDER_LIVE_ENABLED"
    }
} $false

Run-Test "Connector live disabled" {
    if ((Get-CertificationReadinessState).ConnectorLiveAllowed) {
        throw "CONNECTOR_LIVE_ENABLED"
    }
} $false

Run-Test "Secrets disabled" {
    if ((Get-CertificationReadinessState).SecretsAllowed) {
        throw "SECRETS_ENABLED"
    }
} $false

Run-Test "Certification environment required" {
    Test-CertificationReadiness `
        -Environment "SANDBOX" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true
} $true

Run-Test "Certification mode required" {
    Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "SANDBOX" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true
} $true

Run-Test "Sandbox validation required" {
    Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION"
} $true

Run-Test "Human approval produces BLOCK" {
    $r = Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $false

    if (($r.Decision -ne "BLOCK") -or
        ($r.HumanApprovalRequired -ne $true) -or
        ($r.HumanApprovalGranted -ne $false) -or
        ($r.LiveExecutionAllowed -ne $false)) {
        throw "APPROVAL_BLOCK_CONTRACT_INVALID"
    }
} $false

Run-Test "Approved certification allowed" {
    $r = Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true

    if (($r.Decision -ne "ALLOW") -or
        ($r.Authorized -ne $true) -or
        ($r.CertificationReady -ne $true)) {
        throw "CERTIFICATION_ALLOW_CONTRACT_INVALID"
    }
} $false

Run-Test "Approved certification remains non-live" {
    $r = Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true

    if (($r.LiveExecutionAllowed -ne $false) -or
        ($r.ExternalActionsAllowed -ne $false) -or
        ($r.ProviderLiveAllowed -ne $false) -or
        ($r.ConnectorLiveAllowed -ne $false) -or
        ($r.SecretsAllowed -ne $false)) {
        throw "CERTIFICATION_ESCALATION"
    }
} $false

Run-Test "Sandbox must be validated" {
    Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $false `
        -HumanApprovalGranted $true
} $true

Run-Test "Wrong environment blocked" {
    Test-CertificationReadiness `
        -Environment "LIVE" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true
} $true

Run-Test "Wrong mode blocked" {
    Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "LIVE" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true
} $true

Run-Test "Assert blocks without approval" {
    Assert-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $false
} $true

Run-Test "Assert allows approved certification" {
    $r = Assert-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true

    if (($r.Decision -ne "ALLOW") -or
        ($r.Reason -ne "CERTIFICATION_READY") -or
        ($r.Authorized -ne $true) -or
        ($r.CertificationReady -ne $true)) {
        throw "ASSERT_ALLOW_CONTRACT_INVALID"
    }
} $false

Run-Test "State file present" {
    $StateFile = Join-Path $PSScriptRoot "state\certification-state.json"

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        throw "STATE_MISSING"
    }

    $State = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json

    if (($State.Schema -ne "BK-AI-WORKERS-CERTIFICATION-READINESS") -or
        ($State.Stage -ne "CERTIFICATION") -or
        ($State.LiveExecutionAllowed -ne $false) -or
        ($State.ExternalActionsAllowed -ne $false) -or
        ($State.ProviderLiveAllowed -ne $false) -or
        ($State.ConnectorLiveAllowed -ne $false) -or
        ($State.SecretsAllowed -ne $false)) {
        throw "STATE_CONTRACT_INVALID"
    }
} $false

Run-Test "Decision reason valid" {
    $r = Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true

    if ($r.Reason -ne "CERTIFICATION_READY") {
        throw "BAD_REASON"
    }
} $false

Run-Test "Human approval remains mandatory" {
    $State = Get-CertificationReadinessState

    if ($State.HumanApprovalRequired -ne $true) {
        throw "HUMAN_APPROVAL_NOT_REQUIRED"
    }
} $false

Run-Test "Initialization remains fail-closed" {
    $State = Initialize-CertificationReadiness

    if (($State.CertificationReady -ne $false) -or
        ($State.Decision -ne "BLOCK") -or
        ($State.LiveExecutionAllowed -ne $false) -or
        ($State.ExternalActionsAllowed -ne $false) -or
        ($State.SecretsAllowed -ne $false)) {
        throw "INITIAL_STATE_NOT_FAIL_CLOSED"
    }
} $false

Run-Test "Provider and connector remain disabled after reinitialization" {
    $State = Get-CertificationReadinessState

    if (($State.ProviderLiveAllowed -ne $false) -or
        ($State.ConnectorLiveAllowed -ne $false)) {
        throw "PROVIDER_CONNECTOR_ESCALATION"
    }
} $false

Run-Test "Approved result carries certification environment and mode" {
    $r = Test-CertificationReadiness `
        -Environment "CERTIFICATION" `
        -Mode "CERTIFICATION" `
        -SandboxValidated $true `
        -HumanApprovalGranted $true

    if (($r.Environment -ne "CERTIFICATION") -or
        ($r.Mode -ne "CERTIFICATION")) {
        throw "IDENTITY_CONTEXT_INVALID"
    }
} $false

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8C-01"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8C-01 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8C-01 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8C-01 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"