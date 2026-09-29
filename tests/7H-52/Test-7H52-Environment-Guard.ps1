Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\environment-guard"
$RuntimeFile = Join-Path $RuntimeRoot "Environment-Guard.ps1"

. $RuntimeFile

Reset-EnvironmentState | Out-Null

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
    (Get-EnvironmentConfig).enabled -eq $true
}

Invoke-Test "02 guard enabled" {
    (Get-EnvironmentConfig).environmentGuardEnabled -eq $true
}

Invoke-Test "03 default simulation" {
    $State = Get-EnvironmentState

    (
        $State.Environment -eq "SIMULATION"
    ) -and (
        $State.LiveEnabled -eq $false
    )
}

Invoke-Test "04 simulation allowed" {
    $Result = Test-ExecutionEnvironment `
        -ActionType "READ"

    (
        $Result.Allowed -eq $true
    ) -and (
        $Result.Decision -eq "SIMULATION"
    )
}

Invoke-Test "05 sandbox transition" {
    $State = Set-ExecutionEnvironment "SANDBOX"

    (
        $State.Environment -eq "SANDBOX"
    ) -and (
        $State.LiveEnabled -eq $false
    )
}

Invoke-Test "06 sandbox allowed" {
    $Result = Test-ExecutionEnvironment `
        -ActionType "EMAIL"

    (
        $Result.Allowed -eq $true
    ) -and (
        $Result.Decision -eq "SANDBOX"
    )
}

Invoke-Test "07 invalid environment rejected" {
    try {
        Set-ExecutionEnvironment "PRODUCTION" | Out-Null
        $false
    }
    catch {
        $true
    }
}

Invoke-Test "08 live disabled by configuration" {
    try {
        Set-ExecutionEnvironment "LIVE" | Out-Null
        $false
    }
    catch {
        $true
    }
}

Invoke-Test "09 live execution remains disabled" {
    $Config = Get-EnvironmentConfig

    $Config.liveEnabled -eq $false
}

Invoke-Test "10 human approval required" {
    (Get-EnvironmentConfig).requireHumanApprovalForLive -eq $true
}

Invoke-Test "11 production flag required" {
    (Get-EnvironmentConfig).requireProductionFlag -eq $true
}

Invoke-Test "12 simulation reset" {
    $State = Set-ExecutionEnvironment "SIMULATION"

    (
        $State.Environment -eq "SIMULATION"
    ) -and (
        $State.LiveEnabled -eq $false
    )
}

Invoke-Test "13 disable live command" {
    $State = Disable-LiveExecution

    (
        $State.Environment -eq "SIMULATION"
    ) -and (
        $State.LiveEnabled -eq $false
    )
}

Invoke-Test "14 state persisted" {
    $State = Get-EnvironmentState

    (
        $State.Environment -eq "SIMULATION"
    ) -and (
        $State.LiveEnabled -eq $false
    )
}

Invoke-Test "15 no secrets config" {
    $ConfigText = Get-Content `
        -Raw `
        -Path (Join-Path $RuntimeRoot "config.json")

    $Forbidden = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue)"\s*:'

    $ConfigText -notmatch $Forbidden
}

Invoke-Test "16 no payload state" {
    $StatePath = Join-Path $RuntimeRoot "state\environment.json"
    $StateText = Get-Content -Raw -Path $StatePath

    $StateText -notmatch '(?i)"payload"\s*:'
}

Invoke-Test "17 unknown environment blocked" {
    $StatePath = Join-Path $RuntimeRoot "state\environment.json"

    $BadState = [ordered]@{
        Environment = "UNKNOWN"
        LiveEnabled = $false
        ProductionFlag = $false
        HumanApproval = $false
    }

    $Json = ConvertTo-Json -InputObject $BadState -Depth 10

    [System.IO.File]::WriteAllText(
        $StatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )

    $Result = Test-ExecutionEnvironment `
        -ActionType "PAYMENT"

    $Result.Allowed -eq $false
}

Invoke-Test "18 reset restores safety" {
    Reset-EnvironmentState | Out-Null

    $State = Get-EnvironmentState

    (
        $State.Environment -eq "SIMULATION"
    ) -and (
        $State.LiveEnabled -eq $false
    ) -and (
        $State.ProductionFlag -eq $false
    ) -and (
        $State.HumanApproval -eq $false
    )
}

Invoke-Test "19 live approval requires approver" {
    try {
        Enable-LiveExecution `
            -Approver "" `
            -ProductionFlag "BK-AI-PRODUCTION-ENABLE" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "20 invalid production flag rejected" {
    try {
        Enable-LiveExecution `
            -Approver "KADER" `
            -ProductionFlag "WRONG-FLAG" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "21 action type cannot bypass simulation guard" {
    Reset-EnvironmentState | Out-Null

    $Result = Test-ExecutionEnvironment `
        -ActionType "TRANSFER" `
        -RequiresLive $true

    (
        $Result.Allowed -eq $true
    ) -and (
        $Result.Decision -eq "SIMULATION"
    )
}

Invoke-Test "22 live disabled remains authoritative" {
    $Config = Get-EnvironmentConfig

    (
        $Config.liveEnabled -eq $false
    ) -and (
        $Config.requireExplicitLiveEnable -eq $true
    )
}

Invoke-Test "23 reset removes approval state" {
    Reset-EnvironmentState | Out-Null

    $State = Get-EnvironmentState

    (
        $State.HumanApproval -eq $false
    ) -and (
        $State.ProductionFlag -eq $false
    )
}

Invoke-Test "24 final state is simulation safe" {
    $Result = Test-ExecutionEnvironment `
        -ActionType "PAYMENT" `
        -RequiresLive $true

    (
        $Result.Environment -eq "SIMULATION"
    ) -and (
        $Result.Allowed -eq $true
    ) -and (
        $Result.Decision -eq "SIMULATION"
    )
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-52 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if ($script:PassCount -eq 24 -and $script:FailCount -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"