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

function Get-PrivilegeBoundaryConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    return Convert-ToPlainHashtable $cfg
}

function Get-PrivilegeBoundaryField {
    param([Parameter(Mandatory=$true)][string]$Name)

    $cfg=Get-PrivilegeBoundaryConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-PrivilegeBoundaryRecords {
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

function Save-PrivilegeBoundaryRecords {
    param([Parameter(Mandatory=$true)]$Records)

    $cfg=Get-PrivilegeBoundaryConfig
    $items=@($Records)

    if ($items.Count -gt [int]$cfg['maxRecords']) {
        throw 'Maximum privilege boundary record count exceeded.'
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

function Get-PrivilegeBoundaryRecord {
    param([Parameter(Mandatory=$true)][string]$BoundaryId)

    if ([string]::IsNullOrWhiteSpace($BoundaryId)) {
        return $null
    }

    $found=@(
        Get-PrivilegeBoundaryRecords |
        Where-Object { $_.BoundaryId -eq $BoundaryId }
    )

    if ($found.Count -eq 0) {
        return $null
    }

    return $found[0]
}

function New-PrivilegeBoundaryId {
    return 'BOUNDARY-' + [guid]::NewGuid().ToString('N').ToUpperInvariant()
}

function Get-PrivilegeScopeDepth {
    param([Parameter(Mandatory=$true)][string]$ScopeType)

    switch ($ScopeType.ToUpperInvariant()) {
        'KADER'   { return 0 }
        'TENANT'  { return 1 }
        'CLIENT'  { return 2 }
        'PROJECT' { return 3 }
        'WORKER'  { return 4 }
        'TASK'    { return 5 }
        default   { return -1 }
    }
}

function Resolve-PrivilegeParentScope {
    param(
        [Parameter(Mandatory=$true)][string]$ScopeType,
        [string]$ScopeId='',
        [string]$TenantId='',
        [string]$ClientId='',
        [string]$ProjectId=''
    )

    switch ($ScopeType.ToUpperInvariant()) {

        'KADER' {
            return [pscustomobject]@{
                Success=$true
                ParentScopeType=''
                ParentScopeId=''
            }
        }

        'TENANT' {
            return [pscustomobject]@{
                Success=$true
                ParentScopeType='KADER'
                ParentScopeId='KADER'
            }
        }

        'CLIENT' {
            if ([string]::IsNullOrWhiteSpace($TenantId)) {
                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='CLIENT_PARENT_TENANT_REQUIRED'
                }
            }

            return [pscustomobject]@{
                Success=$true
                ParentScopeType='TENANT'
                ParentScopeId=$TenantId
            }
        }

        'PROJECT' {
            if ([string]::IsNullOrWhiteSpace($ClientId)) {
                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='PROJECT_PARENT_CLIENT_REQUIRED'
                }
            }

            return [pscustomobject]@{
                Success=$true
                ParentScopeType='CLIENT'
                ParentScopeId=$ClientId
            }
        }

        'WORKER' {
            if ([string]::IsNullOrWhiteSpace($ProjectId)) {
                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='WORKER_PARENT_PROJECT_REQUIRED'
                }
            }

            return [pscustomobject]@{
                Success=$true
                ParentScopeType='PROJECT'
                ParentScopeId=$ProjectId
            }
        }

        'TASK' {
            if ([string]::IsNullOrWhiteSpace($ProjectId)) {
                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='TASK_PARENT_PROJECT_REQUIRED'
                }
            }

            return [pscustomobject]@{
                Success=$true
                ParentScopeType='PROJECT'
                ParentScopeId=$ProjectId
            }
        }

        default {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='UNKNOWN_SCOPE_TYPE'
            }
        }
    }
}

function Test-PrivilegeScopeDefinition {
    param(
        [Parameter(Mandatory=$true)][string]$ScopeType,
        [Parameter(Mandatory=$true)][string]$ScopeId,
        [string]$ParentScopeType='',
        [string]$ParentScopeId=''
    )

    $depth=Get-PrivilegeScopeDepth -ScopeType $ScopeType

    if ($depth -lt 0) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='UNKNOWN_SCOPE_TYPE'
        }
    }

    if ($depth -eq 0) {
        if ($ScopeId -ne 'KADER') {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='INVALID_KADER_SCOPE_ID'
            }
        }

        return [pscustomobject]@{
            Success=$true
            Decision='ALLOW'
            Reason='VALID_SCOPE'
        }
    }

    if ([string]::IsNullOrWhiteSpace($ScopeId)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='SCOPE_ID_REQUIRED'
        }
    }

    if ([string]::IsNullOrWhiteSpace($ParentScopeType) -or
        [string]::IsNullOrWhiteSpace($ParentScopeId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='PARENT_SCOPE_REQUIRED'
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='VALID_SCOPE'
    }
}

