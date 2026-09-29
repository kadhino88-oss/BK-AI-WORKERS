Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$GatewayRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cost-gateway"
$GatewayRuntime = Join-Path $GatewayRoot "Execution-Cost-Gateway.ps1"

$BudgetRuntime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-budget\Execution-Budget.ps1"
$RateRuntime   = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-rate-card\Execution-Rate-Card.ps1"

. $GatewayRuntime
. $BudgetRuntime
. $RateRuntime

Reset-Authorizations | Out-Null
Reset-BudgetState | Out-Null
Reset-RateCards | Out-Null

$script:PassCount = 0
$script:FailCount = 0
$script:BudgetAccount = $null

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

Invoke-Test "01 config enabled" {
    (Get-GatewayConfig).enabled -eq $true
}

Invoke-Test "02 authorization enabled" {
    (Get-GatewayConfig).authorizationEnabled -eq $true
}

Invoke-Test "03 create budget" {
    $script:BudgetAccount = New-BudgetAccount `
        -Scope TENANT `
        -TenantId T1 `
        -Limit 1000

    Save-BudgetAccount $script:BudgetAccount | Out-Null

    $script:BudgetAccount.Limit -eq 1000
}

Invoke-Test "04 create global rate" {
    $Rate = New-RateCard `
        -Provider TEST `
        -Operation MODEL_CALL `
        -UnitRate 2

    Save-RateCard $Rate | Out-Null

    $Rate.UnitRate -eq 2
}

