$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "EXECUTION-CANCELLATION-CONFIG.json"
$StatePath = Join-Path $StateDir "execution-leases.json"

function Get-ExecutionCancellationConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Execution Cancellation introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-LeaseProofHash {

    param(
        [string]$LeaseToken
    )

    if ([string]::IsNullOrWhiteSpace($LeaseToken)) {
        throw "LeaseToken requis."
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($LeaseToken)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)

    return (
        [System.BitConverter]::ToString($hash)
    ).Replace("-","").ToLowerInvariant()
}
function Get-LeaseMap {

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

function Save-LeaseMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map de lease requise."
    }

    $config = Get-ExecutionCancellationConfig

    if ($Map.Count -gt [int]$config.maxLeaseEntries) {
        throw "Nombre maximal de leases atteint."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Map |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function New-ExecutionLease {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$OwnerId
    )

    foreach ($value in @(
        $ExecutionId,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId,
        $OwnerId
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

    if ([string]::IsNullOrWhiteSpace($OwnerId)) {
        throw "OwnerId requis."
    }

    $config = Get-ExecutionCancellationConfig

    $leaseToken = [Guid]::NewGuid().ToString()

    return [ordered]@{
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        OwnerId = $OwnerId
        Status = "ACTIVE"

        # Le token reste uniquement côté appelant.
        LeaseToken = $leaseToken

        # L'état persistant utilise uniquement son hash.
        LeaseProofHash = Get-LeaseProofHash -LeaseToken $leaseToken

        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        ExpiresAtUtc = (Get-Date).ToUniversalTime().AddSeconds(
            [double]$config.leaseSeconds
        ).ToString("o")
        CancellationRequested = $false
        CancelledAtUtc = $null
        RenewedAtUtc = $null
    }
}
function Acquire-ExecutionLease {

    param(
        [hashtable]$Lease
    )

    $config = Get-ExecutionCancellationConfig

    if (-not $config.enabled -or -not $config.leaseEnabled) {
        throw "Leases desactivees."
    }

    if (-not $Lease) {
        throw "Lease requise."
    }

    $map = Get-LeaseMap

    if ($map.ContainsKey($Lease.ExecutionId)) {

        $existing = $map[$Lease.ExecutionId]

        if ($existing.Status -eq "ACTIVE") {
            return [pscustomobject]@{
                Acquired = $false
                Reason = "Execution deja possedee."
                Lease = $existing
            }
        }
    }

    # Ne jamais persister le LeaseToken en clair.
    $storedLease = [ordered]@{}

    foreach ($property in $Lease.Keys) {

        if ($property -ne "LeaseToken") {
            $storedLease[$property] = $Lease[$property]
        }
    }

    if (-not $storedLease.Contains("LeaseProofHash")) {

        if (-not $Lease.Contains("LeaseToken")) {
            throw "LeaseToken requis pour acquisition."
        }

        $storedLease["LeaseProofHash"] = Get-LeaseProofHash `
            -LeaseToken ([string]$Lease.LeaseToken)
    }

    $map[$Lease.ExecutionId] = $storedLease

    Save-LeaseMap -Map $map | Out-Null

    return [pscustomobject]@{
        Acquired = $true
        Reason = "Lease acquise."
        Lease = $Lease
    }
}
function Get-ExecutionLease {

    param(
        [string]$ExecutionId
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    $map = Get-LeaseMap

    if (-not $map.ContainsKey($ExecutionId)) {
        return $null
    }

    return $map[$ExecutionId]
}

function Test-ExecutionLease {

    param(
        [string]$ExecutionId,
        [string]$OwnerId,
        [string]$LeaseToken
    )

    $lease = Get-ExecutionLease -ExecutionId $ExecutionId

    if ($null -eq $lease) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Lease introuvable."
        }
    }

    if ($lease.Status -ne "ACTIVE") {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Lease inactive."
        }
    }

    if ($lease.OwnerId -ne $OwnerId) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Owner invalide."
        }
    }

    if ([string]::IsNullOrWhiteSpace($LeaseToken)) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "LeaseToken manquant."
        }
    }

    $providedHash = Get-LeaseProofHash `
        -LeaseToken $LeaseToken

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$lease.LeaseProofHash
        )
    ) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "LeaseProofHash manquant."
        }
    }

    if ($lease.LeaseProofHash -ne $providedHash) {

        return [pscustomobject]@{
            Valid = $false
            Reason = "LeaseToken invalide."
        }
    }

    try {

        $expires = [DateTimeOffset]::Parse(
            [string]$lease.ExpiresAtUtc
        ).ToUniversalTime()

        if ([DateTimeOffset]::UtcNow -ge $expires) {

            return [pscustomobject]@{
                Valid = $false
                Reason = "Lease expiree."
            }
        }
    }
    catch {

        return [pscustomobject]@{
            Valid = $false
            Reason = "Expiration invalide."
        }
    }

    return [pscustomobject]@{
        Valid = $true
        Reason = "Lease valide."
    }
}
function Renew-ExecutionLease {

    param(
        [string]$ExecutionId,
        [string]$OwnerId,
        [string]$LeaseToken
    )

    $config = Get-ExecutionCancellationConfig

    $check = Test-ExecutionLease `
        -ExecutionId $ExecutionId `
        -OwnerId $OwnerId `
        -LeaseToken $LeaseToken

    if (-not $check.Valid) {
        return [pscustomobject]@{
            Renewed = $false
            Reason = $check.Reason
        }
    }

    $map = Get-LeaseMap
    $lease = $map[$ExecutionId]

    $lease.ExpiresAtUtc = (
        Get-Date
    ).ToUniversalTime().AddSeconds(
        [double]$config.leaseSeconds
    ).ToString("o")

    $lease.RenewedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $map[$ExecutionId] = $lease

    Save-LeaseMap -Map $map | Out-Null

    return [pscustomobject]@{
        Renewed = $true
        Reason = "Lease renouvelee."
        Lease = $lease
    }
}

function Request-ExecutionCancellation {

    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $config = Get-ExecutionCancellationConfig

    if (-not $config.enabled -or -not $config.cancellationEnabled) {
        throw "Cancellation desactivee."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    $map = Get-LeaseMap

    if (-not $map.ContainsKey($ExecutionId)) {
        return [pscustomobject]@{
            Requested = $false
            Reason = "Execution introuvable."
        }
    }

    $lease = $map[$ExecutionId]

    if ($lease.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Requested = $false
            Reason = "Isolation tenant refusee."
        }
    }

    if ($lease.Status -ne "ACTIVE") {
        return [pscustomobject]@{
            Requested = $false
            Reason = "Execution deja inactive."
        }
    }

    $lease.CancellationRequested = $true

    $map[$ExecutionId] = $lease

    Save-LeaseMap -Map $map | Out-Null

    return [pscustomobject]@{
        Requested = $true
        Reason = "Annulation demandee."
        ExecutionId = $ExecutionId
    }
}

function Confirm-ExecutionCancellation {

    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$OwnerId,
        [string]$LeaseToken
    )

    $config = Get-ExecutionCancellationConfig

    if (-not $config.cancellationEnabled) {
        throw "Cancellation desactivee."
    }

    $check = Test-ExecutionLease `
        -ExecutionId $ExecutionId `
        -OwnerId $OwnerId `
        -LeaseToken $LeaseToken

    if (-not $check.Valid) {

        return [pscustomobject]@{
            Cancelled = $false
            Reason = $check.Reason
        }
    }

    $map = Get-LeaseMap
    $lease = $map[$ExecutionId]

    if ($lease.TenantId -ne $TenantId) {

        return [pscustomobject]@{
            Cancelled = $false
            Reason = "Isolation tenant refusee."
        }
    }

    if (-not [bool]$lease.CancellationRequested) {

        return [pscustomobject]@{
            Cancelled = $false
            Reason = "Aucune demande d'annulation."
        }
    }

    $lease.Status = "CANCELLED"
    $lease.CancelledAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $map[$ExecutionId] = $lease

    Save-LeaseMap -Map $map | Out-Null

    return [pscustomobject]@{
        Cancelled = $true
        Reason = "Execution annulee."
        ExecutionId = $ExecutionId
    }
}

