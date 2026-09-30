$ErrorActionPreference = "Stop"

$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/runtime/State-Lock.ps1")
$StateDir = Join-Path $Root "core/runtime/security-gate/execution-context-integrity/state"
$StateFile = Join-Path $StateDir "bindings.json"

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Get-ContextCanonical {
    param(
        [hashtable]$Context
    )

    $required = @(
        "TenantId",
        "ClientId",
        "ProjectId",
        "ExecutionId",
        "UserId"
    )

    foreach ($name in $required) {
        if (-not $Context.ContainsKey($name)) {
            throw "CONTEXT_FIELD_MISSING:$name"
        }

        if ([string]::IsNullOrWhiteSpace([string]$Context[$name])) {
            throw "CONTEXT_FIELD_EMPTY:$name"
        }
    }

    return (
        "TenantId=$($Context.TenantId)|" +
        "ClientId=$($Context.ClientId)|" +
        "ProjectId=$($Context.ProjectId)|" +
        "ExecutionId=$($Context.ExecutionId)|" +
        "UserId=$($Context.UserId)"
    )
}

function Get-ExecutionContextHash {
    param(
        [hashtable]$Context
    )

    $canonical = Get-ContextCanonical -Context $Context
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        return ([System.BitConverter]::ToString(
            $sha.ComputeHash($bytes)
        )).Replace("-","").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Read-Bindings {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $data = $raw | ConvertFrom-Json

    if ($null -eq $data.bindings) {
        return @()
    }

    return @($data.bindings)
}

function Write-Bindings {
    param(
        [array]$Bindings
    )

    $payload = @{
        schema = "BK-AI-WORKERS-EXECUTION-CONTEXT-INTEGRITY"
        version = "1.0"
        bindings = $Bindings
    }

    $json = $payload | ConvertTo-Json -Depth 8
    Write-BKStateFileAtomic -Path $StateFile -Content $json
}

function Register-ExecutionContext {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Context
    )

    $hash = Get-ExecutionContextHash -Context $Context

    # Lecture -> modification -> ecriture de bindings.json sous le verrou
    # commun : le bloc renvoie l'enregistrement (existant ou nouveau).
    return (Invoke-BKStateLocked {
        $bindings = @(Read-Bindings)

        $existing = @(
            $bindings |
            Where-Object { $_.ExecutionId -eq $Context.ExecutionId }
        )

        if ($existing.Count -gt 0) {
            if ($existing[0].ContextHash -ne $hash) {
                throw "EXECUTION_CONTEXT_MISMATCH"
            }

            return $existing[0]
        }

        $record = [pscustomobject]@{
            TenantId = $Context.TenantId
            ClientId = $Context.ClientId
            ProjectId = $Context.ProjectId
            ExecutionId = $Context.ExecutionId
            UserId = $Context.UserId
            ContextHash = $hash
            CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
            Locked = $true
        }

        $bindings += $record
        Write-Bindings -Bindings $bindings | Out-Null

        return $record
    })
}

function Test-ExecutionContext {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Context
    )

    $hash = Get-ExecutionContextHash -Context $Context
    $bindings = @(Read-Bindings)

    $existing = @(
        $bindings |
        Where-Object { $_.ExecutionId -eq $Context.ExecutionId }
    )

    if ($existing.Count -eq 0) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "EXECUTION_CONTEXT_NOT_REGISTERED"
            ExecutionId = $Context.ExecutionId
        }
    }

    if ($existing.Count -ne 1) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "EXECUTION_CONTEXT_DUPLICATE"
            ExecutionId = $Context.ExecutionId
        }
    }

    if ($existing[0].Locked -ne $true) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "EXECUTION_CONTEXT_UNLOCKED"
            ExecutionId = $Context.ExecutionId
        }
    }

    if ($existing[0].ContextHash -ne $hash) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "EXECUTION_CONTEXT_MISMATCH"
            ExecutionId = $Context.ExecutionId
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Decision = "ALLOW"
        Reason = "EXECUTION_CONTEXT_VALID"
        ExecutionId = $Context.ExecutionId
        TenantId = $Context.TenantId
        ClientId = $Context.ClientId
        ProjectId = $Context.ProjectId
        UserId = $Context.UserId
        ContextHash = $hash
    }
}

function Reset-ExecutionContexts {
    Invoke-BKStateLocked {
        Write-BKStateFileAtomic `
            -Path $StateFile `
            -Content '{"schema":"BK-AI-WORKERS-EXECUTION-CONTEXT-INTEGRITY","version":"1.0","bindings":[]}' | Out-Null
    } | Out-Null
}