Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Credential-Lease.ps1'

. $RuntimeFile

$AuthRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\credential-access-authorization\Credential-Access-Authorization.ps1'
$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'
$FreshnessRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-freshness\Authorization-Freshness.ps1'
$IntegrityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-context-integrity\Authorization-Context-Integrity.ps1'
$RevocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'

. $AuthRuntime
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

# ============================================================
# RESET
# ============================================================

$null=Reset-CredentialLease
$null=Reset-CredentialAccessAuthorization
$null=Reset-AuthorizationContextIntegrity
$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

$Tenant='8A16-TENANT'
$Client='8A16-CLIENT'
$Project='8A16-PROJECT'
$User='8A16-USER'
$Worker='LUCAS'
$Action='READ'
$Connector='google-drive'
$CredentialRef='CREDREF-8A16-001'
$Execution='EXEC-8A16-001'

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
) |
    Where-Object { $_.SessionId } |
    Select-Object -Last 1

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
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) |
    Where-Object { $_.DecisionId } |
    Select-Object -Last 1

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
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) |
    Where-Object { $_.GrantId } |
    Select-Object -Last 1

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
    -ExecutionId $Execution `
    -UserId $User `
    -SessionId $SessionId `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

if ($null -eq $binding -or
    $binding.Success -ne $true) {

    throw 'Execution binding setup failed.'
}

$BindingId=[string]$binding.BindingId

# ============================================================
# FRESHNESS
# ============================================================

$fresh=New-AuthorizationFreshness `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -Grant $RawGrant `
    -BindingId $BindingId `
    -ExecutionId $Execution `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

if ($null -eq $fresh -or
    $fresh.Success -ne $true) {

    throw "Freshness setup failed: $($fresh.Reason)"
}

$FreshnessId=[string]$fresh.FreshnessId
$RawNonce=[string]$fresh.Nonce

# ============================================================
# CONTEXT INTEGRITY
# ============================================================

$integrity=New-AuthorizationContextIntegrity `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $Execution `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce

if ($null -eq $integrity -or
    $integrity.Success -ne $true) {

    throw "Context integrity setup failed: $($integrity.Reason)"
}

$IntegrityId=[string]$integrity.IntegrityId

# ============================================================
# 8A-15 CREDENTIAL AUTHORIZATION
# ============================================================

$credentialAuth=New-CredentialAccessAuthorization `
    -UserId $User `
    -SessionId $SessionId `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -WorkerId $Worker `
    -Action $Action `
    -ConnectorId $Connector `
    -CredentialRef $CredentialRef `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce `
    -IntegrityId $IntegrityId

if ($null -eq $credentialAuth -or
    $credentialAuth.Success -ne $true) {

    throw "Credential authorization setup failed: $($credentialAuth.Reason)"
}

$CredentialAuthorizationId=[string]$credentialAuth.AuthorizationId

# ============================================================
# 01-10 CONFIG
# ============================================================

try {
    Assert-Test `
        ($null -ne (Get-CredentialLeaseConfig)) `
        '01 Config loaded'
}
catch {
    Fail-Test '01 Config loaded' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'credentialLeaseEnabled')) `
        '02 Credential lease enabled'
}
catch {
    Fail-Test '02 Credential lease enabled' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'timeBoundLeaseEnabled')) `
        '03 Time-bound lease enabled'
}
catch {
    Fail-Test '03 Time-bound lease enabled' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'singleUseLeaseEnabled')) `
        '04 Single-use lease enabled'
}
catch {
    Fail-Test '04 Single-use lease enabled' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'requireCredentialAuthorization')) `
        '05 Credential authorization required'
}
catch {
    Fail-Test '05 Credential authorization required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'requireTenantBinding')) `
        '06 Tenant binding required'
}
catch {
    Fail-Test '06 Tenant binding required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'requireClientBinding')) `
        '07 Client binding required'
}
catch {
    Fail-Test '07 Client binding required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'requireProjectBinding')) `
        '08 Project binding required'
}
catch {
    Fail-Test '08 Project binding required' $_.Exception.Message
}

try {
    Assert-Test `
        ([bool](Get-CredentialLeaseField -Name 'requireWorkerBinding')) `
        '09 Worker binding required'
}
catch {
    Fail-Test '09 Worker binding required' $_.Exception.Message
}

try {
    Assert-Test `
        ((Get-CredentialLeaseField -Name 'defaultDecision') -eq 'BLOCK') `
        '10 Default decision BLOCK'
}
catch {
    Fail-Test '10 Default decision BLOCK' $_.Exception.Message
}

