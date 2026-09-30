function Get-ExecutionQueueConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Execution Queue Config introuvable : $ConfigPath"
    }

    try {
        return (
            Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Execution Queue Config invalide."
    }
}

function Get-QueueItems {
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueDirectory
    )

    if (-not (Test-Path -LiteralPath $QueueDirectory)) {
        New-Item -ItemType Directory -Force -Path $QueueDirectory | Out-Null
    }

    $files = @(
        Get-ChildItem `
            -LiteralPath $QueueDirectory `
            -Filter "*.json" `
            -File `
            -ErrorAction SilentlyContinue
    )

    $items = @()

    foreach ($file in $files) {
        try {
            $item =
                Get-Content `
                    -LiteralPath $file.FullName `
                    -Raw `
                    -Encoding UTF8 |
                ConvertFrom-Json

            if ($null -ne $item) {
                $items += $item
            }
        }
        catch {
            # Un fichier invalide n'est jamais exécuté.
            continue
        }
    }

    return @($items)
}

function New-ExecutionQueueItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$QueueDirectory,

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
        [string]$ConnectorId,

        [AllowEmptyString()]
        [string]$Operation,

        [AllowEmptyString()]
        [string]$IdempotencyKey,

        [int]$Priority = 50,

        [ValidateSet(
            "SIMULATION",
            "CONTROLLED",
            "LIVE"
        )]
        [string]$Mode = "SIMULATION"
    )

    $config = Get-ExecutionQueueConfig `
        -ConfigPath $ConfigPath

    if ($config.enabled -ne $true -or $config.queueEnabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_DISABLED"
        }
    }

    # --------------------------------------------------------
    # Contexte
    # --------------------------------------------------------

    $required = [ordered]@{
        ExecutionId   = $ExecutionId
        CorrelationId = $CorrelationId
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        WorkerId      = $WorkerId
        SkillId       = $SkillId
        TaskId        = $TaskId
        ConnectorId   = $ConnectorId
        Operation     = $Operation
    }

    foreach ($field in $required.Keys) {

        if (
            [string]::IsNullOrWhiteSpace(
                [string]$required[$field]
            )
        ) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = $field
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($IdempotencyKey)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "IDEMPOTENCY_KEY_REQUIRED"
        }
    }

    # --------------------------------------------------------
    # Priorité
    # --------------------------------------------------------

    if ($Priority -lt [int]$config.minimumPriority) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "PRIORITY_TOO_LOW"
        }
    }

    if ($Priority -gt [int]$config.maximumPriority) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "PRIORITY_TOO_HIGH"
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
    # Taille de queue
    # --------------------------------------------------------

    $existing = @(Get-QueueItems `
        -QueueDirectory $QueueDirectory)

    $activeQueued = @(
        $existing | Where-Object {
            $_.status -eq "QUEUED"
        }
    )

    if (
        $activeQueued.Count -ge [int]$config.maxQueueSize
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_FULL"
        }
    }

    # --------------------------------------------------------
    # Doublons
    # --------------------------------------------------------

    if ($config.allowDuplicateExecutionIds -ne $true) {

        $duplicateExecution = @(
            $existing | Where-Object {
                $_.executionId -eq $ExecutionId -and
                $_.status -in @(
                    "QUEUED",
                    "RUNNING",
                    "COMPLETED"
                )
            }
        )

        if ($duplicateExecution.Count -gt 0) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "DUPLICATE_EXECUTION_ID"
                executionId = $ExecutionId
            }
        }
    }

    if ($config.allowDuplicateIdempotencyKeys -ne $true) {

        $duplicateIdempotency = @(
            $existing | Where-Object {
                $_.idempotencyKey -eq $IdempotencyKey -and
                $_.status -in @(
                    "QUEUED",
                    "RUNNING",
                    "COMPLETED"
                )
            }
        )

        if ($duplicateIdempotency.Count -gt 0) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "DUPLICATE_IDEMPOTENCY_KEY"
                idempotencyKey = $IdempotencyKey
            }
        }
    }

    # --------------------------------------------------------
    # Création
    # --------------------------------------------------------

    New-Item -ItemType Directory -Force -Path $QueueDirectory | Out-Null

    $sequence = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $queueId =
        "QUEUE-$sequence-$([guid]::NewGuid().ToString())"

    $queuedAt = [DateTime]::UtcNow.ToString("o")

    $item = [ordered]@{
        queueVersion = "1.0"

        queueId = $queueId
        status = "QUEUED"

        createdAtUtc = $queuedAt
        queuedAtUtc = $queuedAt
        startedAtUtc = $null
        completedAtUtc = $null

        executionId = $ExecutionId
        correlationId = $CorrelationId

        tenantId = $TenantId
        clientId = $ClientId
        projectId = $ProjectId

        workerId = $WorkerId
        skillId = $SkillId
        taskId = $TaskId

        connectorId = $ConnectorId
        operation = $Operation

        idempotencyKey = $IdempotencyKey

        priority = $Priority
        mode = $Mode

        secretExposure = $false
        containsSecret = $false
        externalCallPerformed = $false
    }

    $fileName = "$queueId.json"

    $filePath = Join-Path `
        $QueueDirectory `
        $fileName

    $item |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $filePath `
            -Encoding UTF8

    return [pscustomobject]@{
        status = "QUEUED"
        queueId = $queueId
        filePath = $filePath
        executionId = $ExecutionId
        priority = $Priority
        queuedAtUtc = $queuedAt
        secretExposure = $false
    }
}

