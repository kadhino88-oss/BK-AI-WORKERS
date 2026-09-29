Set-StrictMode -Version 2.0

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

function Get-AuthorizationGatewayConfig {
    $file=Join-Path $PSScriptRoot 'config.json'

    if (-not (Test-Path -LiteralPath $file)) {
        throw "Configuration file missing: $file"
    }

    $cfg=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json

    return Convert-ToPlainHashtable $cfg
}

function Get-AuthorizationGatewayField {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $cfg=Get-AuthorizationGatewayConfig

    if (-not $cfg.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $cfg[$Name]
}

function Get-AuthorizationDecisions {
    $file=Join-Path $PSScriptRoot 'state\decisions.json'

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

function Save-AuthorizationDecisions {
    param(
        [Parameter(Mandatory=$true)]
        $Decisions
    )

    $cfg=Get-AuthorizationGatewayConfig
    $max=[int]$cfg['maxDecisions']
    $items=@($Decisions)

    if ($items.Count -gt $max) {
        throw "Maximum authorization decision count exceeded."
    }

    $wrapper=[ordered]@{
        version='1.0'
        items=@($items)
    }

    $file=Join-Path $PSScriptRoot 'state\decisions.json'

    ConvertTo-Json -InputObject $wrapper -Depth 30 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}

function Get-AuthorizationDecision {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DecisionId
    )

    if ([string]::IsNullOrWhiteSpace($DecisionId)) {
        return $null
    }

    $items=@(
        Get-AuthorizationDecisions |
        Where-Object { $_.DecisionId -eq $DecisionId }
    )

    if ($items.Count -eq 0) {
        return $null
    }

    return $items[0]
}

function Assert-AuthorizationContext {
    param(
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId
    )

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw 'UserId is required.'
    }

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        throw 'SessionId is required.'
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw 'TenantId is required.'
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw 'ClientId is required.'
    }

    return $true
}

function New-AuthorizationDecisionId {
    return ('AUTHZ-' + [guid]::NewGuid().ToString('N').ToUpperInvariant())
}

