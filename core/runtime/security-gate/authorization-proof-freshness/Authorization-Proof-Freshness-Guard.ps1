$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$StateDir = Join-Path $Root "core\runtime\security-gate\authorization-proof-freshness\state"

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Assert-FreshnessContext {
    param(
        [hashtable]$Context
    )

    foreach ($Name in @(
        "TenantId",
        "ClientId",
        "ProjectId",
        "ExecutionId",
        "UserId"
    )) {
        if (-not $Context.ContainsKey($Name)) {
            throw "FRESHNESS_CONTEXT_MISSING:$Name"
        }

        if ([string]::IsNullOrWhiteSpace([string]$Context[$Name])) {
            throw "FRESHNESS_CONTEXT_EMPTY:$Name"
        }
    }
}

function Get-FreshnessFile {
    param(
        [hashtable]$Context,
        [string]$Action
    )

    Assert-FreshnessContext -Context $Context

    if ([string]::IsNullOrWhiteSpace($Action)) {
        throw "FRESHNESS_ACTION_MISSING"
    }

    $Execution = [string]$Context.ExecutionId
    $SafeExecution = $Execution -replace '[^a-zA-Z0-9._-]', '_'

    $SafeAction = $Action -replace '[^a-zA-Z0-9._-]', '_'

    return Join-Path $StateDir (
        $SafeExecution + "__" + $SafeAction + ".json"
    )
}

function Get-FreshnessCanonical {
    param(
        [hashtable]$Context,
        [string]$Action,
        [string]$ProofHash,
        [datetime]$IssuedAtUtc,
        [int]$LifetimeSeconds
    )

    Assert-FreshnessContext -Context $Context

    if ([string]::IsNullOrWhiteSpace($Action)) {
        throw "FRESHNESS_ACTION_MISSING"
    }

    if ([string]::IsNullOrWhiteSpace($ProofHash)) {
        throw "FRESHNESS_PROOF_HASH_MISSING"
    }

    if ($LifetimeSeconds -le 0) {
        throw "FRESHNESS_LIFETIME_INVALID"
    }

    return (
        "TenantId=$($Context.TenantId)|" +
        "ClientId=$($Context.ClientId)|" +
        "ProjectId=$($Context.ProjectId)|" +
        "ExecutionId=$($Context.ExecutionId)|" +
        "UserId=$($Context.UserId)|" +
        "Action=$Action|" +
        "ProofHash=$ProofHash|" +
        "IssuedAtUtc=$($IssuedAtUtc.ToUniversalTime().ToString("o"))|" +
        "LifetimeSeconds=$LifetimeSeconds"
    )
}

function Get-FreshnessHash {
    param(
        [hashtable]$Context,
        [string]$Action,
        [string]$ProofHash,
        [datetime]$IssuedAtUtc,
        [int]$LifetimeSeconds
    )

    $Canonical = Get-FreshnessCanonical `
        -Context $Context `
        -Action $Action `
        -ProofHash $ProofHash `
        -IssuedAtUtc $IssuedAtUtc `
        -LifetimeSeconds $LifetimeSeconds

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Canonical)
    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        return (
            [System.BitConverter]::ToString(
                $Sha.ComputeHash($Bytes)
            )
        ).Replace("-","").ToLowerInvariant()
    }
    finally {
        $Sha.Dispose()
    }
}

function Write-FreshnessRecord {
    param(
        [string]$File,
        [object]$Record
    )

    $Json = $Record | ConvertTo-Json -Depth 10

    [System.IO.File]::WriteAllText(
        $File,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Read-FreshnessRecord {
    param(
        [string]$File
    )

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        return $null
    }

    $Raw = Get-Content `
        -LiteralPath $File `
        -Raw `
        -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return $null
    }

    return ($Raw | ConvertFrom-Json)
}

