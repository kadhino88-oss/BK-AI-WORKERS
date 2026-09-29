Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Delegation-Integrity.ps1'

. $RuntimeFile

$WorkerRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\worker-task-authority\Worker-Task-Authority.ps1'
$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'
$FreshnessRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-freshness\Authorization-Freshness.ps1'
$IntegrityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-context-integrity\Authorization-Context-Integrity.ps1'
$RevocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'

. $WorkerRuntime
. $IdentityRuntime
. $GrantRuntime
. $ExecutionRuntime
. $GatewayRuntime
. $RBACRuntime
. $FreshnessRuntime
. $IntegrityRuntime
. $RevocationRuntime

$script:Pass=0
$script:Fail=0

function Pass-Test {
    param([string]$Name)
    $script:Pass++
    Write-Host "[PASS] $Name"
}

function Fail-Test {
    param(
        [string]$Name,
        [string]$Reason=''
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
        [string]$Reason=''
    )

    if ($Condition) {
        Pass-Test $Name
    }
    else {
        Fail-Test $Name $Reason
    }
}

function New-TestChain {
    param(
        [string]$Suffix,
        [string]$WorkerId='LUCAS',
        [string]$TaskId='TASK-001'
    )

    $tenant="8A13-$Suffix-TENANT"
    $client="8A13-$Suffix-CLIENT"
    $project="8A13-$Suffix-PROJECT"
    $user="8A13-$Suffix-USER"
    $execution="EXEC-8A13-$Suffix-001"
    $action='READ'

    $null=New-IdentityUser `
        -UserId $user `
        -Username $user `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project `
        -AccountStatus 'ACTIVE'

    $session=@(
        New-IdentitySession `
            -UserId $user `
            -TenantId $tenant `
            -ClientId $client `
            -ProjectId $project
    ) |
        Where-Object { $_.SessionId } |
        Select-Object -Last 1

    if ($null -eq $session) {
        throw "Session setup failed: $Suffix"
    }

    $sessionId=[string]$session.SessionId

    $null=New-RBACBinding `
        -PrincipalId $user `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'TENANT' `
        -ScopeId $tenant

    $auth=@(
        Authorize-Request `
            -UserId $user `
            -SessionId $sessionId `
            -Action $action `
            -TenantId $tenant `
            -ClientId $client `
            -ProjectId $project
    ) |
        Where-Object { $_.DecisionId } |
        Select-Object -Last 1

    if ($null -eq $auth -or $auth.Success -ne $true) {
        throw "Authorization setup failed: $Suffix"
    }

    $grant=@(
        New-AuthorizationGrant `
            -AuthorizationId $auth.DecisionId `
            -UserId $user `
            -SessionId $sessionId `
            -Action $action `
            -TenantId $tenant `
            -ClientId $client `
            -ProjectId $project
    ) |
        Where-Object { $_.GrantId } |
        Select-Object -Last 1

    if ($null -eq $grant -or $grant.Success -ne $true) {
        throw "Grant setup failed: $Suffix"
    }

    $grantId=[string]$grant.GrantId
    $rawGrant=[string]$grant.Grant

    $binding=New-ExecutionGrantBinding `
        -GrantId $grantId `
        -Grant $rawGrant `
        -ExecutionId $execution `
        -UserId $user `
        -SessionId $sessionId `
        -Action $action `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    if ($null -eq $binding -or $binding.Success -ne $true) {
        throw "Binding setup failed: $Suffix"
    }

    $bindingId=[string]$binding.BindingId

    $fresh=New-AuthorizationFreshness `
        -UserId $user `
        -SessionId $sessionId `
        -GrantId $grantId `
        -Grant $rawGrant `
        -BindingId $bindingId `
        -ExecutionId $execution `
        -Action $action `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    if ($null -eq $fresh -or $fresh.Success -ne $true) {
        throw "Freshness setup failed: $Suffix"
    }

    $freshId=[string]$fresh.FreshnessId
    $rawNonce=[string]$fresh.Nonce

    $integrity=New-AuthorizationContextIntegrity `
        -UserId $user `
        -SessionId $sessionId `
        -GrantId $grantId `
        -BindingId $bindingId `
        -ExecutionId $execution `
        -Action $action `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project `
        -Grant $rawGrant `
        -FreshnessId $freshId `
        -Nonce $rawNonce

    if ($null -eq $integrity -or $integrity.Success -ne $true) {
        throw "Integrity setup failed: $Suffix"
    }

    $authority=New-WorkerTaskAuthority `
        -UserId $user `
        -SessionId $sessionId `
        -GrantId $grantId `
        -BindingId $bindingId `
        -ExecutionId $execution `
        -Action $action `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project `
        -WorkerId $WorkerId `
        -TaskId $TaskId `
        -Grant $rawGrant `
        -FreshnessId $freshId `
        -Nonce $rawNonce `
        -IntegrityId ([string]$integrity.IntegrityId)

    if ($null -eq $authority -or $authority.Success -ne $true) {
        throw "Worker authority setup failed: $Suffix"
    }

    return [pscustomobject]@{
        Tenant=$tenant
        Client=$client
        Project=$project
        User=$user
        SessionId=$sessionId
        GrantId=$grantId
        RawGrant=$rawGrant
        BindingId=$bindingId
        Execution=$execution
        Action=$action
        FreshnessId=$freshId
        RawNonce=$rawNonce
        IntegrityId=[string]$integrity.IntegrityId
        WorkerId=$WorkerId
        TaskId=$TaskId
        AuthorityId=[string]$authority.AuthorityId
    }
}

