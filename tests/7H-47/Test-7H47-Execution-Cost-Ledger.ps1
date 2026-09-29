Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cost-ledger"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Cost-Ledger.ps1"

. $RuntimeFile

Reset-CostLedger | Out-Null

$script:PassCount = 0
$script:FailCount = 0
$script:BaseEvent = $null

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
    (Get-CostConfig).enabled -eq $true
}

Invoke-Test "02 ledger enabled" {
    (Get-CostConfig).ledgerEnabled -eq $true
}

Invoke-Test "03 create cost event" {
    $script:BaseEvent = New-CostEvent `
        -EventId "EV1" `
        -ExecutionId "EX1" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "MAYA" `
        -Amount 100 `
        -Provider "TEST" `
        -Operation "MODEL_CALL"

    $script:BaseEvent.Status -eq "RECORDED"
}

Invoke-Test "04 add cost event" {
    (Add-CostEvent $script:BaseEvent).Status -eq "RECORDED"
}

Invoke-Test "05 event retrievable" {
    $Loaded = Get-CostEvent "EV1"
    $Loaded.EventId -eq "EV1"
}

Invoke-Test "06 execution total" {
    (Get-ExecutionCostTotal "EX1") -eq 100
}

Invoke-Test "07 duplicate blocked" {
    (Add-CostEvent $script:BaseEvent).Status -eq "DUPLICATE"
}

Invoke-Test "08 second event accepted" {
    $Event2 = New-CostEvent `
        -EventId "EV2" `
        -ExecutionId "EX1" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "MAYA" `
        -Amount 25

    (Add-CostEvent $Event2).Status -eq "RECORDED"
}

Invoke-Test "09 execution aggregation" {
    (Get-ExecutionCostTotal "EX1") -eq 125
}

Invoke-Test "10 project aggregation" {
    (Get-ProjectCostTotal `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1") -eq 125
}

Invoke-Test "11 exact reconciliation" {
    (Reconcile-ExecutionCost `
        -ExecutionId "EX1" `
        -ExpectedAmount 125).Status -eq "MATCHED"
}

Invoke-Test "12 mismatch detected" {
    (Reconcile-ExecutionCost `
        -ExecutionId "EX1" `
        -ExpectedAmount 100).Status -eq "MISMATCH"
}

Invoke-Test "13 tolerance accepted" {
    $Result = Reconcile-ExecutionCost `
        -ExecutionId "EX1" `
        -ExpectedAmount 125.0000005

    $Result.Reconciled -eq $true
}

Invoke-Test "14 negative amount rejected" {
    try {
        New-CostEvent `
            -EventId "EVNEG" `
            -ExecutionId "EXNEG" `
            -TenantId "T1" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -Amount -1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "15 missing tenant rejected" {
    try {
        New-CostEvent `
            -EventId "EVT" `
            -ExecutionId "EXT" `
            -TenantId "" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -Amount 1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "16 missing client rejected" {
    try {
        New-CostEvent `
            -EventId "EVC" `
            -ExecutionId "EXC" `
            -TenantId "T1" `
            -ClientId "" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -Amount 1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "17 missing project rejected" {
    try {
        New-CostEvent `
            -EventId "EVP" `
            -ExecutionId "EXP" `
            -TenantId "T1" `
            -ClientId "C1" `
            -ProjectId "" `
            -WorkerId "SAM" `
            -Amount 1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "18 tenant isolation" {
    $EventT2 = New-CostEvent `
        -EventId "EVT2" `
        -ExecutionId "EXT2" `
        -TenantId "T2" `
        -ClientId "C2" `
        -ProjectId "P2" `
        -WorkerId "SAM" `
        -Amount 300

    Add-CostEvent $EventT2 | Out-Null

    $T1Total = Get-ProjectCostTotal `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $T2Total = Get-ProjectCostTotal `
        -TenantId "T2" `
        -ClientId "C2" `
        -ProjectId "P2"

    ($T1Total -eq 125) -and ($T2Total -eq 300)
}

Invoke-Test "19 cross tenant not visible" {
    $T1Total = Get-ProjectCostTotal `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    $T1Total -ne 425
}

Invoke-Test "20 append-only count" {
    $Ledger = @(Get-CostLedger)

    $Ledger.Count -eq 3
}

Invoke-Test "21 no payload stored" {
    $Ledger = @(Get-CostLedger)
    $Json = ConvertTo-Json -InputObject $Ledger -Depth 20

    $Json -notmatch "(?i)payload"
}

Invoke-Test "22 no secret stored" {
    $Ledger = @(Get-CostLedger)
    $Json = ConvertTo-Json -InputObject $Ledger -Depth 20

    $Json -notmatch '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue)"\s*:'
}

Invoke-Test "23 zero amount allowed" {
    $ZeroEvent = New-CostEvent `
        -EventId "EV0" `
        -ExecutionId "EX0" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "SAM" `
        -Amount 0

    $ZeroEvent.Amount -eq 0
}

Invoke-Test "24 reset ledger" {
    Reset-CostLedger | Out-Null

    $Ledger = @(Get-CostLedger)

    $Ledger.Count -eq 0
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-47 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

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