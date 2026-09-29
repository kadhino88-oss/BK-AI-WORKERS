Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RBACRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac"
$RBACConfigFile = Join-Path $RBACRoot "config.json"
$RBACStateDir = Join-Path $RBACRoot "state"
$RBACRolesFile = Join-Path $RBACStateDir "roles.json"
$RBACBindingsFile = Join-Path $RBACStateDir "bindings.json"

function Get-RBACConfig {
    return Get-Content -LiteralPath $RBACConfigFile -Raw |
        ConvertFrom-Json
}

function Get-RBACField {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Config = Get-RBACConfig
    $Property = $Config.PSObject.Properties[$Name]

    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}

function Get-RBACRoles {
    if (-not (Test-Path -LiteralPath $RBACRolesFile)) {
        return @()
    }

    $Raw = Get-Content -LiteralPath $RBACRolesFile -Raw

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    $Store = ConvertFrom-Json $Raw

    if ($null -eq $Store.PSObject.Properties["items"]) {
        return @()
    }

    return @($Store.items)
}

function Save-RBACRoles {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Roles
    )

    $Store = [pscustomobject][ordered]@{
        version = "1.0"
        items = @($Roles)
    }

    $Json = ConvertTo-Json -InputObject $Store -Depth 10

    [System.IO.File]::WriteAllText(
        $RBACRolesFile,
        $Json,
        [System.Text.Encoding]::UTF8
    )

    return $null
}

function Get-RBACBindings {
    if (-not (Test-Path -LiteralPath $RBACBindingsFile)) {
        return @()
    }

    $Raw = Get-Content -LiteralPath $RBACBindingsFile -Raw

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    $Store = ConvertFrom-Json $Raw

    if ($null -eq $Store.PSObject.Properties["items"]) {
        return @()
    }

    return @($Store.items)
}

function Save-RBACBindings {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Bindings
    )

    $Store = [pscustomobject][ordered]@{
        version = "1.0"
        items = @($Bindings)
    }

    $Json = ConvertTo-Json -InputObject $Store -Depth 10

    [System.IO.File]::WriteAllText(
        $RBACBindingsFile,
        $Json,
        [System.Text.Encoding]::UTF8
    )

    return $null
}

function Get-RBACRole {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RoleId
    )

    $Roles = @(Get-RBACRoles)

    foreach ($Role in $Roles) {
        if ([string]$Role.RoleId -eq $RoleId) {
            return $Role
        }
    }

    return $null
}

function Get-RBACRoleByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Roles = @(Get-RBACRoles)

    foreach ($Role in $Roles) {
        if ([string]$Role.Name -eq $Name) {
            return $Role
        }
    }

    return $null
}

function Test-RBACContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $false)]
        [string]$ClientId,

        [Parameter(Mandatory = $false)]
        [string]$ProjectId
    )

    if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "PRINCIPAL_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "TENANT_ID_REQUIRED"
        }
    }

    if (
        -not [string]::IsNullOrWhiteSpace($ProjectId) -and
        [string]::IsNullOrWhiteSpace($ClientId)
    ) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "CLIENT_ID_REQUIRED_FOR_PROJECT_SCOPE"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status = "VALID"
        Reason = "RBAC_CONTEXT_VALID"
        PrincipalId = $PrincipalId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
    }
}

