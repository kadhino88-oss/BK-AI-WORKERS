Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RuntimeFile = Join-Path $PSScriptRoot 'Authorization-Grant.ps1'
$GatewayRuntime = 'C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$IdentityRuntime = 'C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$RBACRuntime = 'C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'

if (-not (Test-Path -LiteralPath $RuntimeFile)) {
    throw "Authorization Grant runtime missing: $RuntimeFile"
}

if (-not (Test-Path -LiteralPath $GatewayRuntime)) {
    throw "Authorization Gateway runtime missing: $GatewayRuntime"
}

if (-not (Test-Path -LiteralPath $IdentityRuntime)) {
    throw "Identity runtime missing: $IdentityRuntime"
}

if (-not (Test-Path -LiteralPath $RBACRuntime)) {
    throw "RBAC runtime missing: $RBACRuntime"
}

. $RuntimeFile
. $GatewayRuntime
. $IdentityRuntime
. $RBACRuntime

$script:Pass = 0
$script:Fail = 0

function Pass-Test {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $script:Pass++
    Write-Host "[PASS] $Name"
}

function Fail-Test {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,

        [string]$Reason = ''
    )

    $script:Fail++
    Write-Host "[FAIL] $Name"

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Host "       $Reason"
    }
}

function Assert-Test {
    param(
        [Parameter(Mandatory=$true)]
        [bool]$Condition,

        [Parameter(Mandatory=$true)]
        [string]$Name,

        [string]$Reason = ''
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

$null = Reset-AuthorizationGateway
$null = Reset-AuthorizationGrants
$null = Reset-IdentityAuth
$null = Reset-RBAC

# ============================================================
# TEST CONTEXT
# ============================================================

$TenantId = 'GRANT-TENANT'
$ClientId = 'GRANT-CLIENT'
$ProjectId = 'GRANT-PROJECT'
$UserId = 'GRANT-OWNER-USER'

# ============================================================
# IDENTITY
# ============================================================

try {
    $identityUser = New-IdentityUser `
        -UserId $UserId `
        -Username $UserId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -AccountStatus 'ACTIVE'

    if ($identityUser -is [array]) {
        $identityUser = @($identityUser)[-1]
    }

    $identityOk = (
        $null -ne $identityUser -and
        $identityUser.Success -eq $true
    )
}
catch {
    $identityOk = $false
}

if (-not $identityOk) {
    throw "Impossible de préparer l'utilisateur de test."
}

# ============================================================
# SESSION
# ============================================================

try {
    $sessionResult = New-IdentitySession `
        -UserId $UserId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    $sessionResult = @($sessionResult)

    $session = $sessionResult | Where-Object {
        $_.SessionId
    } | Select-Object -Last 1

    if ($null -eq $session) {
        throw "SessionId introuvable."
    }

    $SessionId = [string]$session.SessionId
}
catch {
    throw "Impossible de préparer la session de test : $($_.Exception.Message)"
}

# ============================================================
# RBAC
# ============================================================

try {
    $binding = New-RBACBinding `
        -PrincipalId $UserId `
        -RoleId 'ROLE-OWNER' `
        -ScopeType 'TENANT' `
        -ScopeId $TenantId

    if ($binding -is [array]) {
        $binding = @($binding)[-1]
    }

    if ($null -eq $binding -or $binding.Success -ne $true) {
        throw "Binding OWNER impossible."
    }
}
catch {
    throw "Impossible de préparer le RBAC de test : $($_.Exception.Message)"
}

# ============================================================
# AUTHORIZATION
# ============================================================

try {
    $authorizationResult = Authorize-Request `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ($authorizationResult -is [array]) {
        $authorizationResult = @($authorizationResult) |
            Where-Object { $_.DecisionId } |
            Select-Object -Last 1
    }

    if ($null -eq $authorizationResult) {
        throw "AuthorizationId introuvable."
    }

    $AuthorizationId = [string]$authorizationResult.DecisionId

    if ($authorizationResult.Success -ne $true -or
        $authorizationResult.Decision -ne 'ALLOW') {
        throw "L'autorisation de préparation n'est pas ALLOW."
    }
}
catch {
    throw "Impossible de préparer l'autorisation : $($_.Exception.Message)"
}

# ============================================================
# 01 — CONFIG
# ============================================================

try {
    $cfg = Get-AuthorizationGrantConfig

    Assert-Test `
        ($null -ne $cfg) `
        '01 Config loaded'
}
catch {
    Fail-Test '01 Config loaded' $_.Exception.Message
}

# ============================================================
# 02 — ENABLED
# ============================================================

try {
    $enabled = [bool](Get-AuthorizationGrantField -Name 'enabled')

    Assert-Test `
        $enabled `
        '02 Grant system enabled'
}
catch {
    Fail-Test '02 Grant system enabled' $_.Exception.Message
}

# ============================================================
# 03 — DURATION
# ============================================================

try {
    $duration = [int](Get-AuthorizationGrantField -Name 'grantDurationSeconds')

    Assert-Test `
        ($duration -eq 900) `
        '03 Grant duration configured'
}
catch {
    Fail-Test '03 Grant duration configured' $_.Exception.Message
}

# ============================================================
# 04 — USER BINDING
# ============================================================

try {
    Assert-Test `
        ([bool](Get-AuthorizationGrantField -Name 'bindUser')) `
        '04 User binding required'
}
catch {
    Fail-Test '04 User binding required' $_.Exception.Message
}

# ============================================================
# 05 — SESSION BINDING
# ============================================================

try {
    Assert-Test `
        ([bool](Get-AuthorizationGrantField -Name 'bindSession')) `
        '05 Session binding required'
}
catch {
    Fail-Test '05 Session binding required' $_.Exception.Message
}

# ============================================================
# 06 — TENANT BINDING
# ============================================================

try {
    Assert-Test `
        ([bool](Get-AuthorizationGrantField -Name 'bindTenant')) `
        '06 Tenant binding required'
}
catch {
    Fail-Test '06 Tenant binding required' $_.Exception.Message
}

# ============================================================
# 07 — CLIENT BINDING
# ============================================================

try {
    Assert-Test `
        ([bool](Get-AuthorizationGrantField -Name 'bindClient')) `
        '07 Client binding required'
}
catch {
    Fail-Test '07 Client binding required' $_.Exception.Message
}

# ============================================================
# 08 — PROJECT BINDING
# ============================================================

try {
    Assert-Test `
        ([bool](Get-AuthorizationGrantField -Name 'bindProject')) `
        '08 Project binding required'
}
catch {
    Fail-Test '08 Project binding required' $_.Exception.Message
}

# ============================================================
# 09 — EXPIRATION
# ============================================================

try {
    Assert-Test `
        ([bool](Get-AuthorizationGrantField -Name 'expirationEnabled')) `
        '09 Expiration enabled'
}
catch {
    Fail-Test '09 Expiration enabled' $_.Exception.Message
}

# ============================================================
# 10 — REVOCATION
# ============================================================

try {
    Assert-Test `
        ([bool](Get-AuthorizationGrantField -Name 'revocationEnabled')) `
        '10 Revocation enabled'
}
catch {
    Fail-Test '10 Revocation enabled' $_.Exception.Message
}

# ============================================================
# 11 — CREATE GRANT
# ============================================================

try {
    $grantResult = New-AuthorizationGrant `
        -AuthorizationId $AuthorizationId `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ($grantResult -is [array]) {
        $grantResult = @($grantResult) |
            Where-Object { $_.GrantId } |
            Select-Object -Last 1
    }

    $grantOk = (
        $null -ne $grantResult -and
        $grantResult.Success -eq $true -and
        $grantResult.Status -eq 'CREATED' -and
        -not [string]::IsNullOrWhiteSpace([string]$grantResult.GrantId) -and
        -not [string]::IsNullOrWhiteSpace([string]$grantResult.Grant)
    )

    Assert-Test `
        $grantOk `
        '11 Grant created from ALLOW'
}
catch {
    Fail-Test '11 Grant created from ALLOW' $_.Exception.Message
}

# ============================================================
# 12 — RAW GRANT NOT PERSISTED
# ============================================================

try {
    $record = Get-AuthorizationGrant -GrantId $grantResult.GrantId

    if ($null -eq $record) {
        throw 'Grant record introuvable.'
    }

    $propertyNames = @(
        $record.PSObject.Properties | ForEach-Object {
            $_.Name
        }
    )

    $rawGrantStored = $propertyNames -contains 'Grant'

    $hashPresent = -not [string]::IsNullOrWhiteSpace(
        [string]$record.GrantHash
    )

    Assert-Test `
        (-not $rawGrantStored -and $hashPresent) `
        '12 Raw grant not persisted'
}
catch {
    Fail-Test '12 Raw grant not persisted' $_.Exception.Message
}

# ============================================================
# 13 — VALID GRANT
# ============================================================

try {
    $valid = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    Assert-Test `
        ($valid.Success -eq $true -and $valid.Decision -eq 'ALLOW') `
        '13 Valid grant allowed'
}
catch {
    Fail-Test '13 Valid grant allowed' $_.Exception.Message
}

# ============================================================
# 14 — HASH MISMATCH
# ============================================================

try {
    $wrongGrant = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant 'INVALID-GRANT' `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    Assert-Test `
        ($wrongGrant.Success -eq $false -and
         $wrongGrant.Decision -eq 'BLOCK') `
        '14 Grant hash mismatch blocked'
}
catch {
    Fail-Test '14 Grant hash mismatch blocked' $_.Exception.Message
}

# ============================================================
# 15 — USER MISMATCH
# ============================================================

try {
    $wrongUser = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId 'OTHER-USER' `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    Assert-Test `
        ($wrongUser.Success -eq $false -and
         $wrongUser.Decision -eq 'BLOCK') `
        '15 User mismatch blocked'
}
catch {
    Fail-Test '15 User mismatch blocked' $_.Exception.Message
}

# ============================================================
# 16 — SESSION MISMATCH
# ============================================================

try {
    $wrongSession = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId 'OTHER-SESSION' `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    Assert-Test `
        ($wrongSession.Success -eq $false -and
         $wrongSession.Decision -eq 'BLOCK') `
        '16 Session mismatch blocked'
}
catch {
    Fail-Test '16 Session mismatch blocked' $_.Exception.Message
}

# ============================================================
# 17 — TENANT MISMATCH
# ============================================================

try {
    $wrongTenant = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId 'OTHER-TENANT' `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    Assert-Test `
        ($wrongTenant.Success -eq $false -and
         $wrongTenant.Decision -eq 'BLOCK') `
        '17 Tenant mismatch blocked'
}
catch {
    Fail-Test '17 Tenant mismatch blocked' $_.Exception.Message
}

# ============================================================
# 18 — CLIENT MISMATCH
# ============================================================

try {
    $wrongClient = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $ProjectId

    Assert-Test `
        ($wrongClient.Success -eq $false -and
         $wrongClient.Decision -eq 'BLOCK') `
        '18 Client mismatch blocked'
}
catch {
    Fail-Test '18 Client mismatch blocked' $_.Exception.Message
}

# ============================================================
# 19 — PROJECT MISMATCH
# ============================================================

try {
    $wrongProject = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId 'OTHER-PROJECT'

    Assert-Test `
        ($wrongProject.Success -eq $false -and
         $wrongProject.Decision -eq 'BLOCK') `
        '19 Project mismatch blocked'
}
catch {
    Fail-Test '19 Project mismatch blocked' $_.Exception.Message
}

# ============================================================
# 20 — ACTION MISMATCH
# ============================================================

try {
    $wrongAction = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'WRITE' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    Assert-Test `
        ($wrongAction.Success -eq $false -and
         $wrongAction.Decision -eq 'BLOCK') `
        '20 Action mismatch blocked'
}
catch {
    Fail-Test '20 Action mismatch blocked' $_.Exception.Message
}

# ============================================================
# 21 — EXPIRATION
# ============================================================

try {
    $future = [datetime]::UtcNow.AddSeconds(901)

    $expired = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ReferenceTime $future

    Assert-Test `
        ($expired.Success -eq $false -and
         $expired.Decision -eq 'BLOCK' -and
         $expired.Reason -eq 'GRANT_EXPIRED') `
        '21 Expired grant blocked'
}
catch {
    Fail-Test '21 Expired grant blocked' $_.Exception.Message
}

# ============================================================
# 22 — REVOKE
# ============================================================

try {
    $revoked = Revoke-AuthorizationGrant `
        -GrantId $grantResult.GrantId

    Assert-Test `
        ($revoked.Success -eq $true -and
         $revoked.Status -eq 'REVOKED') `
        '22 Grant revoked'
}
catch {
    Fail-Test '22 Grant revoked' $_.Exception.Message
}

# ============================================================
# 23 — REVOKED GRANT BLOCKED
# ============================================================

try {
    $afterRevoke = Test-AuthorizationGrant `
        -GrantId $grantResult.GrantId `
        -Grant $grantResult.Grant `
        -UserId $UserId `
        -SessionId $SessionId `
        -Action 'READ' `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    Assert-Test `
        ($afterRevoke.Success -eq $false -and
         $afterRevoke.Decision -eq 'BLOCK') `
        '23 Revoked grant blocked'
}
catch {
    Fail-Test '23 Revoked grant blocked' $_.Exception.Message
}

# ============================================================
# 24 — PROVENANCE
# ============================================================

try {
    $allGrants = @(Get-AuthorizationGrants)

    $persisted = @(
        $allGrants | Where-Object {
            $_.GrantId -eq $grantResult.GrantId -and
            $_.AuthorizationId -eq $AuthorizationId -and
            $_.UserId -eq $UserId -and
            $_.SessionId -eq $SessionId -and
            $_.TenantId -eq $TenantId -and
            $_.ClientId -eq $ClientId -and
            $_.ProjectId -eq $ProjectId -and
            $_.Action -eq 'READ' -and
            $_.Status -eq 'REVOKED'
        }
    )

    Assert-Test `
        ($persisted.Count -eq 1) `
        '24 Grant provenance persisted'
}
catch {
    Fail-Test '24 Grant provenance persisted' $_.Exception.Message
}

# ============================================================
# RESULTATS
# ============================================================

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-05'
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