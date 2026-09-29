Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Authorization-Freshness.ps1'

. $RuntimeFile

$RevocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'
$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

. $RevocationRuntime
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

    $tenant="8A08-$Suffix-TENANT"
    $client="8A08-$Suffix-CLIENT"
    $project="8A08-$Suffix-PROJECT"
    $user="8A08-$Suffix-USER"
    $execution="EXEC-8A08-$Suffix-001"

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
        BindingId=[string]$binding.BindingId
    }
}

# ============================================================
# RESET
# ============================================================

$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

# ============================================================
# PRIMARY CHAIN
# ============================================================

$chain1=New-TestChain -Suffix 'PRIMARY'

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

# ============================================================
# SECONDARY CHAIN
# Conservée intacte pour le test 23
# ============================================================

$chain2=New-TestChain -Suffix 'SECONDARY'

# ============================================================
# 01 — CONFIG
# ============================================================

try {
    Assert-Test `
        ($null -ne (Get-AuthorizationFreshnessConfig)) `
        '01 Config loaded'
}
catch {
    Fail-Test '01 Config loaded' $_.Exception.Message
}

# 02
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'freshnessGuardEnabled')) `
        '02 Freshness guard enabled'
}
catch {
    Fail-Test '02 Freshness guard enabled' $_.Exception.Message
}

# 03
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'antiReplayEnabled')) `
        '03 Anti-replay enabled'
}
catch {
    Fail-Test '03 Anti-replay enabled' $_.Exception.Message
}

# 04
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'oneTimeNonceEnabled')) `
        '04 One-time nonce enabled'
}
catch {
    Fail-Test '04 One-time nonce enabled' $_.Exception.Message
}

# 05
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'hashNonceBeforeStorage')) `
        '05 Nonce hashing enabled'
}
catch {
    Fail-Test '05 Nonce hashing enabled' $_.Exception.Message
}

# 06
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'requireRevocationChain')) `
        '06 Revocation chain required'
}
catch {
    Fail-Test '06 Revocation chain required' $_.Exception.Message
}

# 07
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'requireUserBinding')) `
        '07 User binding required'
}
catch {
    Fail-Test '07 User binding required' $_.Exception.Message
}

# 08
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'requireSessionBinding')) `
        '08 Session binding required'
}
catch {
    Fail-Test '08 Session binding required' $_.Exception.Message
}

# 09
try {
    Assert-Test `
        ([bool](Get-AuthorizationFreshnessField -Name 'requireExecutionBinding')) `
        '09 Execution binding required'
}
catch {
    Fail-Test '09 Execution binding required' $_.Exception.Message
}

# 10
try {
    Assert-Test `
        ((Get-AuthorizationFreshnessField -Name 'defaultDecision') -eq 'BLOCK') `
        '10 Default decision BLOCK'
}
catch {
    Fail-Test '10 Default decision BLOCK' $_.Exception.Message
}

# ============================================================
# PRIMARY FRESHNESS
# ============================================================

$fresh=New-AuthorizationFreshness `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -Grant $RawGrant `
    -BindingId $BindingId `
    -ExecutionId $ExecutionId `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

if ($fresh.Success -ne $true) {
    throw 'Primary freshness issuance failed.'
}

$FreshnessId=[string]$fresh.FreshnessId
$RawNonce=[string]$fresh.Nonce

# 11
try {
    Assert-Test `
        ($fresh.Success -eq $true -and
         $fresh.Decision -eq 'ALLOW' -and
         -not [string]::IsNullOrWhiteSpace($FreshnessId)) `
        '11 Freshness issued'
}
catch {
    Fail-Test '11 Freshness issued' $_.Exception.Message
}

# 12
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($RawNonce)) `
        '12 Raw nonce returned only to caller'
}
catch {
    Fail-Test '12 Raw nonce returned only to caller' $_.Exception.Message
}

# 13
try {
    $record=Get-AuthorizationFreshnessRecord -FreshnessId $FreshnessId

    $propertyNames=@(
        $record.PSObject.Properties |
        ForEach-Object { $_.Name }
    )

    Assert-Test `
        ($propertyNames -contains 'NonceHash' -and
         $propertyNames -notcontains 'Nonce') `
        '13 Only nonce hash persisted'
}
catch {
    Fail-Test '13 Only nonce hash persisted' $_.Exception.Message
}