# ============================================================
# RESET
# ============================================================

$null=Reset-DelegationIntegrity
$null=Reset-AuthorizationContextIntegrity
$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC
$null=Reset-WorkerTaskAuthority

# ============================================================
# PRIMARY CHAIN
# ============================================================

$chain=New-TestChain -Suffix 'PRIMARY'

$User=$chain.User
$SessionId=$chain.SessionId
$GrantId=$chain.GrantId
$RawGrant=$chain.RawGrant
$BindingId=$chain.BindingId
$ExecutionId=$chain.Execution
$Action=$chain.Action
$Tenant=$chain.Tenant
$Client=$chain.Client
$Project=$chain.Project
$FreshnessId=$chain.FreshnessId
$RawNonce=$chain.RawNonce
$IntegrityId=$chain.IntegrityId
$WorkerId=$chain.WorkerId
$TaskId=$chain.TaskId
$ParentAuthorityId=$chain.AuthorityId

# ============================================================
# 01-10 CONFIG
# ============================================================

try {
    Assert-Test `
        ($null -ne (Get-DelegationIntegrityConfig)) `
        '01 Config loaded'
}
catch {
    Fail-Test '01 Config loaded' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'delegationIntegrityEnabled')) `
        '02 Delegation integrity enabled'
}
catch {
    Fail-Test '02 Delegation integrity enabled' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'antiPrivilegeTransferEnabled')) `
        '03 Anti privilege transfer enabled'
}
catch {
    Fail-Test '03 Anti privilege transfer enabled' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'requireParentAuthority')) `
        '04 Parent authority required'
}
catch {
    Fail-Test '04 Parent authority required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'requireSameUser')) `
        '05 Same user required'
}
catch {
    Fail-Test '05 Same user required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'requireSameTenant')) `
        '06 Same tenant required'
}
catch {
    Fail-Test '06 Same tenant required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'requireSameClient')) `
        '07 Same client required'
}
catch {
    Fail-Test '07 Same client required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'requireSameProject')) `
        '08 Same project required'
}
catch {
    Fail-Test '08 Same project required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-DelegationIntegrityField -Name 'rejectParentReuse')) `
        '09 Parent reuse rejected'
}
catch {
    Fail-Test '09 Parent reuse rejected' $_.Exception.Message
}

try {
    Assert-Test `
        ((Get-DelegationIntegrityField -Name 'defaultDecision') -eq 'BLOCK') `
        '10 Default decision BLOCK'
}
catch {
    Fail-Test '10 Default decision BLOCK' $_.Exception.Message
}

# ============================================================
# DELEGATION
# ============================================================

$delegation=New-DelegationIntegrity `
    -ParentAuthorityId $ParentAuthorityId `
    -ParentWorkerId $WorkerId `
    -ParentTaskId $TaskId `
    -ChildWorkerId $WorkerId `
    -ChildTaskId 'TASK-CHILD-001' `
    -UserId $User `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $ExecutionId `
    -Action $Action `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce `
    -IntegrityId $IntegrityId

if ($null -eq $delegation -or $delegation.Success -ne $true) {
    throw "Delegation creation failed: $($delegation.Reason)"
}

$DelegationId=[string]$delegation.DelegationId

# 11
try {
    Assert-Test `
        ($delegation.Success -eq $true -and
         $delegation.Decision -eq 'ALLOW' -and
         -not [string]::IsNullOrWhiteSpace($DelegationId)) `
        '11 Delegation authority created'
}
catch {
    Fail-Test '11 Delegation authority created' $_.Exception.Message
}

