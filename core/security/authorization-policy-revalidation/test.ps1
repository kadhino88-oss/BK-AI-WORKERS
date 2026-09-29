Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Authorization-Policy-Revalidation.ps1'

. $RuntimeFile

$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

. $IdentityRuntime
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

$null=Reset-AuthorizationPolicyRevalidation
$null=Reset-IdentityAuth
$null=Reset-RBAC
$null=Reset-AuthorizationGateway

$Tenant='8A11-TENANT'
$Client='8A11-CLIENT'
$Project='8A11-PROJECT'
$User='8A11-USER'
$Action='READ'

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
# RBAC ALLOW
# ============================================================

$null=New-RBACBinding `
    -PrincipalId $User `
    -RoleId 'ROLE-OWNER' `
    -ScopeType 'TENANT' `
    -ScopeId $Tenant

# ============================================================
# 01-10 CONFIG
# ============================================================

try { Assert-Test ($null -ne (Get-AuthorizationPolicyRevalidationConfig)) '01 Config loaded' }
catch { Fail-Test '01 Config loaded' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'policyRevalidationEnabled')) '02 Policy revalidation enabled' }
catch { Fail-Test '02 Policy revalidation enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'rbacDriftDetectionEnabled')) '03 RBAC drift detection enabled' }
catch { Fail-Test '03 RBAC drift detection enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'failClosed')) '04 Fail closed enabled' }
catch { Fail-Test '04 Fail closed enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'requireIdentityState')) '05 Identity state required' }
catch { Fail-Test '05 Identity state required' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'requireSessionState')) '06 Session state required' }
catch { Fail-Test '06 Session state required' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'requireCurrentRbacDecision')) '07 Current RBAC decision required' }
catch { Fail-Test '07 Current RBAC decision required' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'requireRevocationChain')) '08 Revocation chain required' }
catch { Fail-Test '08 Revocation chain required' $_.Exception.Message }

try { Assert-Test ([bool](Get-AuthorizationPolicyRevalidationField -Name 'requireFreshnessValidation')) '09 Freshness validation required' }
catch { Fail-Test '09 Freshness validation required' $_.Exception.Message }

try { Assert-Test ((Get-AuthorizationPolicyRevalidationField -Name 'defaultDecision') -eq 'BLOCK') '10 Default decision BLOCK' }
catch { Fail-Test '10 Default decision BLOCK' $_.Exception.Message }

# ============================================================
# SNAPSHOT
# ============================================================

$snapshot=New-AuthorizationPolicySnapshot `
    -UserId $User `
    -SessionId $SessionId `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

if ($snapshot.Success -ne $true) {
    throw "Snapshot creation failed: $($snapshot.Reason)"
}

$PolicyRecordId=[string]$snapshot.PolicyRecordId

# 11
try {
    Assert-Test `
        ($snapshot.Success -eq $true -and
         $snapshot.Decision -eq 'ALLOW') `
        '11 Authorization policy snapshot created'
}
catch {
    Fail-Test '11 Authorization policy snapshot created' $_.Exception.Message
}

# 12
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($PolicyRecordId)) `
        '12 Policy record identifier generated'
}
catch {
    Fail-Test '12 Policy record identifier generated' $_.Exception.Message
}

# 13
try {
    $record=Get-AuthorizationPolicyRecord `
        -PolicyRecordId $PolicyRecordId

    Assert-Test `
        ($null -ne $record -and
         $record.Decision -eq 'ALLOW' -and
         $record.Status -eq 'ACTIVE') `
        '13 Active policy snapshot persisted'
}
catch {
    Fail-Test '13 Active policy snapshot persisted' $_.Exception.Message
}

# 14
try {
    $valid=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($valid.Success -eq $true -and
         $valid.Decision -eq 'ALLOW') `
        '14 Current authorization still allowed'
}
catch {
    Fail-Test '14 Current authorization still allowed' $_.Exception.Message
}

# 15
try {
    $bad=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId 'OTHER-USER' `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '15 User drift blocked'
}
catch {
    Fail-Test '15 User drift blocked' $_.Exception.Message
}

# 16
try {
    $bad=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'WRITE' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '16 Action drift blocked'
}
catch {
    Fail-Test '16 Action drift blocked' $_.Exception.Message
}

# 17
try {
    $bad=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '17 Tenant drift blocked'
}
catch {
    Fail-Test '17 Tenant drift blocked' $_.Exception.Message
}

# 18
try {
    $bad=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $Project

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '18 Client drift blocked'
}
catch {
    Fail-Test '18 Client drift blocked' $_.Exception.Message
}

# 19
try {
    $bad=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT'

    Assert-Test `
        ($bad.Success -eq $false -and
         $bad.Decision -eq 'BLOCK') `
        '19 Project drift blocked'
}
catch {
    Fail-Test '19 Project drift blocked' $_.Exception.Message
}

# ============================================================
# 20 — RBAC DRIFT
# Rebuild state with no effective permission
# ============================================================

try {
    $null=Reset-RBAC

    $drift=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($drift.Success -eq $false -and
         $drift.Decision -eq 'BLOCK') `
        '20 RBAC revocation drift blocked'
}
catch {
    Fail-Test '20 RBAC revocation drift blocked' $_.Exception.Message
}

# ============================================================
# 21 — RESTORE RBAC
# ============================================================

try {
    $null=New-RBACBinding `
        -PrincipalId $User `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'TENANT' `
        -ScopeId $Tenant

    $restored=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($restored.Success -eq $true -and
         $restored.Decision -eq 'ALLOW') `
        '21 Restored RBAC authorization allowed'
}
catch {
    Fail-Test '21 Restored RBAC authorization allowed' $_.Exception.Message
}

# 22
try {
    $null=Invalidate-AuthorizationPolicySnapshot `
        -PolicyRecordId $PolicyRecordId

    $invalid=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId $PolicyRecordId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($invalid.Success -eq $false -and
         $invalid.Decision -eq 'BLOCK') `
        '22 Invalidated policy snapshot blocked'
}
catch {
    Fail-Test '22 Invalidated policy snapshot blocked' $_.Exception.Message
}

# 23
try {
    $unknown=Test-AuthorizationPolicyRevalidation `
        -PolicyRecordId 'POLICY-NOT-FOUND' `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($unknown.Success -eq $false -and
         $unknown.Decision -eq 'BLOCK') `
        '23 Unknown policy record blocked'
}
catch {
    Fail-Test '23 Unknown policy record blocked' $_.Exception.Message
}

# 24
try {
    $recordFinal=Get-AuthorizationPolicyRecord `
        -PolicyRecordId $PolicyRecordId

    Assert-Test `
        ($recordFinal.Status -eq 'INVALIDATED' -and
         $recordFinal.Decision -eq 'ALLOW' -and
         -not [string]::IsNullOrWhiteSpace([string]$recordFinal.ContextHash)) `
        '24 Policy provenance retained after invalidation'
}
catch {
    Fail-Test '24 Policy provenance retained after invalidation' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-11'
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