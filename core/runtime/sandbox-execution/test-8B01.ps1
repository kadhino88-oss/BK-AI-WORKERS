$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-EXECUTION-RUNTIME.ps1"

. $Module

Initialize-SandboxState | Out-Null

$script:Total = 0
$script:Pass = 0
$script:Fail = 0
$script:Result = $null

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

$Base = @{
    TenantId = "TEN-8B01"
    ClientId = "CLI-8B01"
    ProjectId = "PROJ-8B01"
    ExecutionId = "EXEC-8B01"
    UserId = "USER-8B01"
    TaskId = "TASK-8B01"
    OperationName = "AI_SIMULATION"
    Environment = "SANDBOX"
    Mode = "SANDBOX"
    SessionValid = $true
    AuthorizationValid = $true
    CapabilityAuthorized = $true
    AuthorityAuthorized = $true
    PolicyAuthorized = $true
    WorkerTaskAuthorized = $true
    DirectProviderExecution = $false
    DirectConnectorExecution = $false
    SecretsPresent = $false
}

# 01
Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

# 02
Run-Test "Sandbox runtime pret" {
    $r = Test-SandboxRuntime

    if ($r.Ready -ne $true) {
        throw "SANDBOX_NOT_READY"
    }
} $false

# 03
Run-Test "Mode SANDBOX" {
    $r = Test-SandboxRuntime

    if ($r.Mode -ne "SANDBOX") {
        throw "BAD_MODE"
    }
} $false

# 04
Run-Test "LIVE desactive" {
    $r = Test-SandboxRuntime

    if ($r.LiveEnabled -ne $false) {
        throw "LIVE_ENABLED"
    }
} $false

# 05
Run-Test "Actions externes desactivees" {
    $r = Test-SandboxRuntime

    if ($r.ExternalActionsEnabled -ne $false) {
        throw "EXTERNAL_ACTIONS_ENABLED"
    }
} $false

# 06
Run-Test "Secrets interdits" {
    $r = Test-SandboxRuntime

    if ($r.SecretsAllowed -ne $false) {
        throw "SECRETS_ALLOWED"
    }
} $false

# 07
Run-Test "Provider LIVE desactive" {
    $r = Test-SandboxRuntime

    if ($r.ProviderLiveEnabled -ne $false) {
        throw "PROVIDER_LIVE_ENABLED"
    }
} $false

# 08
Run-Test "Connector LIVE desactive" {
    $r = Test-SandboxRuntime

    if ($r.ConnectorLiveEnabled -ne $false) {
        throw "CONNECTOR_LIVE_ENABLED"
    }
} $false

# 09
Run-Test "Execution sandbox autorisee" {
    $script:Result = Invoke-SandboxExecution @Base

    if ($script:Result.Decision -ne "ALLOW") {
        throw "SANDBOX_NOT_ALLOWED"
    }
} $false

# 10
Run-Test "Execution marquee autorisee" {
    if ($script:Result.Authorized -ne $true) {
        throw "NOT_AUTHORIZED"
    }
} $false

# 11
Run-Test "Provider simule" {
    if ($script:Result.ProviderExecution -ne "SIMULATED") {
        throw "PROVIDER_NOT_SIMULATED"
    }
} $false

# 12
Run-Test "Connector simule" {
    if ($script:Result.ConnectorExecution -ne "SIMULATED") {
        throw "CONNECTOR_NOT_SIMULATED"
    }
} $false

# 13
Run-Test "Aucune action externe executee" {
    if ($script:Result.ExternalActionExecuted -ne $false) {
        throw "EXTERNAL_ACTION_EXECUTED"
    }
} $false

# 14
Run-Test "Aucun secret utilise" {
    if ($script:Result.SecretsUsed -ne $false) {
        throw "SECRETS_USED"
    }
} $false

# 15
Run-Test "Aucun LIVE execute" {
    if ($script:Result.LiveExecution -ne $false) {
        throw "LIVE_EXECUTED"
    }
} $false

# 16
Run-Test "Replay sandbox bloque" {
    Invoke-SandboxExecution @Base
} $true

# 17
Run-Test "Session absente bloque" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-17"
    $x.SessionValid = $false

    Invoke-SandboxExecution @x
} $true

# 18
Run-Test "Authorization absente bloque" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-18"
    $x.AuthorizationValid = $false

    Invoke-SandboxExecution @x
} $true

# 19
Run-Test "Capability absente bloque" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-19"
    $x.CapabilityAuthorized = $false

    Invoke-SandboxExecution @x
} $true

# 20
Run-Test "Provider direct bloque" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-20"
    $x.DirectProviderExecution = $true

    Invoke-SandboxExecution @x
} $true

# 21
Run-Test "Connector direct bloque" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-21"
    $x.DirectConnectorExecution = $true

    Invoke-SandboxExecution @x
} $true

# 22
Run-Test "Secrets presents bloques" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-22"
    $x.SecretsPresent = $true

    Invoke-SandboxExecution @x
} $true

# 23
Run-Test "LIVE environnement bloque" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-23"
    $x.Environment = "LIVE"
    $x.Mode = "LIVE"

    Invoke-SandboxExecution @x
} $true

# 24
Run-Test "Contexte sandbox incomplet bloque" {
    $x = @{} + $Base
    $x.ExecutionId = "EXEC-8B01-24"
    $x.TaskId = ""

    Invoke-SandboxExecution @x
} $true

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8B-01" -ForegroundColor Cyan
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-01 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-01 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-01 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"