function Register-ProofFreshness {
    param(
        [hashtable]$Context,
        [string]$Action,
        [string]$ProofHash,
        [datetime]$IssuedAtUtc = ([DateTime]::UtcNow),
        [int]$LifetimeSeconds = 300
    )

    if ($LifetimeSeconds -le 0) {
        throw "FRESHNESS_LIFETIME_INVALID"
    }

    $File = Get-FreshnessFile `
        -Context $Context `
        -Action $Action

    $Issued = $IssuedAtUtc.ToUniversalTime()

    $Hash = Get-FreshnessHash `
        -Context $Context `
        -Action $Action `
        -ProofHash $ProofHash `
        -IssuedAtUtc $Issued `
        -LifetimeSeconds $LifetimeSeconds

    $Existing = Read-FreshnessRecord -File $File

    if ($null -ne $Existing) {

        if ([string]$Existing.FreshnessHash -ne [string]$Hash) {
            throw "FRESHNESS_REPLAY_MISMATCH"
        }

        return $Existing
    }

    $Record = [ordered]@{
        Schema          = "BK-AI-WORKERS-AUTHORIZATION-PROOF-FRESHNESS"
        Version         = "1.0"
        TenantId        = [string]$Context.TenantId
        ClientId        = [string]$Context.ClientId
        ProjectId       = [string]$Context.ProjectId
        ExecutionId     = [string]$Context.ExecutionId
        UserId          = [string]$Context.UserId
        Action          = [string]$Action
        ProofHash       = [string]$ProofHash
        FreshnessHash   = [string]$Hash
        IssuedAtUtc     = $Issued.ToString("o")
        ExpiresAtUtc    = $Issued.AddSeconds($LifetimeSeconds).ToString("o")
        LifetimeSeconds = [int]$LifetimeSeconds
        Consumed        = $false
        Locked          = $true
    }

    Write-FreshnessRecord `
        -File $File `
        -Record $Record

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "FRESHNESS_WRITE_FAILED"
    }

    return (Read-FreshnessRecord -File $File)
}

function Test-ProofFreshness {
    param(
        [hashtable]$Context,
        [string]$Action,
        [string]$ProofHash,
        [datetime]$NowUtc = ([DateTime]::UtcNow)
    )

    $File = Get-FreshnessFile `
        -Context $Context `
        -Action $Action

    $Record = Read-FreshnessRecord -File $File

    if ($null -eq $Record) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "FRESHNESS_NOT_FOUND"
        }
    }

    if ($Record.Locked -ne $true) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "FRESHNESS_UNLOCKED"
        }
    }

    if ([string]$Record.TenantId -ne [string]$Context.TenantId -or
        [string]$Record.ClientId -ne [string]$Context.ClientId -or
        [string]$Record.ProjectId -ne [string]$Context.ProjectId -or
        [string]$Record.ExecutionId -ne [string]$Context.ExecutionId -or
        [string]$Record.UserId -ne [string]$Context.UserId) {

        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "FRESHNESS_CONTEXT_MISMATCH"
        }
    }

    if ([string]$Record.ProofHash -ne [string]$ProofHash) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "FRESHNESS_PROOF_MISMATCH"
        }
    }

    $Issued = [DateTime]::Parse(
        [string]$Record.IssuedAtUtc
    ).ToUniversalTime()

    $Expires = [DateTime]::Parse(
        [string]$Record.ExpiresAtUtc
    ).ToUniversalTime()

    $ExpectedHash = Get-FreshnessHash `
        -Context @{
            TenantId = [string]$Record.TenantId
            ClientId = [string]$Record.ClientId
            ProjectId = [string]$Record.ProjectId
            ExecutionId = [string]$Record.ExecutionId
            UserId = [string]$Record.UserId
        } `
        -Action ([string]$Record.Action) `
        -ProofHash ([string]$Record.ProofHash) `
        -IssuedAtUtc $Issued `
        -LifetimeSeconds ([int]$Record.LifetimeSeconds)

    if ([string]$Record.FreshnessHash -ne [string]$ExpectedHash) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "FRESHNESS_HASH_MISMATCH"
        }
    }

    if ($Record.Consumed -eq $true) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_REPLAY_BLOCKED"
        }
    }

    $Now = $NowUtc.ToUniversalTime()

    if ($Now -lt $Issued) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_PROOF_NOT_YET_VALID"
        }
    }

    if ($Now -ge $Expires) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_PROOF_EXPIRED"
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Decision = "ALLOW"
        Reason = "AUTHORIZATION_PROOF_FRESH"
        TenantId = $Record.TenantId
        ClientId = $Record.ClientId
        ProjectId = $Record.ProjectId
        ExecutionId = $Record.ExecutionId
        UserId = $Record.UserId
        Action = $Record.Action
        ProofHash = $Record.ProofHash
        FreshnessHash = $Record.FreshnessHash
        ExpiresAtUtc = $Record.ExpiresAtUtc
    }
}

function Consume-ProofFreshness {
    param(
        [hashtable]$Context,
        [string]$Action
    )

    $File = Get-FreshnessFile `
        -Context $Context `
        -Action $Action

    $Record = Read-FreshnessRecord -File $File

    if ($null -eq $Record) {
        throw "FRESHNESS_NOT_FOUND"
    }

    if ($Record.Consumed -eq $true) {
        throw "AUTHORIZATION_REPLAY_BLOCKED"
    }

    if ($Record.Locked -ne $true) {
        throw "FRESHNESS_UNLOCKED"
    }

    $Record.Consumed = $true

    Write-FreshnessRecord `
        -File $File `
        -Record $Record
}

function Reset-ProofFreshness {
    if (Test-Path -LiteralPath $StateDir -PathType Container) {
        Get-ChildItem `
            -LiteralPath $StateDir `
            -File `
            -Filter "*.json" |
            Remove-Item -Force
    }
}