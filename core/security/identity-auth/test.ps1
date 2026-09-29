$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth"

. (Join-Path $Dir "runtime.ps1")

$Pass = 0
$Fail = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition
    )

    if ($Condition) {
        Write-Host "[PASS] $Name"
        $script:Pass++
    }
    else {
        Write-Host "[FAIL] $Name"
        $script:Fail++
    }
}

$UserId    = "USER-8001"
$Username  = "kader"
$TenantId  = "TENANT-01"
$ClientId  = "CLIENT-01"
$ProjectId = "PROJECT-01"

$null = Reset-IdentityAuth

# 1
$cfg = Get-IdentityAuthConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Identity enabled" (
    $cfg.identityEnabled -eq $true
)

# 3
Assert-Test "Authentication enabled" (
    $cfg.authenticationEnabled -eq $true
)

# 4
Assert-Test "Session enabled" (
    $cfg.sessionEnabled -eq $true
)

# 5
Assert-Test "Initial users state empty" (
    @(Get-IdentityUsers).Length -eq 0
)

# 6
$context = Test-IdentityContext `
    -UserId $UserId `
    -Username $Username `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -AccountStatus "ACTIVE"

Assert-Test "Valid identity context accepted" (
    $context.Success -eq $true
)

# 7
$missingUser = Test-IdentityContext `
    -Username $Username `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -AccountStatus "ACTIVE"

Assert-Test "Missing UserId blocked" (
    $missingUser.Reason -eq "USER_ID_REQUIRED"
)

# 8
$missingTenant = Test-IdentityContext `
    -UserId $UserId `
    -Username $Username `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -AccountStatus "ACTIVE"

Assert-Test "Missing TenantId blocked" (
    $missingTenant.Reason -eq "TENANT_ID_REQUIRED"
)

# 9
$missingClient = Test-IdentityContext `
    -UserId $UserId `
    -Username $Username `
    -TenantId $TenantId `
    -ProjectId $ProjectId `
    -AccountStatus "ACTIVE"

Assert-Test "Missing ClientId blocked" (
    $missingClient.Reason -eq "CLIENT_ID_REQUIRED"
)

# 10
$badStatus = Test-IdentityContext `
    -UserId $UserId `
    -Username $Username `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -AccountStatus "INVALID"

Assert-Test "Invalid account status blocked" (
    $badStatus.Reason -eq "ACCOUNT_STATUS_INVALID"
)

# 11
$created = New-IdentityUser `
    -UserId $UserId `
    -Username $Username `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -AccountStatus "ACTIVE"

Assert-Test "User created" (
    $created.Success -eq $true
)

# 12
Assert-Test "User status ACTIVE" (
    $created.AccountStatus -eq "ACTIVE"
)

# 13
$user = Get-IdentityUser `
    -UserId $UserId

Assert-Test "User retrievable" (
    $null -ne $user
)

# 14
$duplicateUser = New-IdentityUser `
    -UserId "USER-8002" `
    -Username $Username `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -AccountStatus "ACTIVE"

Assert-Test "Duplicate username in tenant blocked" (
    $duplicateUser.Status -eq "DUPLICATE"
)

# 15
$auth = Test-IdentityAuthentication `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Valid authentication accepted" (
    $auth.Success -eq $true -and
    $auth.Status -eq "AUTHENTICATED"
)

# 16
$wrongTenant = Test-IdentityAuthentication `
    -UserId $UserId `
    -TenantId "TENANT-02" `
    -ClientId $ClientId

Assert-Test "Tenant mismatch blocked" (
    $wrongTenant.Reason -eq "TENANT_MISMATCH"
)

# 17
$wrongClient = Test-IdentityAuthentication `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId "CLIENT-02"

Assert-Test "Client mismatch blocked" (
    $wrongClient.Reason -eq "CLIENT_MISMATCH"
)

# 18
$missingUserAuth = Test-IdentityAuthentication `
    -UserId "UNKNOWN-USER" `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Unknown user blocked" (
    $missingUserAuth.Reason -eq "USER_NOT_FOUND"
)

# 19
$session = New-IdentitySession `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Session created" (
    $session.Success -eq $true -and
    $session.Status -eq "SESSION_CREATED"
)

# 20
$sessionCheck = Test-IdentitySession `
    -SessionId $session.SessionId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Valid session accepted" (
    $sessionCheck.Success -eq $true -and
    $sessionCheck.Status -eq "VALID"
)

# 21
$wrongSessionTenant = Test-IdentitySession `
    -SessionId $session.SessionId `
    -TenantId "TENANT-02" `
    -ClientId $ClientId

Assert-Test "Session tenant mismatch blocked" (
    $wrongSessionTenant.Reason -eq "SESSION_TENANT_MISMATCH"
)

# 22
$wrongSessionClient = Test-IdentitySession `
    -SessionId $session.SessionId `
    -TenantId $TenantId `
    -ClientId "CLIENT-02"

Assert-Test "Session client mismatch blocked" (
    $wrongSessionClient.Reason -eq "SESSION_CLIENT_MISMATCH"
)

# 23
$revoke = Revoke-IdentitySession `
    -SessionId $session.SessionId

$revokedCheck = Test-IdentitySession `
    -SessionId $session.SessionId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Revoked session rejected" (
    $revoke.Success -eq $true -and
    $revokedCheck.Reason -eq "SESSION_NOT_ACTIVE"
)

# 24
$users = @(Get-IdentityUsers)
$sessions = @(Get-IdentitySessions)

Assert-Test "Identity state persisted correctly" (
    $users.Length -eq 1 -and
    $sessions.Length -eq 1 -and
    $users[0].UserId -eq $UserId -and
    $sessions[0].SessionId -eq $session.SessionId -and
    $sessions[0].Status -eq "REVOKED"
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 8A-01"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host "=============================================="

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"