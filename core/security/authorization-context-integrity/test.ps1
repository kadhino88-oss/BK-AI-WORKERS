Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Authorization-Context-Integrity.ps1'

. $RuntimeFile

$RevocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'
$FreshnessRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-freshness\Authorization-Freshness.ps1'
$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

. $RevocationRuntime
. $FreshnessRuntime
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
    param(
        [string]$Suffix,
        [string]$Action='READ'
    )

    $tenant="8A09-$Suffix-TENANT"
    $client="8A09-$Suffix-CLIENT"
    $project="8A09-$Suffix-PROJECT"
    $user="8A09-$Suffix-USER"
    $execution="EXEC-8A09-$Suffix-001"

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
            -Action $Action `
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
            -Action $Action `
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
        -Action $Action `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    if ($null -eq $binding -or $binding.Success -ne $true) {
        throw "Execution binding setup failed for $Suffix."
    }

    $bindingId=[string]$binding.BindingId

    $fresh=New-AuthorizationFreshness `
        -UserId $user `
        -SessionId $sessionId `
        -GrantId $grantId `
        -Grant $rawGrant `
        -BindingId $bindingId `
        -ExecutionId $execution `
        -Action $Action `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    if ($null -eq $fresh -or $fresh.Success -ne $true) {
        throw "Freshness setup failed for $Suffix."
    }

    return [pscustomobject]@{
        Tenant=$tenant
        Client=$client
        Project=$project
        User=$user
        Action=$Action
        Execution=$execution
        SessionId=$sessionId
        GrantId=$grantId
        RawGrant=$rawGrant
        BindingId=$bindingId
        FreshnessId=[string]$fresh.FreshnessId
        RawNonce=[string]$fresh.Nonce
    }
}

# ============================================================
# RESET
# ============================================================

$null=Reset-AuthorizationContextIntegrity
$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

# ============================================================
# CHAINES DE TEST
# ============================================================

$chain1=New-TestChain -Suffix 'PRIMARY'
$chain2=New-TestChain -Suffix 'SECONDARY'

$User=$chain1.User
$SessionId=$chain1.SessionId
$GrantId=$chain1.GrantId
$RawGrant=$chain1.RawGrant
$BindingId=$chain1.BindingId
$ExecutionId=$chain1.Execution
$Action=$chain1.Action
$Tenant=$chain1.Tenant
$Client=$chain1.Client
$Project=$chain1.Project
$FreshnessId=$chain1.FreshnessId
$RawNonce=$chain1.RawNonce

# ============================================================
# CONFIG
# ============================================================

try {
    Assert-Test ($null -ne (Get-AuthorizationContextIntegrityConfig)) '01 Config loaded'
}
catch {
    Fail-Test '01 Config loaded' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'contextIntegrityEnabled')) '02 Context integrity enabled'
}
catch {
    Fail-Test '02 Context integrity enabled' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'hashContextBeforeStorage')) '03 Context hashing enabled'
}
catch {
    Fail-Test '03 Context hashing enabled' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'requireRevocationChain')) '04 Revocation chain required'
}
catch {
    Fail-Test '04 Revocation chain required' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'requireFreshnessValidation')) '05 Freshness validation required'
}
catch {
    Fail-Test '05 Freshness validation required' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'requireUserBinding')) '06 User binding required'
}
catch {
    Fail-Test '06 User binding required' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'requireSessionBinding')) '07 Session binding required'
}
catch {
    Fail-Test '07 Session binding required' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'requireGrantBinding')) '08 Grant binding required'
}
catch {
    Fail-Test '08 Grant binding required' $_.Exception.Message
}

try {
    Assert-Test ([bool](Get-AuthorizationContextIntegrityField -Name 'requireExecutionBinding')) '09 Execution binding required'
}
catch {
    Fail-Test '09 Execution binding required' $_.Exception.Message
}

try {
    Assert-Test ((Get-AuthorizationContextIntegrityField -Name 'defaultDecision') -eq 'BLOCK') '10 Default decision BLOCK'
}
catch {
    Fail-Test '10 Default decision BLOCK' $_.Exception.Message
}

# ============================================================
# CREATE INTEGRITY SNAPSHOT
# ============================================================

$snapshot=New-AuthorizationContextIntegrity `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $ExecutionId `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce

if ($snapshot.Success -ne $true) {
    throw "Integrity snapshot creation failed: $($snapshot.Reason)"
}

$IntegrityId=[string]$snapshot.IntegrityId

# 11
try {
    Assert-Test `
        ($snapshot.Success -eq $true -and
         $snapshot.Decision -eq 'ALLOW' -and
         -not [string]::IsNullOrWhiteSpace($IntegrityId)) `
        '11 Integrity snapshot issued'
}
catch {
    Fail-Test '11 Integrity snapshot issued' $_.Exception.Message
}

# 12
try {
    $record=Get-AuthorizationContextIntegrityRecord `
        -IntegrityId $IntegrityId

    Assert-Test `
        ($null -ne $record -and
         -not [string]::IsNullOrWhiteSpace([string]$record.ContextHash)) `
        '12 Context hash persisted'
}
catch {
    Fail-Test '12 Context hash persisted' $_.Exception.Message
}

