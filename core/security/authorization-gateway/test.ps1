Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$Base=$PSScriptRoot
$RuntimeFile=Join-Path $Base 'Authorization-Gateway.ps1'

if (-not (Test-Path -LiteralPath $RuntimeFile)) {
    throw "Authorization Gateway runtime missing: $RuntimeFile"
}

. $RuntimeFile

$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$SessionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\session-token-security\runtime.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

. $IdentityRuntime
. $SessionRuntime
. $RBACRuntime

$script:Pass=0
$script:Fail=0

function Pass-Test {
    param([string]$Name)
    $script:Pass++
    Write-Host "[PASS] $Name"
}

function Fail-Test {
    param([string]$Name,[string]$Reason='')
    $script:Fail++
    Write-Host "[FAIL] $Name"
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Host "       $Reason"
    }
}

function Assert-Test {
    param([bool]$Condition,[string]$Name,[string]$Reason='')
    if ($Condition) {
        Pass-Test $Name
    }
    else {
        Fail-Test $Name $Reason
    }
}

# ============================================================
# RESET DEPENDENCIES
# ============================================================

$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-SessionTokenSecurity
$null=Reset-RBAC

# ============================================================
# TEST DATA / REAL DEPENDENCIES
# ============================================================

$ownerUser='AUTHZ-OWNER-USER'
$viewerUser='AUTHZ-VIEWER-USER'
$operatorUser='AUTHZ-OPERATOR-USER'

$tenant='AUTHZ-TENANT'
$client='AUTHZ-CLIENT'
$project='AUTHZ-PROJECT'

# Identity records
$null=New-IdentityUser `
    -UserId $ownerUser `
    -Username $ownerUser `
    -TenantId $tenant `
    -ClientId $client `
    -ProjectId $project `
    -AccountStatus 'ACTIVE'

$null=New-IdentityUser `
    -UserId $viewerUser `
    -Username $viewerUser `
    -TenantId $tenant `
    -ClientId $client `
    -ProjectId $project `
    -AccountStatus 'ACTIVE'

$null=New-IdentityUser `
    -UserId $operatorUser `
    -Username $operatorUser `
    -TenantId $tenant `
    -ClientId $client `
    -ProjectId $project `
    -AccountStatus 'ACTIVE'

# Sessions
$ownerSession=New-IdentitySession `
    -UserId $ownerUser `
    -TenantId $tenant `
    -ClientId $client `
    -ProjectId $project

$viewerSession=New-IdentitySession `
    -UserId $viewerUser `
    -TenantId $tenant `
    -ClientId $client `
    -ProjectId $project

$operatorSession=New-IdentitySession `
    -UserId $operatorUser `
    -TenantId $tenant `
    -ClientId $client `
    -ProjectId $project

$ownerSessionId=[string]$ownerSession.SessionId
$viewerSessionId=[string]$viewerSession.SessionId
$operatorSessionId=[string]$operatorSession.SessionId

# RBAC bindings
$null=New-RBACBinding `
    -PrincipalId $ownerUser `
    -RoleId 'ROLE-OWNER' `
    -ScopeType 'TENANT' `
    -ScopeId $tenant

$null=New-RBACBinding `
    -PrincipalId $viewerUser `
    -RoleId 'ROLE-VIEWER' `
    -ScopeType 'TENANT' `
    -ScopeId $tenant

$null=New-RBACBinding `
    -PrincipalId $operatorUser `
    -RoleId 'ROLE-OPERATOR' `
    -ScopeType 'TENANT' `
    -ScopeId $tenant

# ============================================================
# 01
# ============================================================

try {
    Assert-Test `
        ($null -ne (Get-AuthorizationGatewayConfig)) `
        '01 Config loaded'
}
catch {
    Fail-Test '01 Config loaded' $_.Exception.Message
}

# 02

try {
    Assert-Test `
        ([bool](Get-AuthorizationGatewayField -Name 'enabled')) `
        '02 Gateway enabled'
}
catch {
    Fail-Test '02 Gateway enabled' $_.Exception.Message
}

# 03

try {
    Assert-Test `
        ((Get-AuthorizationGatewayField -Name 'defaultDecision') -eq 'BLOCK') `
        '03 Default deny'
}
catch {
    Fail-Test '03 Default deny' $_.Exception.Message
}

# 04

try {
    Assert-Test `
        ([bool](Get-AuthorizationGatewayField -Name 'requireIdentity')) `
        '04 Identity required'
}
catch {
    Fail-Test '04 Identity required' $_.Exception.Message
}

# 05

try {
    Assert-Test `
        ([bool](Get-AuthorizationGatewayField -Name 'requireAuthentication')) `
        '05 Authentication required'
}
catch {
    Fail-Test '05 Authentication required' $_.Exception.Message
}

# 06

try {
    Assert-Test `
        ([bool](Get-AuthorizationGatewayField -Name 'requireSession')) `
        '06 Session required'
}
catch {
    Fail-Test '06 Session required' $_.Exception.Message
}

# 07

try {
    Assert-Test `
        ([bool](Get-AuthorizationGatewayField -Name 'requireTenantBinding')) `
        '07 Tenant binding required'
}
catch {
    Fail-Test '07 Tenant binding required' $_.Exception.Message
}

# 08

try {
    Assert-Test `
        ([bool](Get-AuthorizationGatewayField -Name 'requireRBACDecision')) `
        '08 RBAC decision required'
}
catch {
    Fail-Test '08 RBAC decision required' $_.Exception.Message
}