function New-RBACBinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$RoleId,

        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "KADER",
            "TENANT",
            "CLIENT",
            "PROJECT",
            "WORKER",
            "TASK"
        )]
        [string]$ScopeType,

        [Parameter(Mandatory = $true)]
        [string]$ScopeId,

        [Parameter(Mandatory = $false)]
        [bool]$Deny = $false
    )

    if ([string]::IsNullOrWhiteSpace($PrincipalId)) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "PRINCIPAL_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RoleId)) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "ROLE_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ScopeId)) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "SCOPE_ID_REQUIRED"
        }
    }

    $Role = Get-RBACRole -RoleId $RoleId

    if ($null -eq $Role) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "ROLE_NOT_FOUND"
            RoleId = $RoleId
        }
    }

    $Bindings = @(Get-RBACBindings)

    foreach ($Existing in $Bindings) {
        if (
            [string]$Existing.PrincipalId -eq $PrincipalId -and
            [string]$Existing.RoleId -eq $RoleId -and
            [string]$Existing.ScopeType -eq $ScopeType -and
            [string]$Existing.ScopeId -eq $ScopeId -and
            [bool]$Existing.Deny -eq $Deny -and
            [bool]$Existing.Active -eq $true
        ) {
            return [pscustomobject]@{
                Success = $false
                Status = "DUPLICATE"
                Reason = "RBAC_BINDING_ALREADY_EXISTS"
                BindingId = $Existing.BindingId
            }
        }
    }

    $NewBinding = [pscustomobject][ordered]@{
        BindingId = "BIND-" + (
            [guid]::NewGuid().ToString("N").ToUpperInvariant()
        )
        PrincipalId = $PrincipalId
        RoleId = $RoleId
        ScopeType = $ScopeType
        ScopeId = $ScopeId
        Deny = $Deny
        CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
        Active = $true
    }

    $Bindings += $NewBinding

    $null = Save-RBACBindings -Bindings @($Bindings)

    return [pscustomobject]@{
        Success = $true
        Status = "CREATED"
        Reason = "RBAC_BINDING_CREATED"
        BindingId = $NewBinding.BindingId
        PrincipalId = $PrincipalId
        RoleId = $RoleId
        ScopeType = $ScopeType
        ScopeId = $ScopeId
        Deny = $Deny
    }
}

function Get-RBACPrincipalBindings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId
    )

    $Bindings = @(Get-RBACBindings)
    $Result = @()

    foreach ($Binding in $Bindings) {
        if (
            [string]$Binding.PrincipalId -eq $PrincipalId -and
            [bool]$Binding.Active -eq $true
        ) {
            $Result += $Binding
        }
    }

    return @($Result)
}

function Test-RBACScopeMatch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScopeType,

        [Parameter(Mandatory = $true)]
        [string]$ScopeId,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $false)]
        [string]$ClientId,

        [Parameter(Mandatory = $false)]
        [string]$ProjectId
    )

    if ($ScopeType -eq "KADER") {
        return $true
    }

    if ($ScopeType -eq "TENANT") {
        return (
            -not [string]::IsNullOrWhiteSpace($TenantId) -and
            $ScopeId -eq $TenantId
        )
    }

    if ($ScopeType -eq "CLIENT") {
        return (
            -not [string]::IsNullOrWhiteSpace($ClientId) -and
            $ScopeId -eq $ClientId
        )
    }

    if ($ScopeType -eq "PROJECT") {
        return (
            -not [string]::IsNullOrWhiteSpace($ProjectId) -and
            $ScopeId -eq $ProjectId
        )
    }

    if ($ScopeType -eq "WORKER") {
        return (
            -not [string]::IsNullOrWhiteSpace($ProjectId) -and
            $ScopeId -eq $ProjectId
        )
    }

    if ($ScopeType -eq "TASK") {
        return (
            -not [string]::IsNullOrWhiteSpace($ProjectId) -and
            $ScopeId -eq $ProjectId
        )
    }

    return $false
}

