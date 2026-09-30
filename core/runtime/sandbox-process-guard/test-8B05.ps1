$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-PROCESS-CHILD-PROCESS-GUARD.ps1"

. $Module

Initialize-SandboxProcessGuard | Out-Null

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

# 01
Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

# 02
Run-Test "State SANDBOX" {
    $s = Get-SandboxProcessGuardState
    if ($s.Mode -ne "SANDBOX") { throw "BAD_MODE" }
} $false

# 03
Run-Test "Process spawn disabled" {
    $s = Get-SandboxProcessGuardState
    if ($s.ProcessSpawnAllowed -ne $false) { throw "PROCESS_ENABLED" }
} $false

# 04
Run-Test "Child process disabled" {
    $s = Get-SandboxProcessGuardState
    if ($s.ChildProcessAllowed -ne $false) { throw "CHILD_PROCESS_ENABLED" }
} $false

# 05
Run-Test "Shell execution disabled" {
    $s = Get-SandboxProcessGuardState
    if ($s.ShellExecutionAllowed -ne $false) { throw "SHELL_ENABLED" }
} $false

# 06
Run-Test "PowerShell execution disabled" {
    $s = Get-SandboxProcessGuardState
    if ($s.PowerShellExecutionAllowed -ne $false) { throw "POWERSHELL_ENABLED" }
} $false

# 07
Run-Test "Command execution disabled" {
    $s = Get-SandboxProcessGuardState
    if ($s.CommandExecutionAllowed -ne $false) { throw "COMMAND_ENABLED" }
} $false

# 08
Run-Test "External binary disabled" {
    $s = Get-SandboxProcessGuardState
    if ($s.ExternalBinaryAllowed -ne $false) { throw "BINARY_ENABLED" }
} $false

# 09
Run-Test "Script execution disabled" {
    $s = Get-SandboxProcessGuardState
    if ($s.ScriptExecutionAllowed -ne $false) { throw "SCRIPT_ENABLED" }
} $false

# 10
Run-Test "Request neutre autorisee" {
    $r = Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Decision -ne "ALLOW") { throw "NEUTRAL_REQUEST_BLOCKED" }
} $false

# 11
Run-Test "Process spawn bloque" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestProcessSpawn $true
} $true

# 12
Run-Test "Child process bloque" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestChildProcess $true
} $true

# 13
Run-Test "Shell bloque" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestShell $true
} $true

# 14
Run-Test "PowerShell bloque" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestPowerShell $true
} $true

# 15
Run-Test "Commande bloquee" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestCommand $true
} $true

# 16
Run-Test "Binaire externe bloque" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestExternalBinary $true
} $true

# 17
Run-Test "Execution script bloquee" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestScriptExecution $true
} $true

# 18
Run-Test "LIVE environment bloque" {
    Test-SandboxProcessRequest `
        -Environment "LIVE" `
        -Mode "LIVE"
} $true

# 19
Run-Test "Mode LIVE bloque" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "LIVE"
} $true

# 20
Run-Test "Environment vide bloque" {
    Test-SandboxProcessRequest `
        -Environment "" `
        -Mode "SANDBOX"
} $true

# 21
Run-Test "Mode vide bloque" {
    Test-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode ""
} $true

# 22
Run-Test "Assert process neutre autorise" {
    $r = Assert-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX"

    if ($r.Isolated -ne $true) {
        throw "ASSERT_ISOLATION_FAILED"
    }
} $false

# 23
Run-Test "Assert bloque execution PowerShell" {
    Assert-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestPowerShell $true
} $true

# 24
Run-Test "Fail closed combinaison process" {
    Assert-SandboxProcessRequest `
        -Environment "SANDBOX" `
        -Mode "SANDBOX" `
        -RequestProcessSpawn $true `
        -RequestChildProcess $true `
        -RequestShell $true `
        -RequestPowerShell $true `
        -RequestCommand $true `
        -RequestExternalBinary $true `
        -RequestScriptExecution $true
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B-05"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-05 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-05 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-05 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"