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

function Get-AuthorizationContextIntegrityConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

    return Convert-ToPlainHashtable $cfg
}

function Get-AuthorizationContextIntegrityField {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $cfg=Get-AuthorizationContextIntegrityConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-AuthorizationContextIntegrityRecords {
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

function Save-AuthorizationContextIntegrityRecords {
    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $cfg=Get-AuthorizationContextIntegrityConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum context integrity record count exceeded.'
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state/records.json'

    Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 30)

    return $null
}

function Get-SHA256ContextHash {
    param(
        [Parameter(Mandatory=$true)]
        [string]$CanonicalContext
    )

    $sha=[System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes=[System.Text.Encoding]::UTF8.GetBytes($CanonicalContext)
        $hash=$sha.ComputeHash($bytes)

        return (-join ($hash | ForEach-Object {
            $_.ToString('x2')
        })).ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-CanonicalAuthorizationContext {
    param(
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

    $parts=@(
        'UserId=' + $UserId
        'SessionId=' + $SessionId
        'GrantId=' + $GrantId
        'BindingId=' + $BindingId
        'ExecutionId=' + $ExecutionId
        'Action=' + $Action
        'TenantId=' + $TenantId
        'ClientId=' + $ClientId
        'ProjectId=' + $ProjectId
    )

    return ($parts -join "`n")
}

function New-AuthorizationContextIntegrityId {
    return 'CTXINT-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function Get-AuthorizationContextIntegrityRecord {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IntegrityId
    )

    if ([string]::IsNullOrWhiteSpace($IntegrityId)) {
        return $null
    }

    $found=@(
        Get-AuthorizationContextIntegrityRecords |
        Where-Object { $_.IntegrityId -eq $IntegrityId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-AuthorizationContextIntegrity {
    param(
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

        [string]$ProjectId='',

        [string]$Grant='',

        [string]$FreshnessId='',

        [string]$Nonce=''
    )

    $cfg=Get-AuthorizationContextIntegrityConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['contextIntegrityEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CONTEXT_INTEGRITY_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($GrantId) -or
        [string]::IsNullOrWhiteSpace($BindingId) -or
        [string]::IsNullOrWhiteSpace($ExecutionId) -or
        [string]::IsNullOrWhiteSpace($Action) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CONTEXT_INTEGRITY_CONTEXT_INCOMPLETE'
        }
    }

    $revocationRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/revocation-cascade/Revocation-Cascade.ps1')

    if ([bool]$cfg['requireRevocationChain']) {

        if (-not (Test-Path -LiteralPath $revocationRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='REVOCATION_RUNTIME_MISSING'
            }
        }

        . $revocationRuntime

        if ([string]::IsNullOrWhiteSpace($Grant) -or
            [string]::IsNullOrWhiteSpace($FreshnessId) -or
            [string]::IsNullOrWhiteSpace($Nonce)) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='AUTHORIZATION_PROOF_MISSING'
            }
        }

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

    if ([bool]$cfg['requireFreshnessValidation']) {

        $freshnessRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-freshness/Authorization-Freshness.ps1')

        if (-not (Test-Path -LiteralPath $freshnessRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_RUNTIME_MISSING'
            }
        }

        . $freshnessRuntime

        if ([string]::IsNullOrWhiteSpace($FreshnessId) -or
            [string]::IsNullOrWhiteSpace($Nonce)) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_PROOF_MISSING'
            }
        }

        try {
            $freshCheck=@(
                Test-AuthorizationFreshness `
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
            ) | Select-Object -Last 1
        }
        catch {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_CHECK_FAILED'
            }
        }

        if ($null -eq $freshCheck -or
            $freshCheck.Success -ne $true -or
            $freshCheck.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_BLOCKED'
            }
        }
    }

    $canonical=Get-CanonicalAuthorizationContext `
        -UserId $UserId `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    $contextHash=Get-SHA256ContextHash -CanonicalContext $canonical

    $record=[pscustomobject]@{
        IntegrityId=New-AuthorizationContextIntegrityId
        ContextHash=$contextHash
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        FreshnessId=$FreshnessId
        IssuedAtUtc=[datetime]::UtcNow.ToString('o')
        Status='ACTIVE'
        VerifiedAtUtc=$null
    }

    $null=Invoke-BKStateLocked {
        $records=@(Get-AuthorizationContextIntegrityRecords)
        $records += $record

        $null=Save-AuthorizationContextIntegrityRecords -Records $records
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        IntegrityId=$record.IntegrityId
        ContextHash=$contextHash
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        FreshnessId=$FreshnessId
    }
}

function Test-AuthorizationContextIntegrity {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IntegrityId,

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

        [string]$ProjectId='',

        [string]$Grant='',

        [string]$FreshnessId='',

        [string]$Nonce=''
    )

    $cfg=Get-AuthorizationContextIntegrityConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['contextIntegrityEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CONTEXT_INTEGRITY_DISABLED'
        }
    }

    $record=Get-AuthorizationContextIntegrityRecord `
        -IntegrityId $IntegrityId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='INTEGRITY_RECORD_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='INTEGRITY_RECORD_INACTIVE'
        }
    }

    $canonical=Get-CanonicalAuthorizationContext `
        -UserId $UserId `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    $calculatedHash=Get-SHA256ContextHash `
        -CanonicalContext $canonical

    if ($calculatedHash -ne [string]$record.ContextHash) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CONTEXT_HASH_MISMATCH'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($FreshnessId) -or
        -not [string]::IsNullOrWhiteSpace($Nonce)) {

        if ([string]::IsNullOrWhiteSpace($FreshnessId) -or
            [string]::IsNullOrWhiteSpace($Nonce)) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_CONTEXT_INCOMPLETE'
            }
        }

        $freshnessRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-freshness/Authorization-Freshness.ps1')

        if (-not (Test-Path -LiteralPath $freshnessRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_RUNTIME_MISSING'
            }
        }

        . $freshnessRuntime

        try {
            $freshCheck=@(
                Test-AuthorizationFreshness `
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
            ) | Select-Object -Last 1
        }
        catch {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_RECHECK_FAILED'
            }
        }

        if ($null -eq $freshCheck -or
            $freshCheck.Success -ne $true -or
            $freshCheck.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_RECHECK_BLOCKED'
            }
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CONTEXT_INTEGRITY_VALID'
        IntegrityId=$IntegrityId
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

function Verify-AuthorizationContextIntegrity {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IntegrityId,

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

        [string]$ProjectId='',

        [string]$Grant='',

        [string]$FreshnessId='',

        [string]$Nonce=''
    )

    # Validation (statut ACTIVE) + marquage VerifiedAtUtc dans le MEME bloc
    # verrouille : une invalidation concurrente ne peut pas s'intercaler.
    return (Invoke-BKStateLocked {
        $result=Test-AuthorizationContextIntegrity `
            -IntegrityId $IntegrityId `
            -UserId $UserId `
            -SessionId $SessionId `
            -GrantId $GrantId `
            -BindingId $BindingId `
            -ExecutionId $ExecutionId `
            -Action $Action `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -Grant $Grant `
            -FreshnessId $FreshnessId `
            -Nonce $Nonce

        if ($result.Success -ne $true) {
            return $result
        }

        $records=@(Get-AuthorizationContextIntegrityRecords)

        foreach ($item in $records) {

            if ($item.IntegrityId -eq $IntegrityId) {

                if (@($item.PSObject.Properties | ForEach-Object {
                    $_.Name
                }) -notcontains 'VerifiedAtUtc') {
                    $item | Add-Member `
                        -MemberType NoteProperty `
                        -Name VerifiedAtUtc `
                        -Value $null
                }

                $item.VerifiedAtUtc=[datetime]::UtcNow.ToString('o')
            }
        }

        $null=Save-AuthorizationContextIntegrityRecords `
            -Records $records

        return $result
    })
}

function Invalidate-AuthorizationContextIntegrity {
    param(
        [Parameter(Mandatory=$true)]
        [string]$IntegrityId
    )

    return (Invoke-BKStateLocked {
        $record=Get-AuthorizationContextIntegrityRecord `
            -IntegrityId $IntegrityId

        if ($null -eq $record) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='INTEGRITY_RECORD_NOT_FOUND'
            }
        }

        $records=@(Get-AuthorizationContextIntegrityRecords)

        foreach ($item in $records) {

            if ($item.IntegrityId -eq $IntegrityId) {
                $item.Status='INVALIDATED'
            }
        }

        $null=Save-AuthorizationContextIntegrityRecords `
            -Records $records

        return [pscustomobject]@{
            Success=$true
            Decision='BLOCK'
            Reason='CONTEXT_INTEGRITY_INVALIDATED'
            IntegrityId=$IntegrityId
            Status='INVALIDATED'
        }
    })
}

function Reset-AuthorizationContextIntegrity {
    $file=Join-Path $PSScriptRoot 'state/records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    $null=Invoke-BKStateLocked {
        Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 10)
    }

    return $null
}