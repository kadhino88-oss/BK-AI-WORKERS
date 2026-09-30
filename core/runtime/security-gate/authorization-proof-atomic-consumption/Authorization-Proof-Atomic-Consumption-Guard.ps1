$ErrorActionPreference = "Stop"

$script:AtomicStateDir  = Join-Path $PSScriptRoot "state"
$script:AtomicStateFile = Join-Path $script:AtomicStateDir "atomic-consumption.json"

function Convert-BytesToHex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Reset-AtomicConsumption {
    New-Item -ItemType Directory -Force -Path $script:AtomicStateDir | Out-Null

    $State = [ordered]@{
        Schema  = "BK-AI-WORKERS-AUTHORIZATION-PROOF-ATOMIC-CONSUMPTION"
        Version = "1.0"
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:AtomicStateFile,
        ($State | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-AtomicState {
    if (-not (Test-Path -LiteralPath $script:AtomicStateFile -PathType Leaf)) {
        Reset-AtomicConsumption
    }

    $Raw = Get-Content -LiteralPath $script:AtomicStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "ATOMIC_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Save-AtomicState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    $TempFile = "$($script:AtomicStateFile).tmp-$([Guid]::NewGuid().ToString('N'))"

    [System.IO.File]::WriteAllText(
        $TempFile,
        ($State | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false)
    )

    Move-Item -LiteralPath $TempFile -Destination $script:AtomicStateFile -Force
}

function Get-AtomicProofKey {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][string]$ProofHash
    )

    foreach ($Item in @(
        @{ Name = "TenantId"; Value = $TenantId },
        @{ Name = "ClientId"; Value = $ClientId },
        @{ Name = "ProjectId"; Value = $ProjectId },
        @{ Name = "ExecutionId"; Value = $ExecutionId },
        @{ Name = "UserId"; Value = $UserId },
        @{ Name = "OperationName"; Value = $OperationName },
        @{ Name = "ProofHash"; Value = $ProofHash }
    )) {
        if ([string]::IsNullOrWhiteSpace($Item.Value)) {
            throw "ATOMIC_CONTEXT_MISSING:$($Item.Name)"
        }
    }

    $Canonical = "$TenantId|$ClientId|$ProjectId|$ExecutionId|$UserId|$OperationName|$ProofHash"

    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Canonical)
        $HashBytes = $Sha.ComputeHash($Bytes)
        return (Convert-BytesToHex -Bytes $HashBytes)
    }
    finally {
        $Sha.Dispose()
    }
}

function Register-AtomicProof {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][string]$ProofHash
    )

    $ProofKey = Get-AtomicProofKey @PSBoundParameters
    $State = Get-AtomicState
    $Records = @($State.Records)

    $Existing = @($Records | Where-Object {
        $_.ProofKey -eq $ProofKey
    })

    if ($Existing.Count -gt 0) {
        throw "ATOMIC_PROOF_ALREADY_REGISTERED"
    }

    $Record = [pscustomobject]@{
        ProofKey      = $ProofKey
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        ExecutionId   = $ExecutionId
        UserId        = $UserId
        OperationName = $OperationName
        ProofHash     = $ProofHash
        Consumed      = $false
        Locked        = $true
        CreatedAtUtc  = [DateTime]::UtcNow.ToString("o")
        ConsumedAtUtc = $null
    }

    $Records += $Record
    $State.Records = $Records

    Save-AtomicState -State $State

    return $Record
}

function Consume-AtomicProof {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][string]$ProofHash
    )

    $ProofKey = Get-AtomicProofKey @PSBoundParameters

    $MutexName = "Global\BKAIWORKERS_ATOMIC_$ProofKey"
    $Mutex = [System.Threading.Mutex]::new($false, $MutexName)

    $LockAcquired = $false

    try {
        $LockAcquired = $Mutex.WaitOne(10000)

        if (-not $LockAcquired) {
            throw "ATOMIC_LOCK_TIMEOUT"
        }

        $State = Get-AtomicState
        $Records = @($State.Records)

        $Record = @($Records | Where-Object {
            $_.ProofKey -eq $ProofKey
        }) | Select-Object -First 1

        if ($null -eq $Record) {
            throw "ATOMIC_PROOF_NOT_FOUND"
        }

        if ($Record.Locked -ne $true) {
            throw "ATOMIC_PROOF_NOT_LOCKED"
        }

        if ($Record.Consumed -eq $true) {
            throw "ATOMIC_REPLAY_BLOCKED"
        }

        $Record.Consumed = $true
        $Record.ConsumedAtUtc = [DateTime]::UtcNow.ToString("o")

        $State.Records = $Records

        Save-AtomicState -State $State

        return [pscustomobject]@{
            Decision      = "ALLOW"
            Consumed      = $true
            ProofKey      = $ProofKey
            ConsumedAtUtc = $Record.ConsumedAtUtc
        }
    }
    finally {
        if ($LockAcquired) {
            try {
                $Mutex.ReleaseMutex() | Out-Null
            }
            catch {}
        }

        $Mutex.Dispose()
    }
}

function Test-AtomicProof {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][string]$ProofHash
    )

    try {
        $ProofKey = Get-AtomicProofKey @PSBoundParameters
        $State = Get-AtomicState

        $Record = @($State.Records | Where-Object {
            $_.ProofKey -eq $ProofKey
        }) | Select-Object -First 1

        if ($null -eq $Record) {
            return [pscustomobject]@{
                Decision = "BLOCK"
                Valid    = $false
                Reason   = "ATOMIC_PROOF_NOT_FOUND"
            }
        }

        if ($Record.Consumed -eq $true) {
            return [pscustomobject]@{
                Decision = "BLOCK"
                Valid    = $false
                Reason   = "ATOMIC_REPLAY_BLOCKED"
            }
        }

        return [pscustomobject]@{
            Decision  = "ALLOW"
            Valid     = $true
            Consumed  = $false
            Reason    = "ATOMIC_PROOF_AVAILABLE"
        }
    }
    catch {
        return [pscustomobject]@{
            Decision = "BLOCK"
            Valid    = $false
            Reason   = $_.Exception.Message
        }
    }
}