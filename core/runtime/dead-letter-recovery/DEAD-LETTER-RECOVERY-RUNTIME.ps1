$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "DEAD-LETTER-RECOVERY-CONFIG.json"
$QueuePath = Join-Path $StateDir "dead-letter-queue.jsonl"

function Get-DeadLetterConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Dead Letter Recovery introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function New-DeadLetterEntry {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$ConnectorId,
        [string]$FailureCode,
        [string]$FailureMessage,
        [bool]$Retryable,
        [int]$Attempt = 1
    )

    foreach ($value in @(
        $ExecutionId,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId,
        $ConnectorId,
        $FailureCode,
        $FailureMessage
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

    if ([string]::IsNullOrWhiteSpace($FailureCode)) {
        throw "FailureCode requis."
    }

    if ([string]::IsNullOrWhiteSpace($FailureMessage)) {
        throw "FailureMessage requis."
    }

    if ($Attempt -lt 1) {
        throw "Attempt invalide."
    }

    return [ordered]@{
        EntryId = [Guid]::NewGuid().ToString()
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        ConnectorId = $ConnectorId
        FailureCode = $FailureCode
        FailureMessage = $FailureMessage
        Retryable = $Retryable
        Attempt = $Attempt
        Status = "PENDING"
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        ReplayedAtUtc = $null
        ResolvedAtUtc = $null
    }
}

function Get-DeadLetterEntries {

    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [ValidateSet("PENDING","REPLAYED","RESOLVED")]
        [string]$Status
    )

    if (-not (Test-Path -LiteralPath $QueuePath)) {
        return @()
    }

    $result = @()

    foreach ($row in Get-Content -LiteralPath $QueuePath -Encoding UTF8) {

        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        try {
            $entry = $row | ConvertFrom-Json
        }
        catch {
            continue
        }

        if ($TenantId -and $entry.TenantId -ne $TenantId) { continue }
        if ($ClientId -and $entry.ClientId -ne $ClientId) { continue }
        if ($ProjectId -and $entry.ProjectId -ne $ProjectId) { continue }
        if ($WorkerId -and $entry.WorkerId -ne $WorkerId) { continue }
        if ($Status -and $entry.Status -ne $Status) { continue }

        $result += $entry
    }

    return @($result)
}

function Add-DeadLetterEntry {

    param(
        [hashtable]$Entry
    )

    $config = Get-DeadLetterConfig

    if (-not $config.enabled -or -not $config.deadLetterEnabled) {
        throw "Dead Letter Queue desactivee."
    }

    if (-not $Entry) {
        throw "Entry requis."
    }

    $count = @(Get-DeadLetterEntries).Count

    if ($count -ge [int]$config.maxQueueEntries) {
        throw "Capacite maximale DLQ atteinte."
    }

    $serialized = $Entry | ConvertTo-Json -Compress

    if (
        $serialized -match '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
    ) {
        throw "Donnee sensible detectee."
    }

    if (
        $config.captureSecrets -or
        $config.capturePayloads
    ) {
        throw "Capture sensible interdite."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $serialized |
        Add-Content `
            -LiteralPath $QueuePath `
            -Encoding UTF8

    return $true
}

function Get-RecoveryDecision {

    param(
        [hashtable]$Entry
    )

    if (-not $Entry) {
        throw "Entry requis."
    }

    $config = Get-DeadLetterConfig

    if (-not $config.recoveryEnabled) {

        return [pscustomobject]@{
            Action = "BLOCK"
            Reason = "Recovery desactive."
        }
    }

    if (-not [bool]$Entry.Retryable) {

        return [pscustomobject]@{
            Action = "DLQ"
            Reason = "Erreur non retryable."
        }
    }

    if ([int]$Entry.Attempt -ge [int]$config.maxReplayAttempts) {

        return [pscustomobject]@{
            Action = "DLQ"
            Reason = "Maximum de tentatives atteint."
        }
    }

    return [pscustomobject]@{
        Action = "REPLAY"
        Reason = "Erreur retryable et tentatives disponibles."
    }
}

function Replay-DeadLetterEntry {

    param(
        [string]$EntryId
    )

    $config = Get-DeadLetterConfig

    if (-not $config.enabled -or -not $config.replayEnabled) {
        throw "Replay desactive."
    }

    if ([string]::IsNullOrWhiteSpace($EntryId)) {
        throw "EntryId requis."
    }

    if (-not (Test-Path -LiteralPath $QueuePath)) {
        return $null
    }

    $rows = @(Get-Content -LiteralPath $QueuePath -Encoding UTF8)

    $output = @()
    $found = $false
    $result = $null

    foreach ($row in $rows) {

        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        try {
            $entry = $row | ConvertFrom-Json
        }
        catch {
            $output += $row
            continue
        }

        if ($entry.EntryId -eq $EntryId -and $entry.Status -eq "PENDING") {

            if (-not [bool]$entry.Retryable) {
                throw "Entrée non retryable."
            }

            if ([int]$entry.Attempt -ge [int]$config.maxReplayAttempts) {
                throw "Nombre maximal de replay atteint."
            }

            $entry.Attempt = [int]$entry.Attempt + 1
            $entry.Status = "REPLAYED"
            $entry.ReplayedAtUtc = (Get-Date).ToUniversalTime().ToString("o")

            $found = $true
            $result = [pscustomobject]$entry
        }

        $output += ($entry | ConvertTo-Json -Compress)
    }

    if ($found) {

        [System.IO.File]::WriteAllLines(
            $QueuePath,
            $output,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    return $result
}

function Resolve-DeadLetterEntry {

    param(
        [string]$EntryId
    )

    if ([string]::IsNullOrWhiteSpace($EntryId)) {
        throw "EntryId requis."
    }

    if (-not (Test-Path -LiteralPath $QueuePath)) {
        return $false
    }

    $rows = @(Get-Content -LiteralPath $QueuePath -Encoding UTF8)

    $output = @()
    $changed = $false

    foreach ($row in $rows) {

        if ([string]::IsNullOrWhiteSpace($row)) {
            continue
        }

        try {
            $entry = $row | ConvertFrom-Json
        }
        catch {
            $output += $row
            continue
        }

        if (
            $entry.EntryId -eq $EntryId -and
            $entry.Status -in @("PENDING","REPLAYED")
        ) {

            $entry.Status = "RESOLVED"
            $entry.ResolvedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            $changed = $true
        }

        $output += ($entry | ConvertTo-Json -Compress)
    }

    if ($changed) {

        [System.IO.File]::WriteAllLines(
            $QueuePath,
            $output,
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    return $changed
}

function Reset-DeadLetterState {

    if (Test-Path -LiteralPath $QueuePath) {
        Remove-Item -LiteralPath $QueuePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}