Set-StrictMode -Version 2.0

# Verrou inter-processus + ecriture atomique du fichier d'etat partage
# (state/grants.json) - voir core/runtime/State-Lock.ps1.
$BKLockRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $BKLockRoot "core/runtime/State-Lock.ps1")

function Convert-ToPlainHashtable {
    param([Parameter(Mandatory=$true)]$InputObject)
    # PowerShell 7 convertit les dates ISO en [datetime] (recursion infinie via .Date) ;
    # Windows PowerShell 5.1 les laissait en texte : on renvoie le meme texte ISO.
    if ($InputObject -is [datetime]) { return $InputObject.ToString("o") }
    if ($InputObject -is [datetimeoffset]) { return $InputObject.ToString("o") }


    if ($null -eq $InputObject) { return $null }

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

function Get-AuthorizationGrantConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return Convert-ToPlainHashtable $cfg
}

function Get-AuthorizationGrantField {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $cfg=Get-AuthorizationGrantConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-AuthorizationGrants {
    $file=Join-Path $PSScriptRoot 'state/grants.json'

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

function Save-AuthorizationGrants {
    param(
        [Parameter(Mandatory=$true)]
        $Grants
    )

    $cfg=Get-AuthorizationGrantConfig
    $items=@($Grants)

    if ($items.Count -gt [int]$cfg['maxGrants']) {
        throw "Maximum grant count exceeded."
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state/grants.json'

    Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 30)

    return $null
}

function Get-SHA256GrantHash {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Grant
    )

    $sha=[System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes=[System.Text.Encoding]::UTF8.GetBytes($Grant)
        $hash=$sha.ComputeHash($bytes)

        return (
            [System.BitConverter]::ToString($hash)
        ).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-AuthorizationGrant {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GrantId
    )

    if ([string]::IsNullOrWhiteSpace($GrantId)) {
        return $null
    }

    $items=@(
        Get-AuthorizationGrants |
        Where-Object { $_.GrantId -eq $GrantId }
    )

    if ($items.Count -eq 0) {
        return $null
    }

    return $items[0]
}

function Get-GrantReferenceTime {
    param(
        [Parameter()]
        [datetime]$ReferenceTime = [datetime]::UtcNow
    )

    return $ReferenceTime.ToUniversalTime()
}

function New-RandomAuthorizationGrant {
    $bytes=New-Object byte[] 32

    $rng=[System.Security.Cryptography.RandomNumberGenerator]::Create()

    try {
        $rng.GetBytes($bytes)

        return [Convert]::ToBase64String($bytes).
            Replace('+','-').
            Replace('/','_').
            TrimEnd('=')
    }
    finally {
        $rng.Dispose()
    }
}

function New-AuthorizationGrant {
    param(
        [Parameter(Mandatory=$true)]
        [string]$AuthorizationId,

        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$SessionId,

        [Parameter(Mandatory=$true)]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [string]$ClientId,

        [string]$ProjectId=''
    )

    $cfg=Get-AuthorizationGrantConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['grantEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='GRANT_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId) -or
        [string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($Action) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId)) {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='GRANT_CONTEXT_INCOMPLETE'
        }
    }

    $gatewayFile=Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        'authorization-gateway/Authorization-Gateway.ps1'

    if (-not (Test-Path -LiteralPath $gatewayFile)) {
        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_GATEWAY_MISSING'
        }
    }

    . $gatewayFile

    try {
        $authorization=Get-AuthorizationDecision `
            -DecisionId $AuthorizationId
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_LOOKUP_FAILED'
        }
    }

    if ($null -eq $authorization) {
        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_NOT_FOUND'
        }
    }

    if ($authorization.Success -ne $true -or
        $authorization.Decision -ne 'ALLOW') {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_NOT_ALLOWED'
        }
    }

    if ($authorization.UserId -ne $UserId -or
        $authorization.SessionId -ne $SessionId -or
        $authorization.Action -ne $Action -or
        $authorization.TenantId -ne $TenantId -or
        $authorization.ClientId -ne $ClientId -or
        $authorization.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_CONTEXT_MISMATCH'
        }
    }

    $now=[datetime]::UtcNow
    $expires=$now.AddSeconds([int]$cfg['grantDurationSeconds'])

    $rawGrant=New-RandomAuthorizationGrant
    $grantHash=Get-SHA256GrantHash -Grant $rawGrant
    $grantId=('GRANT-' + [guid]::NewGuid().ToString('N').ToUpperInvariant())

    $record=[pscustomobject]@{
        GrantId=$grantId
        GrantHash=$grantHash
        AuthorizationId=$AuthorizationId
        UserId=$UserId
        SessionId=$SessionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        Status='ACTIVE'
        CreatedAtUtc=$now.ToString('o')
        ExpiresAtUtc=$expires.ToString('o')
        RevokedAtUtc=$null
    }

    # Lecture -> ajout -> ecriture de state/grants.json sous le verrou commun.
    $null=Invoke-BKStateLocked {
        $items=@(Get-AuthorizationGrants)
        $items += $record

        $null=Save-AuthorizationGrants -Grants $items
    }

    return [pscustomobject]@{
        Success=$true
        Status='CREATED'
        Reason='AUTHORIZATION_GRANT_CREATED'
        GrantId=$grantId
        Grant=$rawGrant
        AuthorizationId=$AuthorizationId
        UserId=$UserId
        SessionId=$SessionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        ExpiresAtUtc=$expires.ToString('o')
    }
}

function Test-AuthorizationGrant {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GrantId,

        [Parameter(Mandatory=$true)]
        [string]$Grant,

        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$SessionId,

        [Parameter(Mandatory=$true)]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [string]$ClientId,

        [string]$ProjectId='',

        [Parameter()]
        [datetime]$ReferenceTime=[datetime]::UtcNow
    )

    $record=Get-AuthorizationGrant -GrantId $GrantId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GRANT_NOT_FOUND'
        }
    }

    $hash=Get-SHA256GrantHash -Grant $Grant

    if ($hash -ne [string]$record.GrantHash) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GRANT_HASH_MISMATCH'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GRANT_NOT_ACTIVE'
        }
    }

    $now=Get-GrantReferenceTime -ReferenceTime $ReferenceTime
    $expires=[datetime]::Parse(
        [string]$record.ExpiresAtUtc
    ).ToUniversalTime()

    if ($now -ge $expires) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GRANT_EXPIRED'
        }
    }

    if ($record.UserId -ne $UserId -or
        $record.SessionId -ne $SessionId -or
        $record.Action -ne $Action -or
        $record.TenantId -ne $TenantId -or
        $record.ClientId -ne $ClientId -or
        $record.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GRANT_CONTEXT_MISMATCH'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='AUTHORIZATION_GRANT_VALID'
        GrantId=$GrantId
        AuthorizationId=$record.AuthorizationId
        UserId=$record.UserId
        SessionId=$record.SessionId
        Action=$record.Action
        TenantId=$record.TenantId
        ClientId=$record.ClientId
        ProjectId=$record.ProjectId
        ExpiresAtUtc=$record.ExpiresAtUtc
    }
}

function Revoke-AuthorizationGrant {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GrantId
    )

    # Lecture -> revocation -> ecriture de state/grants.json sous le verrou
    # commun ; chaque "return" ci-dessous sort du bloc et devient la valeur
    # renvoyee par la fonction.
    return (Invoke-BKStateLocked {
        $items=@(Get-AuthorizationGrants)

        $found=@(
            $items | Where-Object { $_.GrantId -eq $GrantId }
        )

        if ($found.Count -eq 0) {
            return [pscustomobject]@{
                Success=$false
                Status='NOT_FOUND'
                Reason='GRANT_NOT_FOUND'
            }
        }

        $record=$found[0]

        if ($record.Status -eq 'REVOKED') {
            return [pscustomobject]@{
                Success=$false
                Status='DUPLICATE'
                Reason='GRANT_ALREADY_REVOKED'
                GrantId=$GrantId
            }
        }

        $updated=@()

        foreach ($item in $items) {
            if ($item.GrantId -eq $GrantId) {
                $copy=$item | Select-Object *
                $copy.Status='REVOKED'
                $copy.RevokedAtUtc=[datetime]::UtcNow.ToString('o')
                $updated += $copy
            }
            else {
                $updated += $item
            }
        }

        $null=Save-AuthorizationGrants -Grants $updated

        return [pscustomobject]@{
            Success=$true
            Status='REVOKED'
            Reason='AUTHORIZATION_GRANT_REVOKED'
            GrantId=$GrantId
        }
    })
}

function Reset-AuthorizationGrants {
    $file=Join-Path $PSScriptRoot 'state/grants.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    # Sous le verrou commun : une remise a zero ne peut pas s'intercaler
    # entre la lecture et l'ecriture d'une autre mission.
    $null=Invoke-BKStateLocked {
        Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 10)
    }

    return $null
}