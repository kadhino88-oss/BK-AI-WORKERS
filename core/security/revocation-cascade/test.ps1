Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot

$RuntimeFile=Join-Path $BasePath 'Revocation-Cascade.ps1'
. $RuntimeFile

$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

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

# ============================================================
# RESET
# ============================================================

$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

$Tenant='8A07-TENANT'
$Client='8A07-CLIENT'
$Project='8A07-PROJECT'
$User='8A07-USER'
$ExecutionId='EXEC-8A07-001'

# ============================================================
# IDENTITY
# ============================================================

$null=New-IdentityUser `
    -UserId $User `
    -Username $User `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -AccountStatus 'ACTIVE'

$session=@(
    New-IdentitySession `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) | Where-Object { $_.SessionId } | Select-Object -Last 1

if ($null -eq $session) {
    throw 'Session setup failed.'
}

$SessionId=[string]$session.SessionId

# ============================================================
# RBAC
# ============================================================

$null=New-RBACBinding `
    -PrincipalId $User `
    -RoleId 'ROLE-OWNER' `
    -ScopeType 'TENANT' `
    -ScopeId $Tenant

# ============================================================
# AUTHORIZATION
# ============================================================

$auth=@(
    Authorize-Request `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) | Where-Object { $_.DecisionId } | Select-Object -Last 1

if ($null -eq $auth -or
    $auth.Success -ne $true) {
    throw 'Authorization setup failed.'
}

# ============================================================
# GRANT
# ============================================================

$grant=@(
    New-AuthorizationGrant `
        -AuthorizationId $auth.DecisionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) | Where-Object { $_.GrantId } | Select-Object -Last 1

if ($null -eq $grant -or
    $grant.Success -ne $true) {
    throw 'Grant setup failed.'
}

$GrantId=[string]$grant.GrantId
$RawGrant=[string]$grant.Grant

# ============================================================
# EXECUTION BINDING
# ============================================================

$binding=New-ExecutionGrantBinding `
    -GrantId $GrantId `
    -Grant $RawGrant `
    -ExecutionId $ExecutionId `
    -UserId $User `
    -SessionId $SessionId `
    -Action 'READ' `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

if ($binding.Success -ne $true) {
    throw 'Execution binding setup failed.'
}

$BindingId=[string]$binding.BindingId

# ============================================================
# 01 — CONFIG
# ============================================================

try {
    Assert-Test `
        ($null -ne (Get-RevocationCascadeConfig)) `
        '01 Config loaded'
}
catch {
    Fail-Test '01 Config loaded' $_.Exception.Message
}

# 02
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'revocationCascadeEnabled')) `
        '02 Revocation cascade enabled'
}
catch {
    Fail-Test '02 Revocation cascade enabled' $_.Exception.Message
}

# 03
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'sessionRevocationBlocksAuthorization')) `
        '03 Session revocation blocks authorization'
}
catch {
    Fail-Test '03 Session revocation blocks authorization' $_.Exception.Message
}

# 04
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'grantRevocationBlocksAuthorization')) `
        '04 Grant revocation blocks authorization'
}
catch {
    Fail-Test '04 Grant revocation blocks authorization' $_.Exception.Message
}

# 05
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'executionBindingRevocationAware')) `
        '05 Execution binding revocation aware'
}
catch {
    Fail-Test '05 Execution binding revocation aware' $_.Exception.Message
}

# 06
try {
    Assert-Test `
        ([string](Get-RevocationCascadeField -Name 'defaultDecision') -eq 'BLOCK') `
        '06 Default decision BLOCK'
}
catch {
    Fail-Test '06 Default decision BLOCK' $_.Exception.Message
}

# 07
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'requireIdentityState')) `
        '07 Identity state required'
}
catch {
    Fail-Test '07 Identity state required' $_.Exception.Message
}

# 08
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'requireSessionState')) `
        '08 Session state required'
}
catch {
    Fail-Test '08 Session state required' $_.Exception.Message
}

# 09
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'requireGrantState')) `
        '09 Grant state required'
}
catch {
    Fail-Test '09 Grant state required' $_.Exception.Message
}

# 10
try {
    Assert-Test `
        ([bool](Get-RevocationCascadeField -Name 'requireExecutionBindingState')) `
        '10 Execution binding state required'
}
catch {
    Fail-Test '10 Execution binding state required' $_.Exception.Message
}

# 11
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $true -and $r.Decision -eq 'ALLOW') `
        '11 Active revocation chain allowed'
}
catch {
    Fail-Test '11 Active revocation chain allowed' $_.Exception.Message
}

# 12
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -Grant 'INVALID-GRANT' `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '12 Invalid grant blocked'
}
catch {
    Fail-Test '12 Invalid grant blocked' $_.Exception.Message
}

