Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Worker-Task-Authority.ps1'

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

$null=Reset-WorkerTaskAuthority
$null=Reset-AuthorizationContextIntegrity
$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC

$Tenant='8A12-TENANT'
$Client='8A12-CLIENT'
$Project='8A12-PROJECT'
$User='8A12-USER'
$Worker='LUCAS'
$Task='TASK-001'
$Action='READ'
$Execution='EXEC-8A12-001'

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
    -ExecutionId $Execution `
    -UserId $User `
    -SessionId $SessionId `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

$BindingId=[string]$binding.BindingId

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

$FreshnessId=[string]$fresh.FreshnessId
$RawNonce=[string]$fresh.Nonce

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

$IntegrityId=[string]$integrity.IntegrityId

# ============================================================
# 01-10 CONFIG
# ============================================================

try { Assert-Test ($null -ne (Get-WorkerTaskAuthorityConfig)) '01 Config loaded' }
catch { Fail-Test '01 Config loaded' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'workerTaskAuthorityEnabled')) '02 Worker/task authority enabled' }
catch { Fail-Test '02 Worker/task authority enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'antiConfusedDeputyEnabled')) '03 Anti confused-deputy enabled' }
catch { Fail-Test '03 Anti confused-deputy enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'requireWorkerBinding')) '04 Worker binding required' }
catch { Fail-Test '04 Worker binding required' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'requireTaskBinding')) '05 Task binding required' }
catch { Fail-Test '05 Task binding required' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'rejectWorkerSubstitution')) '06 Worker substitution rejected' }
catch { Fail-Test '06 Worker substitution rejected' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'rejectTaskSubstitution')) '07 Task substitution rejected' }
catch { Fail-Test '07 Task substitution rejected' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'requireRevocationChain')) '08 Revocation chain required' }
catch { Fail-Test '08 Revocation chain required' $_.Exception.Message }

try { Assert-Test ([bool](Get-WorkerTaskAuthorityField -Name 'requireFreshnessValidation')) '09 Freshness validation required' }
catch { Fail-Test '09 Freshness validation required' $_.Exception.Message }

try { Assert-Test ((Get-WorkerTaskAuthorityField -Name 'defaultDecision') -eq 'BLOCK') '10 Default decision BLOCK' }
catch { Fail-Test '10 Default decision BLOCK' $_.Exception.Message }

# ============================================================
# AUTHORITY CREATION
# ============================================================

$authority=New-WorkerTaskAuthority `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $Execution `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -WorkerId $Worker `
    -TaskId $Task `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce `
    -IntegrityId $IntegrityId

if ($null -eq $authority -or $authority.Success -ne $true) {
    throw "Authority creation failed: $($authority.Reason)"
}

$AuthorityId=[string]$authority.AuthorityId

# 11
try {
    Assert-Test `
        ($authority.Decision -eq 'ALLOW') `
        '11 Worker/task authority created'
}
catch {
    Fail-Test '11 Worker/task authority created' $_.Exception.Message
}

# 12
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($AuthorityId)) `
        '12 Authority identifier generated'
}
catch {
    Fail-Test '12 Authority identifier generated' $_.Exception.Message
}

# 13
try {
    $record=Get-WorkerTaskAuthorityRecord -AuthorityId $AuthorityId

    Assert-Test `
        ($null -ne $record -and
         $record.WorkerId -eq $Worker -and
         $record.TaskId -eq $Task) `
        '13 Worker/task binding persisted'
}
catch {
    Fail-Test '13 Worker/task binding persisted' $_.Exception.Message
}

# 14
try {
    $valid=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($valid.Success -eq $true -and $valid.Decision -eq 'ALLOW') `
        '14 Valid worker/task authority allowed'
}
catch {
    Fail-Test '14 Valid worker/task authority allowed' $_.Exception.Message
}

# 15
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId 'SAM' `
        -TaskId $Task

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '15 Worker substitution blocked'
}
catch {
    Fail-Test '15 Worker substitution blocked' $_.Exception.Message
}

# 16
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId 'TASK-002'

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '16 Task substitution blocked'
}
catch {
    Fail-Test '16 Task substitution blocked' $_.Exception.Message
}

# 17
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId 'OTHER-EXECUTION' `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '17 Execution substitution blocked'
}
catch {
    Fail-Test '17 Execution substitution blocked' $_.Exception.Message
}

# 18
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action 'WRITE' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '18 Action substitution blocked'
}
catch {
    Fail-Test '18 Action substitution blocked' $_.Exception.Message
}

# 19
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '19 Tenant substitution blocked'
}
catch {
    Fail-Test '19 Tenant substitution blocked' $_.Exception.Message
}

# 20
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '20 Client substitution blocked'
}
catch {
    Fail-Test '20 Client substitution blocked' $_.Exception.Message
}

# 21
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT' `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '21 Project substitution blocked'
}
catch {
    Fail-Test '21 Project substitution blocked' $_.Exception.Message
}

# 22
try {
    $bad=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId 'OTHER-BINDING' `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($bad.Success -eq $false -and $bad.Decision -eq 'BLOCK') `
        '22 Binding substitution blocked'
}
catch {
    Fail-Test '22 Binding substitution blocked' $_.Exception.Message
}

# 23
try {
    $invalidated=Invalidate-WorkerTaskAuthority `
        -AuthorityId $AuthorityId

    $after=Test-WorkerTaskAuthority `
        -AuthorityId $AuthorityId `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($invalidated.Success -eq $true -and
         $invalidated.Status -eq 'INVALIDATED' -and
         $after.Success -eq $false -and
         $after.Decision -eq 'BLOCK') `
        '23 Invalidated worker/task authority blocked'
}
catch {
    Fail-Test '23 Invalidated worker/task authority blocked' $_.Exception.Message
}

# 24
try {
    $unknown=Test-WorkerTaskAuthority `
        -AuthorityId 'WTA-NOT-FOUND' `
        -UserId $User `
        -SessionId $SessionId `
        -GrantId $GrantId `
        -BindingId $BindingId `
        -ExecutionId $Execution `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task

    Assert-Test `
        ($unknown.Success -eq $false -and
         $unknown.Decision -eq 'BLOCK') `
        '24 Unknown worker/task authority blocked'
}
catch {
    Fail-Test '24 Unknown worker/task authority blocked' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-12'
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