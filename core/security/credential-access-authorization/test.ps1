Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Credential-Access-Authorization.ps1'

. $RuntimeFile

$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'
$FreshnessRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-freshness\Authorization-Freshness.ps1'
$IntegrityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-context-integrity\Authorization-Context-Integrity.ps1'
$RevocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'

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

$null=Reset-CredentialAccessAuthorization
$null=Reset-AuthorizationContextIntegrity
$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

$Tenant='8A15-TENANT'
$Client='8A15-CLIENT'
$Project='8A15-PROJECT'
$User='8A15-USER'
$Worker='LUCAS'
$Task='TASK-CRED-001'
$Action='READ'
$Connector='google-drive'
$CredentialRef='CREDREF-8A15-GDRIVE-001'

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

$null=New-RBACBinding `
    -PrincipalId $User `
    -RoleId 'ROLE-OWNER' `
    -ScopeType 'TENANT' `
    -ScopeId $Tenant

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

$GrantId=[string]$grant.GrantId
$RawGrant=[string]$grant.Grant

$binding=New-ExecutionGrantBinding `
    -GrantId $GrantId `
    -Grant $RawGrant `
    -ExecutionId 'EXEC-8A15-001' `
    -UserId $User `
    -SessionId $SessionId `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

$BindingId=[string]$binding.BindingId
$ExecutionId='EXEC-8A15-001'

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

$FreshnessId=[string]$fresh.FreshnessId
$RawNonce=[string]$fresh.Nonce

$integrity=New-AuthorizationContextIntegrity `
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

$IntegrityId=[string]$integrity.IntegrityId

# ============================================================
# 01-10 CONFIG
# ============================================================

try { Assert-Test ($null -ne (Get-CredentialAccessAuthorizationConfig)) '01 Config loaded' }
catch { Fail-Test '01 Config loaded' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'credentialAccessAuthorizationEnabled')) '02 Credential access authorization enabled' }
catch { Fail-Test '02 Credential access authorization enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'leastPrivilegeEnabled')) '03 Least privilege enabled' }
catch { Fail-Test '03 Least privilege enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'requireTenantBinding')) '04 Tenant binding required' }
catch { Fail-Test '04 Tenant binding required' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'requireClientBinding')) '05 Client binding required' }
catch { Fail-Test '05 Client binding required' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'requireProjectBinding')) '06 Project binding required' }
catch { Fail-Test '06 Project binding required' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'requireWorkerBinding')) '07 Worker binding required' }
catch { Fail-Test '07 Worker binding required' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'requireActionBinding')) '08 Action binding required' }
catch { Fail-Test '08 Action binding required' $_.Exception.Message }

try { Assert-Test ([bool](Get-CredentialAccessAuthorizationField -Name 'neverPersistRawSecrets')) '09 Raw secrets never persisted' }
catch { Fail-Test '09 Raw secrets never persisted' $_.Exception.Message }

try { Assert-Test ((Get-CredentialAccessAuthorizationField -Name 'defaultDecision') -eq 'BLOCK') '10 Default decision BLOCK' }
catch { Fail-Test '10 Default decision BLOCK' $_.Exception.Message }

# ============================================================
# AUTHORIZATION
# ============================================================

$authorization=New-CredentialAccessAuthorization `
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

if ($null -eq $authorization -or
    $authorization.Success -ne $true) {

    throw "Credential authorization setup failed: $($authorization.Reason)"
}

$AuthorizationId=[string]$authorization.AuthorizationId

# 11
try {
    Assert-Test `
        ($authorization.Success -eq $true -and
         $authorization.Decision -eq 'ALLOW') `
        '11 Credential access authorized'
}
catch {
    Fail-Test '11 Credential access authorized' $_.Exception.Message
}

# 12
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($AuthorizationId)) `
        '12 Authorization identifier generated'
}
catch {
    Fail-Test '12 Authorization identifier generated' $_.Exception.Message
}

# 13
try {
    $record=Get-CredentialAccessAuthorizationRecord `
        -AuthorizationId $AuthorizationId

    Assert-Test `
        ($null -ne $record -and
         $record.CredentialRefHash -eq $authorization.CredentialRefHash) `
        '13 Credential reference hash persisted'
}
catch {
    Fail-Test '13 Credential reference hash persisted' $_.Exception.Message
}

# 14
try {
    $record=Get-CredentialAccessAuthorizationRecord `
        -AuthorizationId $AuthorizationId

    $propertyNames=@(
        $record.PSObject.Properties |
        ForEach-Object { $_.Name }
    )

    Assert-Test `
        ($propertyNames -notcontains 'CredentialSecret' -and
         $propertyNames -notcontains 'RawSecret' -and
         $propertyNames -notcontains 'Secret') `
        '14 Raw credential secret not persisted'
}
catch {
    Fail-Test '14 Raw credential secret not persisted' $_.Exception.Message
}

# 15
try {
    $valid=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector

    Assert-Test `
        ($valid.Success -eq $true -and
         $valid.Decision -eq 'ALLOW') `
        '15 Valid credential authorization allowed'
}
catch {
    Fail-Test '15 Valid credential authorization allowed' $_.Exception.Message
}

# 16
try {
    $bad=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef 'OTHER-CREDENTIAL' `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector

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
    $bad=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '17 Cross-tenant credential access blocked'
}
catch {
    Fail-Test '17 Cross-tenant credential access blocked' $_.Exception.Message
}

# 18
try {
    $bad=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '18 Cross-client credential access blocked'
}
catch {
    Fail-Test '18 Cross-client credential access blocked' $_.Exception.Message
}

# 19
try {
    $bad=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT' `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '19 Cross-project credential access blocked'
}
catch {
    Fail-Test '19 Cross-project credential access blocked' $_.Exception.Message
}

# 20
try {
    $bad=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId 'SAM' `
        -Action $Action `
        -ConnectorId $Connector

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '20 Cross-worker credential access blocked'
}
catch {
    Fail-Test '20 Cross-worker credential access blocked' $_.Exception.Message
}

# 21
try {
    $bad=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action 'WRITE' `
        -ConnectorId $Connector

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '21 Action substitution blocked'
}
catch {
    Fail-Test '21 Action substitution blocked' $_.Exception.Message
}

# 22
try {
    $bad=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId 'github'

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '22 Connector substitution blocked'
}
catch {
    Fail-Test '22 Connector substitution blocked' $_.Exception.Message
}

# 23
try {
    $invalidated=Invalidate-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId

    $after=Test-CredentialAccessAuthorization `
        -AuthorizationId $AuthorizationId `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector

    Assert-Test `
        ($invalidated.Success -eq $true -and
         $invalidated.Status -eq 'INVALIDATED' -and
         $after.Success -eq $false -and
         $after.Decision -eq 'BLOCK') `
        '23 Invalidated credential authorization blocked'
}
catch {
    Fail-Test '23 Invalidated credential authorization blocked' $_.Exception.Message
}

# 24
try {
    $unknown=Test-CredentialAccessAuthorization `
        -AuthorizationId 'CRED-AUTH-NOT-FOUND' `
        -CredentialRef $CredentialRef `
        -UserId $User `
        -SessionId $SessionId `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -Action $Action `
        -ConnectorId $Connector

    Assert-Test `
        ($unknown.Success -eq $false -and
         $unknown.Decision -eq 'BLOCK') `
        '24 Unknown credential authorization blocked'
}
catch {
    Fail-Test '24 Unknown credential authorization blocked' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-15'
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