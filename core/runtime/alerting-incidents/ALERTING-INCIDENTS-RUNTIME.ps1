$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "ALERTING-INCIDENTS-CONFIG.json"
$AlertsPath = Join-Path $StateDir "alerts.jsonl"

function Get-AlertingConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Alerting introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function New-Alert {

    param(
        [string]$Type,
        [ValidateSet("INFO","WARNING","CRITICAL")]
        [string]$Severity,
        [string]$Message,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$Source
    )

    if ([string]::IsNullOrWhiteSpace($Type)) {
        throw "Type requis."
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw "Message requis."
    }

    foreach ($value in @(
        $Type,
        $Message,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId,
        $Source
    )) {

        if ($value -and $value -match '[\r\n]') {
            throw "Valeur invalide."
        }
    }

    return [ordered]@{
        AlertId = [Guid]::NewGuid().ToString()
        IncidentId = $null
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Status = "OPEN"
        Type = $Type
        Severity = $Severity
        Message = $Message
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        Source = $Source
    }
}

function Get-AlertFingerprint {

    param(
        [hashtable]$Alert
    )

    $value = @(
        $Alert.Type
        $Alert.Severity
        $Alert.TenantId
        $Alert.ClientId
        $Alert.ProjectId
        $Alert.WorkerId
        $Alert.Source
    ) -join "|"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)

    return ([System.BitConverter]::ToString($hash)).Replace("-","").ToLowerInvariant()
}

function Test-AlertDeduplication {

    param(
        [hashtable]$Alert
    )

    $config = Get-AlertingConfig

    if (-not $config.deduplicationEnabled) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $AlertsPath)) {
        return $false
    }

    $fingerprint = Get-AlertFingerprint -Alert $Alert
    $now = (Get-Date).ToUniversalTime()

    $rows = Get-Content -LiteralPath $AlertsPath -Encoding UTF8

    foreach ($row in $rows) {

        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        try {
            $existing = $row | ConvertFrom-Json
        }
        catch {
            continue
        }

        if (-not $existing.Fingerprint) {
            continue
        }

        if ($existing.Fingerprint -ne $fingerprint) {
            continue
        }

        if ($existing.Status -ne "OPEN") {
            continue
        }

        try {
            $created = [DateTime]::Parse($existing.CreatedAtUtc)
            $age = ($now - $created).TotalSeconds

            if ($age -lt [double]$config.cooldownSeconds) {
                return $true
            }
        }
        catch {
            continue
        }
    }

    return $false
}

