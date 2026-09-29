Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$RuntimeFile=Join-Path $PSScriptRoot 'Authorization-Grant-Execution.ps1'

. $RuntimeFile

$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

. $GrantRuntime
. $GatewayRuntime
. $IdentityRuntime
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

$Tenant='8A06-TENANT'
$Client='8A06-CLIENT'
$Project='8A06-PROJECT'
$User='8A06-USER'

$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGrants
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

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

$null=New-RBACBinding `
    -PrincipalId $User `
    -RoleId 'ROLE-OWNER' `
    -ScopeType 'TENANT' `
    -ScopeId $Tenant

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
    $auth.Success -ne $true -or
    $auth.Decision -ne 'ALLOW') {
    throw 'Authorization setup failed.'
}

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
$ExecutionId='EXEC-8A06-001'

# 01
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'executionBindingEnabled')) '01 Execution binding enabled' } catch { Fail-Test '01 Execution binding enabled' $_.Exception.Message }

# 02
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'singleExecutionPerGrant')) '02 Single execution per grant' } catch { Fail-Test '02 Single execution per grant' $_.Exception.Message }

# 03
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'requireGrantValidation')) '03 Grant validation required' } catch { Fail-Test '03 Grant validation required' $_.Exception.Message }

# 04
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'requireExecutionId')) '04 ExecutionId required' } catch { Fail-Test '04 ExecutionId required' $_.Exception.Message }

# 05
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'bindUser')) '05 User binding enabled' } catch { Fail-Test '05 User binding enabled' $_.Exception.Message }

# 06
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'bindSession')) '06 Session binding enabled' } catch { Fail-Test '06 Session binding enabled' $_.Exception.Message }

# 07
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'bindAction')) '07 Action binding enabled' } catch { Fail-Test '07 Action binding enabled' $_.Exception.Message }

# 08
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'bindTenant')) '08 Tenant binding enabled' } catch { Fail-Test '08 Tenant binding enabled' $_.Exception.Message }

# 09
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'bindClient')) '09 Client binding enabled' } catch { Fail-Test '09 Client binding enabled' $_.Exception.Message }

# 10
try { Assert-Test ([bool](Get-GrantExecutionField -Name 'bindProject')) '10 Project binding enabled' } catch { Fail-Test '10 Project binding enabled' $_.Exception.Message }

# 11
try {
    $bound=New-ExecutionGrantBinding `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($bound.Success -eq $true -and $bound.Status -eq 'BOUND') `
        '11 Grant bound to execution'
}
catch { Fail-Test '11 Grant bound to execution' $_.Exception.Message }

# 12
try {
    $record=Get-GrantExecutionBinding -BindingId $bound.BindingId

    Assert-Test `
        ($null -ne $record -and
         $record.GrantId -eq $GrantId -and
         $record.ExecutionId -eq $ExecutionId) `
        '12 Binding persisted'
}
catch { Fail-Test '12 Binding persisted' $_.Exception.Message }

# 13
try {
    $valid=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($valid.Success -eq $true -and $valid.Decision -eq 'ALLOW') `
        '13 Valid execution binding allowed'
}
catch { Fail-Test '13 Valid execution binding allowed' $_.Exception.Message }

# 14
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId 'EXEC-OTHER' `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '14 Execution mismatch blocked'
}
catch { Fail-Test '14 Execution mismatch blocked' $_.Exception.Message }

# 15
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId 'OTHER-USER' `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '15 User mismatch blocked'
}
catch { Fail-Test '15 User mismatch blocked' $_.Exception.Message }

# 16
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId 'OTHER-SESSION' `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '16 Session mismatch blocked'
}
catch { Fail-Test '16 Session mismatch blocked' $_.Exception.Message }

# 17
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'WRITE' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '17 Action mismatch blocked'
}
catch { Fail-Test '17 Action mismatch blocked' $_.Exception.Message }

# 18
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '18 Tenant mismatch blocked'
}
catch { Fail-Test '18 Tenant mismatch blocked' $_.Exception.Message }

# 19
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '19 Client mismatch blocked'
}
catch { Fail-Test '19 Client mismatch blocked' $_.Exception.Message }

# 20
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT'

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '20 Project mismatch blocked'
}
catch { Fail-Test '20 Project mismatch blocked' $_.Exception.Message }

# 21
try {
    $r=New-ExecutionGrantBinding `
        -GrantId $GrantId `
        -Grant $RawGrant `
        -ExecutionId 'EXEC-OTHER' `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Status -eq 'DUPLICATE') `
        '21 Grant reuse blocked'
}
catch { Fail-Test '21 Grant reuse blocked' $_.Exception.Message }

# 22
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId 'GEB-NOT-FOUND' `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '22 Unknown binding blocked'
}
catch { Fail-Test '22 Unknown binding blocked' $_.Exception.Message }

# 23
try {
    $r=Complete-ExecutionGrantBinding -BindingId $bound.BindingId

    Assert-Test `
        ($r.Success -eq $true -and $r.Status -eq 'COMPLETED') `
        '23 Execution binding completed'
}
catch { Fail-Test '23 Execution binding completed' $_.Exception.Message }

# 24
try {
    $r=Test-ExecutionGrantBinding `
        -BindingId $bound.BindingId `
        -ExecutionId $ExecutionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project

    Assert-Test `
        ($r.Success -eq $false -and $r.Decision -eq 'BLOCK') `
        '24 Completed binding cannot be reused'
}
catch { Fail-Test '24 Completed binding cannot be reused' $_.Exception.Message }

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-06'
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