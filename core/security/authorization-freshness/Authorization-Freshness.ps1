Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

# Verrou inter-processus + ecriture atomique de state/records.json (fichier
# commun a toutes les missions) : voir core/runtime/State-Lock.ps1.
$BKLockRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $BKLockRoot "core/runtime/State-Lock.ps1")

function Convert-ToPlainHashtable {
    param(
        [Parameter(Mandatory=$true)]
        $InputObject
    )
    # PowerShell 7 convertit les dates ISO en [datetime] (recursion infinie via .Date) ;
    # Windows PowerShell 5.1 les laissait en texte : on renvoie le meme texte ISO.
    if ($InputObject -is [datetime]) { return $InputObject.ToString("o") }
    if ($InputObject -is [datetimeoffset]) { return $InputObject.ToString("o") }


    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [hashtable]) {
        $h=@{}
        foreach ($k in $InputObject.Keys) {
            $h[$k]=Convert-ToPlainHashtable $InputObject[$k]
        }
        return $h
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $h=@{}
        foreach ($k in $InputObject.Keys) {
            $h[$k]=Convert-ToPlainHashtable $InputObject[$k]
        }
        return $h
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and
        -not ($InputObject -is [string])) {

        $a=@()

        foreach ($item in $InputObject) {
            $a += Convert-ToPlainHashtable $item
        }

        return @($a)
    }

    if ($InputObject.PSObject -and
        @($InputObject.PSObject.Properties).Count -gt 0 -and
        -not ($InputObject -is [string])) {

        $h=@{}

        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name]=Convert-ToPlainHashtable $p.Value
        }

        return $h
    }

    return $InputObject
}

function Get-AuthorizationFreshnessConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

    return Convert-ToPlainHashtable $cfg
}

function Get-AuthorizationFreshnessField {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $cfg=Get-AuthorizationFreshnessConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-AuthorizationFreshnessRecords {
    $file=Join-Path $PSScriptRoot 'state/records.json'

    if (-not (Test-Path -LiteralPath $file)) {
        return @()
    }

    $raw=Get-Content -LiteralPath $file -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $obj=$raw | ConvertFrom-Json

    if ($null -eq $obj) {
        return @()
    }

    if ($obj.PSObject.Properties.Name -contains 'items') {
        return @($obj.items)
    }

    return @($obj)
}

function Save-AuthorizationFreshnessRecords {
    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $cfg=Get-AuthorizationFreshnessConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum freshness record count exceeded.'
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state/records.json'

    Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 30)

    return $null
}

