$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Usage-Guard.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-18 CREDENTIAL USAGE REVALIDATION & EXECUTION GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialUsageGuard

$results = @()

function Add-Test {

    param(
        [string]$Name,
        [bool]$Passed
    )

    if ($Passed) {

        $script:results += [pscustomobject]@{
            Test = $Name
            Result = "PASS"
        }

        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {

        $script:results += [pscustomobject]@{
            Test = $Name
            Result = "FAIL"
        }

        Write-Host "[FAIL] $Name" -ForegroundColor Red
    }
}

# ============================================================
# FIXTURE 8A-17
# ============================================================

function Test-CredentialMaterialization {

    param(
        [string]$MaterializationId,
        [string]$LeaseId,
        [string]$CredentialRef,
        [string]$ExecutionId,
        [string]$WorkerId,
        [string]$Action,
        [string]$Connector,
        [string]$ProjectId,
        [string]$ClientId,
        [string]$TenantId
    )

    return [pscustomobject]@{
        Allowed = $true
        Code = "AUTHORIZED"
        MaterializationId = $MaterializationId
    }
}

$MaterializationId = "MAT-8A18-001"
$LeaseId = "LEASE-8A18-001"
$CredentialRef = "cred:test:controlled"
$ExecutionId = "EXEC-8A18-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "CONTROLLED-API"
$ProjectId = "PROJECT-001"
$ClientId = "CLIENT-001"
$TenantId = "TENANT-001"

# ============================================================
# 01-10 CONFIG
# ============================================================

$config = Get-CredentialUsageGuardConfig

Add-Test "01 config enabled" (
    $config.enabled -eq $true
)

Add-Test "02 usage guard enabled" (
    $config.usageGuardEnabled -eq $true
)

Add-Test "03 pre-use revalidation enabled" (
    $config.preUseRevalidationEnabled -eq $true
)

Add-Test "04 single use enabled" (
    $config.singleUseUsageEnabled -eq $true
)

Add-Test "05 fail closed enabled" (
    $config.failClosed -eq $true
)

Add-Test "06 materialization required" (
    $config.requireMaterialization -eq $true
)

Add-Test "07 execution binding required" (
    $config.requireExecutionBinding -eq $true
)

Add-Test "08 worker binding required" (
    $config.requireWorkerBinding -eq $true
)

Add-Test "09 action binding required" (
    $config.requireActionBinding -eq $true
)

Add-Test "10 connector binding required" (
    $config.requireConnectorBinding -eq $true
)

# ============================================================
# 11-15 FUNCTIONS
# ============================================================

Add-Test "11 usage constructor exists" (
    $null -ne (
        Get-Command Invoke-CredentialUsageGuard `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "12 usage validator exists" (
    $null -ne (
        Get-Command Test-CredentialUsageGuard `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "13 usage consume exists" (
    $null -ne (
        Get-Command Consume-CredentialUsageGuard `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "14 usage revoke exists" (
    $null -ne (
        Get-Command Revoke-CredentialUsageGuard `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "15 reset exists" (
    $null -ne (
        Get-Command Reset-CredentialUsageGuard `
            -ErrorAction SilentlyContinue
    )
)

# ============================================================
# CREATE AUTHORIZED USAGE
# ============================================================

$usage = Invoke-CredentialUsageGuard `
    -MaterializationId $MaterializationId `
    -LeaseId $LeaseId `
    -CredentialRef $CredentialRef `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$records = @(Get-CredentialUsageGuardRecords)

$record = $null

foreach ($item in $records) {

    if ($item.UsageId -eq $usage.UsageId) {

        $record = $item
        break
    }
}

# ============================================================
# 16-24 SECURITY
# ============================================================

Add-Test "16 usage authorization allowed" (
    $usage.Allowed -eq $true
)

Add-Test "17 usage id generated" (
    -not [string]::IsNullOrWhiteSpace(
        $usage.UsageId
    )
)

Add-Test "18 usage hash SHA256" (
    $usage.UsageHash.Length -eq 64
)

$created = [datetime]::Parse(
    $record.CreatedAtUtc
).ToUniversalTime()

$expires = [datetime]::Parse(
    $record.ExpiresAtUtc
).ToUniversalTime()

Add-Test "19 usage expiration valid" (
    $expires -gt $created
)

Add-Test "20 authorized state persisted" (
    $record.Status -eq "AUTHORIZED" -and
    $record.Used -eq $false -and
    $null -eq $record.ConsumedAtUtc
)

$rawState = Get-Content `
    -LiteralPath "$Root\state\records.json" `
    -Raw

Add-Test "21 raw secret never persisted" (
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
)

Add-Test "22 raw credential never persisted" (
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

$valid = Test-CredentialUsageGuard `
    -UsageId $usage.UsageId `
    -MaterializationId $MaterializationId `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

Add-Test "23 valid pre-use revalidation allowed" (
    $valid.Allowed -eq $true
)

$consume = Consume-CredentialUsageGuard `
    -UsageId $usage.UsageId

$replay = Test-CredentialUsageGuard `
    -UsageId $usage.UsageId `
    -MaterializationId $MaterializationId `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$after = @(Get-CredentialUsageGuardRecords)

$consumed = $null

foreach ($item in $after) {

    if ($item.UsageId -eq $usage.UsageId) {

        $consumed = $item
        break
    }
}

Add-Test "24 consumed usage blocks replay" (
    $consume.Status -eq "CONSUMED" -and
    $consumed.Status -eq "CONSUMED" -and
    $consumed.Used -eq $true -and
    -not [string]::IsNullOrWhiteSpace(
        $consumed.ConsumedAtUtc
    ) -and
    $replay.Allowed -eq $false
)

# ============================================================
# FINAL
# ============================================================

$pass = @(
    $results |
    Where-Object {
        $_.Result -eq "PASS"
    }
).Count

$fail = @(
    $results |
    Where-Object {
        $_.Result -eq "FAIL"
    }
).Count

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-18 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (($pass -eq 24) -and ($fail -eq 0)) {

    Write-Host "8A-18 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-18 : ECHEC - NE PAS PASSER A 8A-19" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
