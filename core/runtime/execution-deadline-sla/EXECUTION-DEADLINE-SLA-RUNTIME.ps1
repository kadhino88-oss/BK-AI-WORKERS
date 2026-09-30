$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "EXECUTION-DEADLINE-SLA-CONFIG.json"
$StatePath = Join-Path $StateDir "deadlines.json"

function Get-DeadlineSlaConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Deadline/SLA introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-DeadlineMap {

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @{}
    }

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $obj = $raw | ConvertFrom-Json
    $map = @{}

    foreach ($property in $obj.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Save-DeadlineMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map Deadline requise."
    }

    $config = Get-DeadlineSlaConfig

    if ($Map.Count -gt [int]$config.maxDeadlineEntries) {
        throw "Nombre maximal d'entrées Deadline atteint."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Map |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function Get-DeadlineField {

    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {

        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Convert-ToDeadlineRecord {

    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        throw "Record Deadline requis."
    }

    $result = [ordered]@{}

    foreach ($field in @(
        "ExecutionId",
        "TenantId",
        "ClientId",
        "ProjectId",
        "WorkerId",
        "SlaSeconds",
        "WarningSeconds",
        "StartedAtUtc",
        "DeadlineAtUtc",
        "Status",
        "WarningRaised",
        "EscalatedAtUtc",
        "CompletedAtUtc"
    )) {

        $result[$field] = Get-DeadlineField `
            -InputObject $InputObject `
            -Name $field
    }

    return $result
}

function New-ExecutionDeadline {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [int]$SlaSeconds = 0
    )

    foreach ($value in @(
        $ExecutionId,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId
    )) {

        if ($value -and $value -match '[\r\n]') {
            throw "Valeur invalide."
        }
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    $config = Get-DeadlineSlaConfig

    # IMPORTANT :
    # Une valeur négative fournie explicitement est toujours invalide.
    if ($SlaSeconds -lt 0) {
        throw "SlaSeconds invalide."
    }

    # 0 = utilisation de la valeur par défaut.
    if ($SlaSeconds -eq 0) {
        $SlaSeconds = [int]$config.defaultSlaSeconds
    }

    if ($SlaSeconds -le 0) {
        throw "SlaSeconds invalide."
    }

    $warningSeconds = [math]::Floor(
        [double]$SlaSeconds *
        [double]$config.warningRatio
    )

    if ($warningSeconds -lt 1) {
        $warningSeconds = 1
    }

    $now = [DateTimeOffset]::UtcNow
    $deadline = $now.AddSeconds(
        [double]$SlaSeconds
    )

    return [ordered]@{
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        SlaSeconds = $SlaSeconds
        WarningSeconds = $warningSeconds
        StartedAtUtc = $now.ToString("o")
        DeadlineAtUtc = $deadline.ToString("o")
        Status = "ACTIVE"
        WarningRaised = $false
        EscalatedAtUtc = $null
        CompletedAtUtc = $null
    }
}
function Save-ExecutionDeadline {

    param(
        [object]$Deadline
    )

    $config = Get-DeadlineSlaConfig

    if (-not $config.enabled -or -not $config.deadlineManagerEnabled) {
        throw "Deadline Manager desactive."
    }

    if ($null -eq $Deadline) {
        throw "Deadline requise."
    }

    $record = Convert-ToDeadlineRecord `
        -InputObject $Deadline

    if ([string]::IsNullOrWhiteSpace(
        [string]$record["ExecutionId"]
    )) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace(
        [string]$record["TenantId"]
    )) {
        throw "TenantId requis."
    }

    $map = Get-DeadlineMap

    $map[$record["ExecutionId"]] = $record

    Save-DeadlineMap -Map $map | Out-Null

    return $true
}

function Get-ExecutionDeadline {

    param(
        [string]$ExecutionId,
        [AllowEmptyString()]
        [string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    $map = Get-DeadlineMap

    if (-not $map.ContainsKey($ExecutionId)) {
        return $null
    }

    $record = Convert-ToDeadlineRecord `
        -InputObject $map[$ExecutionId]

    if (
        $TenantId -and
        [string]$record["TenantId"] -ne $TenantId
    ) {
        return $null
    }

    return [pscustomobject]$record
}

function Test-DeadlineStatus {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $config = Get-DeadlineSlaConfig

    $deadline = Get-ExecutionDeadline `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $deadline) {

        return [pscustomobject]@{
            Status = "UNKNOWN"
            Warning = $false
            EscalationRequired = $false
            RemainingSeconds = 0
        }
    }

    if ([string]$deadline.Status -eq "COMPLETED") {

        return [pscustomobject]@{
            Status = "COMPLETED"
            Warning = $false
            EscalationRequired = $false
            RemainingSeconds = 0
        }
    }

    try {

        $now = [DateTimeOffset]::UtcNow

        $start = [DateTimeOffset]::Parse(
            [string]$deadline.StartedAtUtc
        )

        $deadlineAt = [DateTimeOffset]::Parse(
            [string]$deadline.DeadlineAtUtc
        )

        $remaining = (
            $deadlineAt - $now
        ).TotalSeconds

        $warning = (
            $remaining -le (
                [int]$deadline.WarningSeconds
            )
        )

        if ($remaining -le 0) {

            return [pscustomobject]@{
                Status = "EXPIRED"
                Warning = $true
                EscalationRequired = (
                    $config.escalationEnabled -eq $true
                )
                RemainingSeconds = 0
                ElapsedSeconds = (
                    $now - $start
                ).TotalSeconds
            }
        }

        if ($warning) {

            return [pscustomobject]@{
                Status = "WARNING"
                Warning = $true
                EscalationRequired = $false
                RemainingSeconds = $remaining
                ElapsedSeconds = (
                    $now - $start
                ).TotalSeconds
            }
        }

        return [pscustomobject]@{
            Status = "ON_TIME"
            Warning = $false
            EscalationRequired = $false
            RemainingSeconds = $remaining
            ElapsedSeconds = (
                $now - $start
            ).TotalSeconds
        }
    }
    catch {

        return [pscustomobject]@{
            Status = "UNKNOWN"
            Warning = $false
            EscalationRequired = $false
            RemainingSeconds = 0
        }
    }
}

function Mark-DeadlineWarning {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $deadline = Get-ExecutionDeadline `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $deadline) {
        return $false
    }

    $map = Get-DeadlineMap
    $record = Convert-ToDeadlineRecord -InputObject $deadline

    $record["WarningRaised"] = $true

    $map[$ExecutionId] = $record

    Save-DeadlineMap -Map $map | Out-Null

    return $true
}

function Escalate-Deadline {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $config = Get-DeadlineSlaConfig

    if (-not $config.escalationEnabled) {
        return $false
    }

    $deadline = Get-ExecutionDeadline `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $deadline) {
        return $false
    }

    $status = Test-DeadlineStatus `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($status.Status -ne "EXPIRED") {
        return $false
    }

    $map = Get-DeadlineMap
    $record = Convert-ToDeadlineRecord -InputObject $deadline

    if (-not [string]::IsNullOrWhiteSpace(
        [string]$record["EscalatedAtUtc"]
    )) {
        return $true
    }

    $record["EscalatedAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $map[$ExecutionId] = $record

    Save-DeadlineMap -Map $map | Out-Null

    return $true
}

function Complete-ExecutionDeadline {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $deadline = Get-ExecutionDeadline `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $deadline) {
        return $false
    }

    $map = Get-DeadlineMap
    $record = Convert-ToDeadlineRecord -InputObject $deadline

    $record["Status"] = "COMPLETED"
    $record["CompletedAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $map[$ExecutionId] = $record

    Save-DeadlineMap -Map $map | Out-Null

    return $true
}

function Set-DeadlineForTesting {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [int]$SecondsFromNow
    )

    if ($SecondsFromNow -eq 0) {
        throw "SecondsFromNow ne peut pas etre zero."
    }

    $deadline = Get-ExecutionDeadline `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $deadline) {
        return $false
    }

    $map = Get-DeadlineMap
    $record = Convert-ToDeadlineRecord -InputObject $deadline

    $record["DeadlineAtUtc"] = (
        [DateTimeOffset]::UtcNow.AddSeconds(
            $SecondsFromNow
        ).ToString("o")
    )

    $map[$ExecutionId] = $record

    Save-DeadlineMap -Map $map | Out-Null

    return $true
}

function Reset-DeadlineState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}