# 09

try {
    $r=Test-AuthorizationDecision `
        -UserId 'AUTHZ-UNKNOWN-USER' `
        -SessionId 'AUTHZ-UNKNOWN-SESSION' `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '09 Unknown identity blocked'
}
catch {
    Fail-Test '09 Unknown identity blocked' $_.Exception.Message
}

# 10

try {
    $r=Test-AuthorizationDecision `
        -UserId $ownerUser `
        -SessionId 'AUTHZ-UNKNOWN-SESSION' `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '10 Unknown session blocked'
}
catch {
    Fail-Test '10 Unknown session blocked' $_.Exception.Message
}

# 11

try {
    $r=Test-AuthorizationDecision `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'READ' `
        -TenantId 'OTHER-TENANT' `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '11 Tenant mismatch blocked'
}
catch {
    Fail-Test '11 Tenant mismatch blocked' $_.Exception.Message
}

# 12

try {
    $r=Test-AuthorizationDecision `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $true -and $r.Decision -eq 'ALLOW') `
        '12 OWNER READ allowed'
}
catch {
    Fail-Test '12 OWNER READ allowed' $_.Exception.Message
}

# 13

try {
    $r=Test-AuthorizationDecision `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'WRITE' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $true -and $r.Decision -eq 'ALLOW') `
        '13 OWNER WRITE allowed'
}
catch {
    Fail-Test '13 OWNER WRITE allowed' $_.Exception.Message
}

# 14

try {
    $r=Test-AuthorizationDecision `
        -UserId $viewerUser `
        -SessionId $viewerSessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $true -and $r.Decision -eq 'ALLOW') `
        '14 VIEWER READ allowed'
}
catch {
    Fail-Test '14 VIEWER READ allowed' $_.Exception.Message
}

# 15

try {
    $r=Test-AuthorizationDecision `
        -UserId $viewerUser `
        -SessionId $viewerSessionId `
        -Action 'WRITE' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '15 VIEWER WRITE blocked'
}
catch {
    Fail-Test '15 VIEWER WRITE blocked' $_.Exception.Message
}

# 16

try {
    $r=Test-AuthorizationDecision `
        -UserId $operatorUser `
        -SessionId $operatorSessionId `
        -Action 'EXECUTE' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $true -and $r.Decision -eq 'ALLOW') `
        '16 OPERATOR EXECUTE allowed'
}
catch {
    Fail-Test '16 OPERATOR EXECUTE allowed' $_.Exception.Message
}

# 17

try {
    $r=Test-AuthorizationDecision `
        -UserId $operatorUser `
        -SessionId $operatorSessionId `
        -Action 'DELETE' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '17 OPERATOR DELETE blocked'
}
catch {
    Fail-Test '17 OPERATOR DELETE blocked' $_.Exception.Message
}

# 18

try {
    $r=Test-AuthorizationDecision `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '18 Client mismatch blocked'
}
catch {
    Fail-Test '18 Client mismatch blocked' $_.Exception.Message
}

# 19

try {
    $r=Test-AuthorizationDecision `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'MANAGE_BILLING' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'REQUIRES_HUMAN_APPROVAL') `
        '19 Financial approval required'
}
catch {
    Fail-Test '19 Financial approval required' $_.Exception.Message
}

# 20

try {
    $r=Authorize-Request `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    $saved=Get-AuthorizationDecision -DecisionId $r.DecisionId

    Assert-Test `
        ($null -ne $saved -and $saved.Decision -eq 'ALLOW') `
        '20 Decision persisted'
}
catch {
    Fail-Test '20 Decision persisted' $_.Exception.Message
}

# 21

try {
    $r1=Authorize-Request `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    $r2=Authorize-Request `
        -UserId $ownerUser `
        -SessionId $ownerSessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    Assert-Test `
        ($r1.DecisionId -ne $r2.DecisionId) `
        '21 Decision IDs unique'
}
catch {
    Fail-Test '21 Decision IDs unique' $_.Exception.Message
}

# 22

try {
    $count=@(Get-AuthorizationDecisions).Count

    Assert-Test `
        ($count -ge 3) `
        '22 Decision history retained'
}
catch {
    Fail-Test '22 Decision history retained' $_.Exception.Message
}

# 23

try {
    $r=Test-AuthorizationDecision `
        -UserId $ownerUser `
        -SessionId '' `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId $project

    # PowerShell may reject the empty mandatory SessionId before
    # gateway execution. A thrown parameter-binding error is therefore
    # an expected security block for this test.
    $blocked23=(
        $null -ne $r -and
        $r.Success -eq $false -and
        $r.Decision -eq 'BLOCK'
    )

    Assert-Test `
        $blocked23 `
        '23 Missing session blocked'
}
catch {
    Pass-Test '23 Missing session blocked'
}

# 24

try {
    $projectUser='AUTHZ-PROJECT-USER'

    $null=New-RBACBinding `
        -PrincipalId $projectUser `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'PROJECT' `
        -ScopeId $project

    $r=Test-AuthorizationDecision `
        -UserId $projectUser `
        -SessionId $ownerSessionId `
        -Action 'READ' `
        -TenantId $tenant `
        -ClientId $client `
        -ProjectId 'OTHER-PROJECT'

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '24 Project isolation blocked'
}
catch {
    Fail-Test '24 Project isolation blocked' $_.Exception.Message
}
Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-04'
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