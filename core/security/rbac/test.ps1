Set-StrictMode -Version 2.0

$ErrorActionPreference = 'Stop'

$RuntimeFile = Join-Path $PSScriptRoot 'RBAC.ps1'

if (-not (Test-Path -LiteralPath $RuntimeFile)) {
    throw "RBAC runtime introuvable : $RuntimeFile"
}

. $RuntimeFile

$script:Pass = 0
$script:Fail = 0

function Pass-Test {
    param([string]$Name)

    $script:Pass++
    Write-Host "[PASS] $Name"
}

function Fail-Test {
    param(
        [string]$Name,
        [string]$Reason = ""
    )

    $script:Fail++
    Write-Host "[FAIL] $Name"

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Host "       $Reason"
    }
}

function Assert-Test {
    param(
        [bool]$Condition,
        [string]$Name,
        [string]$Reason = ""
    )

    if ($Condition) {
        Pass-Test $Name
    }
    else {
        Fail-Test $Name $Reason
    }
}

# ============================================================
# RESET
# ============================================================

$null = Reset-RBAC

# ============================================================
# 01 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â CONFIG
# ============================================================

try {
    $config = Get-RBACConfig

    Assert-Test `
        ($null -ne $config) `
        "01 Config loaded" `
        "Get-RBACConfig returned NULL."
}
catch {
    Fail-Test "01 Config loaded" $_.Exception.Message
}

# ============================================================
# 02 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â RBAC ENABLED
# ============================================================

try {
    $enabled = [bool](Get-RBACField -Name 'enabled')

    Assert-Test `
        $enabled `
        "02 RBAC enabled" `
        "RBAC enabled=false."
}
catch {
    Fail-Test "02 RBAC enabled" $_.Exception.Message
}

# ============================================================
# 03 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â HIERARCHICAL SCOPE
# ============================================================

try {
    $hierarchical = [bool](Get-RBACField -Name 'hierarchicalScopeEnabled')

    Assert-Test `
        $hierarchical `
        "03 Hierarchical scope enabled" `
        "hierarchicalScopeEnabled=false."
}
catch {
    Fail-Test "03 Hierarchical scope enabled" $_.Exception.Message
}

# ============================================================
# 04 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â DENY PRECEDENCE
# ============================================================

try {
    $denyPrecedence = [bool](Get-RBACField -Name 'denyPrecedence')

    Assert-Test `
        $denyPrecedence `
        "04 Deny precedence enabled" `
        "denyPrecedenceEnabled=false."
}
catch {
    Fail-Test "04 Deny precedence enabled" $_.Exception.Message
}

# ============================================================
# 05 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â 8 ROLES
# ============================================================

try {
    $roles = @(Get-RBACRoles)

    Assert-Test `
        ($roles.Count -eq 8) `
        "05 Eight roles loaded" `
        ("Expected 8 roles, got {0}." -f $roles.Count)
}
catch {
    Fail-Test "05 Eight roles loaded" $_.Exception.Message
}

# ============================================================
# 06 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OWNER FOUND
# ============================================================

try {
    $owner = Get-RBACRole -RoleId 'ROLE-OWNER'

    Assert-Test `
        ($null -ne $owner -and $owner.Name -eq 'OWNER') `
        "06 OWNER role found" `
        "ROLE-OWNER missing."
}
catch {
    Fail-Test "06 OWNER role found" $_.Exception.Message
}

# ============================================================
# 07 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OWNER PERMISSIONS
# ============================================================

try {
    $owner = Get-RBACRole -RoleId 'ROLE-OWNER'

    $expectedOwnerPermissions = @(
        'READ'
        'WRITE'
        'EXECUTE'
        'APPROVE'
        'DELETE'
        'MANAGE_USERS'
        'MANAGE_ROLES'
        'MANAGE_CONNECTORS'
        'MANAGE_BILLING'
    )

    $ownerPermissions = @($owner.Permissions)

    $ownerPermissionsCorrect = `
        ($ownerPermissions.Count -eq $expectedOwnerPermissions.Count) -and `
        (@($expectedOwnerPermissions | Where-Object {
            $ownerPermissions -notcontains $_
        }).Count -eq 0)

    Assert-Test `
        $ownerPermissionsCorrect `
        "07 OWNER permissions correct" `
        "OWNER permissions do not match expected set."
}
catch {
    Fail-Test "07 OWNER permissions correct" $_.Exception.Message
}

# ============================================================
# 08 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â VIEWER READ ONLY
# ============================================================

try {
    $viewer = Get-RBACRole -RoleId 'ROLE-VIEWER'
    $viewerPermissions = @($viewer.Permissions)

    $viewerCorrect = `
        ($viewerPermissions.Count -eq 1) -and `
        ($viewerPermissions[0] -eq 'READ')

    Assert-Test `
        $viewerCorrect `
        "08 VIEWER read-only" `
        "VIEWER permissions are not READ-only."
}
catch {
    Fail-Test "08 VIEWER read-only" $_.Exception.Message
}

