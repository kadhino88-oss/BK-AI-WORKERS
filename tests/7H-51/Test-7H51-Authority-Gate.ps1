Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\authority-gate"
$RuntimeFile = Join-Path $RuntimeRoot "Authority-Gate.ps1"

. $RuntimeFile

Reset-AuthorityRequests | Out-Null

$script:PassCount = 0
$script:FailCount = 0

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
    (Get-AuthorityConfig).enabled -eq $true
}

Invoke-Test "02 gate enabled" {
    (Get-AuthorityConfig).authorityGateEnabled -eq $true
}

Invoke-Test "03 low risk classification" {
    (Get-RiskClass "READ") -eq "LOW"
}

Invoke-Test "04 financial critical classification" {
    (Get-RiskClass "PAYMENT") -eq "CRITICAL"
}

Invoke-Test "05 create low risk request" {
    $Result = New-AuthorityRequest `
        -RequestId "R1" `
        -ExecutionId "EX1" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "LUCAS" `
        -ActionType "READ"

    $Result.Decision -eq "ALLOW_SIMULATION"
}

Invoke-Test "06 create financial request" {
    $Result = New-AuthorityRequest `
        -RequestId "R2" `
        -ExecutionId "EX2" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "NOAH" `
        -ActionType "PAYMENT"

    (
        $Result.RiskClass -eq "CRITICAL"
    ) -and (
        $Result.ApprovalStatus -eq "PENDING"
    )
}

Invoke-Test "07 financial approval required" {
    $Result = Test-AuthorityExecution "R2"

    $Result.Allowed -eq $true -and
    $Result.Decision -eq "SIMULATION_ONLY"
}

Invoke-Test "08 no live execution" {
    (Get-AuthorityConfig).liveExecutionEnabled -eq $false
}

Invoke-Test "09 simulation only request" {
    $Request = Get-AuthorityRequest "R2"

    $Request.SimulationOnly -eq $true
}

Invoke-Test "10 request persisted" {
    $Request = Get-AuthorityRequest "R2"

    $null -ne $Request
}

Invoke-Test "11 tenant retained" {
    $Request = Get-AuthorityRequest "R2"

    $Request.TenantId -eq "T1"
}

Invoke-Test "12 client retained" {
    $Request = Get-AuthorityRequest "R2"

    $Request.ClientId -eq "C1"
}

Invoke-Test "13 project retained" {
    $Request = Get-AuthorityRequest "R2"

    $Request.ProjectId -eq "P1"
}

Invoke-Test "14 approval succeeds" {
    $Result = Approve-AuthorityRequest `
        -RequestId "R2" `
        -Approver "KADER"

    $Result.ApprovalStatus -eq "APPROVED"
}

Invoke-Test "15 approver recorded" {
    $Request = Get-AuthorityRequest "R2"

    $Request.Approver -eq "KADER"
}

Invoke-Test "16 approval execution allowed" {
    $Result = Test-AuthorityExecution "R2"

    (
        $Result.Allowed -eq $true
    ) -and (
        $Result.Reason -eq "LIVE_EXECUTION_DISABLED"
    )
}

Invoke-Test "17 duplicate approval blocked" {
    $Result = Approve-AuthorityRequest `
        -RequestId "R2" `
        -Approver "KADER"

    $Result.Status -eq "DUPLICATE_APPROVAL"
}

Invoke-Test "18 unknown request blocked" {
    $Result = Test-AuthorityExecution "UNKNOWN"

    $Result.Allowed -eq $false
}

Invoke-Test "19 missing tenant rejected" {
    try {
        New-AuthorityRequest `
            -RequestId "R19" `
            -ExecutionId "EX19" `
            -TenantId "" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -ActionType "PAYMENT" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "20 missing approver rejected" {
    try {
        New-AuthorityRequest `
            -RequestId "R20" `
            -ExecutionId "EX20" `
            -TenantId "T1" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -ActionType "TRANSFER" | Out-Null

        Approve-AuthorityRequest `
            -RequestId "R20" `
            -Approver "" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "21 duplicate request blocked" {
    $Result = New-AuthorityRequest `
        -RequestId "R2" `
        -ExecutionId "EX2" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "NOAH" `
        -ActionType "PAYMENT"

    $Result.Status -eq "DUPLICATE"
}

Invoke-Test "22 default unknown action is high risk" {
    (Get-RiskClass "UNKNOWN_ACTION") -eq "HIGH"
}

Invoke-Test "23 no secrets or payloads" {
    $ConfigText = Get-Content `
        -Raw `
        -Path (Join-Path $RuntimeRoot "config.json")

    $StatePath = Join-Path $RuntimeRoot "state\authority-requests.json"
    $StateText = Get-Content -Raw -Path $StatePath

    $Forbidden = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue|payload)"\s*:'

    (
        $ConfigText -notmatch $Forbidden
    ) -and (
        $StateText -notmatch $Forbidden
    )
}

Invoke-Test "24 reset state" {
    Reset-AuthorityRequests | Out-Null

    @(Get-AuthorityRequests).Count -eq 0
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-51 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if ($script:PassCount -eq 24 -and $script:FailCount -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"