function Test-AuthorizationDecision {
    param(
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

        [string]$TokenId='',

        [string]$Token=''
    )

    $cfg=Get-AuthorizationGatewayConfig

    if (-not [bool]$cfg['enabled'] -or
        -not [bool]$cfg['authorizationGatewayEnabled']) {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHORIZATION_GATEWAY_DISABLED'
        }
    }

    try {
        $null=Assert-AuthorizationContext `
            -UserId $UserId `
            -SessionId $SessionId `
            -TenantId $TenantId `
            -ClientId $ClientId
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='CONTEXT_INVALID'
            UserId=$UserId
            SessionId=$SessionId
            TenantId=$TenantId
            ClientId=$ClientId
            ProjectId=$ProjectId
        }
    }

    if ([string]::IsNullOrWhiteSpace($Action)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='ACTION_REQUIRED'
            UserId=$UserId
            SessionId=$SessionId
            TenantId=$TenantId
            ClientId=$ClientId
            ProjectId=$ProjectId
        }
    }

    # --------------------------------------------------------
    # 8A-01 Identity
    # --------------------------------------------------------

    $identityFile=Join-Path (Split-Path $PSScriptRoot -Parent) 'identity-auth\runtime.ps1'

    if (-not (Test-Path -LiteralPath $identityFile)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='IDENTITY_RUNTIME_MISSING'
        }
    }

    . $identityFile

    try {
        $identityContext=Test-IdentityContext `
            -UserId $UserId `
            -Username $UserId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -AccountStatus 'ACTIVE'

        if ($null -eq $identityContext -or
            $identityContext.Success -ne $true) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='IDENTITY_CONTEXT_INVALID'
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='IDENTITY_CONTEXT_REJECTED'
        }
    }

    # --------------------------------------------------------
    # 8A-01 Authentication
    # --------------------------------------------------------

    try {
        $auth=Test-IdentityAuthentication `
            -UserId $UserId `
            -TenantId $TenantId `
            -ClientId $ClientId

        if ($null -eq $auth -or $auth.Success -ne $true) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='AUTHENTICATION_FAILED'
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHENTICATION_REJECTED'
        }
    }

    # --------------------------------------------------------
    # 8A-01 Session
    # --------------------------------------------------------

    try {
        $session=Test-IdentitySession `
            -SessionId $SessionId `
            -TenantId $TenantId `
            -ClientId $ClientId

        if ($null -eq $session -or
            $session.Success -ne $true) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='SESSION_INVALID'
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='SESSION_REJECTED'
        }
    }

    # --------------------------------------------------------
    # 8A-02 Token, when supplied
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

        $tokenFile=Join-Path (Split-Path $PSScriptRoot -Parent) 'session-token-security\runtime.ps1'

        if (-not (Test-Path -LiteralPath $tokenFile)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='TOKEN_RUNTIME_MISSING'
            }
        }

        . $tokenFile

        try {
            $tokenResult=Test-SessionSecurityToken `
                -TokenId $TokenId `
                -Token $Token `
                -SessionId $SessionId `
                -UserId $UserId `
                -TenantId $TenantId `
                -ClientId $ClientId

            if ($null -eq $tokenResult -or
                $tokenResult.Success -ne $true) {

                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='TOKEN_INVALID'
                }
            }
        }
        catch {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='TOKEN_REJECTED'
            }
        }
    }

    # --------------------------------------------------------
    # RBAC
    # --------------------------------------------------------

    $rbacFile=Join-Path (Split-Path $PSScriptRoot -Parent) 'rbac\RBAC.ps1'

    if (-not (Test-Path -LiteralPath $rbacFile)) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='RBAC_RUNTIME_MISSING'
        }
    }

    . $rbacFile

    try {
        $rbac=Test-RBACPermission `
            -PrincipalId $UserId `
            -Action $Action `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='RBAC_EVALUATION_ERROR'
        }
    }

    if ($null -eq $rbac) {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='RBAC_NO_DECISION'
        }
    }

    if ($rbac.Decision -eq 'REQUIRES_HUMAN_APPROVAL' -or
        $rbac.Reason -eq 'REQUIRES_HUMAN_APPROVAL') {

        return [pscustomobject]@{
            Success=$false
            Decision='REQUIRES_HUMAN_APPROVAL'
            Reason='FINANCIAL_OR_HIGH_RISK_APPROVAL_REQUIRED'
            UserId=$UserId
            SessionId=$SessionId
            Action=$Action
            TenantId=$TenantId
            ClientId=$ClientId
            ProjectId=$ProjectId
        }
    }

    if ($rbac.Success -ne $true -or
        $rbac.Decision -ne 'ALLOW') {

        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason=[string]$rbac.Reason
            UserId=$UserId
            SessionId=$SessionId
            Action=$Action
            TenantId=$TenantId
            ClientId=$ClientId
            ProjectId=$ProjectId
        }
    }

    return [pscustomobject]@{
        Success=$true
        Decision='ALLOW'
        Reason='IDENTITY_SESSION_RBAC_GRANTED'
        UserId=$UserId
        SessionId=$SessionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
    }
}

function Authorize-Request {
    param(
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

        [string]$TokenId='',

        [string]$Token=''
    )

    $result=Test-AuthorizationDecision `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -TokenId $TokenId `
        -Token $Token

    $decision=[ordered]@{
        DecisionId=New-AuthorizationDecisionId
        UserId=$UserId
        SessionId=$SessionId
        Action=$Action
        TenantId=$TenantId
        ClientId=$ClientId
        ProjectId=$ProjectId
        Decision=$result.Decision
        Success=[bool]$result.Success
        Reason=$result.Reason
        CreatedAtUtc=[DateTime]::UtcNow.ToString('o')
    }

    $items=@(Get-AuthorizationDecisions)
    $items += [pscustomobject]$decision

    $null=Save-AuthorizationDecisions -Decisions $items

    return [pscustomobject]$decision
}

function Reset-AuthorizationGateway {
    $file=Join-Path $PSScriptRoot 'state\decisions.json'

    $wrapper=[ordered]@{
        version='1.0'
        items=@()
    }

    ConvertTo-Json -InputObject $wrapper -Depth 10 |
        Set-Content -LiteralPath $file -Encoding UTF8

    return $null
}

function Test-AuthorizationDecision {
    param(
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

        [string]$TokenId='',

        [string]$Token=''
    )

    try {
        if ([string]::IsNullOrWhiteSpace($UserId) -or
            [string]::IsNullOrWhiteSpace($SessionId) -or
            [string]::IsNullOrWhiteSpace($Action) -or
            [string]::IsNullOrWhiteSpace($TenantId) -or
            [string]::IsNullOrWhiteSpace($ClientId)) {

            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='AUTHORIZATION_CONTEXT_INCOMPLETE'
                UserId=$UserId
                SessionId=$SessionId
                Action=$Action
                TenantId=$TenantId
                ClientId=$ClientId
                ProjectId=$ProjectId
            }
        }

        $identityFile=Join-Path $Root 'core\security\identity-auth\runtime.ps1'
        $rbacFile=Join-Path $Root 'core\security\rbac\RBAC.ps1'
        $tokenFile=Join-Path $Root 'core\security\session-token-security\runtime.ps1'

        if (-not (Test-Path -LiteralPath $identityFile)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='IDENTITY_RUNTIME_MISSING'
            }
        }

        . $identityFile

        $auth=Test-IdentityAuthentication `
            -UserId $UserId `
            -TenantId $TenantId `
            -ClientId $ClientId

        if ($null -eq $auth -or $auth.Success -ne $true) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='AUTHENTICATION_FAILED'
            }
        }

        $session=Test-IdentitySession `
            -SessionId $SessionId `
            -TenantId $TenantId `
            -ClientId $ClientId

        if ($null -eq $session -or $session.Success -ne $true) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='SESSION_INVALID'
            }
        }

        if (-not (Test-Path -LiteralPath $rbacFile)) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='RBAC_RUNTIME_MISSING'
            }
        }

        . $rbacFile

        $rbac=Test-RBACPermission `
            -PrincipalId $UserId `
            -Action $Action `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId

        if ($null -eq $rbac) {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason='RBAC_NO_DECISION'
            }
        }

        if ($rbac.Decision -eq 'REQUIRES_HUMAN_APPROVAL') {
            return [pscustomobject]@{
                Success=$false
                Decision='REQUIRES_HUMAN_APPROVAL'
                Reason='FINANCIAL_OR_HIGH_RISK_APPROVAL_REQUIRED'
                UserId=$UserId
                SessionId=$SessionId
                Action=$Action
                TenantId=$TenantId
                ClientId=$ClientId
                ProjectId=$ProjectId
            }
        }

        if ($rbac.Success -ne $true -or $rbac.Decision -ne 'ALLOW') {
            return [pscustomobject]@{
                Success=$false
                Decision='BLOCK'
                Reason=[string]$rbac.Reason
                UserId=$UserId
                SessionId=$SessionId
                Action=$Action
                TenantId=$TenantId
                ClientId=$ClientId
                ProjectId=$ProjectId
            }
        }

        if ((-not [string]::IsNullOrWhiteSpace($TokenId)) -or
            (-not [string]::IsNullOrWhiteSpace($Token))) {

            if ([string]::IsNullOrWhiteSpace($TokenId) -or
                [string]::IsNullOrWhiteSpace($Token)) {

                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='TOKEN_CONTEXT_INCOMPLETE'
                }
            }

            if (-not (Test-Path -LiteralPath $tokenFile)) {
                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='TOKEN_RUNTIME_MISSING'
                }
            }

            . $tokenFile

            $tokenResult=Test-SessionSecurityToken `
                -TokenId $TokenId `
                -Token $Token `
                -SessionId $SessionId `
                -UserId $UserId `
                -TenantId $TenantId `
                -ClientId $ClientId

            if ($null -eq $tokenResult -or $tokenResult.Success -ne $true) {
                return [pscustomobject]@{
                    Success=$false
                    Decision='BLOCK'
                    Reason='TOKEN_INVALID'
                }
            }
        }

        return [pscustomobject]@{
            Success=$true
            Decision='ALLOW'
            Reason='IDENTITY_SESSION_RBAC_GRANTED'
            UserId=$UserId
            SessionId=$SessionId
            Action=$Action
            TenantId=$TenantId
            ClientId=$ClientId
            ProjectId=$ProjectId
        }
    }
    catch {
        return [pscustomobject]@{
            Success=$false
            Decision='BLOCK'
            Reason='AUTHORIZATION_GATEWAY_ERROR'
            Error=$_.Exception.Message
            UserId=$UserId
            SessionId=$SessionId
            Action=$Action
            TenantId=$TenantId
            ClientId=$ClientId
            ProjectId=$ProjectId
        }
    }
}