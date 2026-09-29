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

function Get-DelegationIntegrityConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return Convert-ToPlainHashtable $cfg
}

function Get-DelegationIntegrityField {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cfg=Get-DelegationIntegrityConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-DelegationIntegrityRecords {
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

function Save-DelegationIntegrityRecords {
    param([Parameter(Mandatory=$true)]$Records)

    $cfg=Get-DelegationIntegrityConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum delegation integrity record count exceeded.'
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

function Get-DelegationIntegrityRecord {
    param([Parameter(Mandatory=$true)][string]$DelegationId)

    if ([string]::IsNullOrWhiteSpace($DelegationId)) {
        return $null
    }

    $found=@(
        Get-DelegationIntegrityRecords |
        Where-Object { $_.DelegationId -eq $DelegationId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-DelegationIntegrityId {
    return 'DELEG-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function New-DelegationIntegrity {
    param(
        [Parameter(Mandatory=$true)][string]$ParentAuthorityId,
        [Parameter(Mandatory=$true)][string]$ParentWorkerId,
        [Parameter(Mandatory=$true)][string]$ParentTaskId,
        [Parameter(Mandatory=$true)][string]$ChildWorkerId,
        [Parameter(Mandatory=$true)][string]$ChildTaskId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$GrantId,
        [Parameter(Mandatory=$true)][string]$BindingId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [string]$Grant='',
        [string]$FreshnessId='',
        [string]$Nonce='',
        [string]$IntegrityId=''
    )

    $cfg=Get-DelegationIntegrityConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['delegationIntegrityEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_INTEGRITY_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($ParentAuthorityId) -or
        [string]::IsNullOrWhiteSpace($ParentWorkerId) -or
        [string]::IsNullOrWhiteSpace($ParentTaskId) -or
        [string]::IsNullOrWhiteSpace($ChildWorkerId) -or
        [string]::IsNullOrWhiteSpace($ChildTaskId) -or
        [string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId) -or
        [string]::IsNullOrWhiteSpace($ProjectId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($GrantId) -or
        [string]::IsNullOrWhiteSpace($BindingId) -or
        [string]::IsNullOrWhiteSpace($ExecutionId) -or
        [string]::IsNullOrWhiteSpace($Action)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_CONTEXT_INCOMPLETE'
        }
    }

    if ([bool]$cfg['requireParentAuthority']) {

        $workerRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\worker-task-authority\Worker-Task-Authority.ps1'

        if (-not (Test-Path -LiteralPath $workerRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='WORKER_AUTHORITY_RUNTIME_MISSING'
            }
        }

        . $workerRuntime

        try {
            $parent=@(
                Test-WorkerTaskAuthority `
                    -AuthorityId $ParentAuthorityId `
                    -UserId $UserId `
                    -SessionId $SessionId `
                    -GrantId $GrantId `
                    -BindingId $BindingId `
                    -ExecutionId $ExecutionId `
                    -Action $Action `
                    -TenantId $TenantId `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId `
                    -WorkerId $ParentWorkerId `
                    -TaskId $ParentTaskId
            ) | Select-Object -Last 1
        }
        catch {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='PARENT_AUTHORITY_CHECK_FAILED'
            }
        }

        if ($null -eq $parent -or
            $parent.Success -ne $true -or
            $parent.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='PARENT_AUTHORITY_INVALID'
            }
        }
    }

    if ([bool]$cfg['requireSameUser'] -and
        [string]::IsNullOrWhiteSpace($UserId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='USER_BINDING_REQUIRED'
        }
    }

    if ([bool]$cfg['rejectCrossWorkerDelegation'] -and
        $ParentWorkerId -ne $ChildWorkerId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CROSS_WORKER_DELEGATION_BLOCKED'
        }
    }

    $records=@(Get-DelegationIntegrityRecords)

    $existing=@(
        $records |
        Where-Object {
            $_.ParentAuthorityId -eq $ParentAuthorityId -and
            $_.ExecutionId -eq $ExecutionId -and
            $_.ChildWorkerId -eq $ChildWorkerId -and
            $_.ChildTaskId -eq $ChildTaskId
        }
    )

    if ($existing.Count -gt 0) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='PARENT_REUSE_BLOCKED'
        }
    }

    $record=[pscustomobject]@{
        DelegationId=New-DelegationIntegrityId
        ParentAuthorityId=$ParentAuthorityId
        ParentWorkerId=$ParentWorkerId
        ParentTaskId=$ParentTaskId
        ChildWorkerId=$ChildWorkerId
        ChildTaskId=$ChildTaskId
        UserId=$UserId
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        FreshnessId=$FreshnessId
        IntegrityId=$IntegrityId
        CreatedAtUtc=[datetime]::UtcNow.ToString('o')
        Status='ACTIVE'
    }

    $records += $record

    $null=Save-DelegationIntegrityRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='DELEGATION_CREATED'
        DelegationId=$record.DelegationId
        ParentAuthorityId=$ParentAuthorityId
        ChildWorkerId=$ChildWorkerId
        ChildTaskId=$ChildTaskId
    }
}

function Test-DelegationIntegrity {
    param(
        [Parameter(Mandatory=$true)][string]$DelegationId,
        [Parameter(Mandatory=$true)][string]$ParentAuthorityId,
        [Parameter(Mandatory=$true)][string]$ChildWorkerId,
        [Parameter(Mandatory=$true)][string]$ChildTaskId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$GrantId,
        [Parameter(Mandatory=$true)][string]$BindingId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$Action
    )

    $cfg=Get-DelegationIntegrityConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['delegationIntegrityEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_INTEGRITY_DISABLED'
        }
    }

    $record=Get-DelegationIntegrityRecord `
        -DelegationId $DelegationId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_INACTIVE'
        }
    }

    if ([string]$record.ParentAuthorityId -ne $ParentAuthorityId -or
        [string]$record.ChildWorkerId -ne $ChildWorkerId -or
        [string]$record.ChildTaskId -ne $ChildTaskId -or
        [string]$record.UserId -ne $UserId -or
        [string]$record.TenantId -ne $TenantId -or
        [string]$record.ClientId -ne $ClientId -or
        [string]$record.ProjectId -ne $ProjectId -or
        [string]$record.SessionId -ne $SessionId -or
        [string]$record.GrantId -ne $GrantId -or
        [string]$record.BindingId -ne $BindingId -or
        [string]$record.ExecutionId -ne $ExecutionId -or
        [string]$record.Action -ne $Action) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_CONTEXT_MISMATCH'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='DELEGATION_VALID'
        DelegationId=$DelegationId
        ParentAuthorityId=$ParentAuthorityId
        ChildWorkerId=$ChildWorkerId
        ChildTaskId=$ChildTaskId
    }
}

function Invalidate-DelegationIntegrity {
    param([Parameter(Mandatory=$true)][string]$DelegationId)

    $record=Get-DelegationIntegrityRecord `
        -DelegationId $DelegationId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='DELEGATION_NOT_FOUND'
        }
    }

    $records=@(Get-DelegationIntegrityRecords)

    foreach ($item in $records) {
        if ($item.DelegationId -eq $DelegationId) {
            $item.Status='INVALIDATED'
        }
    }

    $null=Save-DelegationIntegrityRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='BLOCK'
        Reason='DELEGATION_INVALIDATED'
        DelegationId=$DelegationId
        Status='INVALIDATED'
    }
}

function Reset-DelegationIntegrity {
    $file=Join-Path $PSScriptRoot 'state\records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}