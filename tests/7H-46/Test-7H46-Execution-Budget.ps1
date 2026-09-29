Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-budget"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Budget.ps1"

. $RuntimeFile

Reset-BudgetState | Out-Null

$script:PassCount = 0
$script:FailCount = 0
$script:TenantAccount = $null
$script:ClientAccount = $null
$script:ProjectAccount = $null

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        $Result = & $Action

        if ($Result -eq $false) {
            throw "ASSERTION FALSE"
        }

        $script:PassCount++
        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {
        $script:FailCount++
        Write-Host "FAIL $Name :: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ------------------------------------------------------------
# 01 CONFIG
# ------------------------------------------------------------

Invoke-Test "01 config enabled" {
    $Config = Get-BudgetConfig
    $Config.enabled -eq $true
}

# ------------------------------------------------------------
# 02 TENANT DEFAULT
# ------------------------------------------------------------

Invoke-Test "02 tenant default" {
    $script:TenantAccount = New-BudgetAccount `
        -Scope "TENANT" `
        -TenantId "T1"

    $script:TenantAccount.Limit -eq 10000
}

# ------------------------------------------------------------
# 03 CLIENT DEFAULT
# ------------------------------------------------------------

Invoke-Test "03 client default" {
    $script:ClientAccount = New-BudgetAccount `
        -Scope "CLIENT" `
        -TenantId "T1" `
        -ClientId "C1"

    $script:ClientAccount.Limit -eq 5000
}

# ------------------------------------------------------------
# 04 PROJECT DEFAULT
# ------------------------------------------------------------

Invoke-Test "04 project default" {
    $script:ProjectAccount = New-BudgetAccount `
        -Scope "PROJECT" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $script:ProjectAccount.Limit -eq 2500
}

# ------------------------------------------------------------
# 05 SAVE / GET
# ------------------------------------------------------------

Invoke-Test "05 save and get" {
    Save-BudgetAccount $script:TenantAccount | Out-Null

    $Loaded = Get-BudgetAccount $script:TenantAccount.BudgetId

    $Loaded.BudgetId -eq $script:TenantAccount.BudgetId
}

# ------------------------------------------------------------
# 06 EXPLICIT LIMIT
# ------------------------------------------------------------

Invoke-Test "06 explicit limit" {
    $Account = New-BudgetAccount `
        -Scope "TENANT" `
        -TenantId "T2" `
        -Limit 750

    $Account.Limit -eq 750
}

# ------------------------------------------------------------
# 07 ADMISSION ALLOWED
# ------------------------------------------------------------

Invoke-Test "07 admission allowed" {
    $Result = Test-BudgetAdmission `
        -BudgetId $script:TenantAccount.BudgetId `
        -Cost 100

    $Result.Allowed -eq $true
}

# ------------------------------------------------------------
# 08 ADMISSION BLOCKED
# ------------------------------------------------------------

Invoke-Test "08 admission blocked" {
    $Result = Test-BudgetAdmission `
        -BudgetId $script:TenantAccount.BudgetId `
        -Cost 20000

    $Result.Allowed -eq $false
}

# ------------------------------------------------------------
# 09 RESERVATION
# ------------------------------------------------------------

Invoke-Test "09 reserve" {
    $Result = Reserve-Budget `
        -BudgetId $script:TenantAccount.BudgetId `
        -ExecutionId "E1" `
        -Cost 1000

    $Result.Status -eq "RESERVED"
}

# ------------------------------------------------------------
# 10 RESERVED REFLECTED
# ------------------------------------------------------------

Invoke-Test "10 reservation reflected" {
    $Account = Get-BudgetAccount $script:TenantAccount.BudgetId

    $Account.Reserved -eq 1000
}

# ------------------------------------------------------------
# 11 COMMIT
# ------------------------------------------------------------

Invoke-Test "11 commit reservation" {
    $Result = Commit-BudgetReservation `
        -BudgetId $script:TenantAccount.BudgetId `
        -ExecutionId "E1"

    $Result.Status -eq "COMMITTED"
}

# ------------------------------------------------------------
# 12 CONSUMPTION REFLECTED
# ------------------------------------------------------------

Invoke-Test "12 consumption reflected" {
    $Account = Get-BudgetAccount $script:TenantAccount.BudgetId

    $Account.Consumed -eq 1000
}

# ------------------------------------------------------------
# 13 RELEASE
# ------------------------------------------------------------

Invoke-Test "13 release reservation" {
    Reserve-Budget `
        -BudgetId $script:TenantAccount.BudgetId `
        -ExecutionId "E2" `
        -Cost 500 | Out-Null

    $Result = Release-BudgetReservation `
        -BudgetId $script:TenantAccount.BudgetId `
        -ExecutionId "E2"

    $Result.Status -eq "RELEASED"
}

# ------------------------------------------------------------
# 14 DIRECT CONSUMPTION
# ------------------------------------------------------------

Invoke-Test "14 direct consumption" {
    $Result = Register-BudgetConsumption `
        -BudgetId $script:TenantAccount.BudgetId `
        -Cost 250

    $Result.Status -eq "CONSUMED"
}

# ------------------------------------------------------------
# 15 INSUFFICIENT RESERVATION
# ------------------------------------------------------------

Invoke-Test "15 insufficient reserve blocked" {
    $Result = Reserve-Budget `
        -BudgetId $script:TenantAccount.BudgetId `
        -ExecutionId "E3" `
        -Cost 100000

    $Result.Status -eq "BLOCKED"
}

# ------------------------------------------------------------
# 16 DUPLICATE RESERVATION
# ------------------------------------------------------------

Invoke-Test "16 duplicate reservation rejected" {
    Reserve-Budget `
        -BudgetId $script:TenantAccount.BudgetId `
        -ExecutionId "E4" `
        -Cost 100 | Out-Null

    try {
        Reserve-Budget `
            -BudgetId $script:TenantAccount.BudgetId `
            -ExecutionId "E4" `
            -Cost 100 | Out-Null

        $false
    }
    catch {
        $true
    }
}

