Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

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

function Get-CredentialLeaseConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return Convert-ToPlainHashtable $cfg
}

function Get-CredentialLeaseField {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cfg=Get-CredentialLeaseConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-CredentialLeaseRecords {
    $file=Join-Path $PSScriptRoot 'state\records.json'

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

function Save-CredentialLeaseRecords {
    param([Parameter(Mandatory=$true)]$Records)

    $cfg=Get-CredentialLeaseConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum credential lease record count exceeded.'
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state\records.json'

    ConvertTo-Json -InputObject $wrapper -Depth 30 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}

function Get-CredentialLeaseRecord {
    param([Parameter(Mandatory=$true)][string]$LeaseId)

    if ([string]::IsNullOrWhiteSpace($LeaseId)) {
        return $null
    }

    $found=@(
        Get-CredentialLeaseRecords |
        Where-Object { $_.LeaseId -eq $LeaseId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-CredentialLeaseId {
    return 'LEASE-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function New-CredentialLease {
    param(
        [Parameter(Mandatory=$true)][string]$CredentialAuthorizationId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$CredentialRef,
        [string]$ExecutionId=''
    )

    $cfg=Get-CredentialLeaseConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['credentialLeaseEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_LEASE_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($CredentialAuthorizationId) -or
        [string]::IsNullOrWhiteSpace($UserId) -or
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
            Reason='CREDENTIAL_LEASE_CONTEXT_INCOMPLETE'
        }
    }

    $authorizationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\credential-access-authorization\Credential-Access-Authorization.ps1'

    if (-not (Test-Path -LiteralPath $authorizationRuntime)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_AUTHORIZATION_RUNTIME_MISSING'
        }
    }

    . $authorizationRuntime

    $authorizationCheck=@(
        Test-CredentialAccessAuthorization `
            -AuthorizationId $CredentialAuthorizationId `
            -CredentialRef $CredentialRef `
            -UserId $UserId `
            -SessionId $SessionId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -WorkerId $WorkerId `
            -Action $Action `
            -ConnectorId $ConnectorId
    ) | Select-Object -Last 1

    if ($null -eq $authorizationCheck -or
        $authorizationCheck.Success -ne $true -or
        $authorizationCheck.Decision -ne 'ALLOW') {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_AUTHORIZATION_BLOCKED'
        }
    }

    $now=[datetime]::UtcNow
    $expires=$now.AddSeconds([double]$cfg['leaseDurationSeconds'])

    $record=[pscustomobject]@{
        LeaseId=New-CredentialLeaseId
        CredentialAuthorizationId=$CredentialAuthorizationId
        UserId=$UserId
        SessionId=$SessionId
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        WorkerId=$WorkerId
        Action=$Action
        ConnectorId=$ConnectorId
        CredentialRef=$CredentialRef
        ExecutionId=$ExecutionId
        IssuedAtUtc=$now.ToString('o')
        ExpiresAtUtc=$expires.ToString('o')
        Status='ACTIVE'
        ConsumedAtUtc=$null
    }

    $records=@(Get-CredentialLeaseRecords)
    $records += $record

    $null=Save-CredentialLeaseRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CREDENTIAL_LEASE_CREATED'
        LeaseId=$record.LeaseId
        ExpiresAtUtc=$record.ExpiresAtUtc
        UserId=$UserId
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        WorkerId=$WorkerId
        Action=$Action
        ConnectorId=$ConnectorId
        ExecutionId=$ExecutionId
    }
}

function Test-CredentialLease {
    param(
        [Parameter(Mandatory=$true)][string]$LeaseId,
        [Parameter(Mandatory=$true)][string]$CredentialRef,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [string]$ExecutionId=''
    )

    $cfg=Get-CredentialLeaseConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['credentialLeaseEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_LEASE_DISABLED'
        }
    }

    $record=Get-CredentialLeaseRecord -LeaseId $LeaseId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='LEASE_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='LEASE_NOT_ACTIVE'
        }
    }

    if ([string]$record.CredentialRef -ne $CredentialRef) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CREDENTIAL_REFERENCE_MISMATCH'
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
            Reason='LEASE_CONTEXT_MISMATCH'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$record.ExecutionId) -and
        [string]$record.ExecutionId -ne $ExecutionId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='LEASE_EXECUTION_MISMATCH'
        }
    }

    $expires=[datetime]::Parse($record.ExpiresAtUtc).ToUniversalTime()

    if ([datetime]::UtcNow -ge $expires) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='LEASE_EXPIRED'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CREDENTIAL_LEASE_VALID'
        LeaseId=$LeaseId
        ConnectorId=$ConnectorId
        WorkerId=$WorkerId
        Action=$Action
        ExpiresAtUtc=$record.ExpiresAtUtc
    }
}

function Consume-CredentialLease {
    param(
        [Parameter(Mandatory=$true)][string]$LeaseId,
        [Parameter(Mandatory=$true)][string]$CredentialRef,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [string]$ExecutionId=''
    )

    $check=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $UserId `
        -SessionId $SessionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -Action $Action `
        -ConnectorId $ConnectorId `
        -ExecutionId $ExecutionId

    if ($check.Success -ne $true) {
        return $check
    }

    $records=@(Get-CredentialLeaseRecords)

    foreach ($item in $records) {

        if ($item.LeaseId -eq $LeaseId) {

            if (@($item.PSObject.Properties | ForEach-Object {
                $_.Name
            }) -notcontains 'ConsumedAtUtc') {

                $item | Add-Member `
                    -MemberType NoteProperty `
                    -Name ConsumedAtUtc `
                    -Value $null
            }

            $item.Status='CONSUMED'
            $item.ConsumedAtUtc=[datetime]::UtcNow.ToString('o')
        }
    }

    $null=Save-CredentialLeaseRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CREDENTIAL_LEASE_CONSUMED'
        LeaseId=$LeaseId
        Status='CONSUMED'
    }
}

function Revoke-CredentialLease {
    param([Parameter(Mandatory=$true)][string]$LeaseId)

    $record=Get-CredentialLeaseRecord -LeaseId $LeaseId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='LEASE_NOT_FOUND'
        }
    }

    $records=@(Get-CredentialLeaseRecords)

    foreach ($item in $records) {
        if ($item.LeaseId -eq $LeaseId) {
            $item.Status='REVOKED'
        }
    }

    $null=Save-CredentialLeaseRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='BLOCK'
        Reason='CREDENTIAL_LEASE_REVOKED'
        LeaseId=$LeaseId
        Status='REVOKED'
    }
}

function Reset-CredentialLease {
    $file=Join-Path $PSScriptRoot 'state\records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}