function Test-RBACPermission {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $false)]
        [string]$ClientId,

        [Parameter(Mandatory = $false)]
        [string]$ProjectId
    )

    $Config = Get-RBACConfig

    if (
        $Config.enabled -ne $true -or
        $Config.rbacEnabled -ne $true
    ) {
        return [pscustomobject]@{
            Success = $false
            Decision = "BLOCK"
            Reason = "RBAC_DISABLED"
        }
    }

    $AllowedActions = @($Config.allowedActions)

    if ($Action -notin $AllowedActions) {
        return [pscustomobject]@{
            Success = $false
            Decision = "BLOCK"
            Reason = "ACTION_NOT_ALLOWED"
            Action = $Action
        }
    }

    $Context = Test-RBACContext `
        -PrincipalId $PrincipalId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ($Context.Success -ne $true) {
        return [pscustomobject]@{
            Success = $false
            Decision = "BLOCK"
            Reason = $Context.Reason
            Action = $Action
        }
    }

    $Bindings = @(Get-RBACPrincipalBindings -PrincipalId $PrincipalId)

    $Allows = @()
    $Denies = @()

    foreach ($Binding in $Bindings) {

        $Matches = Test-RBACScopeMatch `
            -ScopeType $Binding.ScopeType `
            -ScopeId $Binding.ScopeId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId

        if ($Matches -ne $true) {
            continue
        }

        $Role = Get-RBACRole -RoleId $Binding.RoleId

        if ($null -eq $Role) {
            continue
        }

        $Permissions = @($Role.Permissions)

        if ($Action -notin $Permissions) {
            continue
        }

        if ([bool]$Binding.Deny -eq $true) {
            $Denies += $Binding
        }

        if ([bool]$Binding.Deny -ne $true) {
            $Allows += $Binding
        }
    }

    if ($Denies.Count -gt 0) {
        return [pscustomobject]@{
            Success = $false
            Decision = "BLOCK"
            Reason = "EXPLICIT_DENY"
            PrincipalId = $PrincipalId
            Action = $Action
            TenantId = $TenantId
            ClientId = $ClientId
            ProjectId = $ProjectId
        }
    }

    if ($Allows.Count -eq 0) {
        return [pscustomobject]@{
            Success = $false
            Decision = "BLOCK"
            Reason = "PERMISSION_NOT_GRANTED"
            PrincipalId = $PrincipalId
            Action = $Action
            TenantId = $TenantId
            ClientId = $ClientId
            ProjectId = $ProjectId
        }
    }

    if (
        $Config.financialApprovalRequired -eq $true -and
        $Action -eq "MANAGE_BILLING"
    ) {
        return [pscustomobject]@{
            Success = $false
            Decision = "REQUIRES_HUMAN_APPROVAL"
            Reason = "FINANCIAL_HUMAN_APPROVAL_REQUIRED"
            PrincipalId = $PrincipalId
            Action = $Action
        }
    }

    return [pscustomobject]@{
        Success = $true
        Decision = "ALLOW"
        Reason = "RBAC_PERMISSION_GRANTED"
        PrincipalId = $PrincipalId
        Action = $Action
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
    }
}

function Remove-RBACBinding {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BindingId
    )

    $Bindings = @(Get-RBACBindings)

    $Found = $false
    $Updated = @()

    foreach ($Binding in $Bindings) {

        if ([string]$Binding.BindingId -eq $BindingId) {

            $Found = $true

            Add-Member `
                -InputObject $Binding `
                -MemberType NoteProperty `
                -Name "Active" `
                -Value $false `
                -Force

            Add-Member `
                -InputObject $Binding `
                -MemberType NoteProperty `
                -Name "RevokedAtUtc" `
                -Value ([DateTime]::UtcNow.ToString("o")) `
                -Force
        }

        $Updated += $Binding
    }

    if (-not $Found) {
        return [pscustomobject]@{
            Success = $false
            Status = "NOT_FOUND"
            Reason = "RBAC_BINDING_NOT_FOUND"
        }
    }

    $null = Save-RBACBindings -Bindings @($Updated)

    return [pscustomobject]@{
        Success = $true
        Status = "REVOKED"
        Reason = "RBAC_BINDING_REVOKED"
        BindingId = $BindingId
    }
}

function Reset-RBAC {
    $null = Save-RBACBindings -Bindings @()

    return [pscustomobject]@{
        Success = $true
        Status = "RESET"
        Reason = "RBAC_STATE_RESET"
    }
}