# ============================================================
# 09 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â UNKNOWN PRINCIPAL BLOCKED
# ============================================================

try {
    $result09 = Test-RBACPermission `
        -PrincipalId 'AUDIT-UNKNOWN-USER' `
        -Action 'READ' `
        -TenantId 'AUDIT-TENANT' `
        -ClientId 'AUDIT-CLIENT' `
        -ProjectId 'AUDIT-PROJECT'

    $blocked09 = `
        ($null -ne $result09) -and `
        ($result09.Success -eq $false) -and `
        ($result09.Decision -eq 'BLOCK')

    Assert-Test `
        $blocked09 `
        "09 Invalid context blocked" `
        "Expected BLOCK for unknown principal."
}
catch {
    Fail-Test "09 Invalid context blocked" $_.Exception.Message
}

# ============================================================
# 10 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â PROJECT WITHOUT CLIENT BLOCKED
# ============================================================

try {
    $result10 = Test-RBACPermission `
        -PrincipalId 'AUDIT-UNKNOWN-USER' `
        -Action 'READ' `
        -TenantId 'AUDIT-TENANT' `
        -ClientId '' `
        -ProjectId 'AUDIT-PROJECT'

    $blocked10 = `
        ($null -ne $result10) -and `
        ($result10.Success -eq $false)

    Assert-Test `
        $blocked10 `
        "10 Project without client blocked" `
        "Project context without client was not blocked."
}
catch {
    Fail-Test "10 Project without client blocked" $_.Exception.Message
}

# ============================================================
# 11 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OWNER BINDING
# ============================================================

try {
    $ownerBinding = New-RBACBinding `
        -PrincipalId 'AUDIT-OWNER-USER' `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'TENANT' `
        -ScopeId 'AUDIT-TENANT'

    $binding11 = `
        ($null -ne $ownerBinding) -and `
        ($ownerBinding.Success -eq $true) -and `
        ($ownerBinding.Status -eq 'CREATED')

    Assert-Test `
        $binding11 `
        "11 OWNER binding created" `
        "OWNER binding creation failed."
}
catch {
    Fail-Test "11 OWNER binding created" $_.Exception.Message
}

# ============================================================
# 12 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OWNER READ ALLOWED
# ============================================================

try {
    $result12 = Test-RBACPermission `
        -PrincipalId 'AUDIT-OWNER-USER' `
        -Action 'READ' `
        -TenantId 'AUDIT-TENANT'

    $allowed12 = `
        ($null -ne $result12) -and `
        ($result12.Success -eq $true) -and `
        ($result12.Decision -eq 'ALLOW')

    Assert-Test `
        $allowed12 `
        "12 OWNER READ allowed" `
        "OWNER READ was not allowed."
}
catch {
    Fail-Test "12 OWNER READ allowed" $_.Exception.Message
}

# ============================================================
# 13 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OWNER WRITE ALLOWED
# ============================================================

try {
    $result13 = Test-RBACPermission `
        -PrincipalId 'AUDIT-OWNER-USER' `
        -Action 'WRITE' `
        -TenantId 'AUDIT-TENANT'

    $allowed13 = `
        ($null -ne $result13) -and `
        ($result13.Success -eq $true) -and `
        ($result13.Decision -eq 'ALLOW')

    Assert-Test `
        $allowed13 `
        "13 OWNER WRITE allowed" `
        "OWNER WRITE was not allowed."
}
catch {
    Fail-Test "13 OWNER WRITE allowed" $_.Exception.Message
}

# ============================================================
# 14 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â TENANT MISMATCH BLOCKED
# ============================================================