function Select-NextExecution {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$QueueDirectory,

        [int]$CurrentRunningCount = 0
    )

    $config = Get-ExecutionQueueConfig `
        -ConfigPath $ConfigPath

    if ($config.schedulerEnabled -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "SCHEDULER_DISABLED"
        }
    }

    if (
        $CurrentRunningCount -ge
        [int]$config.maxConcurrentExecutions
    ) {
        return [pscustomobject]@{
            status = "WAIT"
            reason = "CONCURRENCY_LIMIT_REACHED"
        }
    }

    $items = @(
        Get-QueueItems `
            -QueueDirectory $QueueDirectory |
        Where-Object {
            $_.status -eq "QUEUED"
        }
    )

    if ($items.Count -eq 0) {
        return [pscustomobject]@{
            status = "EMPTY"
            reason = "QUEUE_EMPTY"
        }
    }

    # Priorité la plus haute.
    # À priorité identique : plus ancien en premier.
    $next = $items |
        Sort-Object `
            -Property @(
                @{ Expression = { [int]$_.priority }; Descending = $true },
                @{ Expression = { [DateTime]$_.queuedAtUtc }; Descending = $false }
            ) |
        Select-Object -First 1

    return [pscustomobject]@{
        status = "SELECTED"
        queueId = $next.queueId
        executionId = $next.executionId
        tenantId = $next.tenantId
        clientId = $next.clientId
        projectId = $next.projectId
        priority = $next.priority
        queuedAtUtc = $next.queuedAtUtc
    }
}

function Set-ExecutionQueueStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueDirectory,

        [AllowEmptyString()]
        [string]$QueueId,

        [ValidateSet(
            "QUEUED",
            "RUNNING",
            "COMPLETED",
            "FAILED",
            "CANCELLED"
        )]
        [string]$Status
    )

    if ([string]::IsNullOrWhiteSpace($QueueId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_ID_REQUIRED"
        }
    }

    $path = Join-Path `
        $QueueDirectory `
        "$QueueId.json"

    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_ITEM_NOT_FOUND"
        }
    }

    try {
        $item =
            Get-Content `
                -LiteralPath $path `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_ITEM_INVALID"
        }
    }

    $current = $item.status

    $allowed = $false

    switch ($current) {

        "QUEUED" {
            if ($Status -in @("RUNNING", "CANCELLED")) {
                $allowed = $true
            }
        }

        "RUNNING" {
            if ($Status -in @(
                "COMPLETED",
                "FAILED",
                "CANCELLED"
            )) {
                $allowed = $true
            }
        }

        default {
            $allowed = $false
        }
    }

    if (-not $allowed) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_QUEUE_TRANSITION"
            currentStatus = $current
            requestedStatus = $Status
        }
    }

    $item.status = $Status

    if ($Status -eq "RUNNING") {
        $item.startedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    if ($Status -in @(
        "COMPLETED",
        "FAILED",
        "CANCELLED"
    )) {
        $item.completedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $item |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $path `
            -Encoding UTF8

    return [pscustomobject]@{
        status = "UPDATED"
        queueId = $QueueId
        previousStatus = $current
        currentStatus = $Status
        externalCallPerformed = $false
        secretExposure = $false
    }
}

function Cancel-ExecutionQueueItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$QueueDirectory,

        [AllowEmptyString()]
        [string]$QueueId
    )

    if ([string]::IsNullOrWhiteSpace($QueueId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_ID_REQUIRED"
        }
    }

    $path = Join-Path `
        $QueueDirectory `
        "$QueueId.json"

    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_ITEM_NOT_FOUND"
        }
    }

    try {
        $item =
            Get-Content `
                -LiteralPath $path `
                -Raw `
                -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "QUEUE_ITEM_INVALID"
        }
    }

    if ($item.status -ne "QUEUED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CANCEL_ONLY_QUEUED"
            currentStatus = $item.status
        }
    }

    $item.status = "CANCELLED"
    $item.completedAtUtc = [DateTime]::UtcNow.ToString("o")

    $item |
        ConvertTo-Json -Depth 20 |
        Set-Content `
            -LiteralPath $path `
            -Encoding UTF8

    return [pscustomobject]@{
        status = "CANCELLED"
        queueId = $QueueId
        executionId = $item.executionId
        secretExposure = $false
    }
}