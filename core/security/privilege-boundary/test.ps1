Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Privilege-Boundary.ps1'

. $RuntimeFile

$RevocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'
$FreshnessRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-freshness\Authorization-Freshness.ps1'
$IntegrityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-context-integrity\Authorization-Context-Integrity.ps1'
$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

. $RevocationRuntime
. $FreshnessRuntime
. $IntegrityRuntime
. $IdentityRuntime
. $GrantRuntime
. $ExecutionRuntime
. $GatewayRuntime
. $RBACRuntime

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
    param([string]$Suffix)

    $tenant="8A10-$Suffix-TENANT"
    $client="8A10-$Suffix-CLIENT"
    $project="8A10-$Suffix-PROJECT"
    $user="8A10-$Suffix-USER"
    $execution="EXEC-8A10-$Suffix-001"

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
        throw "Session setup failed for $Suffix."
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
            -Action 'READ' `
            -TenantId $tenant `
            -ClientId $client `
            -ProjectId $project
    ) |
        Where-Object { $_.DecisionId } |
        Select-Object -Last 1

    if ($null -eq $auth -or $auth.Success -ne $true) {
        throw "Authorization setup failed for $Suffix."
    }

    $grant=@(
        New-AuthorizationGrant `
            -AuthorizationId $auth.DecisionId `
            -UserId $user `
            -SessionId $sessionId `
            -Action 'READ' `
            -TenantId $tenant `
            -ClientId $client `
            -ProjectId $project
    ) |
        Where-Object { $_.GrantId } |
        Select-Object -Last 1

    if ($null -eq $grant -or $grant.Success -ne $true) {
        throw "Grant setup failed for $Suffix."
    }

    $grantId=[string]$grant.GrantId
    $rawGrant=[string]$grant.Grant

    $binding=New-ExecutionGrantBinding `
        -GrantId $grantId `
        -Grant $rawGrant `
        -ExecutionId $execution `
        -UserId $user `
        -SessionId $sessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    if ($null -eq $binding -or $binding.Success -ne $true) {
        throw "Binding setup failed for $Suffix."
    }

    $fresh=New-AuthorizationFreshness `
        -UserId $user `
        -SessionId $sessionId `
        -GrantId $grantId `
        -Grant $rawGrant `
        -BindingId ([string]$binding.BindingId) `
        -ExecutionId $execution `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    if ($null -eq $fresh -or $fresh.Success -ne $true) {
        throw "Freshness setup failed for $Suffix."
    }

    $integrity=New-AuthorizationContextIntegrity `
        -UserId $user `
        -SessionId $sessionId `
        -GrantId $grantId `
        -BindingId ([string]$binding.BindingId) `
        -ExecutionId $execution `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project `
        -Grant $rawGrant `
        -FreshnessId ([string]$fresh.FreshnessId) `
        -Nonce ([string]$fresh.Nonce)

    if ($null -eq $integrity -or $integrity.Success -ne $true) {
        throw "Integrity setup failed for $Suffix."
    }

    return [pscustomobject]@{
        Tenant=$tenant
        Client=$client
        Project=$project
        User=$user
        Execution=$execution
        SessionId=$sessionId
        GrantId=$grantId
        RawGrant=$rawGrant
        BindingId=[string]$binding.BindingId
        FreshnessId=[string]$fresh.FreshnessId
        RawNonce=[string]$fresh.Nonce
        IntegrityId=[string]$integrity.IntegrityId
    }
}

$null=Reset-PrivilegeBoundary
$null=Reset-AuthorizationContextIntegrity
$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

$chain=New-TestChain -Suffix 'PRIMARY'

$User=$chain.User
$SessionId=$chain.SessionId
$GrantId=$chain.GrantId
$RawGrant=$chain.RawGrant
$BindingId=$chain.BindingId
$ExecutionId=$chain.Execution
$Tenant=$chain.Tenant
$Client=$chain.Client
$Project=$chain.Project
$FreshnessId=$chain.FreshnessId
$RawNonce=$chain.RawNonce
$IntegrityId=$chain.IntegrityId

# ============================================================
# 01-10 CONFIG
# ============================================================

try { Assert-Test ($null -ne (Get-PrivilegeBoundaryConfig)) '01 Config loaded' }
catch { Fail-Test '01 Config loaded' $_.Exception.Message }

try { Assert-Test ([bool](Get-PrivilegeBoundaryField -Name 'privilegeBoundaryEnabled')) '02 Privilege boundary enabled' }
catch { Fail-Test '02 Privilege boundary enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-PrivilegeBoundaryField -Name 'scopeHierarchyEnabled')) '03 Scope hierarchy enabled' }
catch { Fail-Test '03 Scope hierarchy enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-PrivilegeBoundaryField -Name 'allowDownwardScopeOnly')) '04 Downward scope only' }
catch { Fail-Test '04 Downward scope only' $_.Exception.Message }

try { Assert-Test (-not [bool](Get-PrivilegeBoundaryField -Name 'allowCrossTenant')) '05 Cross-tenant blocked' }
catch { Fail-Test '05 Cross-tenant blocked' $_.Exception.Message }

try { Assert-Test (-not [bool](Get-PrivilegeBoundaryField -Name 'allowCrossClient')) '06 Cross-client blocked' }
catch { Fail-Test '06 Cross-client blocked' $_.Exception.Message }

try { Assert-Test (-not [bool](Get-PrivilegeBoundaryField -Name 'allowCrossProject')) '07 Cross-project blocked' }
catch { Fail-Test '07 Cross-project blocked' $_.Exception.Message }

try { Assert-Test ([bool](Get-PrivilegeBoundaryField -Name 'requireRevocationChain')) '08 Revocation required' }
catch { Fail-Test '08 Revocation required' $_.Exception.Message }

try { Assert-Test ([bool](Get-PrivilegeBoundaryField -Name 'requireFreshnessValidation')) '09 Freshness required' }
catch { Fail-Test '09 Freshness required' $_.Exception.Message }

try { Assert-Test ((Get-PrivilegeBoundaryField -Name 'defaultDecision') -eq 'BLOCK') '10 Default decision BLOCK' }
catch { Fail-Test '10 Default decision BLOCK' $_.Exception.Message }

# ============================================================
# CREATE PROJECT BOUNDARY
# Parent CLIENT is now automatically resolved
# ============================================================

$boundary=New-PrivilegeBoundary `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $ExecutionId `
    -Action 'READ' `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -AuthorizedScopeType 'PROJECT' `
    -AuthorizedScopeId $Project `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce `
    -IntegrityId $IntegrityId

if ($null -eq $boundary -or $boundary.Success -ne $true) {
    throw "Boundary creation failed: $($boundary.Reason)"
}

$BoundaryId=[string]$boundary.BoundaryId

# 11
try {
    Assert-Test `
        ($boundary.Decision -eq 'ALLOW') `
        '11 Project boundary created'
}
catch {
    Fail-Test '11 Project boundary created' $_.Exception.Message
}

# 12
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($BoundaryId)) `
        '12 Boundary identifier generated'
}
catch {
    Fail-Test '12 Boundary identifier generated' $_.Exception.Message
}

