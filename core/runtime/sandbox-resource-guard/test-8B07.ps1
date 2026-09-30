$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-RESOURCE-QUOTA-GUARD.ps1"

. $Module

Initialize-SandboxResourceGuard | Out-Null

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
    $s = Get-SandboxResourceGuardState
    if ($s.Mode -ne "SANDBOX") { throw "BAD_MODE" }
} $false

Run-Test "Resource unlimited disabled" {
    $s = Get-SandboxResourceGuardState
    if ($s.ResourceUnlimited -ne $false) { throw "RESOURCE_UNLIMITED" }
} $false

Run-Test "Quota bypass disabled" {
    $s = Get-SandboxResourceGuardState
    if ($s.QuotaBypassAllowed -ne $false) { throw "QUOTA_BYPASS_ENABLED" }
} $false

Run-Test "Concurrent quota configured" {
    $s = Get-SandboxResourceGuardState
    if ([int]$s.MaxConcurrentExecutions -lt 1) { throw "CONCURRENT_QUOTA_INVALID" }
} $false

Run-Test "Duration quota configured" {
    $s = Get-SandboxResourceGuardState
    if ([int]$s.MaxExecutionDurationSeconds -lt 1) { throw "DURATION_QUOTA_INVALID" }
} $false

Run-Test "Memory quota configured" {
    $s = Get-SandboxResourceGuardState
    if ([int]$s.MaxMemoryMb -lt 1) { throw "MEMORY_QUOTA_INVALID" }
} $false

Run-Test "Input quota configured" {
    $s = Get-SandboxResourceGuardState
    if ([long]$s.MaxInputBytes -lt 1) { throw "INPUT_QUOTA_INVALID" }
} $false

Run-Test "Output quota configured" {
    $s = Get-SandboxResourceGuardState
    if ([long]$s.MaxOutputBytes -lt 1) { throw "OUTPUT_QUOTA_INVALID" }
} $false

Run-Test "Request neutre autorisee" {
    $r = Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Decision -ne "ALLOW") {
        throw "NEUTRAL_REQUEST_BLOCKED"
    }
} $false

Run-Test "Quota concurrent valide" {
    $r = Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ConcurrentExecutions 4

    if ($r.Valid -ne $true) {
        throw "CONCURRENT_VALIDATION_FAILED"
    }
} $false

Run-Test "Quota duree valide" {
    $r = Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -DurationSeconds 300

    if ($r.Valid -ne $true) {
        throw "DURATION_VALIDATION_FAILED"
    }
} $false

Run-Test "Quota memoire valide" {
    $r = Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -MemoryMb 512

    if ($r.Valid -ne $true) {
        throw "MEMORY_VALIDATION_FAILED"
    }
} $false

Run-Test "Concurrent quota depasse" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ConcurrentExecutions 5
} $true

Run-Test "Duree quota depassee" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -DurationSeconds 301
} $true

Run-Test "Memoire quota depassee" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -MemoryMb 513
} $true

Run-Test "Output quota depasse" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -OutputBytes 10485761
} $true

Run-Test "Input quota depasse" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -InputBytes 10485761
} $true

Run-Test "Process quota depasse" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ProcessCount 1
} $true

Run-Test "Network quota depasse" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -NetworkRequests 1
} $true

Run-Test "Quota bypass bloque" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -QuotaBypass $true
} $true

Run-Test "LIVE bloque" {
    Test-SandboxResourceRequest `
        -Environment "LIVE" `
        -Mode "LIVE"
} $true

Run-Test "Parametre negatif bloque" {
    Test-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -DurationSeconds -1
} $true
Run-Test "Fail closed assertion" {
    Assert-SandboxResourceRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -ConcurrentExecutions 99 `
        -DurationSeconds 9999 `
        -MemoryMb 9999 `
        -QuotaBypass $true
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B-07"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-07 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-07 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-07 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"