# 13
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId 'OTHER-SESSION' `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '13 Session mismatch blocked'
}
catch {
    Fail-Test '13 Session mismatch blocked' $_.Exception.Message
}

# 14
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '14 Tenant mismatch blocked'
}
catch {
    Fail-Test '14 Tenant mismatch blocked' $_.Exception.Message
}

# 15
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'WRITE' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '15 Action mismatch blocked'
}
catch {
    Fail-Test '15 Action mismatch blocked' $_.Exception.Message
}

# 16
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -BindingId 'GEB-NOT-FOUND' `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '16 Missing execution binding blocked'
}
catch {
    Fail-Test '16 Missing execution binding blocked' $_.Exception.Message
}

# 17
try {
    $revokeGrant=Revoke-AuthorizationGrant -GrantId $GrantId

    Assert-Test `
        ($revokeGrant.Success -eq $true -and
         $revokeGrant.Status -eq 'REVOKED') `
        '17 Grant revocation recorded'
}
catch {
    Fail-Test '17 Grant revocation recorded' $_.Exception.Message
}

# 18
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -BindingId $BindingId `
        -ExecutionId $ExecutionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and
         $r.Decision -eq 'BLOCK') `
        '18 Revoked grant blocks chain'
}
catch {
    Fail-Test '18 Revoked grant blocks chain' $_.Exception.Message
}

# Fresh grant for session cascade
$auth2=@(
    Authorize-Request `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) | Where-Object { $_.DecisionId } | Select-Object -Last 1

$grant2=@(
    New-AuthorizationGrant `
        -AuthorizationId $auth2.DecisionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) | Where-Object { $_.GrantId } | Select-Object -Last 1

$GrantId2=[string]$grant2.GrantId
$RawGrant2=[string]$grant2.Grant

$binding2=New-ExecutionGrantBinding `
    -GrantId $GrantId2 `
    -Grant $RawGrant2 `
    -ExecutionId 'EXEC-8A07-002' `
    -UserId $User `
    -SessionId $SessionId `
    -Action 'READ' `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

$BindingId2=[string]$binding2.BindingId

# 19
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId2 `
        -Grant $RawGrant2 `
        -BindingId $BindingId2 `
        -ExecutionId 'EXEC-8A07-002' `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $true -and
         $r.Decision -eq 'ALLOW') `
        '19 Fresh chain allowed'
}
catch {
    Fail-Test '19 Fresh chain allowed' $_.Exception.Message
}

# 20 — SESSION REVOCATION
try {
    $revokedSession=Revoke-IdentitySession -SessionId $SessionId

    Assert-Test `
        ($null -ne $revokedSession -and
         $revokedSession.Success -eq $true) `
        '20 Session revocation recorded'
}
catch {
    Fail-Test '20 Session revocation recorded' $_.Exception.Message
}

# 21 — SESSION CASCADE
try {
    $r=Test-RevocationCascade `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId2 `
        -Grant $RawGrant2 `
        -BindingId $BindingId2 `
        -ExecutionId 'EXEC-8A07-002' `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and
         $r.Decision -eq 'BLOCK') `
        '21 Revoked session cascades to authorization'
}
catch {
    Fail-Test '21 Revoked session cascades to authorization' $_.Exception.Message
}

# 22
try {
    $event=Register-RevocationEvent `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId2 `
        -BindingId $BindingId2 `
        -ExecutionId 'EXEC-8A07-002' `
        -Reason 'SESSION_REVOKED'

    Assert-Test `
        ($null -ne $event -and
         $event.Status -eq 'RECORDED') `
        '22 Revocation event recorded'
}
catch {
    Fail-Test '22 Revocation event recorded' $_.Exception.Message
}

# 23
try {
    $records=@(Get-RevocationCascadeRecords)

    Assert-Test `
        (@($records | Where-Object {
            $_.GrantId -eq $GrantId2 -and
            $_.SessionId -eq $SessionId -and
            $_.Reason -eq 'SESSION_REVOKED'
        }).Count -eq 1) `
        '23 Revocation provenance persisted'
}
catch {
    Fail-Test '23 Revocation provenance persisted' $_.Exception.Message
}

# 24
try {
    $record=Get-RevocationCascadeRecord -RecordId $event.RecordId

    Assert-Test `
        ($null -ne $record -and
         $record.UserId -eq $User -and
         $record.SessionId -eq $SessionId -and
         $record.GrantId -eq $GrantId2 -and
         $record.BindingId -eq $BindingId2 -and
         $record.ExecutionId -eq 'EXEC-8A07-002') `
        '24 Revocation context fully bound'
}
catch {
    Fail-Test '24 Revocation context fully bound' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-07'
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