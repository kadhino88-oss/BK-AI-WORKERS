$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "Authorization-Proof-Atomic-Consumption-Guard.ps1"
. $Module

Reset-AtomicConsumption

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
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:Total, $TestName)
            $script:Fail++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total, $TestName)
            $script:Pass++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1} -> {2}" -f $script:Total, $TestName, $_.Exception.Message)
            $script:Pass++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total, $TestName, $_.Exception.Message)
            $script:Fail++
        }
    }
}

$Base = @{
    TenantId      = "TEN-54"
    ClientId      = "CLI-54"
    ProjectId     = "PROJ-54"
    ExecutionId   = "EXEC-54"
    UserId        = "USER-54"
    OperationName = "AI_EXECUTION"
    ProofHash     = "PROOF-54"
}

Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

Run-Test "Etat initial bloque correctement" {
    $Result = Test-AtomicProof @Base
    if ($Result.Decision -ne "BLOCK") {
        throw "INITIAL_STATE_NOT_BLOCKED"
    }
} $false

Run-Test "Tenant manquant bloque" {
    $X = @{} + $Base
    $X.TenantId = ""
    Register-AtomicProof @X
} $true

Run-Test "Client manquant bloque" {
    $X = @{} + $Base
    $X.ClientId = ""
    Register-AtomicProof @X
} $true

Run-Test "Project manquant bloque" {
    $X = @{} + $Base
    $X.ProjectId = ""
    Register-AtomicProof @X
} $true

Run-Test "Execution manquante bloque" {
    $X = @{} + $Base
    $X.ExecutionId = ""
    Register-AtomicProof @X
} $true

Run-Test "User manquant bloque" {
    $X = @{} + $Base
    $X.UserId = ""
    Register-AtomicProof @X
} $true

Run-Test "Operation manquante bloque" {
    $X = @{} + $Base
    $X.OperationName = ""
    Register-AtomicProof @X
} $true

Run-Test "ProofHash manquant bloque" {
    $X = @{} + $Base
    $X.ProofHash = ""
    Register-AtomicProof @X
} $true

Run-Test "Enregistrement initial" {
    $Result = Register-AtomicProof @Base
    if ($null -eq $Result) {
        throw "REGISTER_FAILED"
    }
} $false

Run-Test "Preuve disponible avant consommation" {
    $Result = Test-AtomicProof @Base
    if ($Result.Decision -ne "ALLOW") {
        throw "PROOF_NOT_AVAILABLE"
    }
    if ($Result.Valid -ne $true) {
        throw "PROOF_NOT_VALID"
    }
} $false

Run-Test "Premier consume autorise" {
    $Result = Consume-AtomicProof @Base
    if ($Result.Decision -ne "ALLOW") {
        throw "FIRST_CONSUME_NOT_ALLOWED"
    }
    if ($Result.Consumed -ne $true) {
        throw "FIRST_CONSUME_NOT_RECORDED"
    }
} $false

Run-Test "Deuxieme consume bloque" {
    Consume-AtomicProof @Base
} $true

Run-Test "Replay detecte par Test" {
    $Result = Test-AtomicProof @Base
    if ($Result.Decision -ne "BLOCK") {
        throw "REPLAY_NOT_BLOCKED"
    }
    if ($Result.Reason -ne "ATOMIC_REPLAY_BLOCKED") {
        throw "BAD_REASON:$($Result.Reason)"
    }
} $false

Run-Test "ProofHash different bloque" {
    $X = @{} + $Base
    $X.ProofHash = "OTHER"
    Consume-AtomicProof @X
} $true

Run-Test "Operation differente bloque" {
    $X = @{} + $Base
    $X.OperationName = "OTHER_OPERATION"
    Consume-AtomicProof @X
} $true

Run-Test "Execution differente bloque" {
    $X = @{} + $Base
    $X.ExecutionId = "OTHER_EXECUTION"
    Consume-AtomicProof @X
} $true

Run-Test "Preuve inconnue fail-closed" {
    $X = @{} + $Base
    $X.ExecutionId = "UNKNOWN_EXECUTION"

    $Result = Test-AtomicProof @X

    if ($Result.Decision -ne "BLOCK") {
        throw "FAIL_CLOSED_BROKEN"
    }
} $false

Run-Test "Double enregistrement bloque" {
    Register-AtomicProof @Base
} $true

Run-Test "Etat consommation persiste" {
    $File = Join-Path $PSScriptRoot "state\atomic-consumption.json"
    $Data = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json

    $Key = Get-AtomicProofKey @Base
    $Record = @($Data.Records | Where-Object { $_.ProofKey -eq $Key }) | Select-Object -First 1

    if ($null -eq $Record) {
        throw "RECORD_MISSING"
    }

    if ($Record.Consumed -ne $true) {
        throw "CONSUMED_NOT_PERSISTED"
    }
} $false

Run-Test "Timestamp consommation present" {
    $File = Join-Path $PSScriptRoot "state\atomic-consumption.json"
    $Data = Get-Content -LiteralPath $File -Raw -Encoding UTF8 | ConvertFrom-Json

    $Key = Get-AtomicProofKey @Base
    $Record = @($Data.Records | Where-Object { $_.ProofKey -eq $Key }) | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$Record.ConsumedAtUtc)) {
        throw "CONSUMED_TIMESTAMP_MISSING"
    }
} $false

Run-Test "Clef atomique stable" {
    $Key1 = Get-AtomicProofKey @Base
    $Key2 = Get-AtomicProofKey @Base

    if ($Key1 -ne $Key2) {
        throw "KEY_NOT_DETERMINISTIC"
    }

    if ([string]::IsNullOrWhiteSpace($Key1)) {
        throw "KEY_EMPTY"
    }
} $false

Run-Test "Scope client different bloque" {
    $X = @{} + $Base
    $X.ClientId = "OTHER_CLIENT"
    Consume-AtomicProof @X
} $true

Run-Test "Scope tenant different bloque" {
    $X = @{} + $Base
    $X.TenantId = "OTHER_TENANT"
    Consume-AtomicProof @X
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8A-54"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8A-54 : VALIDEE - 24/24"
}
else {
    Write-Host "8A-54 : NON VALIDEE"
}

Write-Host "============================================================"
Write-Host "8A-54 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"