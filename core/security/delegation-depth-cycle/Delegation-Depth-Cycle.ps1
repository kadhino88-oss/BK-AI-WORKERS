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

function Get-DelegationDepthCycleConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

    return Convert-ToPlainHashtable $cfg
}

function Get-DelegationDepthCycleField {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cfg=Get-DelegationDepthCycleConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-DelegationDepthCycleRecords {
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

function Save-DelegationDepthCycleRecords {
    param([Parameter(Mandatory=$true)]$Records)

    $cfg=Get-DelegationDepthCycleConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum delegation depth/cycle record count exceeded.'
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

function Get-DelegationDepthCycleRecord {
    param([Parameter(Mandatory=$true)][string]$GuardId)

    if ([string]::IsNullOrWhiteSpace($GuardId)) {
        return $null
    }

    $found=@(
        Get-DelegationDepthCycleRecords |
        Where-Object { $_.GuardId -eq $GuardId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-DelegationDepthCycleId {
    return 'DGC-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function Get-DelegationSourceRuntime {
    $runtime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\delegation-integrity\Delegation-Integrity.ps1'

    if (-not (Test-Path -LiteralPath $runtime)) {
        throw "Delegation integrity runtime missing: $runtime"
    }

    . $runtime
}

function Get-DelegationParentRecord {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ParentDelegationId
    )

    Get-DelegationSourceRuntime

    return Get-DelegationIntegrityRecord `
        -DelegationId $ParentDelegationId
}

function Get-DelegationChainIds {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ParentDelegationId
    )

    $chain=@()
    $visited=@{}
    $cursor=$ParentDelegationId

    while (-not [string]::IsNullOrWhiteSpace($cursor)) {

        if ($visited.ContainsKey($cursor)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='DELEGATION_CYCLE_DETECTED'
                Chain=@($chain)
            }
        }

        $visited[$cursor]=$true
        $chain += $cursor

        $record=Get-DelegationParentRecord `
            -ParentDelegationId $cursor

        if ($null -eq $record) {
            break
        }

        $propertyNames=@(
            $record.PSObject.Properties |
            ForEach-Object { $_.Name }
        )

        if ($propertyNames -contains 'ParentDelegationId') {
            $cursor=[string]$record.ParentDelegationId
        }
        else {
            $cursor=''
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='CHAIN_RESOLVED'
        Chain=@($chain)
    }
}

function Test-DelegationDepthCycle {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ParentDelegationId,

        [Parameter(Mandatory=$true)]
        [string]$ChildDelegationId,

        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [string]$ClientId,

        [Parameter(Mandatory=$true)]
        [string]$ProjectId,

        [Parameter(Mandatory=$true)]
        [int]$RequestedDepth
    )

    $cfg=Get-DelegationDepthCycleConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['delegationDepthCycleGuardEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DEPTH_CYCLE_GUARD_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($ParentDelegationId) -or
        [string]::IsNullOrWhiteSpace($ChildDelegationId) -or
        [string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId) -or
        [string]::IsNullOrWhiteSpace($ProjectId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DEPTH_CYCLE_CONTEXT_INCOMPLETE'
        }
    }

    if ($ParentDelegationId -eq $ChildDelegationId) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='SELF_DELEGATION_CYCLE'
        }
    }

    if ([bool]$cfg['maxDepthEnabled'] -and
        $RequestedDepth -gt [int]$cfg['maxDelegationDepth']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='MAX_DELEGATION_DEPTH_EXCEEDED'
        }
    }

    # --------------------------------------------------------
    # SOURCE DE VERITE : 8A-13
    # --------------------------------------------------------

    $parent=Get-DelegationParentRecord `
        -ParentDelegationId $ParentDelegationId

    if ($null -eq $parent) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='PARENT_DELEGATION_NOT_FOUND'
        }
    }

    $propertyNames=@(
        $parent.PSObject.Properties |
        ForEach-Object { $_.Name }
    )

    $requiredParentFields=@(
        'UserId',
        'TenantId',
        'ClientId',
        'ProjectId',
        'Status'
    )

    foreach ($field in $requiredParentFields) {

        if ($propertyNames -notcontains $field) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason="PARENT_AUTHORITY_FIELD_MISSING_$field"
            }
        }
    }

    if ([string]$parent.Status -ne 'ACTIVE') {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='PARENT_DELEGATION_INACTIVE'
        }
    }

    if ([bool]$cfg['requireSameUser'] -and
        [string]$parent.UserId -ne $UserId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_USER_MISMATCH'
        }
    }

    if ([bool]$cfg['requireSameTenant'] -and
        [string]$parent.TenantId -ne $TenantId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_TENANT_MISMATCH'
        }
    }

    if ([bool]$cfg['requireSameClient'] -and
        [string]$parent.ClientId -ne $ClientId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_CLIENT_MISMATCH'
        }
    }

    if ([bool]$cfg['requireSameProject'] -and
        [string]$parent.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_PROJECT_MISMATCH'
        }
    }

    $chainResult=Get-DelegationChainIds `
        -ParentDelegationId $ParentDelegationId

    if ($chainResult.Success -ne $true) {
        return $chainResult
    }

    $chain=@($chainResult.Chain)

    if ($chain -contains $ChildDelegationId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='ANCESTOR_REUSE_BLOCKED'
        }
    }

    $records=@(Get-DelegationDepthCycleRecords)

    $duplicate=@(
        $records |
        Where-Object {
            $_.ParentDelegationId -eq $ParentDelegationId -and
            $_.ChildDelegationId -eq $ChildDelegationId -and
            $_.Status -eq 'ACTIVE'
        }
    )

    if ($duplicate.Count -gt 0) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DUPLICATE_DELEGATION_BLOCKED'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='DEPTH_CYCLE_CHECK_VALID'
        Depth=$RequestedDepth
        ChainLength=$chain.Count
        ParentUserId=[string]$parent.UserId
        ParentTenantId=[string]$parent.TenantId
        ParentClientId=[string]$parent.ClientId
        ParentProjectId=[string]$parent.ProjectId
    }
}

