$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "OBSERVABILITY-METRICS-CONFIG.json"
$EventsPath = Join-Path $StateDir "metrics.jsonl"

function Get-ObservabilityConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration observability introuvable."
    }

    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-MetricIdentifier {
    param(
        [AllowEmptyString()]
        [string]$Value,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if ($Value -match '[\r\n]') {
        return $false
    }

    if ($Value.Length -gt 200) {
        return $false
    }

    return $true
}

function New-MetricEvent {
    param(
        [string]$MetricName,
        [ValidateSet("SUCCESS","ERROR","BLOCKED","INFO")]
        [string]$Status,
        [double]$DurationMs,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$Operation
    )

    $config = Get-ObservabilityConfig

    if (-not $config.enabled -or -not $config.metricsEnabled) {
        throw "Observability/Metrics desactive."
    }

    if ([string]::IsNullOrWhiteSpace($MetricName)) {
        throw "MetricName requis."
    }

    if ($MetricName.Length -gt 200) {
        throw "MetricName trop long."
    }

    if ($MetricName -match '[\r\n]') {
        throw "MetricName invalide."
    }

    if ($DurationMs -lt 0) {
        throw "DurationMs invalide."
    }

    $required = @{
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
    }

    foreach ($entry in $required.GetEnumerator()) {
        if (-not (Test-MetricIdentifier -Value $entry.Value -Name $entry.Key)) {
            throw "$($entry.Key) invalide."
        }
    }

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        throw "Operation requise."
    }

    if ($Operation.Length -gt 200 -or $Operation -match '[\r\n]') {
        throw "Operation invalide."
    }

    return [ordered]@{
        EventId = [Guid]::NewGuid().ToString()
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        MetricName = $MetricName
        Status = $Status
        DurationMs = [math]::Round($DurationMs,2)
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        Operation = $Operation
    }
}

function Write-MetricEvent {
    param(
        [hashtable]$Event
    )

    $config = Get-ObservabilityConfig

    if (-not $config.enabled -or -not $config.metricsEnabled) {
        throw "Observability/Metrics desactive."
    }

    if (-not $Event) {
        throw "Event requis."
    }

    $allowed = @(
        "EventId",
        "TimestampUtc",
        "MetricName",
        "Status",
        "DurationMs",
        "TenantId",
        "ClientId",
        "ProjectId",
        "WorkerId",
        "Operation"
    )

    foreach ($key in $Event.Keys) {
        if ($allowed -notcontains $key) {
            throw "Champ non autorise dans l'evenement: $key"
        }
    }

    $serialized = $Event | ConvertTo-Json -Compress

    if ($serialized -match '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)') {
        throw "Donnee sensible detectee dans l'evenement."
    }

    if ($config.captureSecrets -or $config.capturePrompts -or $config.capturePayloads) {
        throw "La configuration de capture sensible est interdite."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    Add-Content `
        -LiteralPath $EventsPath `
        -Value $serialized `
        -Encoding UTF8

    return $true
}

function Get-MetricEvents {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$MetricName
    )

    if (-not (Test-Path -LiteralPath $EventsPath)) {
        return @()
    }

    $rows = Get-Content -LiteralPath $EventsPath -Encoding UTF8

    $events = foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        try {
            $event = $row | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($TenantId -and $event.TenantId -ne $TenantId) { continue }
        if ($ClientId -and $event.ClientId -ne $ClientId) { continue }
        if ($ProjectId -and $event.ProjectId -ne $ProjectId) { continue }
        if ($WorkerId -and $event.WorkerId -ne $WorkerId) { continue }
        if ($MetricName -and $event.MetricName -ne $MetricName) { continue }

        $event
    }

    return @($events)
}

function Get-MetricSummary {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$MetricName
    )

    $events = @(Get-MetricEvents `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -MetricName $MetricName)

    if ($events.Count -eq 0) {
        return [pscustomobject]@{
            Count = 0
            SuccessCount = 0
            ErrorCount = 0
            BlockedCount = 0
            InfoCount = 0
            AvgDurationMs = 0
            MinDurationMs = 0
            MaxDurationMs = 0
        }
    }

    $durations = @($events | ForEach-Object { [double]$_.DurationMs })

    return [pscustomobject]@{
        Count = $events.Count
        SuccessCount = @($events | Where-Object Status -eq "SUCCESS").Count
        ErrorCount = @($events | Where-Object Status -eq "ERROR").Count
        BlockedCount = @($events | Where-Object Status -eq "BLOCKED").Count
        InfoCount = @($events | Where-Object Status -eq "INFO").Count
        AvgDurationMs = [math]::Round((($durations | Measure-Object -Average).Average),2)
        MinDurationMs = [math]::Round((($durations | Measure-Object -Minimum).Minimum),2)
        MaxDurationMs = [math]::Round((($durations | Measure-Object -Maximum).Maximum),2)
    }
}

function Reset-MetricState {
    if (Test-Path -LiteralPath $EventsPath) {
        Remove-Item -LiteralPath $EventsPath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    return $true
}