Invoke-Test "05 authorization context validation" {
    try {
        Authorize-ExecutionCost `
            -AuthorizationId A1 `
            -ExecutionId EX1 `
            -BudgetId B1 `
            -Provider TEST `
            -Operation MODEL_CALL `
            -Units 1 `
            -TenantId "" `
            -ClientId C1 `
            -ProjectId P1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "06 negative units rejected" {
    try {
        Authorize-ExecutionCost `
            -AuthorizationId A2 `
            -ExecutionId EX2 `
            -BudgetId B1 `
            -Provider TEST `
            -Operation MODEL_CALL `
            -Units -1 `
            -TenantId T1 `
            -ClientId C1 `
            -ProjectId P1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "07 valid rate calculation" {
    $Result = Calculate-ExecutionCost `
        -Provider TEST `
        -Operation MODEL_CALL `
        -Units 10 `
        -TenantId T1 `
        -ClientId C1 `
        -ProjectId P1

    [decimal]$Result.Amount -eq [decimal]20
}

Invoke-Test "08 budget available" {
    $Check = Test-BudgetAdmission `
        -BudgetId $script:BudgetAccount.BudgetId `
        -Cost 20

    $Check.Allowed -eq $true
}

Invoke-Test "09 authorization allowed" {
    $Result = Authorize-ExecutionCost `
        -AuthorizationId AUTH9 `
        -ExecutionId EX9 `
        -BudgetId $script:BudgetAccount.BudgetId `
        -Provider TEST `
        -Operation MODEL_CALL `
        -Units 10 `
        -TenantId T1 `
        -ClientId C1 `
        -ProjectId P1

    $Result.Decision -eq "ALLOW"
}

Invoke-Test "10 authorization persisted" {
    $Loaded = Get-Authorization "AUTH9"

    $null -ne $Loaded
}

Invoke-Test "11 simulation only" {
    $Loaded = Get-Authorization "AUTH9"

    $Loaded.SimulationOnly -eq $true
}

Invoke-Test "12 estimated cost exact" {
    $Loaded = Get-Authorization "AUTH9"

    [decimal]$Loaded.EstimatedCost -eq [decimal]20
}

Invoke-Test "13 tenant retained" {
    $Loaded = Get-Authorization "AUTH9"

    $Loaded.TenantId -eq "T1"
}

Invoke-Test "14 client retained" {
    $Loaded = Get-Authorization "AUTH9"

    $Loaded.ClientId -eq "C1"
}

Invoke-Test "15 project retained" {
    $Loaded = Get-Authorization "AUTH9"

    $Loaded.ProjectId -eq "P1"
}

Invoke-Test "16 missing rate blocked" {
    $UnknownAuth = [guid]::NewGuid().ToString("N")

    $Result = Authorize-ExecutionCost `
        -AuthorizationId $UnknownAuth `
        -ExecutionId EX16 `
        -BudgetId $script:BudgetAccount.BudgetId `
        -Provider UNKNOWN `
        -Operation UNKNOWN `
        -Units 10 `
        -TenantId T1 `
        -ClientId C1 `
        -ProjectId P1

    $Result.Decision -eq "BLOCK"
}

Invoke-Test "17 missing rate reason" {
    $UnknownAuth = [guid]::NewGuid().ToString("N")

    $Result = Authorize-ExecutionCost `
        -AuthorizationId $UnknownAuth `
        -ExecutionId EX17 `
        -BudgetId $script:BudgetAccount.BudgetId `
        -Provider UNKNOWN `
        -Operation UNKNOWN `
        -Units 10 `
        -TenantId T1 `
        -ClientId C1 `
        -ProjectId P1

    $Result.Reason -eq "RATE_NOT_FOUND"
}

Invoke-Test "18 duplicate authorization blocked" {
    $Result = Authorize-ExecutionCost `
        -AuthorizationId AUTH9 `
        -ExecutionId EX18 `
        -BudgetId $script:BudgetAccount.BudgetId `
        -Provider TEST `
        -Operation MODEL_CALL `
        -Units 10 `
        -TenantId T1 `
        -ClientId C1 `
        -ProjectId P1

    $Result.Decision -eq "DUPLICATE"
}

Invoke-Test "19 no secrets in config" {
    $ConfigText = Get-Content `
        -Raw `
        -Path (Join-Path $GatewayRoot "config.json")

    $Forbidden = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue)"\s*:'

    $ConfigText -notmatch $Forbidden
}

Invoke-Test "20 no payload in authorization" {
    $Text = Get-Content `
        -Raw `
        -Path (Join-Path $GatewayRoot "state\authorizations.json")

    $Text -notmatch '(?i)"payload"\s*:'
}

Invoke-Test "21 zero units allowed by rate layer" {
    $Result = Calculate-ExecutionCost `
        -Provider TEST `
        -Operation MODEL_CALL `
        -Units 0 `
        -TenantId T1 `
        -ClientId C1 `
        -ProjectId P1

    [decimal]$Result.Amount -eq [decimal]0
}

Invoke-Test "22 missing budget blocked" {
    $UnknownBudget = [guid]::NewGuid().ToString("N")

    $Result = Authorize-ExecutionCost `
        -AuthorizationId AUTH22 `
        -ExecutionId EX22 `
        -BudgetId $UnknownBudget `
        -Provider TEST `
        -Operation MODEL_CALL `
        -Units 1 `
        -TenantId T1 `
        -ClientId C1 `
        -ProjectId P1

    $Result.Reason -eq "BUDGET_NOT_FOUND"
}

Invoke-Test "23 tenant mismatch blocked" {
    $Result = Authorize-ExecutionCost `
        -AuthorizationId AUTH23 `
        -ExecutionId EX23 `
        -BudgetId $script:BudgetAccount.BudgetId `
        -Provider TEST `
        -Operation MODEL_CALL `
        -Units 1 `
        -TenantId T2 `
        -ClientId C2 `
        -ProjectId P2

    $Result.Reason -eq "TENANT_MISMATCH"
}

Invoke-Test "24 reset authorizations" {
    Reset-Authorizations | Out-Null

    $Records = @(Get-AuthorizationStore)

    $Records.Count -eq 0
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-49 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if ($script:PassCount -eq 24 -and $script:FailCount -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"