function New-DelegationDepthCycleGuard {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ParentDelegationId,

        [Parameter(Mandatory=$true)]
        [string]$ChildDelegationId,

        [Parameter(Mandatory=$true)]
        [string]$UserId,

        [Parameter(Mandatory=$true)]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [string]$ClientId,

        [Parameter(Mandatory=$true)]
        [string]$ProjectId,

        [Parameter(Mandatory=$true)]
        [int]$Depth
    )

    $check=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId $ChildDelegationId `
        -UserId $UserId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -RequestedDepth $Depth

    if ($check.Success -ne $true) {
        return $check
    }

    $record=[pscustomobject]@{
        GuardId=New-DelegationDepthCycleId
        ParentDelegationId=$ParentDelegationId
        ChildDelegationId=$ChildDelegationId
        UserId=$UserId
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        Depth=$Depth
        ChainLength=[int]$check.ChainLength
        CreatedAtUtc=[datetime]::UtcNow.ToString('o')
        Status='ACTIVE'
    }

    $records=@(Get-DelegationDepthCycleRecords)
    $records += $record

    $null=Save-DelegationDepthCycleRecords `
        -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='DEPTH_CYCLE_GUARD_CREATED'
        GuardId=$record.GuardId
        ParentDelegationId=$ParentDelegationId
        ChildDelegationId=$ChildDelegationId
        Depth=$Depth
    }
}

function Invalidate-DelegationDepthCycleGuard {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GuardId
    )

    $record=Get-DelegationDepthCycleRecord `
        -GuardId $GuardId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GUARD_NOT_FOUND'
        }
    }

    $records=@(Get-DelegationDepthCycleRecords)

    foreach ($item in $records) {

        if ($item.GuardId -eq $GuardId) {
            $item.Status='INVALIDATED'
        }
    }

    $null=Save-DelegationDepthCycleRecords `
        -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='BLOCK'
        Reason='GUARD_INVALIDATED'
        GuardId=$GuardId
        Status='INVALIDATED'
    }
}

function Test-DelegationDepthCycleGuardState {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GuardId
    )

    $record=Get-DelegationDepthCycleRecord `
        -GuardId $GuardId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GUARD_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='GUARD_INACTIVE'
            Status=$record.Status
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='GUARD_ACTIVE'
        GuardId=$GuardId
    }
}

function Reset-DelegationDepthCycle {
    $file=Join-Path $PSScriptRoot 'state\records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}