# 12
try {
    Assert-Test `
        ($delegation.Decision -eq 'ALLOW') `
        '12 Valid delegation allowed'
}
catch {
    Fail-Test '12 Valid delegation allowed' $_.Exception.Message
}

# 13
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($DelegationId)) `
        '13 Delegation identifier generated'
}
catch {
    Fail-Test '13 Delegation identifier generated' $_.Exception.Message
}

# 14
try {
    $record=Get-DelegationIntegrityRecord `
        -DelegationId $DelegationId

    Assert-Test `
        ($null -ne $record -and
         $record.ParentAuthorityId -eq $ParentAuthorityId -and
         $record.ChildWorkerId -eq $WorkerId -and
         $record.ChildTaskId -eq 'TASK-CHILD-001') `
        '14 Parent and child binding persisted'
}
catch {
    Fail-Test '14 Parent and child binding persisted' $_.Exception.Message
}

# 15
try {
    $valid=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($valid.Success -eq $true -and
         $valid.Decision -eq 'ALLOW') `
        '15 Valid delegation verified'
}
catch {
    Fail-Test '15 Valid delegation verified' $_.Exception.Message
}

# 16
try {
    $bad=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId 'OTHER-PARENT' `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '16 Parent substitution blocked'
}
catch {
    Fail-Test '16 Parent substitution blocked' $_.Exception.Message
}

# 17
try {
    $bad=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId 'SAM' `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '17 Cross-worker transfer blocked'
}
catch {
    Fail-Test '17 Cross-worker transfer blocked' $_.Exception.Message
}

# 18
try {
    $bad=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-OTHER' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '18 Child task substitution blocked'
}
catch {
    Fail-Test '18 Child task substitution blocked' $_.Exception.Message
}

# 19
try {
    $bad=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '19 Cross-tenant delegation blocked'
}
catch {
    Fail-Test '19 Cross-tenant delegation blocked' $_.Exception.Message
}

# 20
try {
    $bad=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '20 Cross-client delegation blocked'
}
catch {
    Fail-Test '20 Cross-client delegation blocked' $_.Exception.Message
}

# 21
try {
    $bad=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT' `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '21 Cross-project delegation blocked'
}
catch {
    Fail-Test '21 Cross-project delegation blocked' $_.Exception.Message
}

# 22
try {
    $duplicate=New-DelegationIntegrity `
        -ParentAuthorityId $ParentAuthorityId `
        -ParentWorkerId $WorkerId `
        -ParentTaskId $TaskId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -Grant $RawGrant `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -IntegrityId $IntegrityId

    Assert-Test `
        ($duplicate.Success -eq $false -and
         $duplicate.Decision -eq 'BLOCK') `
        '22 Parent delegation reuse blocked'
}
catch {
    Fail-Test '22 Parent delegation reuse blocked' $_.Exception.Message
}

# 23
try {
    $invalidated=Invalidate-DelegationIntegrity `
        -DelegationId $DelegationId

    $after=Test-DelegationIntegrity `
        -DelegationId $DelegationId `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($invalidated.Success -eq $true -and
         $invalidated.Status -eq 'INVALIDATED' -and
         $after.Success -eq $false -and
         $after.Decision -eq 'BLOCK') `
        '23 Invalidated delegation blocked'
}
catch {
    Fail-Test '23 Invalidated delegation blocked' $_.Exception.Message
}

# 24
try {
    $unknown=Test-DelegationIntegrity `
        -DelegationId 'DELEG-NOT-FOUND' `
        -ParentAuthorityId $ParentAuthorityId `
        -ChildWorkerId $WorkerId `
        -ChildTaskId 'TASK-CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action

    Assert-Test `
        ($unknown.Success -eq $false -and
         $unknown.Decision -eq 'BLOCK') `
        '24 Unknown delegation blocked'
}
catch {
    Fail-Test '24 Unknown delegation blocked' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-13'
Write-Host ('PASS : {0}' -f $script:Pass)
Write-Host ('FAIL : {0}' -f $script:Fail)
Write-Host '=============================================='

if ($script:Pass -eq 24 -and $script:Fail -eq 0) {
    Write-Host 'RESULTAT FINAL : PASS'
}
else {
    Write-Host 'RESULTAT FINAL : FAIL'
}

Read-Host 'Appuyez sur Entree pour fermer'