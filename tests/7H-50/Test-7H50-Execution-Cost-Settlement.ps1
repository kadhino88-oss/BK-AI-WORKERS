Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# DEPENDENCIES
# ============================================================

$SettlementRuntime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cost-settlement\Execution-Cost-Settlement.ps1"
$BudgetRuntime     = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-budget\Execution-Budget.ps1"
$RateRuntime       = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-rate-card\Execution-Rate-Card.ps1"
$AuthRuntime       = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cost-gateway\Execution-Cost-Gateway.ps1"
$LedgerRuntime     = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cost-ledger\Execution-Cost-Ledger.ps1"

if (-not (Test-Path $SettlementRuntime)) {
    throw "Runtime 7H-50 introuvable."
}

if (-not (Test-Path $BudgetRuntime)) {
    throw "Runtime 7H-46 introuvable."
}

if (-not (Test-Path $RateRuntime)) {
    throw "Runtime 7H-48 introuvable."
}

if (-not (Test-Path $AuthRuntime)) {
    throw "Runtime 7H-49 introuvable."
}

if (-not (Test-Path $LedgerRuntime)) {
    throw "Runtime 7H-47 introuvable."
}

. $SettlementRuntime
. $BudgetRuntime
. $RateRuntime
. $AuthRuntime
. $LedgerRuntime

# ============================================================
# CLEAN INITIAL STATE
# ============================================================

Reset-CostSettlements | Out-Null
Reset-BudgetState | Out-Null
Reset-RateCards | Out-Null
Reset-Authorizations | Out-Null
Reset-CostLedger | Out-Null

# ============================================================
# TEST STATE
# ============================================================

$script:PassCount = 0
$script:FailCount = 0
$script:PrimaryBudget = $null
$script:MismatchBudget = $null

# ============================================================
# TEST RUNNER
# ============================================================

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

# ============================================================
# 01
# ============================================================

Invoke-Test "01 config enabled" {
    (Get-SettlementConfig).enabled -eq $true
}

# ============================================================
# 02
# ============================================================

Invoke-Test "02 settlement enabled" {
    (Get-SettlementConfig).settlementEnabled -eq $true
}

# ============================================================
# 03
# ============================================================

Invoke-Test "03 budget created" {

    $script:PrimaryBudget = New-BudgetAccount `
        -Scope TENANT `
        -TenantId "T1" `
        -Limit 500

    Save-BudgetAccount $script:PrimaryBudget | Out-Null

    $script:PrimaryBudget.Limit -eq 500
}

# ============================================================
# 04
# ============================================================

Invoke-Test "04 rate created" {

    $Rate = New-RateCard `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -UnitRate 2

    Save-RateCard $Rate | Out-Null

    $Rate.UnitRate -eq 2
}

# ============================================================
# 05
# ============================================================

Invoke-Test "05 authorization created" {

    $Result = Authorize-ExecutionCost `
        -AuthorizationId "AUTH1" `
        -ExecutionId "EX1" `
        -BudgetId $script:PrimaryBudget.BudgetId `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $Result.Decision -eq "ALLOW"
}

# ============================================================
# 06
# ============================================================

Invoke-Test "06 settlement started" {

    $Result = Start-CostSettlement `
        -SettlementId "SET1" `
        -AuthorizationId "AUTH1" `
        -ExecutionId "EX1" `
        -BudgetId $script:PrimaryBudget.BudgetId `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $Result.Status -eq "STARTED"
}

# ============================================================
# 07
# ============================================================

Invoke-Test "07 settlement persisted" {

    $Loaded = Get-Settlement "SET1"

    $null -ne $Loaded
}

# ============================================================
# 08
# ============================================================

Invoke-Test "08 settlement simulation only" {

    $Loaded = Get-Settlement "SET1"

    $Loaded.SimulationOnly -eq $true
}

# ============================================================
# 09
# ============================================================

Invoke-Test "09 reserve settlement cost" {

    $Result = Reserve-SettlementCost `
        -SettlementId "SET1" `
        -Amount 20

    $Result.Status -eq "RESERVED"
}

# ============================================================
# 10
# ============================================================

Invoke-Test "10 reservation reflected" {

    $Loaded = Get-Settlement "SET1"

    [decimal]$Loaded.ReservedAmount -eq [decimal]20
}

# ============================================================
# 11
# ============================================================

Invoke-Test "11 budget reservation reflected" {

    $Loaded = Get-BudgetAccount `
        $script:PrimaryBudget.BudgetId

    [decimal]$Loaded.Reserved -eq [decimal]20
}

# ============================================================
# 12
# ============================================================

Invoke-Test "12 finalize exact cost" {

    $Result = Finalize-CostSettlement `
        -SettlementId "SET1" `
        -ActualAmount 20 `
        -EventId "EVT1" `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -WorkerId "MAYA"

    $Result.Status -eq "FINALIZED"
}

# ============================================================
# 13
# ============================================================

Invoke-Test "13 reconciliation true" {

    $Loaded = Get-Settlement "SET1"

    $Loaded.Reconciled -eq $true
}

# ============================================================
# 14
# ============================================================

Invoke-Test "14 actual amount exact" {

    $Loaded = Get-Settlement "SET1"

    [decimal]$Loaded.ActualAmount -eq [decimal]20
}

# ============================================================
# 15
# ============================================================

Invoke-Test "15 ledger recorded" {

    $Event = Get-CostEvent "EVT1"

    $null -ne $Event
}

# ============================================================
# 16
# ============================================================