# 13
try {
    $record=Get-PrivilegeBoundaryRecord -BoundaryId $BoundaryId

    Assert-Test `
        ($record.AuthorizedScopeType -eq 'PROJECT' -and
         $record.AuthorizedScopeId -eq $Project -and
         $record.AuthorizedParentScopeType -eq 'CLIENT' -and
         $record.AuthorizedParentScopeId -eq $Client) `
        '13 Project parent client persisted'
}
catch {
    Fail-Test '13 Project parent client persisted' $_.Exception.Message
}

# 14
try {
    $same=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'PROJECT' `
        -RequestedScopeId $Project

    Assert-Test `
        ($same.Success -eq $true -and $same.Decision -eq 'ALLOW') `
        '14 Same project scope allowed'
}
catch {
    Fail-Test '14 Same project scope allowed' $_.Exception.Message
}

# 15
try {
    $worker=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'WORKER' `
        -RequestedScopeId 'LUCAS' `
        -RequestedParentScopeType 'PROJECT' `
        -RequestedParentScopeId $Project

    Assert-Test `
        ($worker.Success -eq $true -and $worker.Decision -eq 'ALLOW') `
        '15 Worker under project allowed'
}
catch {
    Fail-Test '15 Worker under project allowed' $_.Exception.Message
}

