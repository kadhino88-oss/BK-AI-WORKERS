function Get-RetentionAccessAuditConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-RetentionAccessAuditField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RetentionAccessAuditConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RetentionAccessAuditRecords {
    $path = Join-Path $PSScriptRoot "state\decision-records.json"

    if (-not (Test-Path $path)) {
        return @()
    }

    $raw = Get-Content -Raw -Path $path

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json

    if ($null -eq $parsed) {
        return @()
    }

    $result = @()

    foreach ($item in @($parsed)) {
        $result += ,$item
    }

    return $result
}

function Save-RetentionAccessAuditRecords {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\decision-records.json"

    $normalized = @()

    foreach ($item in @($Records)) {
        $normalized += ,$item
    }

    $json = ConvertTo-Json `
        -InputObject $normalized `
        -Depth 100

    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.Encoding]::UTF8
    )

    return $true
}

function Get-RetentionAccessAuditRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DecisionId
    )

    if ([string]::IsNullOrWhiteSpace($DecisionId)) {
        return $null
    }

    $records = @(Get-RetentionAccessAuditRecords)

    foreach ($record in $records) {
        if ([string]$record.DecisionId -eq $DecisionId) {
            return $record
        }
    }

    return $null
}

function Test-RetentionAccessDecisionContext {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DecisionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Operation,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Decision
    )

    $cfg = Get-RetentionAccessAuditConfig

    if (-not $cfg.enabled -or -not $cfg.accessAuditEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "ACCESS_AUDIT_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($DecisionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DECISION_ID_REQUIRED"
        }
    }

    if ($cfg.requireRetentionId -and
        [string]::IsNullOrWhiteSpace($RetentionId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RETENTION_ID_REQUIRED"
        }
    }

    if ($cfg.requireTenantId -and
        [string]::IsNullOrWhiteSpace($TenantId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_ID_REQUIRED"
        }
    }

    if ($cfg.requireClientId -and
        [string]::IsNullOrWhiteSpace($ClientId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLIENT_ID_REQUIRED"
        }
    }

    if ($cfg.requireProjectId -and
        [string]::IsNullOrWhiteSpace($ProjectId)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "PROJECT_ID_REQUIRED"
        }
    }

    if ($cfg.requireOperation -and
        [string]::IsNullOrWhiteSpace($Operation)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "OPERATION_REQUIRED"
        }
    }

    if ($cfg.requireDecision -and
        [string]::IsNullOrWhiteSpace($Decision)) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DECISION_REQUIRED"
        }
    }

    $allowedOperations = @(
        "READ",
        "MUTATE",
        "DELETE",
        "AUDIT"
    )

    $operationValid = $false

    foreach ($value in $allowedOperations) {
        if ($value -eq $Operation) {
            $operationValid = $true
            break
        }
    }

    if (-not $operationValid) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "OPERATION_INVALID"
        }
    }

    $allowedDecisions = @(
        "ALLOW",
        "BLOCK"
    )

    $decisionValid = $false

    foreach ($value in $allowedDecisions) {
        if ($value -eq $Decision) {
            $decisionValid = $true
            break
        }
    }

    if (-not $decisionValid) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DECISION_INVALID"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "VALID"
        Reason  = "ACCESS_DECISION_CONTEXT_VALID"
    }
}

function Register-RetentionAccessDecision {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DecisionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RetentionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Operation,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Decision
    )

    $check = Test-RetentionAccessDecisionContext `
        -DecisionId $DecisionId `
        -RetentionId $RetentionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -Operation $Operation `
        -Decision $Decision

    if (-not $check.Success) {
        return $check
    }

    $records = @(Get-RetentionAccessAuditRecords)

    foreach ($existing in $records) {

        if ([string]$existing.DecisionId -eq $DecisionId) {

            return [pscustomobject]@{
                Success = $false
                Status  = "DUPLICATE"
                Reason  = "DECISION_ID_ALREADY_EXISTS"
                DecisionId = $DecisionId
            }
        }

        if ([string]$existing.RetentionId -eq $RetentionId -and
            [string]$existing.TenantId -eq $TenantId -and
            [string]$existing.ClientId -eq $ClientId -and
            [string]$existing.ProjectId -eq $ProjectId -and
            [string]$existing.Operation -eq $Operation) {

            if ($cfg.allowDuplicateDecision -eq $false) {

                if ($cfg.preventContradictoryDecision -and
                    [string]$existing.Decision -ne $Decision) {

                    return [pscustomobject]@{
                        Success = $false
                        Status  = "BLOCKED"
                        Reason  = "CONTRADICTORY_DECISION_BLOCKED"
                    }
                }

                return [pscustomobject]@{
                    Success = $false
                    Status  = "DUPLICATE"
                    Reason  = "ACCESS_DECISION_ALREADY_EXISTS"
                    DecisionId = $existing.DecisionId
                }
            }
        }
    }

    $cfg = Get-RetentionAccessAuditConfig

    if (@($records).Length -ge [int]$cfg.maxRecords) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DECISION_RECORD_LIMIT_REACHED"
        }
    }

    $record = [pscustomobject]@{
        DecisionId  = $DecisionId
        RetentionId = $RetentionId
        TenantId    = $TenantId
        ClientId    = $ClientId
        ProjectId   = $ProjectId
        Operation   = $Operation
        Decision    = $Decision
        Status      = "RECORDED"
        CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $records += ,$record

    $null = Save-RetentionAccessAuditRecords $records

    return [pscustomobject]@{
        Success    = $true
        Status     = "RECORDED"
        Reason     = "ACCESS_DECISION_RECORDED"
        DecisionId = $DecisionId
        Decision   = $Decision
    }
}

function Test-RetentionAccessDecisionTrace {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DecisionId
    )

    if ([string]::IsNullOrWhiteSpace($DecisionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DECISION_ID_REQUIRED"
        }
    }

    $record = Get-RetentionAccessAuditRecord `
        -DecisionId $DecisionId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DECISION_NOT_FOUND"
        }
    }

    if ([string]$record.Status -ne "RECORDED") {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "DECISION_STATUS_INVALID"
        }
    }

    return [pscustomobject]@{
        Success    = $true
        Status     = "VALID"
        Reason     = "DECISION_TRACE_VALID"
        DecisionId = $record.DecisionId
        Decision   = $record.Decision
    }
}

function Reset-RetentionAccessAudit {
    $null = Save-RetentionAccessAuditRecords @()
    return $true
}