function Test-PrivilegeScopeRelationship {
    param(
        [Parameter(Mandatory=$true)][string]$AuthorizedScopeType,
        [Parameter(Mandatory=$true)][string]$AuthorizedScopeId,
        [string]$AuthorizedParentScopeType='',
        [string]$AuthorizedParentScopeId='',
        [Parameter(Mandatory=$true)][string]$RequestedScopeType,
        [Parameter(Mandatory=$true)][string]$RequestedScopeId,
        [string]$RequestedParentScopeType='',
        [string]$RequestedParentScopeId=''
    )

    $authorizedDepth=Get-PrivilegeScopeDepth -ScopeType $AuthorizedScopeType
    $requestedDepth=Get-PrivilegeScopeDepth -ScopeType $RequestedScopeType

    if ($authorizedDepth -lt 0 -or $requestedDepth -lt 0) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='UNKNOWN_SCOPE_TYPE'
        }
    }

    if ($authorizedDepth -eq 0) {
        if ($AuthorizedScopeId -ne 'KADER') {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='INVALID_AUTHORIZED_SCOPE'
            }
        }

        return [pscustomobject]@{
            Success=$true
            Decision='ALLOW'
            Reason='KADER_SCOPE_ALLOWS_DESCENDANT'
        }
    }

    if ($requestedDepth -lt $authorizedDepth) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='UPWARD_SCOPE_ESCALATION'
        }
    }

    if ($requestedDepth -eq $authorizedDepth) {
        if ($AuthorizedScopeId -ne $RequestedScopeId) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='SAME_LEVEL_SCOPE_MISMATCH'
            }
        }

        return [pscustomobject]@{
            Success=$true
            Decision='ALLOW'
            Reason='SAME_SCOPE'
        }
    }

    switch ($RequestedScopeType.ToUpperInvariant()) {

        'TENANT' {
            if ($AuthorizedScopeType.ToUpperInvariant() -eq 'KADER') {
                return [pscustomobject]@{
                    Success=$true
                    Decision='ALLOW'
                    Reason='TENANT_WITHIN_KADER'
                }
            }
        }

        'CLIENT' {
            if ($AuthorizedScopeType.ToUpperInvariant() -eq 'TENANT' -and
                $RequestedParentScopeType -eq 'TENANT' -and
                $RequestedParentScopeId -eq $AuthorizedScopeId) {

                return [pscustomobject]@{
                    Success=$true
                    Decision='ALLOW'
                    Reason='CLIENT_WITHIN_TENANT'
                }
            }
        }

        'PROJECT' {

            if ($AuthorizedScopeType.ToUpperInvariant() -eq 'TENANT' -and
                $RequestedParentScopeType -eq 'TENANT' -and
                $RequestedParentScopeId -eq $AuthorizedScopeId) {

                return [pscustomobject]@{
                    Success=$true
                    Decision='ALLOW'
                    Reason='PROJECT_WITHIN_TENANT'
                }
            }

            if ($AuthorizedScopeType.ToUpperInvariant() -eq 'CLIENT' -and
                $RequestedParentScopeType -eq 'CLIENT' -and
                $RequestedParentScopeId -eq $AuthorizedScopeId) {

                return [pscustomobject]@{
                    Success=$true
                    Decision='ALLOW'
                    Reason='PROJECT_WITHIN_CLIENT'
                }
            }
        }

        'WORKER' {
            if ($AuthorizedScopeType.ToUpperInvariant() -eq 'PROJECT' -and
                $RequestedParentScopeType -eq 'PROJECT' -and
                $RequestedParentScopeId -eq $AuthorizedScopeId) {

                return [pscustomobject]@{
                    Success=$true
                    Decision='ALLOW'
                    Reason='WORKER_WITHIN_PROJECT'
                }
            }
        }

        'TASK' {

            if ($AuthorizedScopeType.ToUpperInvariant() -eq 'PROJECT' -and
                $RequestedParentScopeType -eq 'PROJECT' -and
                $RequestedParentScopeId -eq $AuthorizedScopeId) {

                return [pscustomobject]@{
                    Success=$true
                    Decision='ALLOW'
                    Reason='TASK_WITHIN_PROJECT'
                }
            }

            if ($AuthorizedScopeType.ToUpperInvariant() -eq 'WORKER' -and
                $RequestedParentScopeType -eq 'WORKER' -and
                $RequestedParentScopeId -eq $AuthorizedScopeId) {

                return [pscustomobject]@{
                    Success=$true
                    Decision='ALLOW'
                    Reason='TASK_WITHIN_WORKER'
                }
            }
        }
    }

    return [pscustomobject]@{
        Success=$false
        Decision='BLOCK'
        Reason='UNSUPPORTED_SCOPE_RELATIONSHIP'
    }
}