# 13
try {
    $record=Get-AuthorizationContextIntegrityRecord `
        -IntegrityId $IntegrityId

    $propertyNames=@(
        $record.PSObject.Properties |
        ForEach-Object { $_.Name }
    )

    Assert-Test `
        ($propertyNames -notcontains 'CanonicalContext') `
        '13 Canonical context not persisted'
}
catch {
    Fail-Test '13 Canonical context not persisted' $_.Exception.Message
}

# 14
try {
    $valid=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($valid.Success -eq $true -and
         $valid.Decision -eq 'ALLOW') `
        '14 Valid context allowed'
}
catch {
    Fail-Test '14 Valid context allowed' $_.Exception.Message
}

# 15
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId 'OTHER-USER' `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '15 User mutation blocked'
}
catch {
    Fail-Test '15 User mutation blocked' $_.Exception.Message
}

# 16
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId 'OTHER-SESSION' `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '16 Session mutation blocked'
}
catch {
    Fail-Test '16 Session mutation blocked' $_.Exception.Message
}

# 17
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId 'OTHER-GRANT' `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '17 Grant mutation blocked'
}
catch {
    Fail-Test '17 Grant mutation blocked' $_.Exception.Message
}

# 18
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId 'OTHER-BINDING' `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '18 Binding mutation blocked'
}
catch {
    Fail-Test '18 Binding mutation blocked' $_.Exception.Message
}

# 19
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId 'OTHER-EXECUTION' `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '19 Execution mutation blocked'
}
catch {
    Fail-Test '19 Execution mutation blocked' $_.Exception.Message
}

# 20 — ACTION / TENANT
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'WRITE' `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '20 Action and tenant mutation blocked'
}
catch {
    Fail-Test '20 Action and tenant mutation blocked' $_.Exception.Message
}

# 21 — CLIENT
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '21 Client mutation blocked'
}
catch {
    Fail-Test '21 Client mutation blocked' $_.Exception.Message
}

# 22 — PROJECT
try {
    $bad=Test-AuthorizationContextIntegrity `
        -IntegrityId $IntegrityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT' `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '22 Project mutation blocked'
}
catch {
    Fail-Test '22 Project mutation blocked' $_.Exception.Message
}

# 23 — EXPLICIT INVALIDATION
try {
    $chain2Snapshot=New-AuthorizationContextIntegrity `
        -UserId $chain2.User `
        -SessionId $chain2.SessionId `
        -GrantId $chain2.GrantId `
        -BindingId $chain2.BindingId `
        -ExecutionId $chain2.Execution `
        -Action $chain2.Action `
        -TenantId $chain2.Tenant `
        -ClientId $chain2.Client `
        -ProjectId $chain2.Project `
        -Grant $chain2.RawGrant `
        -FreshnessId $chain2.FreshnessId `
        -Nonce $chain2.RawNonce

    if ($chain2Snapshot.Success -ne $true) {
        throw "Secondary snapshot creation failed: $($chain2Snapshot.Reason)"
    }

    $invalidated=Invalidate-AuthorizationContextIntegrity `
        -IntegrityId $chain2Snapshot.IntegrityId

    $checkInvalidated=Test-AuthorizationContextIntegrity `
        -IntegrityId $chain2Snapshot.IntegrityId `
        -UserId $chain2.User `
        -SessionId $chain2.SessionId `
        -GrantId $chain2.GrantId `
        -BindingId $chain2.BindingId `
        -ExecutionId $chain2.Execution `
        -Action $chain2.Action `
        -TenantId $chain2.Tenant `
        -ClientId $chain2.Client `
        -ProjectId $chain2.Project `
        -FreshnessId $chain2.FreshnessId `
        -Nonce $chain2.RawNonce

    Assert-Test `
        ($invalidated.Success -eq $true -and
         $invalidated.Status -eq 'INVALIDATED' -and
         $checkInvalidated.Success -eq $false -and
         $checkInvalidated.Decision -eq 'BLOCK') `
        '23 Invalidated context blocked'
}
catch {
    Fail-Test '23 Invalidated context blocked' $_.Exception.Message
}

# 24 — UNKNOWN INTEGRITY ID
try {
    $unknown=Test-AuthorizationContextIntegrity `
        -IntegrityId 'CTXINT-NOT-FOUND' `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce

    Assert-Test `
        ($unknown.Success -eq $false -and
         $unknown.Decision -eq 'BLOCK') `
        '24 Unknown integrity record blocked'
}
catch {
    Fail-Test '24 Unknown integrity record blocked' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-09'
Write-Host ('PASS : {0}' -f $script:Pass)
Write-Host ('FAIL : {0}' -f $script:Fail)
Write-Host '=============================================='

if ($script:Pass -eq 24 -and
    $script:Fail -eq 0) {

    Write-Host 'RESULTAT FINAL : PASS'
}
else {
    Write-Host 'RESULTAT FINAL : FAIL'
}

Read-Host 'Appuyez sur Entree pour fermer'