function Release-ExecutionLease {

    param(
        [string]$ExecutionId,
        [string]$OwnerId,
        [string]$LeaseToken
    )

    $check = Test-ExecutionLease `
        -ExecutionId $ExecutionId `
        -OwnerId $OwnerId `
        -LeaseToken $LeaseToken

    if (-not $check.Valid) {

        return [pscustomobject]@{
            Released = $false
            Reason = $check.Reason
        }
    }

    $map = Get-LeaseMap

    if ($map.ContainsKey($ExecutionId)) {
        $map.Remove($ExecutionId)
    }

    Save-LeaseMap -Map $map | Out-Null

    return [pscustomobject]@{
        Released = $true
        Reason = "Lease liberee."
    }
}

function Cleanup-ExpiredLeases {

    $map = Get-LeaseMap
    $now = [DateTimeOffset]::UtcNow
    $expired = 0

    foreach ($key in @($map.Keys)) {

        $lease = $map[$key]

        if ($lease.Status -ne "ACTIVE") {
            continue
        }

        try {

            $expires = [DateTimeOffset]::Parse(
                [string]$lease.ExpiresAtUtc
            ).ToUniversalTime()

            if ($now -ge $expires) {

                $lease.Status = "EXPIRED"
                $map[$key] = $lease
                $expired++
            }
        }
        catch {
        }
    }

    Save-LeaseMap -Map $map | Out-Null

    return $expired
}

function Reset-ExecutionCancellationState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}