function New-PrivilegeBoundary {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$GrantId,
        [Parameter(Mandatory=$true)][string]$BindingId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ProjectId='',
        [Parameter(Mandatory=$true)][string]$AuthorizedScopeType,
        [Parameter(Mandatory=$true)][string]$AuthorizedScopeId,
        [string]$AuthorizedParentScopeType='',
        [string]$AuthorizedParentScopeId='',
        [string]$Grant='',
        [string]$FreshnessId='',
        [string]$Nonce='',
        [string]$IntegrityId=''
    )

    $cfg=Get-PrivilegeBoundaryConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['privilegeBoundaryEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='PRIVILEGE_BOUNDARY_DISABLED'
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
        [string]::IsNullOrWhiteSpace($AuthorizedScopeType) -or
        [string]::IsNullOrWhiteSpace($AuthorizedScopeId)) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='PRIVILEGE_CONTEXT_INCOMPLETE'
        }
    }

    # --------------------------------------------------------
    # AUTO-RESOLUTION DU PARENT
    # --------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($AuthorizedParentScopeType) -or
        [string]::IsNullOrWhiteSpace($AuthorizedParentScopeId)) {

        $resolved=Resolve-PrivilegeParentScope `
            -ScopeType $AuthorizedScopeType `
            -ScopeId $AuthorizedScopeId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId

        if ($resolved.Success -ne $true) {
            return $resolved
        }

        $AuthorizedParentScopeType=$resolved.ParentScopeType
        $AuthorizedParentScopeId=$resolved.ParentScopeId
    }

    $scopeCheck=Test-PrivilegeScopeDefinition `
        -ScopeType $AuthorizedScopeType `
        -ScopeId $AuthorizedScopeId `
        -ParentScopeType $AuthorizedParentScopeType `
        -ParentScopeId $AuthorizedParentScopeId

    if ($scopeCheck.Success -ne $true) {
        return $scopeCheck
    }

    # --------------------------------------------------------
    # REVOCATION
    # --------------------------------------------------------

    $revocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'

    if ([bool]$cfg['requireRevocationChain']) {

        if (-not (Test-Path -LiteralPath $revocationRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='REVOCATION_RUNTIME_MISSING'
            }
        }

        . $revocationRuntime

        if ([string]::IsNullOrWhiteSpace($Grant)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='GRANT_REQUIRED'
            }
        }

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

    # --------------------------------------------------------
    # FRESHNESS
    # --------------------------------------------------------

    if ([bool]$cfg['requireFreshnessValidation']) {

        $freshnessRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-freshness\Authorization-Freshness.ps1'

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

    # --------------------------------------------------------
    # CONTEXT INTEGRITY
    # --------------------------------------------------------

    if ([bool]$cfg['requireContextIntegrity']) {

        $integrityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-context-integrity\Authorization-Context-Integrity.ps1'

        if (-not (Test-Path -LiteralPath $integrityRuntime)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='CONTEXT_INTEGRITY_RUNTIME_MISSING'
            }
        }

        . $integrityRuntime

        if ([string]::IsNullOrWhiteSpace($IntegrityId)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='INTEGRITY_PROOF_MISSING'
            }
        }

        $integrityCheck=@(
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
                -FreshnessId $FreshnessId `
                -Nonce $Nonce `
                -Grant $Grant
        ) | Select-Object -Last 1

        if ($null -eq $integrityCheck -or
            $integrityCheck.Success -ne $true -or
            $integrityCheck.Decision -ne 'ALLOW') {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='CONTEXT_INTEGRITY_BLOCKED'
            }
        }
    }

    $record=[pscustomobject]@{
        BoundaryId=New-PrivilegeBoundaryId
        UserId=$UserId
        SessionId=$SessionId
        GrantId=$GrantId
        BindingId=$BindingId
        ExecutionId=$ExecutionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        AuthorizedScopeType=$AuthorizedScopeType
        AuthorizedScopeId=$AuthorizedScopeId
        AuthorizedParentScopeType=$AuthorizedParentScopeType
        AuthorizedParentScopeId=$AuthorizedParentScopeId
        IssuedAtUtc=[datetime]::UtcNow.ToString('o')
        Status='ACTIVE'
    }

    $records=@(Get-PrivilegeBoundaryRecords)
    $records += $record

    $null=Save-PrivilegeBoundaryRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='PRIVILEGE_BOUNDARY_CREATED'
        BoundaryId=$record.BoundaryId
        AuthorizedScopeType=$AuthorizedScopeType
        AuthorizedScopeId=$AuthorizedScopeId
        AuthorizedParentScopeType=$AuthorizedParentScopeType
        AuthorizedParentScopeId=$AuthorizedParentScopeId
    }
}

