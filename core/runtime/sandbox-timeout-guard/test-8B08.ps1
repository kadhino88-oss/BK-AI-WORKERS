$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-TIMEOUT-DEADLINE-GUARD.ps1"

. $Module

Initialize-SandboxTimeoutGuard | Out-Null

$script:Total = 0
$script:Pass = 0
$script:Fail = 0

function Run-Test {
    param(
        [string]$TestName,
        [scriptblock]$TestAction,
        [bool]$ExpectThrow
    )

    $script:Total++

    try {
        & $TestAction | Out-Null

        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:Total,$TestName)
            $script:Fail++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$TestName)
            $script:Pass++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Pass++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Fail++
        }
    }
}

Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

Run-Test "State SANDBOX" {
    $s = Get-SandboxTimeoutGuardState
    if ($s.Mode -ne "SANDBOX") { throw "BAD_MODE" }
} $false

Run-Test "Maximum duration configure" {
    $s = Get-SandboxTimeoutGuardState
    if ([int]$s.MaxExecutionDurationSeconds -lt 1) { throw "MAX_DURATION_INVALID" }
} $false

Run-Test "Timeout bypass disabled" {
    $s = Get-SandboxTimeoutGuardState
    if ($s.TimeoutBypassAllowed -ne $false) { throw "TIMEOUT_BYPASS_ENABLED" }
} $false

Run-Test "Deadline bypass disabled" {
    $s = Get-SandboxTimeoutGuardState
    if ($s.DeadlineBypassAllowed -ne $false) { throw "DEADLINE_BYPASS_ENABLED" }
} $false

Run-Test "Infinite execution disabled" {
    $s = Get-SandboxTimeoutGuardState
    if ($s.InfiniteExecutionAllowed -ne $false) { throw "INFINITE_EXECUTION_ENABLED" }
} $false

Run-Test "Request neutre autorisee" {
    $r = Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Decision -ne "ALLOW") { throw "NEUTRAL_REQUEST_BLOCKED" }
} $false

Run-Test "Duree maximale valide" {
    $r = Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 300

    if ($r.Valid -ne $true) { throw "MAX_DURATION_BLOCKED" }
} $false

Run-Test "Temps restant calcule" {
    $r = Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 300 `
        -ElapsedSeconds 100

    if ($r.RemainingSeconds -ne 200) {
        throw "REMAINING_TIME_INVALID"
    }
} $false

Run-Test "Temps egal au deadline autorise" {
    $r = Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 300 `
        -ElapsedSeconds 300

    if ($r.Decision -ne "ALLOW") {
        throw "DEADLINE_EDGE_BLOCKED"
    }
} $false

Run-Test "Duree trop longue bloquee" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 301
} $true

Run-Test "Execution deja expiree bloquee" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 300 `
        -ElapsedSeconds 301
} $true

Run-Test "Duree zero bloquee" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 0
} $true

Run-Test "Temps negatif bloque" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ElapsedSeconds -1
} $true

Run-Test "Timeout bypass bloque" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -TimeoutBypass $true
} $true

Run-Test "Deadline bypass bloque" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -DeadlineBypass $true
} $true

Run-Test "Execution infinie bloquee" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -InfiniteExecution $true
} $true

Run-Test "LIVE environment bloque" {
    Test-SandboxExecutionDeadline `
        -Environment "LIVE" `
        -Mode "LIVE"
} $true

Run-Test "Mode LIVE bloque" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "LIVE"
} $true

Run-Test "Environment vide bloque" {
    Test-SandboxExecutionDeadline `
        -Environment "" `
        -Mode "SANDBOX"
} $true

Run-Test "Mode vide bloque" {
    Test-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode ""
} $true

Run-Test "Etat timeout persiste" {
    $s = Get-SandboxTimeoutGuardState

    if ($s.Mode -ne "SANDBOX") {
        throw "STATE_MODE_INVALID"
    }

    if ($s.TimeoutBypassAllowed -ne $false) {
        throw "STATE_TIMEOUT_BYPASS_INVALID"
    }

    if ($s.DeadlineBypassAllowed -ne $false) {
        throw "STATE_DEADLINE_BYPASS_INVALID"
    }
} $false
Run-Test "Assert deadline valide" {
    $r = Assert-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 120 `
        -ElapsedSeconds 20

    if ($r.RemainingSeconds -ne 100) {
        throw "ASSERT_REMAINING_INVALID"
    }
} $false

Run-Test "Fail closed combinaison deadline" {
    Assert-SandboxExecutionDeadline `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestedDurationSeconds 9999 `
        -ElapsedSeconds 9999 `
        -TimeoutBypass $true `
        -DeadlineBypass $true `
        -InfiniteExecution $true
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B-08"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-08 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-08 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-08 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"