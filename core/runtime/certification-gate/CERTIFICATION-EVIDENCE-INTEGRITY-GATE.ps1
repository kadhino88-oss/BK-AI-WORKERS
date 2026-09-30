$ErrorActionPreference = "Stop"

$script:EvidenceStateFile = Join-Path $PSScriptRoot "state\certification-evidence-state.json"

function Initialize-CertificationEvidenceIntegrity {

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-CERTIFICATION-EVIDENCE-INTEGRITY"
        Version = "1.0"
        Stage = "CERTIFICATION"

        SandboxGlobalValidated = $false
        SandboxChecks = 0
        SandboxPass = 0
        SandboxFail = 0

        ReadinessValidated = $false
        CertificationEvidenceValid = $false

        LiveExecutionAllowed = $false
        ExternalActionsAllowed = $false
        ProviderLiveAllowed = $false
        ConnectorLiveAllowed = $false
        SecretsAllowed = $false

        Decision = "BLOCK"
        Reason = "CERTIFICATION_EVIDENCE_REQUIRED"

        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:EvidenceStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-CertificationEvidenceState {

    if (-not (Test-Path -LiteralPath $script:EvidenceStateFile -PathType Leaf)) {
        return Initialize-CertificationEvidenceIntegrity
    }

    $Raw = Get-Content -LiteralPath $script:EvidenceStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "CERTIFICATION_EVIDENCE_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-CertificationEvidenceIntegrity {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$SandboxGlobalValidated = $false,
        [int]$SandboxChecks = 0,
        [int]$SandboxPass = 0,
        [int]$SandboxFail = 0,
        [bool]$ReadinessValidated = $false
    )

    if ($Environment -ne "CERTIFICATION") {
        throw "CERTIFICATION_ENVIRONMENT_REQUIRED"
    }

    if ($Mode -ne "CERTIFICATION") {
        throw "CERTIFICATION_MODE_REQUIRED"
    }

    if ($SandboxChecks -lt 1) {
        throw "SANDBOX_CHECK_COUNT_REQUIRED"
    }

    if ($SandboxPass -lt 0 -or $SandboxFail -lt 0) {
        throw "SANDBOX_RESULT_VALUES_INVALID"
    }

    if ($SandboxPass -gt $SandboxChecks) {
        throw "SANDBOX_PASS_COUNT_INVALID"
    }

    if ($SandboxFail -gt $SandboxChecks) {
        throw "SANDBOX_FAIL_COUNT_INVALID"
    }

    if (($SandboxPass + $SandboxFail) -ne $SandboxChecks) {
        throw "SANDBOX_RESULT_TOTAL_INVALID"
    }

    $State = Get-CertificationEvidenceState

    if ($State.Stage -ne "CERTIFICATION") {
        throw "CERTIFICATION_STAGE_INVALID"
    }

    if ($State.LiveExecutionAllowed) {
        throw "LIVE_EXECUTION_MUST_REMAIN_DISABLED"
    }

    if ($State.ExternalActionsAllowed) {
        throw "EXTERNAL_ACTIONS_MUST_REMAIN_DISABLED"
    }

    if ($State.ProviderLiveAllowed) {
        throw "PROVIDER_LIVE_MUST_REMAIN_DISABLED"
    }

    if ($State.ConnectorLiveAllowed) {
        throw "CONNECTOR_LIVE_MUST_REMAIN_DISABLED"
    }

    if ($State.SecretsAllowed) {
        throw "SECRETS_MUST_REMAIN_DISABLED"
    }

    if (-not $SandboxGlobalValidated) {
        return [pscustomobject]@{
            Decision = "BLOCK"
            Authorized = $false
            CertificationEvidenceValid = $false
            SandboxGlobalValidated = $false
            ReadinessValidated = $ReadinessValidated
            SandboxChecks = $SandboxChecks
            SandboxPass = $SandboxPass
            SandboxFail = $SandboxFail
            Environment = "CERTIFICATION"
            Mode = "CERTIFICATION"
            LiveExecutionAllowed = $false
            ExternalActionsAllowed = $false
            ProviderLiveAllowed = $false
            ConnectorLiveAllowed = $false
            SecretsAllowed = $false
            Reason = "SANDBOX_GLOBAL_VALIDATION_REQUIRED"
        }
    }

    if ($SandboxFail -ne 0) {
        throw "SANDBOX_FAILURE_PRESENT"
    }

    if ($SandboxPass -ne $SandboxChecks) {
        throw "SANDBOX_EVIDENCE_INCOMPLETE"
    }

    if (-not $ReadinessValidated) {
        return [pscustomobject]@{
            Decision = "BLOCK"
            Authorized = $false
            CertificationEvidenceValid = $false
            SandboxGlobalValidated = $true
            ReadinessValidated = $false
            SandboxChecks = $SandboxChecks
            SandboxPass = $SandboxPass
            SandboxFail = $SandboxFail
            Environment = "CERTIFICATION"
            Mode = "CERTIFICATION"
            LiveExecutionAllowed = $false
            ExternalActionsAllowed = $false
            ProviderLiveAllowed = $false
            ConnectorLiveAllowed = $false
            SecretsAllowed = $false
            Reason = "CERTIFICATION_READINESS_VALIDATION_REQUIRED"
        }
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Authorized = $true
        CertificationEvidenceValid = $true
        SandboxGlobalValidated = $true
        ReadinessValidated = $true
        SandboxChecks = $SandboxChecks
        SandboxPass = $SandboxPass
        SandboxFail = $SandboxFail
        Environment = "CERTIFICATION"
        Mode = "CERTIFICATION"
        LiveExecutionAllowed = $false
        ExternalActionsAllowed = $false
        ProviderLiveAllowed = $false
        ConnectorLiveAllowed = $false
        SecretsAllowed = $false
        Reason = "CERTIFICATION_EVIDENCE_VALID"
    }
}

function Assert-CertificationEvidenceIntegrity {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$SandboxGlobalValidated = $false,
        [int]$SandboxChecks = 0,
        [int]$SandboxPass = 0,
        [int]$SandboxFail = 0,
        [bool]$ReadinessValidated = $false
    )

    $Result = Test-CertificationEvidenceIntegrity @PSBoundParameters

    if ($Result.Decision -ne "ALLOW") {
        throw "CERTIFICATION_EVIDENCE_GATE_BLOCKED:$($Result.Reason)"
    }

    return $Result
}