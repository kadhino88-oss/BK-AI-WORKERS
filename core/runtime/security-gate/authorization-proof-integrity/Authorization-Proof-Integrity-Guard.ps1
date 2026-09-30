$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$StateDir = Join-Path $Root "core\runtime\security-gate\authorization-proof-integrity\state"
$StateFile = Join-Path $StateDir "authorization-proofs.json"

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null

function Get-ProofCanonical {
    param(
        [hashtable]$Context,
        [string]$Decision,
        [string]$Action
    )

    foreach ($name in @(
        "TenantId","ClientId","ProjectId","ExecutionId","UserId"
    )) {
        if (-not $Context.ContainsKey($name) -or
            [string]::IsNullOrWhiteSpace([string]$Context[$name])) {
            throw "AUTH_PROOF_CONTEXT_MISSING:$name"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Decision)) {
        throw "AUTH_PROOF_DECISION_MISSING"
    }

    if ([string]::IsNullOrWhiteSpace($Action)) {
        throw "AUTH_PROOF_ACTION_MISSING"
    }

    return (
        "TenantId=$($Context.TenantId)|" +
        "ClientId=$($Context.ClientId)|" +
        "ProjectId=$($Context.ProjectId)|" +
        "ExecutionId=$($Context.ExecutionId)|" +
        "UserId=$($Context.UserId)|" +
        "Decision=$Decision|" +
        "Action=$Action"
    )
}

function Get-AuthorizationProofHash {
    param(
        [hashtable]$Context,
        [string]$Decision,
        [string]$Action
    )

    $canonical = Get-ProofCanonical `
        -Context $Context `
        -Decision $Decision `
        -Action $Action

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($canonical)
        return ([System.BitConverter]::ToString(
            $sha.ComputeHash($bytes)
        )).Replace("-","").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Read-AuthorizationProofs {
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $data = $raw | ConvertFrom-Json

    if ($null -eq $data.proofs) {
        return @()
    }

    return @($data.proofs)
}

function Write-AuthorizationProofs {
    param(
        [array]$Proofs
    )

    $payload = @{
        schema = "BK-AI-WORKERS-AUTHORIZATION-PROOF-INTEGRITY"
        version = "1.0"
        proofs = $Proofs
    }

    [System.IO.File]::WriteAllText(
        $StateFile,
        ($payload | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Register-AuthorizationProof {
    param(
        [hashtable]$Context,
        [string]$Decision,
        [string]$Action
    )

    if ($Decision -ne "ALLOW") {
        throw "AUTH_PROOF_REGISTRATION_REQUIRES_ALLOW"
    }

    $hash = Get-AuthorizationProofHash `
        -Context $Context `
        -Decision $Decision `
        -Action $Action

    $proofs = @(Read-AuthorizationProofs)

    $existing = @(
        $proofs |
        Where-Object {
            $_.ExecutionId -eq $Context.ExecutionId -and
            $_.Action -eq $Action
        }
    )

    if ($existing.Count -gt 0) {
        if ($existing[0].ProofHash -ne $hash) {
            throw "AUTH_PROOF_MISMATCH"
        }

        return $existing[0]
    }

    $record = [pscustomobject]@{
        TenantId = $Context.TenantId
        ClientId = $Context.ClientId
        ProjectId = $Context.ProjectId
        ExecutionId = $Context.ExecutionId
        UserId = $Context.UserId
        Decision = "ALLOW"
        Action = $Action
        ProofHash = $hash
        Locked = $true
        CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $proofs += $record
    Write-AuthorizationProofs -Proofs $proofs

    return $record
}

function Test-AuthorizationProof {
    param(
        [hashtable]$Context,
        [string]$Decision,
        [string]$Action
    )

    $hash = Get-AuthorizationProofHash `
        -Context $Context `
        -Decision $Decision `
        -Action $Action

    $proofs = @(Read-AuthorizationProofs)

    $matches = @(
        $proofs |
        Where-Object {
            $_.ExecutionId -eq $Context.ExecutionId -and
            $_.Action -eq $Action
        }
    )

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_PROOF_NOT_FOUND"
        }
    }

    if ($matches.Count -ne 1) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_PROOF_DUPLICATE"
        }
    }

    if ($matches[0].Locked -ne $true) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_PROOF_UNLOCKED"
        }
    }

    if ($matches[0].Decision -ne "ALLOW") {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_PROOF_NOT_ALLOWED"
        }
    }

    if ($matches[0].ProofHash -ne $hash) {
        return [pscustomobject]@{
            Valid = $false
            Decision = "BLOCK"
            Reason = "AUTHORIZATION_PROOF_HASH_MISMATCH"
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Decision = "ALLOW"
        Reason = "AUTHORIZATION_PROOF_VALID"
        ProofHash = $hash
        ExecutionId = $Context.ExecutionId
        TenantId = $Context.TenantId
        ClientId = $Context.ClientId
        ProjectId = $Context.ProjectId
        UserId = $Context.UserId
        Action = $Action
    }
}

function Reset-AuthorizationProofs {
    [System.IO.File]::WriteAllText(
        $StateFile,
        '{"schema":"BK-AI-WORKERS-AUTHORIZATION-PROOF-INTEGRITY","version":"1.0","proofs":[]}',
        [System.Text.UTF8Encoding]::new($false)
    )
}