# 14
try {
    $valid=Test-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($valid.Success -eq $true -and
         $valid.Decision -eq 'ALLOW') `
        '14 Valid freshness allowed'
}
catch {
    Fail-Test '14 Valid freshness allowed' $_.Exception.Message
}

# 15
try {
    $bad=Test-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce 'INVALID-NONCE' `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '15 Wrong nonce blocked'
}
catch {
    Fail-Test '15 Wrong nonce blocked' $_.Exception.Message
}

# 16
try {
    $bad=Test-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -UserId 'OTHER-USER' `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '16 User mismatch blocked'
}
catch {
    Fail-Test '16 User mismatch blocked' $_.Exception.Message
}

# 17
try {
    $bad=Test-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId 'OTHER-EXECUTION' `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '17 Execution mismatch blocked'
}
catch {
    Fail-Test '17 Execution mismatch blocked' $_.Exception.Message
}

# 18
try {
    $bad=Test-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'WRITE' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '18 Action mismatch blocked'
}
catch {
    Fail-Test '18 Action mismatch blocked' $_.Exception.Message
}

# 19
try {
    $bad=Test-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '19 Tenant mismatch blocked'
}
catch {
    Fail-Test '19 Tenant mismatch blocked' $_.Exception.Message
}

# 20
try {
    $consume=Consume-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($consume.Success -eq $true -and
         $consume.Decision -eq 'ALLOW') `
        '20 Freshness consumed'
}
catch {
    Fail-Test '20 Freshness consumed' $_.Exception.Message
}

# 21
try {
    $replay=Test-AuthorizationFreshness `
        -FreshnessId $FreshnessId `
        -Nonce $RawNonce `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($replay.Success -eq $false -and
         $replay.Decision -eq 'BLOCK') `
        '21 Replay blocked after consumption'
}
catch {
    Fail-Test '21 Replay blocked after consumption' $_.Exception.Message
}

# 22
try {
    $record2=Get-AuthorizationFreshnessRecord -FreshnessId $FreshnessId

    Assert-Test `
        ($record2.Status -eq 'CONSUMED' -and
         -not [string]::IsNullOrWhiteSpace([string]$record2.ConsumedAtUtc)) `
        '22 Consumed state persisted'
}
catch {
    Fail-Test '22 Consumed state persisted' $_.Exception.Message
}

# ============================================================
# 23 — SECONDARY CHAIN REVOCATION
# ============================================================

try {
    $fresh2=New-AuthorizationFreshness `
        -UserId $chain2.User `
        -SessionId $chain2.SessionId `
        -GrantId $chain2.GrantId `
        -Grant $chain2.RawGrant `
        -BindingId $chain2.BindingId `
        -ExecutionId $chain2.Execution `
        -Action $chain2.Action `
        -TenantId $chain2.Tenant `
        -ClientId $chain2.Client `
        -ProjectId $chain2.Project

    if ($fresh2.Success -ne $true) {
        throw "Secondary freshness issuance failed: $($fresh2.Reason)"
    }

    $rev=Revoke-AuthorizationFreshness `
        -FreshnessId $fresh2.FreshnessId

    $revCheck=Test-AuthorizationFreshness `
        -FreshnessId $fresh2.FreshnessId `
        -Nonce $fresh2.Nonce `
        -UserId $chain2.User `
        -SessionId $chain2.SessionId `
        -GrantId $chain2.GrantId `
        -BindingId $chain2.BindingId `
        -ExecutionId $chain2.Execution `
        -Action $chain2.Action `
        -TenantId $chain2.Tenant `
        -ClientId $chain2.Client `
        -ProjectId $chain2.Project

    Assert-Test `
        ($rev.Success -eq $true -and
         $rev.Status -eq 'REVOKED' -and
         $revCheck.Success -eq $false -and
         $revCheck.Decision -eq 'BLOCK') `
        '23 Revoked freshness blocked'
}
catch {
    Fail-Test '23 Revoked freshness blocked' $_.Exception.Message
}

# 24
try {
    $unknown=Test-AuthorizationFreshness `
        -FreshnessId 'FRESH-NOT-FOUND' `
        -Nonce $RawNonce `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($unknown.Success -eq $false -and
         $unknown.Decision -eq 'BLOCK') `
        '24 Unknown freshness blocked'
}
catch {
    Fail-Test '24 Unknown freshness blocked' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-08'
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