Invoke-Test "16 budget committed" {

    $LoadedBudget = Get-BudgetAccount `
        $script:PrimaryBudget.BudgetId

    (
        [decimal]$LoadedBudget.Reserved -eq [decimal]0
    ) -and (
        [decimal]$LoadedBudget.Consumed -eq [decimal]20
    )
}

# ============================================================
# 17
# ============================================================

Invoke-Test "17 duplicate settlement blocked" {

    $Result = Start-CostSettlement `
        -SettlementId "SET1" `
        -AuthorizationId "AUTH1" `
        -ExecutionId "EX1" `
        -BudgetId $script:PrimaryBudget.BudgetId `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $Result.Status -eq "DUPLICATE"
}

# ============================================================
# 18
# ============================================================

Invoke-Test "18 invalid reservation rejected" {

    $BudgetInvalid = New-BudgetAccount `
        -Scope TENANT `
        -TenantId "T1" `
        -Limit 100

    Save-BudgetAccount $BudgetInvalid | Out-Null

    $AuthInvalid = Authorize-ExecutionCost `
        -AuthorizationId "AUTH18" `
        -ExecutionId "EX18" `
        -BudgetId $BudgetInvalid.BudgetId `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 1 `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    if ($AuthInvalid.Decision -ne "ALLOW") {
        throw "Autorisation AUTH18 invalide."
    }

    $StartedInvalid = Start-CostSettlement `
        -SettlementId "SET18" `
        -AuthorizationId "AUTH18" `
        -ExecutionId "EX18" `
        -BudgetId $BudgetInvalid.BudgetId `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    if ($StartedInvalid.Status -ne "STARTED") {
        throw "SET18 non demarre."
    }

    try {
        Reserve-SettlementCost `
            -SettlementId "SET18" `
            -Amount 0 | Out-Null

        $false
    }
    catch {
        $true
    }
}

# ============================================================
# 19
# ============================================================

Invoke-Test "19 unauthorized settlement blocked" {

    $Result = Start-CostSettlement `
        -SettlementId "SET19" `
        -AuthorizationId "UNKNOWN" `
        -ExecutionId "EX19" `
        -BudgetId $script:PrimaryBudget.BudgetId `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $Result.Status -eq "BLOCKED"
}

# ============================================================
# 20
# ============================================================

Invoke-Test "20 tenant mismatch blocked" {

    $Result = Start-CostSettlement `
        -SettlementId "SET20" `
        -AuthorizationId "AUTH1" `
        -ExecutionId "EX1" `
        -BudgetId $script:PrimaryBudget.BudgetId `
        -TenantId "T2" `
        -ClientId "C1" `
        -ProjectId "P1"

    $Result.Status -eq "BLOCKED"
}

# ============================================================
# 21
# ============================================================

Invoke-Test "21 missing budget blocked" {

    $Result = Start-CostSettlement `
        -SettlementId "SET21" `
        -AuthorizationId "AUTH1" `
        -ExecutionId "EX1" `
        -BudgetId "UNKNOWN-BUDGET" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $Result.Status -eq "BLOCKED"
}

# ============================================================
# 22
# ============================================================

Invoke-Test "22 mismatch finalization blocks" {

    $script:MismatchBudget = New-BudgetAccount `
        -Scope TENANT `
        -TenantId "T1" `
        -Limit 500

    Save-BudgetAccount $script:MismatchBudget | Out-Null

    $AuthMismatch = Authorize-ExecutionCost `
        -AuthorizationId "AUTH22" `
        -ExecutionId "EX22" `
        -BudgetId $script:MismatchBudget.BudgetId `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    if ($AuthMismatch.Decision -ne "ALLOW") {
        throw "AUTH22 non autorisee."
    }

    $StartedMismatch = Start-CostSettlement `
        -SettlementId "SET22" `
        -AuthorizationId "AUTH22" `
        -ExecutionId "EX22" `
        -BudgetId $script:MismatchBudget.BudgetId `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    if ($StartedMismatch.Status -ne "STARTED") {
        throw "SET22 non demarre."
    }

    $ReservedMismatch = Reserve-SettlementCost `
        -SettlementId "SET22" `
        -Amount 20

    if ($ReservedMismatch.Status -ne "RESERVED") {
        throw "SET22 non reserve."
    }

    $FinalMismatch = Finalize-CostSettlement `
        -SettlementId "SET22" `
        -ActualAmount 40 `
        -EventId "EVT22" `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -WorkerId "MAYA"

    $FinalMismatch.Status -eq "BLOCKED"
}

# ============================================================
# 23
# ============================================================

Invoke-Test "23 mismatch releases budget" {

    if ($null -eq $script:MismatchBudget) {
        throw "Budget mismatch non initialise."
    }

    $LoadedBudget = Get-BudgetAccount `
        $script:MismatchBudget.BudgetId

    if ($null -eq $LoadedBudget) {
        throw "Budget mismatch introuvable apres finalisation."
    }

    $Reserved = [decimal]$LoadedBudget.Reserved
    $Consumed = [decimal]$LoadedBudget.Consumed

    Write-Host "DEBUG 23: Reserved=$Reserved Consumed=$Consumed" -ForegroundColor Yellow

    (
        $Reserved -eq [decimal]0
    ) -and (
        $Consumed -eq [decimal]0
    )
}

# ============================================================
# 24
# ============================================================

Invoke-Test "24 reset all settlement state" {

    Reset-CostSettlements | Out-Null
    Reset-Authorizations | Out-Null
    Reset-CostLedger | Out-Null
    Reset-BudgetState | Out-Null
    Reset-RateCards | Out-Null

    (
        @(Get-SettlementStore).Count -eq 0
    ) -and (
        @(Get-AuthorizationStore).Count -eq 0
    ) -and (
        @(Get-CostLedger).Count -eq 0
    )
}

# ============================================================
# FINAL RESULT
# ============================================================

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-50 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

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