Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

function Convert-ToPlainHashtable {
    param([Parameter(Mandatory=$true)]$InputObject)

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

function Get-GrantExecutionConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

    return Convert-ToPlainHashtable $cfg
}

function Get-GrantExecutionField {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $cfg=Get-GrantExecutionConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-GrantExecutionBindings {
    $file=Join-Path $PSScriptRoot 'state\bindings.json'

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

function Save-GrantExecutionBindings {
    param(
        [Parameter(Mandatory=$true)]
        $Bindings
    )

    $cfg=Get-GrantExecutionConfig
    $items=@($Bindings)

    if ($items.Count -gt [int]$cfg['maxBindings']) {
        throw 'Maximum execution binding count exceeded.'
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state\bindings.json'

    ConvertTo-Json -InputObject $wrapper -Depth 30 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}

function Get-GrantExecutionBinding {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BindingId
    )

    if ([string]::IsNullOrWhiteSpace($BindingId)) {
        return $null
    }

    $found=@(
        Get-GrantExecutionBindings |
        Where-Object { $_.BindingId -eq $BindingId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function Get-GrantExecutionByGrantId {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GrantId
    )

    if ([string]::IsNullOrWhiteSpace($GrantId)) {
        return @()
    }

    return @(
        Get-GrantExecutionBindings |
        Where-Object { $_.GrantId -eq $GrantId }
    )
}

function New-ExecutionBindingId {
    return 'GEB-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function New-ExecutionGrantBinding {
    param(
        [Parameter(Mandatory=$true)][string]$GrantId,
        [Parameter(Mandatory=$true)][string]$Grant,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ProjectId=''
    )

    $cfg=Get-GrantExecutionConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['executionBindingEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='EXECUTION_BINDING_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($GrantId) -or
        [string]::IsNullOrWhiteSpace($Grant) -or
        [string]::IsNullOrWhiteSpace($ExecutionId) -or
        [string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($Action) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId)) {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='EXECUTION_BINDING_CONTEXT_INCOMPLETE'
        }
    }

    $grantRuntime=Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        'authorization-grant\Authorization-Grant.ps1'

    if (-not (Test-Path -LiteralPath $grantRuntime)) {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_GRANT_RUNTIME_MISSING'
        }
    }

    . $grantRuntime

    try {
        $grantCheck=Test-AuthorizationGrant `
            -GrantId $GrantId `
            -Grant $Grant `
            -UserId $UserId `
            -SessionId $SessionId `
            -Action $Action `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId
    }
    catch {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_GRANT_VALIDATION_ERROR'
        }
    }

    if ($null -eq $grantCheck -or
        $grantCheck.Success -ne $true -or
        $grantCheck.Decision -ne 'ALLOW') {

        return [pscustomobject]@{
            Success=$false
            Status='BLOCKED'
            Reason='AUTHORIZATION_GRANT_NOT_VALID'
        }
    }

    $existingByGrant=@(
        Get-GrantExecutionByGrantId -GrantId $GrantId
    )

    if ([bool]$cfg['singleExecutionPerGrant'] -and
        $existingByGrant.Count -gt 0) {

        return [pscustomobject]@{
            Success=$false
            Status='DUPLICATE'
            Reason='GRANT_ALREADY_BOUND_TO_EXECUTION'
            GrantId=$GrantId
            ExistingExecutionId=$existingByGrant[0].ExecutionId
        }
    }

    $existingExecution=@(
        Get-GrantExecutionBindings |
        Where-Object { $_.ExecutionId -eq $ExecutionId }
    )

    if ([bool]$cfg['rejectDuplicateExecutionBinding'] -and
        $existingExecution.Count -gt 0) {

        return [pscustomobject]@{
            Success=$false
            Status='DUPLICATE'
            Reason='EXECUTION_ALREADY_BOUND'
            ExecutionId=$ExecutionId
        }
    }

    $record=[pscustomobject]@{
        BindingId=New-ExecutionBindingId
        GrantId=$GrantId
        ExecutionId=$ExecutionId
        AuthorizationId=$grantCheck.AuthorizationId
        UserId=$UserId
        SessionId=$SessionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        Status='BOUND'
        BoundAtUtc=[datetime]::UtcNow.ToString('o')
        CompletedAtUtc=$null
    }

    $items=@(Get-GrantExecutionBindings)
    $items += $record

    $null=Save-GrantExecutionBindings -Bindings $items

    return [pscustomobject]@{
        Success=$true
        Status='BOUND'
        Reason='GRANT_BOUND_TO_EXECUTION'
        BindingId=$record.BindingId
        GrantId=$GrantId
        ExecutionId=$ExecutionId
        AuthorizationId=$record.AuthorizationId
        UserId=$UserId
        SessionId=$SessionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
    }
}

function Test-ExecutionGrantBinding {
    param(
        [Parameter(Mandatory=$true)][string]$BindingId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ProjectId=''
    )

    $record=Get-GrantExecutionBinding -BindingId $BindingId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='EXECUTION_BINDING_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'BOUND') {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='EXECUTION_BINDING_NOT_ACTIVE'
        }
    }

    if ($record.ExecutionId -ne $ExecutionId -or
        $record.UserId -ne $UserId -or
        $record.SessionId -ne $SessionId -or
        $record.Action -ne $Action -or
        $record.TenantId -ne $TenantId -or
        $record.ClientId -ne $ClientId -or
        $record.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='EXECUTION_BINDING_CONTEXT_MISMATCH'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='EXECUTION_BINDING_VALID'
        BindingId=$record.BindingId
        GrantId=$record.GrantId
        ExecutionId=$record.ExecutionId
        AuthorizationId=$record.AuthorizationId
        UserId=$record.UserId
        SessionId=$record.SessionId
        Action=$record.Action
        TenantId=$record.TenantId
        ClientId=$record.ClientId
        ProjectId=$record.ProjectId
    }
}

function Complete-ExecutionGrantBinding {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BindingId
    )

    $items=@(Get-GrantExecutionBindings)

    $found=@(
        $items |
        Where-Object { $_.BindingId -eq $BindingId }
    )

    if ($found.Count -eq 0) {

        return [pscustomobject]@{
            Success=$false
            Status='NOT_FOUND'
            Reason='EXECUTION_BINDING_NOT_FOUND'
        }
    }

    $updated=@()

    foreach ($item in $items) {

        if ($item.BindingId -eq $BindingId) {

            $copy=$item | Select-Object *

            if (-not ($copy.PSObject.Properties.Name -contains 'CompletedAtUtc')) {
                $copy | Add-Member -MemberType NoteProperty `
                    -Name 'CompletedAtUtc' `
                    -Value $null `
                    -Force
            }

            if (-not ($copy.PSObject.Properties.Name -contains 'Status')) {
                $copy | Add-Member -MemberType NoteProperty `
                    -Name 'Status' `
                    -Value 'BOUND' `
                    -Force
            }

            $copy.Status='COMPLETED'
            $copy.CompletedAtUtc=[datetime]::UtcNow.ToString('o')

            $updated += $copy
        }
        else {
            $updated += $item
        }
    }

    $null=Save-GrantExecutionBindings -Bindings $updated

    return [pscustomobject]@{
        Success=$true
        Status='COMPLETED'
        Reason='EXECUTION_GRANT_BINDING_COMPLETED'
        BindingId=$BindingId
    }
}

function Reset-GrantExecutionBindings {
    $file=Join-Path $PSScriptRoot 'state\bindings.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}