Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

# Verrou inter-processus + ecriture atomique de state/records.json (fichier partage par toutes les missions).
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

function Get-WorkerTaskAuthorityConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return Convert-ToPlainHashtable $cfg
}

function Get-WorkerTaskAuthorityField {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cfg=Get-WorkerTaskAuthorityConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-WorkerTaskAuthorityRecords {
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

function Save-WorkerTaskAuthorityRecords {
    param([Parameter(Mandatory=$true)]$Records)

    $cfg=Get-WorkerTaskAuthorityConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum worker/task authority record count exceeded.'
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state/records.json'

    Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 30)

    return $null
}

function Get-WorkerTaskAuthorityRecord {
    param([Parameter(Mandatory=$true)][string]$AuthorityId)

    if ([string]::IsNullOrWhiteSpace($AuthorityId)) {
        return $null
    }

    $found=@(
        Get-WorkerTaskAuthorityRecords |
        Where-Object { $_.AuthorityId -eq $AuthorityId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-WorkerTaskAuthorityId {
    return 'WTA-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function New-WorkerTaskAuthority {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$GrantId,
        [Parameter(Mandatory=$true)][string]$BindingId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [string]$Grant='',
        [string]$FreshnessId='',
        [string]$Nonce='',
        [string]$IntegrityId=''
    )

    $cfg=Get-WorkerTaskAuthorityConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['workerTaskAuthorityEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='WORKER_TASK_AUTHORITY_DISABLED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserId) -or
        [string]::IsNullOrWhiteSpace($SessionId) -or
        [string]::IsNullOrWhiteSpace($GrantId) -or
        [string]::IsNullOrWhiteSpace($BindingId) -or
        [string]::IsNullOrWhiteSpace($ExecutionId) -or
        [string]::IsNullOrWhiteSpace($Action) -or
        [string]::IsNullOrWhiteSpace($TenantId) -or
        [string]::IsNullOrWhiteSpace($ClientId) -or
        [string]::IsNullOrWhiteSpace($ProjectId) -or
        [string]::IsNullOrWhiteSpace($WorkerId) -or
        [string]::IsNullOrWhiteSpace($TaskId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='WORKER_TASK_CONTEXT_INCOMPLETE'
        }
    }

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

        $check=@(
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

        if ($null -eq $check -or
            $check.Success -ne $true -or
            $check.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='REVOCATION_CHAIN_BLOCKED'
            }
        }
    }

    if ([bool]$cfg['requireFreshnessValidation']) {

        $runtime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-freshness/Authorization-Freshness.ps1')

        if (-not (Test-Path -LiteralPath $runtime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_RUNTIME_MISSING'
            }
        }

        . $runtime

        if ([string]::IsNullOrWhiteSpace($FreshnessId) -or
            [string]::IsNullOrWhiteSpace($Nonce)) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_PROOF_MISSING'
            }
        }

        $check=@(
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

        if ($null -eq $check -or
            $check.Success -ne $true -or
            $check.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='FRESHNESS_BLOCKED'
            }
        }
    }

    if ([bool]$cfg['requireContextIntegrity']) {

        $runtime=(Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) 'core/security/authorization-context-integrity/Authorization-Context-Integrity.ps1')

        if (-not (Test-Path -LiteralPath $runtime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='CONTEXT_INTEGRITY_RUNTIME_MISSING'
            }
        }

        . $runtime

        if ([string]::IsNullOrWhiteSpace($IntegrityId)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='INTEGRITY_PROOF_MISSING'
            }
        }

        $check=@(
            Test-AuthorizationContextIntegrity `
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
        ) | Select-Object -Last 1

        if ($null -eq $check -or
            $check.Success -ne $true -or
            $check.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='CONTEXT_INTEGRITY_BLOCKED'
            }
        }
    }

    $record=[pscustomobject]@{
        AuthorityId=New-WorkerTaskAuthorityId
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        WorkerId=$WorkerId
        TaskId=$TaskId
        FreshnessId=$FreshnessId
        IntegrityId=$IntegrityId
        CreatedAtUtc=[datetime]::UtcNow.ToString('o')
        Status='ACTIVE'
    }

    $null=Invoke-BKStateLocked {
        $records=@(Get-WorkerTaskAuthorityRecords)
        $records += $record

        $null=Save-WorkerTaskAuthorityRecords -Records $records
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='WORKER_TASK_AUTHORITY_CREATED'
        AuthorityId=$record.AuthorityId
        WorkerId=$WorkerId
        TaskId=$TaskId
    }
}

function Test-WorkerTaskAuthority {
    param(
        [Parameter(Mandatory=$true)][string]$AuthorityId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$GrantId,
        [Parameter(Mandatory=$true)][string]$BindingId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$TaskId
    )

    $cfg=Get-WorkerTaskAuthorityConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['workerTaskAuthorityEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='WORKER_TASK_AUTHORITY_DISABLED'
        }
    }

    $record=Get-WorkerTaskAuthorityRecord `
        -AuthorityId $AuthorityId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHORITY_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHORITY_INACTIVE'
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
            Reason='AUTHORIZATION_CONTEXT_MISMATCH'
        }
    }

    if ([string]$record.WorkerId -ne $WorkerId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='WORKER_SUBSTITUTION_BLOCKED'
        }
    }

    if ([string]$record.TaskId -ne $TaskId) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='TASK_SUBSTITUTION_BLOCKED'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='WORKER_TASK_AUTHORITY_VALID'
        AuthorityId=$AuthorityId
        WorkerId=$WorkerId
        TaskId=$TaskId
    }
}

function Invalidate-WorkerTaskAuthority {
    param([Parameter(Mandatory=$true)][string]$AuthorityId)

    # Lecture (existence + liste) -> modification -> ecriture dans le MEME bloc verrouille.
    # Un "return" dans le bloc sort du bloc : la fonction renvoie la sortie du bloc.
    return (Invoke-BKStateLocked {
        $record=Get-WorkerTaskAuthorityRecord `
            -AuthorityId $AuthorityId

        if ($null -eq $record) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='AUTHORITY_NOT_FOUND'
            }
        }

        $records=@(Get-WorkerTaskAuthorityRecords)

        foreach ($item in $records) {
            if ($item.AuthorityId -eq $AuthorityId) {
                $item.Status='INVALIDATED'
            }
        }

        $null=Save-WorkerTaskAuthorityRecords -Records $records

        return [pscustomobject]@{
            Success=$true
            Decision='BLOCK'
            Reason='AUTHORITY_INVALIDATED'
            AuthorityId=$AuthorityId
            Status='INVALIDATED'
        }
    })
}

function Reset-WorkerTaskAuthority {
    $file=Join-Path $PSScriptRoot 'state/records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    # Verrouille : la remise a zero ne peut pas s'intercaler au milieu d'une lecture->ecriture d'une autre mission.
    $null=Invoke-BKStateLocked {
        Write-BKStateFileAtomic -Path $file -Content (ConvertTo-Json -InputObject $wrapper -Depth 10)
    }

    return $null
}