function Write-Alert {

    param(
        [hashtable]$Alert
    )

    $config = Get-AlertingConfig

    if (-not $config.enabled -or -not $config.alertingEnabled) {
        throw "Alerting desactive."
    }

    if (-not $Alert) {
        throw "Alert requis."
    }

    $json = $Alert | ConvertTo-Json -Compress

    if ($json -match '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)') {
        throw "Donnee sensible detectee."
    }

    if (
        $config.captureSecrets -or
        $config.capturePayloads
    ) {
        throw "Capture sensible interdite."
    }

    $fingerprint = Get-AlertFingerprint -Alert $Alert
    $Alert["Fingerprint"] = $fingerprint

    if (Test-AlertDeduplication -Alert $Alert) {
        return [pscustomobject]@{
            Written = $false
            Deduplicated = $true
            Alert = $Alert
        }
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Alert |
        ConvertTo-Json -Compress |
        Add-Content `
            -LiteralPath $AlertsPath `
            -Encoding UTF8

    return [pscustomobject]@{
        Written = $true
        Deduplicated = $false
        Alert = $Alert
    }
}

function Get-Alerts {

    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [ValidateSet("OPEN","CLOSED")]
        [string]$Status,
        [ValidateSet("INFO","WARNING","CRITICAL")]
        [string]$Severity
    )

    if (-not (Test-Path -LiteralPath $AlertsPath)) {
        return @()
    }

    $result = @()

    foreach ($row in Get-Content -LiteralPath $AlertsPath -Encoding UTF8) {

        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        try {
            $alert = $row | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($TenantId -and $alert.TenantId -ne $TenantId) { continue }
        if ($ClientId -and $alert.ClientId -ne $ClientId) { continue }
        if ($ProjectId -and $alert.ProjectId -ne $ProjectId) { continue }
        if ($Status -and $alert.Status -ne $Status) { continue }
        if ($Severity -and $alert.Severity -ne $Severity) { continue }

        $result += $alert
    }

    return @($result)
}

function Open-Incident {

    param(
        [hashtable]$Alert
    )

    if (-not $Alert) {
        throw "Alert requis."
    }

    $config = Get-AlertingConfig

    $open = @(Get-Alerts -Status "OPEN")

    if ($open.Count -ge [int]$config.maxOpenIncidents) {
        throw "Nombre maximal d'incidents ouverts atteint."
    }

    if ([string]::IsNullOrWhiteSpace($Alert.IncidentId)) {
        $Alert.IncidentId = "INC-" + (
            [Guid]::NewGuid().ToString().Substring(0,8).ToUpperInvariant()
        )
    }

    $Alert.Status = "OPEN"

    return Write-Alert -Alert $Alert
}

function Close-Incident {

    param(
        [string]$IncidentId
    )

    if ([string]::IsNullOrWhiteSpace($IncidentId)) {
        throw "IncidentId requis."
    }

    if (-not (Test-Path -LiteralPath $AlertsPath)) {
        return $false
    }

    $rows = @(Get-Content -LiteralPath $AlertsPath -Encoding UTF8)

    $changed = $false
    $output = @()

    foreach ($row in $rows) {

        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        try {
            $alert = $row | ConvertFrom-Json
        }
        catch {
            $output += $row
            continue
        }

        if (
            $alert.IncidentId -eq $IncidentId -and
            $alert.Status -eq "OPEN"
        ) {
            $alert.Status = "CLOSED"

            if ($alert.PSObject.Properties.Name -contains "ClosedAtUtc") {
                $alert.ClosedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            }
            else {
                $alert.PSObject.Properties.Add(
                    [System.Management.Automation.PSNoteProperty]::new(
                        "ClosedAtUtc",
                        (Get-Date).ToUniversalTime().ToString("o")
                    )
                )
            }

            $changed = $true
        }

        $output += ($alert | ConvertTo-Json -Compress)
    }

    if ($changed) {

        [System.IO.File]::WriteAllLines(
            $AlertsPath,
            $output,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    return $changed
}

function Test-IncidentThreshold {

    param(
        [int]$ErrorCount = 0,
        [int]$BlockedCount = 0,
        [double]$LatencyMs = 0
    )

    $config = Get-AlertingConfig

    $results = @()

    if ($ErrorCount -ge [int]$config.thresholds.errorCount) {
        $results += [pscustomobject]@{
            Triggered = $true
            Type = "ERROR_THRESHOLD"
            Severity = "CRITICAL"
            Value = $ErrorCount
            Threshold = [int]$config.thresholds.errorCount
        }
    }

    if ($BlockedCount -ge [int]$config.thresholds.blockedCount) {
        $results += [pscustomobject]@{
            Triggered = $true
            Type = "BLOCKED_THRESHOLD"
            Severity = "WARNING"
            Value = $BlockedCount
            Threshold = [int]$config.thresholds.blockedCount
        }
    }

    if ($LatencyMs -ge [double]$config.thresholds.latencyMs) {
        $results += [pscustomobject]@{
            Triggered = $true
            Type = "LATENCY_THRESHOLD"
            Severity = "WARNING"
            Value = $LatencyMs
            Threshold = [double]$config.thresholds.latencyMs
        }
    }

    if ($results.Count -eq 0) {

        $results += [pscustomobject]@{
            Triggered = $false
            Type = "NONE"
            Severity = "INFO"
            Value = 0
            Threshold = 0
        }
    }

    return @($results)
}

function Reset-AlertState {

    if (Test-Path -LiteralPath $AlertsPath) {
        Remove-Item -LiteralPath $AlertsPath -Force
    }

    return $true
}