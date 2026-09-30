function Get-ResultAuditConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Result Audit Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Result Audit Config invalide."
    }
}

function Remove-SensitiveProperties {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {

        $result = [ordered]@{}

        foreach ($key in $InputObject.Keys) {

            $keyName = [string]$key

            if (
                $keyName -match '(?i)(api.?key|access.?token|refresh.?token|client.?secret|password|passwd|private.?key|bearer|secret)'
            ) {
                continue
            }

            $result[$keyName] = Remove-SensitiveProperties `
                -InputObject $InputObject[$key]
        }

        return [pscustomobject]$result
    }

    if ($InputObject -is [pscustomobject]) {

        $result = [ordered]@{}

        foreach ($property in $InputObject.PSObject.Properties) {

            $keyName = [string]$property.Name

            if (
                $keyName -match '(?i)(api.?key|access.?token|refresh.?token|client.?secret|password|passwd|private.?key|bearer|secret)'
            ) {
                continue
            }

            $result[$keyName] = Remove-SensitiveProperties `
                -InputObject $property.Value
        }

        return [pscustomobject]$result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and
        $InputObject -isnot [string]) {

        $list = @()

        foreach ($item in $InputObject) {
            $list += Remove-SensitiveProperties `
                -InputObject $item
        }

        return $list
    }

    return $InputObject
}

function Normalize-ExecutionResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [AllowEmptyString()]
        [string]$ExecutionId,

        [AllowEmptyString()]
        [string]$CorrelationId,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$WorkerId,

        [AllowEmptyString()]
        [string]$SkillId,

        [AllowEmptyString()]
        [string]$TaskId,

        [AllowEmptyString()]
        [string]$ToolId,

        [AllowEmptyString()]
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$AdapterId,

        [AllowEmptyString()]
        [string]$Action,

        [AllowEmptyString()]
        [string]$Mode,

        [AllowEmptyString()]
        [string]$Status,

        [AllowEmptyString()]
        [string]$Reason = "",

        [AllowEmptyString()]
        [string]$FailedStage = "",

        [AllowEmptyString()]
        [string]$Provider = "",

        [AllowEmptyString()]
        [string]$Operation = "",

        [int]$Attempt = 1,

        [int]$DurationMs = 0,

        [bool]$ExternalCallPerformed = $false,

        [bool]$SecretExposure = $false,

        [object]$Data = $null
    )

    $config = Get-ResultAuditConfig `
        -ConfigPath $ConfigPath

    if ($config.enabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RESULT_NORMALIZER_DISABLED"
        }
    }

    # --------------------------------------------------------
    # Contexte minimal
    # --------------------------------------------------------

    $required = @{
        ExecutionId = $ExecutionId
        CorrelationId = $CorrelationId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        SkillId = $SkillId
        TaskId = $TaskId
    }

    foreach ($field in $required.Keys) {

        if ([string]::IsNullOrWhiteSpace([string]$required[$field])) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = $field
            }
        }
    }

    # --------------------------------------------------------
    # Statut
    # --------------------------------------------------------

    $allowedStatuses = @(
        "SUCCESS",
        "SIMULATED",
        "AUTHORIZED",
        "BLOCKED",
        "NEEDS_HUMAN",
        "FAILED"
    )

    if ($allowedStatuses -notcontains $Status) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_RESULT_STATUS"
        }
    }

    if ($Attempt -lt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_ATTEMPT"
        }
    }

    if ($DurationMs -lt 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_DURATION"
        }
    }

    # --------------------------------------------------------
    # LIVE
    # --------------------------------------------------------

    if (
        $Mode -eq "LIVE" -and
        $config.liveExecutionEnabled -ne $true
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LIVE_EXECUTION_DISABLED"
        }
    }

    # --------------------------------------------------------
    # Secret protection
    # --------------------------------------------------------

    if ($SecretExposure -eq $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SECRET_EXPOSURE_DETECTED"
        }
    }

    $safeData = Remove-SensitiveProperties `
        -InputObject $Data

    # --------------------------------------------------------
    # Normalized Result
    # --------------------------------------------------------

    return [pscustomobject]@{
        resultVersion = "1.0"

        status = $Status
        reason = $Reason
        failedStage = $FailedStage

        executionId = $ExecutionId
        correlationId = $CorrelationId

        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId

        workerId = $WorkerId
        skillId = $SkillId
        taskId = $TaskId
        toolId = $ToolId

        connectorId = $ConnectorId
        adapterId = $AdapterId

        provider = $Provider
        action = $Action
        operation = $Operation
        mode = $Mode

        attempt = $Attempt
        durationMs = $DurationMs

        externalCallPerformed = $ExternalCallPerformed

        secretExposure = $false
        data = $safeData

        normalizedAtUtc = [DateTime]::UtcNow.ToString("o")
    }
}

function Write-AuditLedgerEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuditPath,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$NormalizedResult
    )

    if ($null -eq $NormalizedResult) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RESULT_REQUIRED"
        }
    }

    $safeResult = Remove-SensitiveProperties `
        -InputObject $NormalizedResult

    $auditObject = [pscustomobject]@{
        auditVersion = "1.0"
        auditId = "AUDIT-$([guid]::NewGuid().ToString())"
        recordedAtUtc = [DateTime]::UtcNow.ToString("o")
        result = $safeResult
    }

    $json = $auditObject |
        ConvertTo-Json -Depth 30 -Compress

    Add-Content `
        -LiteralPath $AuditPath `
        -Value $json `
        -Encoding UTF8

    return [pscustomobject]@{
        status = "RECORDED"
        auditId = $auditObject.auditId
        auditPath = $AuditPath
        secretExposure = $false
        appendOnly = $true
    }
}

function Test-AuditLedgerForSecrets {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuditPath
    )

    if (-not (Test-Path -LiteralPath $AuditPath)) {
        return [pscustomobject]@{
            status = "EMPTY"
            secretExposure = $false
        }
    }

    $content = Get-Content `
        -LiteralPath $AuditPath `
        -Raw `
        -Encoding UTF8

    $forbiddenPatterns = @(
        '"api_key"\s*:',
        '"apikey"\s*:',
        '"access_token"\s*:',
        '"refresh_token"\s*:',
        '"client_secret"\s*:',
        '"password"\s*:',
        '"private_key"\s*:',
        '"bearer"\s*:'
    )

    foreach ($pattern in $forbiddenPatterns) {

        if ($content -match $pattern) {

            return [pscustomobject]@{
                status = "FAIL"
                secretExposure = $true
                pattern = $pattern
            }
        }
    }

    return [pscustomobject]@{
        status = "VALID"
        secretExposure = $false
    }
}