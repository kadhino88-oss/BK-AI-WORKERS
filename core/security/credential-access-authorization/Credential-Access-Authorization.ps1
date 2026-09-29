Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

# Verrou inter-processus + ecriture atomique de state/records.json (fichier
# commun a toutes les missions) : voir core/runtime/State-Lock.ps1.
$BKLockRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $BKLockRoot "core/runtime/State-Lock.ps1")

function Convert-ToPlainHashtable {
    param([Parameter(Mandatory=$true)]$InputObject)
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

function Get-CredentialAccessAuthorizationConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return Convert-ToPlainHashtable $cfg
}

function Get-CredentialAccessAuthorizationField {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cfg=Get-CredentialAccessAuthorizationConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-CredentialAccessAuthorizationRecords {
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

function Save-CredentialAccessAuthorizationRecords {
    param([Parameter(Mandatory=$true)]$Records)

    $cfg=Get-CredentialAccessAuthorizationConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum credential authorization record count exceeded.'
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state/records.json'

    # Appelee uniquement depuis des blocs Invoke-BKStateLocked (New-/Invalidate-).
    Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 30)

    return $null
}

function Get-SHA256CredentialReference {
    param([Parameter(Mandatory=$true)][string]$Value)

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

function Get-CredentialAccessAuthorizationRecord {
    param([Parameter(Mandatory=$true)][string]$AuthorizationId)

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        return $null
    }

    $found=@(
        Get-CredentialAccessAuthorizationRecords |
        Where-Object { $_.AuthorizationId -eq $AuthorizationId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-CredentialAccessAuthorizationId {
    return 'CRED-AUTH-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function New-CredentialAccessAuthorization {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$CredentialRef,
        [string]$Grant='',
        [string]$FreshnessId='',
        [string]$Nonce='',
        [string]$IntegrityId=''
    )

    $cfg=Get-CredentialAccessAuthorizationConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['credentialAccessAuthorizationEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_AUTHORIZATION_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId) -or
        [string]::IsNullOrWhiteSpace($ProjectId) -or
        [string]::IsNullOrWhiteSpace($WorkerId) -or
        [string]::IsNullOrWhiteSpace($Action) -or
        [string]::IsNullOrWhiteSpace($ConnectorId) -or
        [string]::IsNullOrWhiteSpace($CredentialRef)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_AUTHORIZATION_CONTEXT_INCOMPLETE'
        }
    }

    if ([bool]$cfg['neverPersistRawSecrets'] -and
        $CredentialRef.Length -gt 0) {

        if ($CredentialRef -match 'password|secret|token|apikey|api_key|privatekey') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='RAW_SECRET_PATTERN_REJECTED'
            }
        }
    }

    # --------------------------------------------------------
    # REVOCATION
    # --------------------------------------------------------

    if ([bool]$cfg['requireRevocationChain']) {

        $runtime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/revocation-cascade/Revocation-Cascade.ps1')

        if (-not (Test-Path -LiteralPath $runtime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='REVOCATION_RUNTIME_MISSING'
            }
        }

        . $runtime

        if ([string]::IsNullOrWhiteSpace($Grant)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='GRANT_REQUIRED'
            }
        }
    }

    # --------------------------------------------------------
    # FRESHNESS
    # --------------------------------------------------------

    if ([bool]$cfg['requireFreshnessValidation']) {

        $runtime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-freshness/Authorization-Freshness.ps1')

        if (-not (Test-Path -LiteralPath $runtime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_RUNTIME_MISSING'
            }
        }

        if ([string]::IsNullOrWhiteSpace($FreshnessId) -or
            [string]::IsNullOrWhiteSpace($Nonce)) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_PROOF_MISSING'
            }
        }
    }

    # --------------------------------------------------------
    # CONTEXT INTEGRITY
    # --------------------------------------------------------

    if ([bool]$cfg['requireContextIntegrity']) {

        $runtime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-context-integrity/Authorization-Context-Integrity.ps1')

        if (-not (Test-Path -LiteralPath $runtime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='CONTEXT_INTEGRITY_RUNTIME_MISSING'
            }
        }

        if ([string]::IsNullOrWhiteSpace($IntegrityId)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='INTEGRITY_PROOF_MISSING'
            }
        }
    }

    $credentialHash=Get-SHA256CredentialReference `
        -Value $CredentialRef

    $record=[pscustomobject]@{
        AuthorizationId=New-CredentialAccessAuthorizationId
        UserId=$UserId
        SessionId=$SessionId
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        WorkerId=$WorkerId
        Action=$Action
        ConnectorId=$ConnectorId
        CredentialRefHash=$credentialHash
        GrantId=''
        FreshnessId=$FreshnessId
        IntegrityId=$IntegrityId
        CreatedAtUtc=[datetime]::UtcNow.ToString('o')
        Status='ACTIVE'
        Decision='ALLOW'
    }

    if (-not [string]::IsNullOrWhiteSpace($Grant)) {

        try {
            $grantRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-grant/Authorization-Grant.ps1')
            . $grantRuntime

            $grantIdCandidates=@(
                Get-AuthorizationGrants |
                Where-Object {
                    $_.UserId -eq $UserId -and
                    $_.SessionId -eq $SessionId
                }
            )

            if ($grantIdCandidates.Count -gt 0) {
                $record.GrantId=[string]$grantIdCandidates[-1].GrantId
            }
        }
        catch {
            # Fail closed only when explicit grant validation is expected
        }
    }

    # Lecture -> ajout -> ecriture de records.json sous verrou inter-processus.
    $null=Invoke-BKStateLocked {
        $records=@(Get-CredentialAccessAuthorizationRecords)
        $records += $record

        $null=Save-CredentialAccessAuthorizationRecords -Records $records
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CREDENTIAL_ACCESS_AUTHORIZED'
        AuthorizationId=$record.AuthorizationId
        CredentialRefHash=$credentialHash
        ConnectorId=$ConnectorId
        WorkerId=$WorkerId
        Action=$Action
    }
}

function Test-CredentialAccessAuthorization {
    param(
        [Parameter(Mandatory=$true)][string]$AuthorizationId,
        [Parameter(Mandatory=$true)][string]$CredentialRef,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$ConnectorId
    )

    $cfg=Get-CredentialAccessAuthorizationConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['credentialAccessAuthorizationEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_AUTHORIZATION_DISABLED'
        }
    }

    $record=Get-CredentialAccessAuthorizationRecord `
        -AuthorizationId $AuthorizationId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHORIZATION_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHORIZATION_INACTIVE'
        }
    }

    if ([string]$record.UserId -ne $UserId -or
        [string]$record.SessionId -ne $SessionId -or
        [string]$record.TenantId -ne $TenantId -or
        [string]$record.ClientId -ne $ClientId -or
        [string]$record.ProjectId -ne $ProjectId -or
        [string]$record.WorkerId -ne $WorkerId -or
        [string]$record.Action -ne $Action -or
        [string]$record.ConnectorId -ne $ConnectorId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_AUTHORIZATION_CONTEXT_MISMATCH'
        }
    }

    $hash=Get-SHA256CredentialReference `
        -Value $CredentialRef

    if ($hash -ne [string]$record.CredentialRefHash) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_REFERENCE_MISMATCH'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CREDENTIAL_ACCESS_AUTHORIZATION_VALID'
        AuthorizationId=$AuthorizationId
        ConnectorId=$ConnectorId
        WorkerId=$WorkerId
        Action=$Action
    }
}

function Invalidate-CredentialAccessAuthorization {
    param([Parameter(Mandatory=$true)][string]$AuthorizationId)

    # Verification -> lecture -> modification -> ecriture de records.json dans
    # un seul bloc verrouille ; la fonction renvoie exactement l'objet du bloc.
    return (Invoke-BKStateLocked {
        $record=Get-CredentialAccessAuthorizationRecord `
            -AuthorizationId $AuthorizationId

        if ($null -eq $record) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='AUTHORIZATION_NOT_FOUND'
            }
        }

        $records=@(Get-CredentialAccessAuthorizationRecords)

        foreach ($item in $records) {
            if ($item.AuthorizationId -eq $AuthorizationId) {
                $item.Status='INVALIDATED'
            }
        }

        $null=Save-CredentialAccessAuthorizationRecords `
            -Records $records

        return [pscustomobject]@{
            Success=$true
            Decision='BLOCK'
            Reason='CREDENTIAL_AUTHORIZATION_INVALIDATED'
            AuthorizationId=$AuthorizationId
            Status='INVALIDATED'
        }
    })
}

function Reset-CredentialAccessAuthorization {
    $file=Join-Path $PSScriptRoot 'state/records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    # Ecriture atomique, serialisee avec les lectures/ecritures des autres missions.
    $null=Invoke-BKStateLocked {
        Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 10)
    }

    return $null
}