# ------------------------------------------------------------
# 17 NEGATIVE LIMIT
# ------------------------------------------------------------

Invoke-Test "17 negative limit rejected" {
    try {
        New-BudgetAccount `
            -Scope "TENANT" `
            -TenantId "T3" `
            -Limit -1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

# ------------------------------------------------------------
# 18 ZERO RESERVATION
# ------------------------------------------------------------

Invoke-Test "18 zero reservation rejected" {
    try {
        Reserve-Budget `
            -BudgetId $script:TenantAccount.BudgetId `
            -ExecutionId "E5" `
            -Cost 0 | Out-Null

        $false
    }
    catch {
        $true
    }
}

# ------------------------------------------------------------
# 19 NEGATIVE CONSUMPTION
# ------------------------------------------------------------

Invoke-Test "19 negative consumption rejected" {
    try {
        Register-BudgetConsumption `
            -BudgetId $script:TenantAccount.BudgetId `
            -Cost -1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

# ------------------------------------------------------------
# 20 INCOMPLETE CONTEXT
# ------------------------------------------------------------

Invoke-Test "20 incomplete project context rejected" {
    try {
        New-BudgetAccount `
            -Scope "PROJECT" `
            -TenantId "T1" `
            -ClientId "C1" | Out-Null

        $false
    }
    catch {
        $true
    }
}

# ------------------------------------------------------------
# 21 TENANT ISOLATION
# ------------------------------------------------------------

Invoke-Test "21 tenant isolation" {
    $T2 = New-BudgetAccount `
        -Scope "TENANT" `
        -TenantId "T2" `
        -Limit 100

    Save-BudgetAccount $T2 | Out-Null

    $LoadedT2 = Get-BudgetAccount $T2.BudgetId
    $LoadedT1 = Get-BudgetAccount $script:TenantAccount.BudgetId

    (
        $LoadedT2.TenantId -eq "T2"
    ) -and (
        $LoadedT1.TenantId -eq "T1"
    )
}

# ------------------------------------------------------------
# 22 SET LIMIT
# ------------------------------------------------------------

Invoke-Test "22 set limit" {
    $Updated = Set-BudgetLimit `
        -BudgetId $script:TenantAccount.BudgetId `
        -Limit 12000

    $Updated.Limit -eq 12000
}

# ------------------------------------------------------------
# 23 NO SECRET VALUES
# ------------------------------------------------------------

Invoke-Test "23 no credential values stored" {
    $ConfigText = Get-Content `
        -Raw `
        -Path (Join-Path $RuntimeRoot "config.json")

    $ForbiddenValuePattern = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue)"\s*:\s*"[^"]+"'

    $ConfigText -notmatch $ForbiddenValuePattern
}

# ------------------------------------------------------------
# 24 RESET
# ------------------------------------------------------------

Invoke-Test "24 reset state" {
    Reset-BudgetState | Out-Null

    $Loaded = Get-BudgetAccount $script:TenantAccount.BudgetId

    $null -eq $Loaded
}

# ------------------------------------------------------------
# FINAL
# ------------------------------------------------------------

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-46 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if (
    $script:PassCount -eq 24 -and
    $script:FailCount -eq 0
) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"