# ============================================================
# 11 — CREATE LEASE
# ============================================================

$lease=New-CredentialLease `
    -CredentialAuthorizationId $CredentialAuthorizationId `
    -UserId $User `
    -SessionId $SessionId `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -WorkerId $Worker `
    -Action $Action `
    -ConnectorId $Connector `
    -CredentialRef $CredentialRef `
    -ExecutionId $Execution

if ($null -eq $lease -or
    $lease.Success -ne $true) {

    throw "Lease creation failed: $($lease.Reason)"
}

$LeaseId=[string]$lease.LeaseId

# 11
try {
    Assert-Test `
        ($lease.Success -eq $true -and
         $lease.Decision -eq 'ALLOW') `
        '11 Credential lease created'
}
catch {
    Fail-Test '11 Credential lease created' $_.Exception.Message
}

# 12
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($LeaseId)) `
        '12 Lease identifier generated'
}
catch {
    Fail-Test '12 Lease identifier generated' $_.Exception.Message
}

# 13
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace([string]$lease.ExpiresAtUtc)) `
        '13 Lease expiration defined'
}
catch {
    Fail-Test '13 Lease expiration defined' $_.Exception.Message
}

# 14
try {
    $record=Get-CredentialLeaseRecord -LeaseId $LeaseId

    Assert-Test `
        ($null -ne $record -and
         $record.Status -eq 'ACTIVE' -and
         $record.CredentialAuthorizationId -eq $CredentialAuthorizationId) `
        '14 Active lease persisted'
}
catch {
    Fail-Test '14 Active lease persisted' $_.Exception.Message
}

# 15
try {
    $valid=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    Assert-Test `
        ($valid.Success -eq $true -and
         $valid.Decision -eq 'ALLOW') `
        '15 Valid credential lease allowed'
}
catch {
    Fail-Test '15 Valid credential lease allowed' $_.Exception.Message
}

# 16
try {
    $bad=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef 'OTHER-CREDENTIAL' `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '16 Wrong credential reference blocked'
}
catch {
    Fail-Test '16 Wrong credential reference blocked' $_.Exception.Message
}

# 17
try {
    $bad=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '17 Cross-tenant lease use blocked'
}
catch {
    Fail-Test '17 Cross-tenant lease use blocked' $_.Exception.Message
}

# 18
try {
    $bad=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId 'SAM' `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '18 Worker substitution blocked'
}
catch {
    Fail-Test '18 Worker substitution blocked' $_.Exception.Message
}

# 19
try {
    $bad=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action 'WRITE' `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '19 Action substitution blocked'
}
catch {
    Fail-Test '19 Action substitution blocked' $_.Exception.Message
}

# 20
try {
    $bad=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId 'github' `
        -ExecutionId $Execution

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '20 Connector substitution blocked'
}
catch {
    Fail-Test '20 Connector substitution blocked' $_.Exception.Message
}

# 21
try {
    $bad=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT' `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '21 Cross-project lease use blocked'
}
catch {
    Fail-Test '21 Cross-project lease use blocked' $_.Exception.Message
}

# 22
try {
    $bad=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId 'OTHER-EXECUTION'

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '22 Execution substitution blocked'
}
catch {
    Fail-Test '22 Execution substitution blocked' $_.Exception.Message
}

# 23
try {
    $consume=Consume-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    $replay=Test-CredentialLease `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector `
        -ExecutionId $Execution

    Assert-Test `
        ($consume.Success -eq $true -and
         $consume.Decision -eq 'ALLOW' -and
         $replay.Success -eq $false -and
         $replay.Decision -eq 'BLOCK') `
        '23 Consumed lease cannot be replayed'
}
catch {
    Fail-Test '23 Consumed lease cannot be replayed' $_.Exception.Message
}

# 24
try {
    $recordFinal=Get-CredentialLeaseRecord `
        -LeaseId $LeaseId

    $propertyNames=@(
        $recordFinal.PSObject.Properties |
        ForEach-Object { $_.Name }
    )

    Assert-Test `
        ($recordFinal.Status -eq 'CONSUMED' -and
         $propertyNames -contains 'CredentialRef' -and
         $propertyNames -notcontains 'CredentialSecret' -and
         $propertyNames -notcontains 'RawSecret' -and
         $propertyNames -notcontains 'Secret') `
        '24 Consumed lease retained without raw secret'
}
catch {
    Fail-Test '24 Consumed lease retained without raw secret' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-16'
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