Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-rate-card"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Rate-Card.ps1"
$ConfigFile = Join-Path $RuntimeRoot "config.json"

. $RuntimeFile

Reset-RateCards | Out-Null

$script:PassCount = 0
$script:FailCount = 0
$script:GlobalCard = $null
$script:TenantCard = $null
$script:ClientCard = $null
$script:ProjectCard = $null

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
    (Get-RateConfig).enabled -eq $true
}

Invoke-Test "02 rate card enabled" {
    (Get-RateConfig).rateCardEnabled -eq $true
}

Invoke-Test "03 create global rate" {
    $script:GlobalCard = New-RateCard `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -UnitRate 2.5 `
        -UnitType "UNIT"

    $script:GlobalCard.Scope -eq "GLOBAL"
}

Invoke-Test "04 save global rate" {
    Save-RateCard $script:GlobalCard | Out-Null

    $Loaded = Get-RateCard $script:GlobalCard.RateId

    $Loaded.RateId -eq $script:GlobalCard.RateId
}

Invoke-Test "05 calculation global" {
    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10

    ($Result.Status -eq "CALCULATED") -and
    ([decimal]$Result.Amount -eq [decimal]25)
}

Invoke-Test "06 zero units" {
    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 0

    ($Result.Success -eq $true) -and
    ([decimal]$Result.Amount -eq [decimal]0)
}

Invoke-Test "07 missing rate blocked" {
    $Result = Calculate-ExecutionCost `
        -Provider "UNKNOWN" `
        -Operation "UNKNOWN" `
        -Units 10

    $Result.Status -eq "RATE_NOT_FOUND"
}

Invoke-Test "08 negative units rejected" {
    try {
        Calculate-ExecutionCost `
            -Provider "TEST" `
            -Operation "MODEL_CALL" `
            -Units -1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "09 negative rate rejected" {
    try {
        New-RateCard `
            -Provider "TEST2" `
            -Operation "CALL" `
            -UnitRate -1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "10 tenant rate priority" {
    $script:TenantCard = New-RateCard `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -UnitRate 1.5 `
        -Scope "TENANT" `
        -TenantId "T1"

    Save-RateCard $script:TenantCard | Out-Null

    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T1"

    [decimal]$Result.Amount -eq [decimal]15
}

Invoke-Test "11 global fallback" {
    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "OTHER"

    [decimal]$Result.Amount -eq [decimal]25
}

Invoke-Test "12 client rate priority" {
    $script:ClientCard = New-RateCard `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -UnitRate 1.2 `
        -Scope "CLIENT" `
        -TenantId "T1" `
        -ClientId "C1"

    Save-RateCard $script:ClientCard | Out-Null

    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T1" `
        -ClientId "C1"

    [decimal]$Result.Amount -eq [decimal]12
}

Invoke-Test "13 project rate priority" {
    $script:ProjectCard = New-RateCard `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -UnitRate 1.1 `
        -Scope "PROJECT" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    Save-RateCard $script:ProjectCard | Out-Null

    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    [decimal]$Result.Amount -eq [decimal]11
}

Invoke-Test "14 project isolation" {
    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P2"

    [decimal]$Result.Amount -eq [decimal]12
}

Invoke-Test "15 tenant isolation" {
    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T2" `
        -ClientId "C2" `
        -ProjectId "P2"

    [decimal]$Result.Amount -eq [decimal]25
}

Invoke-Test "16 disable rate" {
    $Updated = Set-RateCardEnabled `
        -RateId $script:ProjectCard.RateId `
        -Enabled $false

    $Updated.Enabled -eq $false
}

Invoke-Test "17 disabled project falls back" {
    $Result = Calculate-ExecutionCost `
        -Provider "TEST" `
        -Operation "MODEL_CALL" `
        -Units 10 `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1"

    [decimal]$Result.Amount -eq [decimal]12
}

Invoke-Test "18 decimal precision" {
    $PrecisionCard = New-RateCard `
        -Provider "TEST2" `
        -Operation "PRECISION" `
        -UnitRate 0.3333333

    Save-RateCard $PrecisionCard | Out-Null

    $Result = Calculate-ExecutionCost `
        -Provider "TEST2" `
        -Operation "PRECISION" `
        -Units 3

    Write-Host "DEBUG 18: UnitRate=$($Result.UnitRate) Units=$($Result.Units) Amount=$($Result.Amount)" -ForegroundColor Yellow

    [decimal]$Result.Amount -eq [decimal]1
}

Invoke-Test "19 missing provider rejected" {
    try {
        New-RateCard `
            -Provider "" `
            -Operation "CALL" `
            -UnitRate 1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "20 missing operation rejected" {
    try {
        New-RateCard `
            -Provider "TEST" `
            -Operation "" `
            -UnitRate 1 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "21 duplicate rate id rejected" {
    try {
        Save-RateCard $script:GlobalCard | Out-Null
        $false
    }
    catch {
        $true
    }
}

Invoke-Test "22 max rate enforced" {
    try {
        New-RateCard `
            -Provider "TEST3" `
            -Operation "MAX" `
            -UnitRate 1000001 | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "23 no secrets or payloads" {
    $ConfigText = Get-Content -Raw -Path $ConfigFile

    $Forbidden = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue|payload)"\s*:'

    $ConfigText -notmatch $Forbidden
}

Invoke-Test "24 reset state" {
    Reset-RateCards | Out-Null

    $Cards = @(Get-RateCards)

    $Cards.Count -eq 0
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-48 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if ($script:PassCount -eq 24 -and $script:FailCount -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"