try {
    $result14 = Test-RBACPermission `
        -PrincipalId 'AUDIT-OWNER-USER' `
        -Action 'READ' `
        -TenantId 'OTHER-TENANT'

    $blocked14 = `
        ($null -ne $result14) -and `
        ($result14.Success -eq $false) -and `
        ($result14.Decision -eq 'BLOCK')

    Assert-Test `
        $blocked14 `
        "14 Tenant mismatch blocked" `
        "Cross-tenant access was not blocked."
}
catch {
    Fail-Test "14 Tenant mismatch blocked" $_.Exception.Message
}

# ============================================================
# 15 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â VIEWER BINDING
# ============================================================

try {
    $viewerBinding = New-RBACBinding `
        -PrincipalId 'AUDIT-VIEWER-USER' `
        -RoleId 'ROLE-VIEWER' `
        -ScopeType 'TENANT' `
        -ScopeId 'AUDIT-TENANT'

    $binding15 = `
        ($null -ne $viewerBinding) -and `
        ($viewerBinding.Success -eq $true) -and `
        ($viewerBinding.Status -eq 'CREATED')

    Assert-Test `
        $binding15 `
        "15 VIEWER binding created" `
        "VIEWER binding creation failed."
}
catch {
    Fail-Test "15 VIEWER binding created" $_.Exception.Message
}

# ============================================================
# 16 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â VIEWER READ ALLOWED
# ============================================================

try {
    $result16 = Test-RBACPermission `
        -PrincipalId 'AUDIT-VIEWER-USER' `
        -Action 'READ' `
        -TenantId 'AUDIT-TENANT'

    $allowed16 = `
        ($null -ne $result16) -and `
        ($result16.Success -eq $true) -and `
        ($result16.Decision -eq 'ALLOW')

    Assert-Test `
        $allowed16 `
        "16 VIEWER READ allowed" `
        "VIEWER READ was not allowed."
}
catch {
    Fail-Test "16 VIEWER READ allowed" $_.Exception.Message
}

# ============================================================
# 17 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â VIEWER WRITE BLOCKED
# ============================================================

try {
    $result17 = Test-RBACPermission `
        -PrincipalId 'AUDIT-VIEWER-USER' `
        -Action 'WRITE' `
        -TenantId 'AUDIT-TENANT'

    $blocked17 = `
        ($null -ne $result17) -and `
        ($result17.Success -eq $false) -and `
        ($result17.Decision -eq 'BLOCK')

    Assert-Test `
        $blocked17 `
        "17 VIEWER WRITE blocked" `
        "VIEWER WRITE was not blocked."
}
catch {
    Fail-Test "17 VIEWER WRITE blocked" $_.Exception.Message
}

# ============================================================
# 18 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OPERATOR BINDING
# ============================================================

try {
    $operatorBinding = New-RBACBinding `
        -PrincipalId 'AUDIT-OPERATOR-USER' `
        -RoleId 'ROLE-OPERATOR' `
        -ScopeType 'TENANT' `
        -ScopeId 'AUDIT-TENANT'

    $binding18 = `
        ($null -ne $operatorBinding) -and `
        ($operatorBinding.Success -eq $true) -and `
        ($operatorBinding.Status -eq 'CREATED')

    Assert-Test `
        $binding18 `
        "18 OPERATOR binding created" `
        "OPERATOR binding creation failed."
}
catch {
    Fail-Test "18 OPERATOR binding created" $_.Exception.Message
}

# ============================================================
# 19 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OPERATOR EXECUTE ALLOWED
# ============================================================

try {
    $result19 = Test-RBACPermission `
        -PrincipalId 'AUDIT-OPERATOR-USER' `
        -Action 'EXECUTE' `
        -TenantId 'AUDIT-TENANT'

    $allowed19 = `
        ($null -ne $result19) -and `
        ($result19.Success -eq $true) -and `
        ($result19.Decision -eq 'ALLOW')

    Assert-Test `
        $allowed19 `
        "19 OPERATOR EXECUTE allowed" `
        "OPERATOR EXECUTE was not allowed."
}
catch {
    Fail-Test "19 OPERATOR EXECUTE allowed" $_.Exception.Message
}

# ============================================================
# 20 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â OPERATOR DELETE BLOCKED
# ============================================================