function Test-PrivilegeBoundary {
    param(
        [Parameter(Mandatory=$true)][string]$BoundaryId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$GrantId,
        [Parameter(Mandatory=$true)][string]$BindingId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$ProjectId='',
        [Parameter(Mandatory=$true)][string]$RequestedScopeType,
        [Parameter(Mandatory=$true)][string]$RequestedScopeId,
        [string]$RequestedParentScopeType='',
        [string]$RequestedParentScopeId=''
    )

    $cfg=Get-PrivilegeBoundaryConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['privilegeBoundaryEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='PRIVILEGE_BOUNDARY_DISABLED'
        }
    }

    $record=Get-PrivilegeBoundaryRecord -BoundaryId $BoundaryId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='BOUNDARY_NOT_FOUND'
        }
    }

    if ($record.Status -ne 'ACTIVE') {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='BOUNDARY_INACTIVE'
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

    if ([string]::IsNullOrWhiteSpace($RequestedParentScopeType) -or
        [string]::IsNullOrWhiteSpace($RequestedParentScopeId)) {

        $resolved=Resolve-PrivilegeParentScope `
            -ScopeType $RequestedScopeType `
            -ScopeId $RequestedScopeId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId

        if ($resolved.Success -eq $true) {
            $RequestedParentScopeType=$resolved.ParentScopeType
            $RequestedParentScopeId=$resolved.ParentScopeId
        }
    }

    return Test-PrivilegeScopeRelationship `
        -AuthorizedScopeType $record.AuthorizedScopeType `
        -AuthorizedScopeId $record.AuthorizedScopeId `
        -AuthorizedParentScopeType $record.AuthorizedParentScopeType `
        -AuthorizedParentScopeId $record.AuthorizedParentScopeId `
        -RequestedScopeType $RequestedScopeType `
        -RequestedScopeId $RequestedScopeId `
        -RequestedParentScopeType $RequestedParentScopeType `
        -RequestedParentScopeId $RequestedParentScopeId
}

function Invalidate-PrivilegeBoundary {
    param([Parameter(Mandatory=$true)][string]$BoundaryId)

    $record=Get-PrivilegeBoundaryRecord -BoundaryId $BoundaryId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='BOUNDARY_NOT_FOUND'
        }
    }

    $records=@(Get-PrivilegeBoundaryRecords)

    foreach ($item in $records) {
        if ($item.BoundaryId -eq $BoundaryId) {
            $item.Status='INVALIDATED'
        }
    }

    $null=Save-PrivilegeBoundaryRecords -Records $records

    return [pscustomobject]@{
        Success=$true
        Decision='BLOCK'
        Reason='BOUNDARY_INVALIDATED'
        BoundaryId=$BoundaryId
        Status='INVALIDATED'
    }
}

function Reset-PrivilegeBoundary {
    $file=Join-Path $PSScriptRoot 'state\records.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}