# 16
try {
    $task=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'TASK' `
        -RequestedScopeId 'TASK-001' `
        -RequestedParentScopeType 'PROJECT' `
        -RequestedParentScopeId $Project

    Assert-Test `
        ($task.Success -eq $true -and $task.Decision -eq 'ALLOW') `
        '16 Task under project allowed'
}
catch {
    Fail-Test '16 Task under project allowed' $_.Exception.Message
}

# 17
try {
    $tenant=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'TENANT' `
        -RequestedScopeId $Tenant

    Assert-Test `
        ($tenant.Success -eq $false -and $tenant.Decision -eq 'BLOCK') `
        '17 Project to tenant escalation blocked'
}
catch {
    Fail-Test '17 Project to tenant escalation blocked' $_.Exception.Message
}

# 18
try {
    $clientScope=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'CLIENT' `
        -RequestedScopeId $Client

    Assert-Test `
        ($clientScope.Success -eq $false -and $clientScope.Decision -eq 'BLOCK') `
        '18 Project to client escalation blocked'
}
catch {
    Fail-Test '18 Project to client escalation blocked' $_.Exception.Message
}

# 19
try {
    $kader=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'KADER' `
        -RequestedScopeId 'KADER'

    Assert-Test `
        ($kader.Success -eq $false -and $kader.Decision -eq 'BLOCK') `
        '19 Project to KADER escalation blocked'
}
catch {
    Fail-Test '19 Project to KADER escalation blocked' $_.Exception.Message
}

# 20
try {
    $otherProject=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'PROJECT' `
        -RequestedScopeId 'OTHER-PROJECT'

    Assert-Test `
        ($otherProject.Success -eq $false -and $otherProject.Decision -eq 'BLOCK') `
        '20 Cross-project access blocked'
}
catch {
    Fail-Test '20 Cross-project access blocked' $_.Exception.Message
}

# 21
try {
    $otherWorker=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'WORKER' `
        -RequestedScopeId 'SAM' `
        -RequestedParentScopeType 'PROJECT' `
        -RequestedParentScopeId 'OTHER-PROJECT'

    Assert-Test `
        ($otherWorker.Success -eq $false -and $otherWorker.Decision -eq 'BLOCK') `
        '21 Worker outside project blocked'
}
catch {
    Fail-Test '21 Worker outside project blocked' $_.Exception.Message
}

# 22
try {
    $otherTask=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'TASK' `
        -RequestedScopeId 'TASK-OTHER' `
        -RequestedParentScopeType 'PROJECT' `
        -RequestedParentScopeId 'OTHER-PROJECT'

    Assert-Test `
        ($otherTask.Success -eq $false -and $otherTask.Decision -eq 'BLOCK') `
        '22 Task outside project blocked'
}
catch {
    Fail-Test '22 Task outside project blocked' $_.Exception.Message
}

# 23
try {
    $badContext=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId 'OTHER-USER' `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'PROJECT' `
        -RequestedScopeId $Project

    Assert-Test `
        ($badContext.Success -eq $false -and $badContext.Decision -eq 'BLOCK') `
        '23 Authorization context mutation blocked'
}
catch {
    Fail-Test '23 Authorization context mutation blocked' $_.Exception.Message
}

# 24
try {
    $invalidated=Invalidate-PrivilegeBoundary `
        -BoundaryId $BoundaryId

    $afterInvalidation=Test-PrivilegeBoundary `
        -BoundaryId $BoundaryId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedScopeType 'PROJECT' `
        -RequestedScopeId $Project

    Assert-Test `
        ($invalidated.Success -eq $true -and
         $invalidated.Status -eq 'INVALIDATED' -and
         $afterInvalidation.Success -eq $false -and
         $afterInvalidation.Decision -eq 'BLOCK') `
        '24 Invalidated boundary blocked'
}
catch {
    Fail-Test '24 Invalidated boundary blocked' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-10'
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