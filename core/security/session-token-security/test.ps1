$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\security\session-token-security"

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

$TokenId   = "TOK-8201"
$SessionId = "SES-8201"
$UserId    = "USER-8201"
$TenantId  = "TEN-01"
$ClientId  = "CLI-01"
$ProjectId = "PROJ-01"

$null = Reset-SessionTokenSecurity

# 1
$cfg = Get-SessionTokenSecurityConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Token security enabled" (
    $cfg.tokenSecurityEnabled -eq $true
)

# 3
Assert-Test "Token hashing enabled" (
    $cfg.hashTokensBeforeStorage -eq $true
)

# 4
Assert-Test "Revocation and rotation enabled" (
    $cfg.revocationEnabled -eq $true -and
    $cfg.rotationEnabled -eq $true
)

# 5
$state = @(Get-SessionTokenRecords)

Assert-Test "Initial token state empty" (
    $state.Length -eq 0
)

# 6
$context = Test-SessionTokenContext `
    -TokenId $TokenId `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Valid token context accepted" (
    $context.Success -eq $true
)

# 7
$missingTokenId = Test-SessionTokenContext `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Missing TokenId blocked" (
    $missingTokenId.Reason -eq "TOKEN_ID_REQUIRED"
)

# 8
$missingSession = Test-SessionTokenContext `
    -TokenId $TokenId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Missing SessionId blocked" (
    $missingSession.Reason -eq "SESSION_ID_REQUIRED"
)

# 9
$missingTenant = Test-SessionTokenContext `
    -TokenId $TokenId `
    -SessionId $SessionId `
    -UserId $UserId `
    -ClientId $ClientId

Assert-Test "Missing TenantId blocked" (
    $missingTenant.Reason -eq "TENANT_ID_REQUIRED"
)

# 10
$missingClient = Test-SessionTokenContext `
    -TokenId $TokenId `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId

Assert-Test "Missing ClientId blocked" (
    $missingClient.Reason -eq "CLIENT_ID_REQUIRED"
)

# 11
$binding = New-SessionSecurityBinding `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Session binding created" (
    $binding.Success -eq $true
)

# 12
$created = New-SessionSecurityToken `
    -TokenId $TokenId `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Token created" (
    $created.Success -eq $true
)

# 13
Assert-Test "Raw token generated only in memory" (
    -not [string]::IsNullOrWhiteSpace([string]$created.Token) -and
    -not [string]::IsNullOrWhiteSpace([string]$created.TokenHash)
)

# 14
$stored = Get-SessionTokenRecord `
    -TokenId $TokenId

Assert-Test "Stored record contains hash and not raw token" (
    ($null -ne $stored) -and
    (-not [string]::IsNullOrWhiteSpace([string]$stored.TokenHash)) -and
    ($null -eq $stored.PSObject.Properties["Token"])
)

# 15
$valid = Test-SessionSecurityToken `
    -TokenId $TokenId `
    -Token $created.Token `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Valid token accepted" (
    $valid.Success -eq $true -and
    $valid.Status -eq "VALID"
)

# 16
$wrongToken = Test-SessionSecurityToken `
    -TokenId $TokenId `
    -Token "WRONG-TOKEN" `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Wrong token blocked" (
    $wrongToken.Reason -eq "TOKEN_HASH_MISMATCH"
)

# 17
$wrongTenant = Test-SessionSecurityToken `
    -TokenId $TokenId `
    -Token $created.Token `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId "TEN-02" `
    -ClientId $ClientId

Assert-Test "Token tenant mismatch blocked" (
    $wrongTenant.Reason -eq "TOKEN_TENANT_MISMATCH"
)

# 18
$wrongClient = Test-SessionSecurityToken `
    -TokenId $TokenId `
    -Token $created.Token `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId "CLI-02"

Assert-Test "Token client mismatch blocked" (
    $wrongClient.Reason -eq "TOKEN_CLIENT_MISMATCH"
)

# 19
# ROTATION DOIT SE FAIRE AVANT LA REVOCATION DU TOKEN ACTIF
$newToken = Rotate-SessionSecurityToken `
    -TokenId $TokenId `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Rotation creates new token" (
    $newToken.Success -eq $true -and
    [string]$newToken.TokenId -ne $TokenId -and
    -not [string]::IsNullOrWhiteSpace([string]$newToken.Token)
)

# 20
$newStored = Get-SessionTokenRecord `
    -TokenId $newToken.TokenId

$oldStored = Get-SessionTokenRecord `
    -TokenId $TokenId

Assert-Test "Rotation revokes old token and links new token" (
    ($null -ne $newStored) -and
    ($null -ne $oldStored) -and
    ($oldStored.Status -eq "REVOKED") -and
    ([string]$newStored.RotatedFrom -eq $TokenId) -and
    ($newStored.Status -eq "ACTIVE")
)

# 21
$oldTokenCheck = Test-SessionSecurityToken `
    -TokenId $TokenId `
    -Token $created.Token `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Old token rejected after rotation" (
    $oldTokenCheck.Reason -eq "TOKEN_REVOKED"
)

# 22
$newTokenCheck = Test-SessionSecurityToken `
    -TokenId $newToken.TokenId `
    -Token $newToken.Token `
    -SessionId $SessionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Rotated token valid" (
    $newTokenCheck.Success -eq $true -and
    $newTokenCheck.Status -eq "VALID"
)

# 23
$secondRevoke = Revoke-SessionSecurityToken `
    -TokenId $TokenId

Assert-Test "Repeated old-token revocation blocked as duplicate" (
    $secondRevoke.Status -eq "DUPLICATE" -and
    $secondRevoke.Reason -eq "TOKEN_ALREADY_REVOKED"
)

# 24
$allTokens = @(Get-SessionTokenRecords)
$allSessions = @(Get-SessionSecurityRecords)

$finalOld = Get-SessionTokenRecord `
    -TokenId $TokenId

$finalNew = Get-SessionTokenRecord `
    -TokenId $newToken.TokenId

Assert-Test "Security state persisted coherently" (
    $allTokens.Length -eq 2 -and
    $allSessions.Length -eq 1 -and
    $finalOld.Status -eq "REVOKED" -and
    $finalNew.Status -eq "ACTIVE" -and
    $finalNew.TenantId -eq $TenantId -and
    $finalNew.ClientId -eq $ClientId -and
    $finalNew.ProjectId -eq $ProjectId -and
    [string]$finalNew.RotatedFrom -eq $TokenId
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 8A-02"
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