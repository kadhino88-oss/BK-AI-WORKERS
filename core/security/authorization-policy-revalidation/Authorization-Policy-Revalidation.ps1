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

function Get-AuthorizationPolicyRevalidationConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return Convert-ToPlainHashtable $cfg
}

function Get-AuthorizationPolicyRevalidationField {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cfg=Get-AuthorizationPolicyRevalidationConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-AuthorizationPolicyRevalidationRecords {
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

function Save-AuthorizationPolicyRevalidationRecords {
    param([Parameter(Mandatory=$true)]$Records)

    $cfg=Get-AuthorizationPolicyRevalidationConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum policy revalidation record count exceeded.'
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

function Get-SHA256PolicyHash {
    param([Parameter(Mandatory=$true)][string]$CanonicalValue)

    $sha=[System.Security.Cryptography.SHA256]::Create()

    try {
        $bytes=[System.Text.Encoding]::UTF8.GetBytes($CanonicalValue)
        $hash=$sha.ComputeHash($bytes)

        return (-join ($hash | ForEach-Object {
            $_.ToString('x2')
        })).ToUpperInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-AuthorizationPolicyRecord {
    param([Parameter(Mandatory=$true)][string]$PolicyRecordId)

    if ([string]::IsNullOrWhiteSpace($PolicyRecordId)) {
        return $null
    }

    $found=@(
        Get-AuthorizationPolicyRevalidationRecords |
        Where-Object { $_.PolicyRecordId -eq $PolicyRecordId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-AuthorizationPolicyRecordId {
    return 'POLICY-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function Get-CanonicalPolicyContext {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ProjectId=''
    )

    return (
        'UserId=' + $UserId + "`n" +
        'SessionId=' + $SessionId + "`n" +
        'Action=' + $Action + "`n" +
        'TenantId=' + $TenantId + "`n" +
        'ClientId=' + $ClientId + "`n" +
        'ProjectId=' + $ProjectId
    )
}

function New-AuthorizationPolicySnapshot {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ProjectId=''
    )

    $cfg=Get-AuthorizationPolicyRevalidationConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['policyRevalidationEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='POLICY_REVALIDATION_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($Action) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='POLICY_CONTEXT_INCOMPLETE'
        }
    }

    $gatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'

    if (-not (Test-Path -LiteralPath $gatewayRuntime)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHORIZATION_GATEWAY_RUNTIME_MISSING'
        }
    }

    . $gatewayRuntime

    try {
        $decision=@(
            Authorize-Request `
                -UserId $UserId `
                -SessionId $SessionId `
                -Action $Action `
                -TenantId $TenantId `
                -ClientId $ClientId `
                -ProjectId $ProjectId
        ) |
            Where-Object { $_.DecisionId } |
            Select-Object -Last 1
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CURRENT_AUTHORIZATION_FAILED'
        }
    }

    if ($null -eq $decision -or
        $decision.Success -ne $true -or
        $decision.Decision -ne 'ALLOW') {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CURRENT_RBAC_DECISION_BLOCKED'
        }
    }

    $canonical=Get-CanonicalPolicyContext `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    $contextHash=Get-SHA256PolicyHash -CanonicalValue $canonical

    $record=[pscustomobject]@{
        PolicyRecordId=New-AuthorizationPolicyRecordId
        AuthorizationDecisionId=[string]$decision.DecisionId
        ContextHash=$contextHash
        UserId=$UserId
        SessionId=$SessionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        Status='ACTIVE'
        Decision='ALLOW'
        CreatedAtUtc=[datetime]::UtcNow.ToString('o')
        LastVerifiedAtUtc=$null
    }

    $records=@(Get-AuthorizationPolicyRevalidationRecords)
    $records += $record

    $null=Save-AuthorizationPolicyRevalidationRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        PolicyRecordId=$record.PolicyRecordId
        AuthorizationDecisionId=$record.AuthorizationDecisionId
        ContextHash=$record.ContextHash
    }
}

function Test-AuthorizationPolicyRevalidation {
    param(
        [Parameter(Mandatory=$true)][string]$PolicyRecordId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ProjectId=''
    )

    $cfg=Get-AuthorizationPolicyRevalidationConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['policyRevalidationEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='POLICY_REVALIDATION_DISABLED'
        }
    }

    $record=Get-AuthorizationPolicyRecord `
        -PolicyRecordId $PolicyRecordId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='POLICY_RECORD_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='POLICY_RECORD_INACTIVE'
        }
    }

    $canonical=Get-CanonicalPolicyContext `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    $contextHash=Get-SHA256PolicyHash -CanonicalValue $canonical

    if ($contextHash -ne [string]$record.ContextHash) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='POLICY_CONTEXT_HASH_MISMATCH'
        }
    }

    $identityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
    $gatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'

    if (-not (Test-Path -LiteralPath $identityRuntime) -or
        -not (Test-Path -LiteralPath $gatewayRuntime)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='REVALIDATION_RUNTIME_MISSING'
        }
    }

    . $identityRuntime
    . $gatewayRuntime

    try {
        $sessionCheck=@(
            Test-IdentitySession `
                -SessionId $SessionId `
                -TenantId $TenantId `
                -ClientId $ClientId
        ) |
            Select-Object -Last 1
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='SESSION_REVALIDATION_FAILED'
        }
    }

    if ($null -eq $sessionCheck -or
        $sessionCheck.Success -ne $true) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='SESSION_REVOKED_OR_INVALID'
        }
    }

    try {
        $currentDecision=@(
            Authorize-Request `
                -UserId $UserId `
                -SessionId $SessionId `
                -Action $Action `
                -TenantId $TenantId `
                -ClientId $ClientId `
                -ProjectId $ProjectId
        ) |
            Where-Object { $_.DecisionId } |
            Select-Object -Last 1
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CURRENT_AUTHORIZATION_CHECK_FAILED'
        }
    }

    if ($null -eq $currentDecision -or
        $currentDecision.Success -ne $true -or
        $currentDecision.Decision -ne 'ALLOW') {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='RBAC_DRIFT_DETECTED'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CURRENT_POLICY_VALID'
        PolicyRecordId=$PolicyRecordId
        CurrentAuthorizationDecisionId=[string]$currentDecision.DecisionId
    }
}

function Invalidate-AuthorizationPolicySnapshot {
    param([Parameter(Mandatory=$true)][string]$PolicyRecordId)

    $record=Get-AuthorizationPolicyRecord `
        -PolicyRecordId $PolicyRecordId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='POLICY_RECORD_NOT_FOUND'
        }
    }

    $records=@(Get-AuthorizationPolicyRevalidationRecords)

    foreach ($item in $records) {
        if ($item.PolicyRecordId -eq $PolicyRecordId) {
            $item.Status='INVALIDATED'
        }
    }

    $null=Save-AuthorizationPolicyRevalidationRecords `
        -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='BLOCK'
        Reason='POLICY_SNAPSHOT_INVALIDATED'
        Status='INVALIDATED'
        PolicyRecordId=$PolicyRecordId
    }
}

function Reset-AuthorizationPolicyRevalidation {
    $file=Join-Path $PSScriptRoot 'state\records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}