try {
    $result20 = Test-RBACPermission `
        -PrincipalId 'AUDIT-OPERATOR-USER' `
        -Action 'DELETE' `
        -TenantId 'AUDIT-TENANT'

    $blocked20 = `
        ($null -ne $result20) -and `
        ($result20.Success -eq $false) -and `
        ($result20.Decision -eq 'BLOCK')

    Assert-Test `
        $blocked20 `
        "20 OPERATOR DELETE blocked" `
        "OPERATOR DELETE was not blocked."
}
catch {
    Fail-Test "20 OPERATOR DELETE blocked" $_.Exception.Message
}

# ============================================================
# 21 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â EXPLICIT DENY
# ============================================================

try {
    $denyBinding = New-RBACBinding `
        -PrincipalId 'AUDIT-DENY-USER' `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'TENANT' `
        -ScopeId 'AUDIT-TENANT' `
        -Deny $true

    $binding21 = `
        ($null -ne $denyBinding) -and `
        ($denyBinding.Success -eq $true) -and `
        ($denyBinding.Deny -eq $true)

    Assert-Test `
        $binding21 `
        "21 Explicit deny created" `
        "Explicit deny binding was not created."
}
catch {
    Fail-Test "21 Explicit deny created" $_.Exception.Message
}

# ============================================================
# 22 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â DENY OVERRIDES ALLOW
# ============================================================

try {
    $allowBinding22 = New-RBACBinding `
        -PrincipalId 'AUDIT-DENY-USER' `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'TENANT' `
        -ScopeId 'ALLOW-TENANT'

    $denyBinding22 = New-RBACBinding `
        -PrincipalId 'AUDIT-DENY-USER' `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'TENANT' `
        -ScopeId 'ALLOW-TENANT' `
        -Deny $true

    $result22 = Test-RBACPermission `
        -PrincipalId 'AUDIT-DENY-USER' `
        -Action 'READ' `
        -TenantId 'ALLOW-TENANT'

    $blocked22 = `
        ($null -ne $allowBinding22) -and `
        ($null -ne $denyBinding22) -and `
        ($result22.Success -eq $false) -and `
        ($result22.Decision -eq 'BLOCK')

    Assert-Test `
        $blocked22 `
        "22 Explicit deny overrides allow" `
        "Explicit DENY did not override ALLOW."
}
catch {
    Fail-Test "22 Explicit deny overrides allow" $_.Exception.Message
}

# ============================================================
# 23 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â FINANCIAL APPROVAL
# ============================================================

try {
    $ownerFinancial = Test-RBACPermission `
        -PrincipalId 'AUDIT-OWNER-USER' `
        -Action 'MANAGE_BILLING' `
        -TenantId 'AUDIT-TENANT'

    $financialApproval = `
        ($null -ne $ownerFinancial) -and `
        (
            $ownerFinancial.Decision -eq 'REQUIRES_HUMAN_APPROVAL' -or
            $ownerFinancial.Reason -eq 'REQUIRES_HUMAN_APPROVAL'
        )

    Assert-Test `
        $financialApproval `
        "23 Financial approval required" `
        "MANAGE_BILLING did not require human approval."
}
catch {
    Fail-Test "23 Financial approval required" $_.Exception.Message
}

# ============================================================
# 24 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â PERSISTENCE / REVOKE / ISOLATION
# ============================================================

try {
    $bindingsBefore = @(Get-RBACBindings)

    $ownerPersisted = @(
        $bindingsBefore | Where-Object {
            $_.PrincipalId -eq 'AUDIT-OWNER-USER' -and
            $_.RoleId -eq 'ROLE-OWNER' -and
            $_.ScopeId -eq 'AUDIT-TENANT'
        }
    )

    $persisted = ($ownerPersisted.Count -ge 1)

    $bindingToRemove = $ownerPersisted[0]

    $removeResult = Remove-RBACBinding -BindingId $bindingToRemove.BindingId

    $bindingsAfter = @(Get-RBACBindings)

    $removed = @(
        $bindingsAfter | Where-Object {
            $_.BindingId -eq $bindingToRemove.BindingId
        }
    )

    $revoked = `
        ($null -ne $removeResult) -and `
        ($removeResult.Success -eq $true) -and `
        ($removeResult.Status -eq 'REVOKED')

    $isolationResult = Test-RBACPermission `
        -PrincipalId 'AUDIT-OWNER-USER' `
        -Action 'READ' `
        -TenantId 'AUDIT-TENANT'

    $isolated = `
        ($null -ne $isolationResult) -and `
        ($isolationResult.Success -eq $false) -and `
        ($isolationResult.Decision -eq 'BLOCK')

    Assert-Test `
        ($persisted -and $revoked -and $isolated) `
        "24 Persistence revoke and isolation" `
        "Persistence, revoke or post-revoke isolation failed."
}
catch {
    Fail-Test "24 Persistence revoke and isolation" $_.Exception.Message
}

# ============================================================
# RESULTATS
# ============================================================

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 8A-03"
Write-Host ("PASS : {0}" -f $script:Pass)
Write-Host ("FAIL : {0}" -f $script:Fail)
Write-Host "=============================================="

if ($script:Fail -eq 0 -and $script:Pass -eq 24) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"