function Get-SHA256FreshnessHash {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Value
    )

    $sha=[System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes=[System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash=$sha.ComputeHash($bytes)

        return (-join ($hash | ForEach-Object {
            $_.ToString('x2')
        })).ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function New-RandomFreshnessNonce {
    $bytes=New-Object byte[] 32

    $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($bytes)

        return [Convert]::ToBase64String($bytes)
    }
    finally {
        $rng.Dispose()
    }
}

function New-AuthorizationFreshnessId {
    return 'FRESH-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function Get-AuthorizationFreshnessRecord {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FreshnessId
    )

    if ([string]::IsNullOrWhiteSpace($FreshnessId)) {
        return $null
    }

    $found=@(
        Get-AuthorizationFreshnessRecords |
        Where-Object { $_.FreshnessId -eq $FreshnessId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-AuthorizationFreshness {
    param(
        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$SessionId,

        [Parameter(Mandatory=$true)]
        [string]$GrantId,

        [Parameter(Mandatory=$true)]
        [string]$Grant,

        [Parameter(Mandatory=$true)]
        [string]$BindingId,

        [Parameter(Mandatory=$true)]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [string]$ClientId,

        [string]$ProjectId=''
    )

    $cfg=Get-AuthorizationFreshnessConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['freshnessGuardEnabled'] -or
        -not [bool]$cfg['antiReplayEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='FRESHNESS_GUARD_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($GrantId) -or
        [string]::IsNullOrWhiteSpace($Grant) -or
        [string]::IsNullOrWhiteSpace($BindingId) -or
        [string]::IsNullOrWhiteSpace($ExecutionId) -or
        [string]::IsNullOrWhiteSpace($Action) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='FRESHNESS_CONTEXT_INCOMPLETE'
        }
    }

    if ([bool]$cfg['requireRevocationChain']) {

        $revocationRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/revocation-cascade/Revocation-Cascade.ps1')

        if (-not (Test-Path -LiteralPath $revocationRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='REVOCATION_RUNTIME_MISSING'
            }
        }

        . $revocationRuntime

        try {
            $chain=@(
                Test-RevocationCascade `
                    -UserId $UserId `
                    -SessionId $SessionId `
                    -GrantId $GrantId `
                    -Grant $Grant `
                    -BindingId $BindingId `
                    -ExecutionId $ExecutionId `
                    -Action $Action `
                    -TenantId $TenantId `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId
            ) | Select-Object -Last 1
        }
        catch {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='REVOCATION_CHAIN_CHECK_FAILED'
            }
        }

        if ($null -eq $chain -or
            $chain.Success -ne $true -or
            $chain.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='REVOCATION_CHAIN_BLOCKED'
            }
        }
    }

    $now=[datetime]::UtcNow
    $expires=$now.AddSeconds([double]$cfg['nonceDurationSeconds'])
    $nonce=New-RandomFreshnessNonce
    $nonceHash=Get-SHA256FreshnessHash -Value $nonce

    $record=[pscustomobject]@{
        FreshnessId=New-AuthorizationFreshnessId
        NonceHash=$nonceHash
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        IssuedAtUtc=$now.ToString('o')
        ExpiresAtUtc=$expires.ToString('o')
        Status='ISSUED'
        ConsumedAtUtc=$null
    }

    $null=Invoke-BKStateLocked {
        $records=@(Get-AuthorizationFreshnessRecords)
        $records += $record

        $null=Save-AuthorizationFreshnessRecords -Records $records
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        FreshnessId=$record.FreshnessId
        Nonce=$nonce
        ExpiresAtUtc=$record.ExpiresAtUtc
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
    }
}

function Test-AuthorizationFreshness {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FreshnessId,

        [Parameter(Mandatory=$true)]
        [string]$Nonce,

        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$SessionId,

        [Parameter(Mandatory=$true)]
        [string]$GrantId,

        [Parameter(Mandatory=$true)]
        [string]$BindingId,

        [Parameter(Mandatory=$true)]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [string]$ClientId,

        [string]$ProjectId=''
    )

    $cfg=Get-AuthorizationFreshnessConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['freshnessGuardEnabled'] -or
        -not [bool]$cfg['antiReplayEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='FRESHNESS_GUARD_DISABLED'
        }
    }

    $record=Get-AuthorizationFreshnessRecord -FreshnessId $FreshnessId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='FRESHNESS_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ISSUED') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='NONCE_ALREADY_CONSUMED_OR_REVOKED'
        }
    }

    $providedHash=Get-SHA256FreshnessHash -Value $Nonce

    if ($providedHash -ne [string]$record.NonceHash) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='NONCE_MISMATCH'
        }
    }

    if ([string]$record.UserId -ne $UserId -or
        [string]$record.SessionId -ne $SessionId -or
        [string]$record.GrantId -ne $GrantId -or
        [string]$record.BindingId -ne $BindingId -or
        [string]$record.ExecutionId -ne $ExecutionId -or
        [string]$record.Action -ne $Action -or
        [string]$record.TenantId -ne $TenantId -or
        [string]$record.ClientId -ne $ClientId -or
        [string]$record.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='FRESHNESS_CONTEXT_MISMATCH'
        }
    }

    $expires=[datetime]::Parse($record.ExpiresAtUtc).ToUniversalTime()

    if ([datetime]::UtcNow -ge $expires) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='NONCE_EXPIRED'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='FRESHNESS_VALID'
        FreshnessId=$FreshnessId
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
    }
}

function Consume-AuthorizationFreshness {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FreshnessId,

        [Parameter(Mandatory=$true)]
        [string]$Nonce,

        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$SessionId,

        [Parameter(Mandatory=$true)]
        [string]$GrantId,

        [Parameter(Mandatory=$true)]
        [string]$BindingId,

        [Parameter(Mandatory=$true)]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [string]$ClientId,

        [string]$ProjectId=''
    )

    # Validation (statut ISSUED) + consommation dans le MEME bloc verrouille :
    # deux missions ne peuvent pas consommer le meme nonce en parallele.
    return (Invoke-BKStateLocked {
        $validation=Test-AuthorizationFreshness `
            -FreshnessId $FreshnessId `
            -Nonce $Nonce `
            -UserId $UserId `
            -SessionId $SessionId `
            -GrantId $GrantId `
            -BindingId $BindingId `
            -ExecutionId $ExecutionId `
            -Action $Action `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId

        if ($validation.Success -ne $true) {
            return $validation
        }

        $records=@(Get-AuthorizationFreshnessRecords)

        foreach ($item in $records) {

            if ($item.FreshnessId -eq $FreshnessId) {

                if (@($item.PSObject.Properties | ForEach-Object {
                    $_.Name
                }) -notcontains 'ConsumedAtUtc') {
                    $item | Add-Member -MemberType NoteProperty -Name ConsumedAtUtc -Value $null
                }

                $item.Status='CONSUMED'
                $item.ConsumedAtUtc=[datetime]::UtcNow.ToString('o')
            }
        }

        $null=Save-AuthorizationFreshnessRecords -Records $records

        return [pscustomobject]@{
            Success=$true
            Decision='ALLOW'
            Reason='NONCE_CONSUMED'
            FreshnessId=$FreshnessId
            ConsumedAtUtc=(
                $records |
                Where-Object { $_.FreshnessId -eq $FreshnessId } |
                Select-Object -ExpandProperty ConsumedAtUtc
            )
        }
    })
}

function Revoke-AuthorizationFreshness {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FreshnessId
    )

    return (Invoke-BKStateLocked {
        $record=Get-AuthorizationFreshnessRecord -FreshnessId $FreshnessId

        if ($null -eq $record) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_NOT_FOUND'
            }
        }

        $records=@(Get-AuthorizationFreshnessRecords)

        foreach ($item in $records) {

            if ($item.FreshnessId -eq $FreshnessId) {

                if (@($item.PSObject.Properties | ForEach-Object {
                    $_.Name
                }) -notcontains 'ConsumedAtUtc') {
                    $item | Add-Member -MemberType NoteProperty -Name ConsumedAtUtc -Value $null
                }

                $item.Status='REVOKED'
            }
        }

        $null=Save-AuthorizationFreshnessRecords -Records $records

        return [pscustomobject]@{
            Success=$true
            Decision='BLOCK'
            Reason='FRESHNESS_REVOKED'
            FreshnessId=$FreshnessId
            Status='REVOKED'
        }
    })
}

function Reset-AuthorizationFreshness {
    $file=Join-Path $PSScriptRoot 'state/records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    # Sous verrou : un reset ne peut pas s'intercaler au milieu d'une
    # lecture -> ecriture d'une autre mission (qui l'ecraserait).
    $null=Invoke-BKStateLocked {
        Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 10)
    }

    return $null
}