$ErrorActionPreference = "Stop"

$script:CertificationStateFile = Join-Path $PSScriptRoot "state\certification-state.json"

function Initialize-CertificationReadiness {

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-CERTIFICATION-READINESS"
        Version = "1.0"
        Stage = "CERTIFICATION"

        SandboxRequired = $true
        SandboxValidated = $false

        LiveExecutionAllowed = $false
        ExternalActionsAllowed = $false
        ProviderLiveAllowed = $false
        ConnectorLiveAllowed = $false
        SecretsAllowed = $false

        CertificationReady = $false
        HumanApprovalRequired = $true
        HumanApprovalGranted = $false

        Decision = "BLOCK"
        Reason = "SANDBOX_VALIDATION_REQUIRED"

        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:CertificationStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-CertificationReadinessState {

    if (-not (Test-Path -LiteralPath $script:CertificationStateFile -PathType Leaf)) {
        return Initialize-CertificationReadiness
    }

    $Raw = Get-Content -LiteralPath $script:CertificationStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "CERTIFICATION_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-CertificationReadiness {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$SandboxValidated = $false,
        [bool]$HumanApprovalGranted = $false
    )

    if ($Environment -ne "CERTIFICATION") {
        throw "CERTIFICATION_ENVIRONMENT_REQUIRED"
    }

    if ($Mode -ne "CERTIFICATION") {
        throw "CERTIFICATION_MODE_REQUIRED"
    }

    $State = Get-CertificationReadinessState

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

    if (-not $SandboxValidated) {
        throw "SANDBOX_NOT_VALIDATED"
    }

    if (-not $HumanApprovalGranted) {
        return [pscustomobject]@{
            Decision = "BLOCK"
            Authorized = $false
            CertificationReady = $false
            Environment = "CERTIFICATION"
            Mode = "CERTIFICATION"
            HumanApprovalRequired = $true
            HumanApprovalGranted = $false
            LiveExecutionAllowed = $false
            ExternalActionsAllowed = $false
            ProviderLiveAllowed = $false
            ConnectorLiveAllowed = $false
            SecretsAllowed = $false
            Reason = "HUMAN_APPROVAL_REQUIRED"
        }
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Authorized = $true
        CertificationReady = $true
        Environment = "CERTIFICATION"
        Mode = "CERTIFICATION"
        HumanApprovalRequired = $true
        HumanApprovalGranted = $true
        SandboxValidated = $true
        LiveExecutionAllowed = $false
        ExternalActionsAllowed = $false
        ProviderLiveAllowed = $false
        ConnectorLiveAllowed = $false
        SecretsAllowed = $false
        Reason = "CERTIFICATION_READY"
    }
}

function Assert-CertificationReadiness {

    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$SandboxValidated = $false,
        [bool]$HumanApprovalGranted = $false
    )

    $Result = Test-CertificationReadiness @PSBoundParameters

    if ($Result.Decision -ne "ALLOW") {
        throw "CERTIFICATION_GATE_BLOCKED:$($Result.Reason)"
    }

    return $Result
}