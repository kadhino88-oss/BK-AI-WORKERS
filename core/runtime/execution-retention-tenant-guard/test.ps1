$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-retention-tenant-guard"

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

$RetentionId = "RET-7801"
$TenantId    = "TEN-01"
$ClientId    = "CLI-01"
$ProjectId   = "PROJ-01"

$null = Reset-RetentionTenantGuard

# 1
$cfg = Get-RetentionTenantGuardConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Tenant isolation enabled" (
    $cfg.tenantIsolationEnabled -eq $true
)

# 3
Assert-Test "Authorization guard enabled" (
    $cfg.authorizationGuardEnabled -eq $true
)

# 4
Assert-Test "Cross-tenant protection enabled" (
    $cfg.preventCrossTenantAccess -eq $true
)

# 5
$state = @(Get-RetentionTenantGuardRecords)

Assert-Test "Initial state empty" (
    $state.Length -eq 0
)

# 6
$validContext = Test-RetentionTenantContext `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Valid tenant context accepted" (
    $validContext.Success -eq $true
)

# 7
$missingRetention = Test-RetentionTenantContext `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Missing RetentionId blocked" (
    $missingRetention.Reason -eq "RETENTION_ID_REQUIRED"
)

# 8
$missingTenant = Test-RetentionTenantContext `
    -RetentionId $RetentionId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Missing TenantId blocked" (
    $missingTenant.Reason -eq "TENANT_ID_REQUIRED"
)

# 9
$missingClient = Test-RetentionTenantContext `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ProjectId $ProjectId

Assert-Test "Missing ClientId blocked" (
    $missingClient.Reason -eq "CLIENT_ID_REQUIRED"
)

# 10
$missingProject = Test-RetentionTenantContext `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId

Assert-Test "Missing ProjectId blocked" (
    $missingProject.Reason -eq "PROJECT_ID_REQUIRED"
)

# 11
$registered = Register-RetentionTenantRecord `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Tenant record registered" (
    $registered.Success -eq $true
)

# 12
Assert-Test "Record status authorized" (
    $registered.Status -eq "REGISTERED"
)

# 13
$loaded = Get-RetentionTenantGuardRecord `
    -RetentionId $RetentionId

Assert-Test "Tenant record retrievable" (
    $null -ne $loaded
)

# 14
$authRead = Test-RetentionTenantAuthorization `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ"

Assert-Test "Authorized READ accepted" (
    $authRead.Success -eq $true -and
    $authRead.Status -eq "AUTHORIZED"
)

# 15
$authMutation = Test-RetentionTenantAuthorization `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "MUTATE"

Assert-Test "Authorized MUTATE accepted" (
    $authMutation.Success -eq $true -and
    $authMutation.Status -eq "AUTHORIZED"
)

# 16
$wrongTenant = Test-RetentionTenantAuthorization `
    -RetentionId $RetentionId `
    -TenantId "TEN-02" `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ"

Assert-Test "Cross-tenant access blocked" (
    $wrongTenant.Reason -eq "CROSS_TENANT_ACCESS_BLOCKED"
)

# 17
$wrongClient = Test-RetentionTenantAuthorization `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId "CLI-02" `
    -ProjectId $ProjectId `
    -Operation "READ"

Assert-Test "Cross-client access blocked" (
    $wrongClient.Reason -eq "CROSS_CLIENT_ACCESS_BLOCKED"
)

# 18
$wrongProject = Test-RetentionTenantAuthorization `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId "PROJ-02" `
    -Operation "READ"

Assert-Test "Cross-project access blocked" (
    $wrongProject.Reason -eq "CROSS_PROJECT_ACCESS_BLOCKED"
)

# 19
$badOperation = Test-RetentionTenantAuthorization `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "DELETE"

Assert-Test "Invalid operation blocked" (
    $badOperation.Reason -eq "OPERATION_INVALID"
)

# 20
$missingRecord = Test-RetentionTenantAuthorization `
    -RetentionId "UNKNOWN-RETENTION" `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ"

Assert-Test "Unknown retention blocked" (
    $missingRecord.Reason -eq "RETENTION_RECORD_NOT_FOUND"
)

# 21
$isolation = Test-RetentionTenantIsolation `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Tenant isolation validated" (
    $isolation.Success -eq $true -and
    $isolation.Status -eq "ISOLATED"
)

# 22
$duplicate = Register-RetentionTenantRecord `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Duplicate retention blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# 23
$records = @(Get-RetentionTenantGuardRecords)

Assert-Test "Exactly one tenant record persisted" (
    $records.Length -eq 1 -and
    $records[0].RetentionId -eq $RetentionId
)

# 24
$null = Reset-RetentionTenantGuard

$empty = @(Get-RetentionTenantGuardRecords)

Assert-Test "Tenant guard state reset" (
    $empty.Length -eq 0
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-78"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"