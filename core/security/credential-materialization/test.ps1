$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Materialization.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-17 CREDENTIAL MATERIALIZATION & USAGE GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialMaterialization

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
# FIXTURE 8A-16
# ============================================================
#
# IMPORTANT :
# Nous définissons ce fixture APRÈS le chargement du runtime.
# 8A-17 n'écrase donc pas le validateur.
#

function Test-CredentialLease {

    param(
        [Parameter(Mandatory)]
        [string]$LeaseId,

        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$WorkerId,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Connector,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$TenantId,

        [string]$UserId,

        [string]$SessionId
    )

    return [pscustomobject]@{
        Allowed = $true
        UserId = $UserId
        SessionId = $SessionId
        LeaseId = $LeaseId
    }
}

# ============================================================
# TEST DATA
# ============================================================

$LeaseId = "LEASE-8A17-001"
$CredentialRef = "cred:test:banking"
$ExecutionId = "EXEC-8A17-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "BANKING-API"
$ProjectId = "PROJECT-001"
$ClientId = "CLIENT-001"
$TenantId = "TENANT-001"

# ============================================================
# 01-10 CONFIGURATION
# ============================================================

$config = Get-CredentialMaterializationConfig

Add-Test "01 config enabled" (
    $config.enabled -eq $true
)

Add-Test "02 materialization enabled" (
    $config.materializationEnabled -eq $true
)

Add-Test "03 ephemeral handle enabled" (
    $config.ephemeralHandleEnabled -eq $true
)

Add-Test "04 single use enabled" (
    $config.singleUseEnabled -eq $true
)

Add-Test "05 fail closed enabled" (
    $config.failClosed -eq $true
)

Add-Test "06 credential lease required" (
    $config.requireCredentialLease -eq $true
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
# CREATE MATERIALIZATION
# ============================================================

$materialization = New-CredentialMaterialization `
    -LeaseId $LeaseId `
    -CredentialRef $CredentialRef `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$records = @(Get-CredentialMaterializationRecords)

$record = $null

foreach ($item in $records) {

    if ($item.MaterializationId -eq $materialization.MaterializationId) {

        $record = $item
        break
    }
}

# ============================================================
# 11-15 RUNTIME
# ============================================================

Add-Test "11 constructor available" (
    $null -ne (
        Get-Command New-CredentialMaterialization `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "12 validator available" (
    $null -ne (
        Get-Command Test-CredentialMaterialization `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "13 consume available" (
    $null -ne (
        Get-Command Consume-CredentialMaterialization `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "14 revoke available" (
    $null -ne (
        Get-Command Revoke-CredentialMaterialization `
            -ErrorAction SilentlyContinue
    )
)

Add-Test "15 state record created" (
    $null -ne $record
)

# ============================================================
# 16-24 SECURITY
# ============================================================

Add-Test "16 materialization allowed" (
    $materialization.Allowed -eq $true
)

Add-Test "17 materialization id generated" (
    -not [string]::IsNullOrWhiteSpace(
        $materialization.MaterializationId
    )
)

Add-Test "18 SHA256 materialization hash" (
    $materialization.MaterializationHash.Length -eq 64
)

$created = [datetime]::Parse(
    $record.CreatedAtUtc
).ToUniversalTime()

$expires = [datetime]::Parse(
    $record.ExpiresAtUtc
).ToUniversalTime()

Add-Test "19 expiration valid" (
    $expires -gt $created
)

Add-Test "20 persisted active state" (
    $record.Status -eq "ACTIVE" -and
    $record.Used -eq $false -and
    $null -eq $record.ConsumedAtUtc -and
    $null -eq $record.RevokedAtUtc
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

$valid = Test-CredentialMaterialization `
    -MaterializationId $materialization.MaterializationId `
    -LeaseId $LeaseId `
    -CredentialRef $CredentialRef `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

Add-Test "23 valid materialization authorized" (
    $valid.Allowed -eq $true
)

$consume = Consume-CredentialMaterialization `
    -MaterializationId $materialization.MaterializationId

$replay = Test-CredentialMaterialization `
    -MaterializationId $materialization.MaterializationId `
    -LeaseId $LeaseId `
    -CredentialRef $CredentialRef `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$afterConsume = @(Get-CredentialMaterializationRecords)

$consumedRecord = $null

foreach ($item in $afterConsume) {

    if ($item.MaterializationId -eq $materialization.MaterializationId) {

        $consumedRecord = $item
        break
    }
}

Add-Test "24 consumed state and replay blocked" (
    $consume.Status -eq "CONSUMED" -and
    $consumedRecord.Status -eq "CONSUMED" -and
    $consumedRecord.Used -eq $true -and
    -not [string]::IsNullOrWhiteSpace(
        $consumedRecord.ConsumedAtUtc
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
Write-Host "RESULTAT 8A-17 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (($pass -eq 24) -and ($fail -eq 0)) {

    Write-Host "8A-17 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-17 : ECHEC - NE PAS PASSER A 8A-18" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
