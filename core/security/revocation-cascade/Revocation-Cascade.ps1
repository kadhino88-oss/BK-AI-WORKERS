Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

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

function Get-RevocationCascadeConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

    return Convert-ToPlainHashtable $cfg
}

function Get-RevocationCascadeField {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $cfg=Get-RevocationCascadeConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-RevocationCascadeRecords {
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

function Save-RevocationCascadeRecords {
    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $cfg=Get-RevocationCascadeConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum revocation record count exceeded.'
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state/records.json'

    ConvertTo-Json -InputObject $wrapper -Depth 30 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}

function Get-RevocationCascadeRecord {
    param(
        [Parameter(Mandatory=$true)]
        [string]$RecordId
    )

    if ([string]::IsNullOrWhiteSpace($RecordId)) {
        return $null
    }

    $found=@(
        Get-RevocationCascadeRecords |
        Where-Object { $_.RecordId -eq $RecordId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-RevocationRecordId {
    return 'REVOKE-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function Test-RevocationCascade {
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

        [string]$ProjectId='',

        [string]$TokenId='',

        [string]$Token=''
    )

    $cfg=Get-RevocationCascadeConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['revocationCascadeEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='REVOCATION_CASCADE_DISABLED'
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
            Reason='REVOCATION_CONTEXT_INCOMPLETE'
        }
    }

    # --------------------------------------------------------
    # IDENTITY
    # --------------------------------------------------------

    $identityRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/identity-auth/runtime.ps1')

    if (-not (Test-Path -LiteralPath $identityRuntime)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='IDENTITY_RUNTIME_MISSING'
        }
    }

    . $identityRuntime

    if ([bool]$cfg['requireIdentityState']) {

        try {
            $identitySession=@(
                Test-IdentitySession `
                    -SessionId $SessionId `
                    -TenantId $TenantId `
                    -ClientId $ClientId
            ) | Select-Object -Last 1
        }
        catch {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='IDENTITY_SESSION_CHECK_FAILED'
            }
        }

        if ($null -eq $identitySession -or
            $identitySession.Success -ne $true) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='SESSION_REVOKED_OR_INVALID'
            }
        }
    }

    # --------------------------------------------------------
    # TOKEN, SI FOURNI
    # --------------------------------------------------------

    if (-not [string]::IsNullOrWhiteSpace($TokenId) -or
        -not [string]::IsNullOrWhiteSpace($Token)) {

        if ([string]::IsNullOrWhiteSpace($TokenId) -or
            [string]::IsNullOrWhiteSpace($Token)) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='TOKEN_CONTEXT_INCOMPLETE'
            }
        }

        $tokenRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/session-token-security/runtime.ps1')

        if (-not (Test-Path -LiteralPath $tokenRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='TOKEN_RUNTIME_MISSING'
            }
        }

        . $tokenRuntime

        try {
            $tokenResult=@(
                Test-SessionSecurityToken `
                    -TokenId $TokenId `
                    -Token $Token `
                    -SessionId $SessionId `
                    -UserId $UserId `
                    -TenantId $TenantId `
                    -ClientId $ClientId
            ) | Select-Object -Last 1
        }
        catch {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='TOKEN_CHECK_FAILED'
            }
        }

        if ($null -eq $tokenResult -or
            $tokenResult.Success -ne $true) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='TOKEN_REVOKED_OR_INVALID'
            }
        }
    }

    # --------------------------------------------------------
    # GRANT
    # --------------------------------------------------------

    $grantRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-grant/Authorization-Grant.ps1')

    if (-not (Test-Path -LiteralPath $grantRuntime)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GRANT_RUNTIME_MISSING'
        }
    }

    . $grantRuntime

    if ([bool]$cfg['requireGrantState']) {

        try {
            $grantResult=@(
                Test-AuthorizationGrant `
                    -GrantId $GrantId `
                    -Grant $Grant `
                    -UserId $UserId `
                    -SessionId $SessionId `
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
                Reason='GRANT_CHECK_FAILED'
            }
        }

        if ($null -eq $grantResult -or
            $grantResult.Success -ne $true -or
            $grantResult.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='GRANT_REVOKED_OR_INVALID'
            }
        }
    }

    # --------------------------------------------------------
    # EXECUTION BINDING
    # --------------------------------------------------------

    $executionRuntime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-grant-execution/Authorization-Grant-Execution.ps1')

    if (-not (Test-Path -LiteralPath $executionRuntime)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='EXECUTION_BINDING_RUNTIME_MISSING'
        }
    }

    . $executionRuntime

    if ([bool]$cfg['requireExecutionBindingState']) {

        try {
            $executionResult=@(
                Test-ExecutionGrantBinding `
                    -BindingId $BindingId `
                    -ExecutionId $ExecutionId `
                    -UserId $UserId `
                    -SessionId $SessionId `
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
                Reason='EXECUTION_BINDING_CHECK_FAILED'
            }
        }

        if ($null -eq $executionResult -or
            $executionResult.Success -ne $true -or
            $executionResult.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='EXECUTION_BINDING_REVOKED_OR_INVALID'
            }
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='REVOCATION_CHAIN_VALID'
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

function Register-RevocationEvent {
    param(
        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$SessionId,

        [string]$GrantId='',

        [string]$BindingId='',

        [string]$ExecutionId='',

        [Parameter(Mandatory=$true)]
        [string]$Reason
    )

    $record=[pscustomobject]@{
        RecordId=New-RevocationRecordId
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Reason=$Reason
        CreatedAtUtc=[datetime]::UtcNow.ToString('o')
        Status='RECORDED'
    }

    $records=@(Get-RevocationCascadeRecords)
    $records += $record

    $null=Save-RevocationCascadeRecords -Records $records

    return $record
}

function Reset-RevocationCascade {
    $file=Join-Path $PSScriptRoot 'state/records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}