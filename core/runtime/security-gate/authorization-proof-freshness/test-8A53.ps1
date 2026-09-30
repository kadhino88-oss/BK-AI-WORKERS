$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Module = Join-Path $Root "core\runtime\security-gate\authorization-proof-freshness\Authorization-Proof-Freshness-Guard.ps1"
$StateDir = Join-Path $Root "core\runtime\security-gate\authorization-proof-freshness\state"

. $Module

$script:i = 0
$script:p = 0
$script:f = 0

function Run-Test {
    param(
        [string]$TestName,
        [scriptblock]$TestAction,
        [bool]$ExpectThrow
    )

    $script:i++

    try {
        & $TestAction | Out-Null

        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:i,$TestName) -ForegroundColor Red
            $script:f++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:i,$TestName) -ForegroundColor Green
            $script:p++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1} -> {2}" -f $script:i,$TestName,$_.Exception.Message) -ForegroundColor Green
            $script:p++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:i,$TestName,$_.Exception.Message) -ForegroundColor Red
            $script:f++
        }
    }
}

function New-Context {
    return @{
        TenantId   = "TEN-53"
        ClientId   = "CLI-53"
        ProjectId  = "PROJ-53"
        ExecutionId = "EXEC-53-001"
        UserId     = "USER-53"
    }
}

Reset-ProofFreshness

$Context = New-Context
$TestActionName = "AI_EXECUTION"
$TestProofHash = "PROOF-53"
$IssuedAt = [DateTime]::UtcNow.AddSeconds(-5)

# 01
Run-Test "Hash déterministe" {
    $a = Get-FreshnessHash `
        -Context $Context `
        -Action $TestActionName `
        -ProofHash $TestProofHash `
        -IssuedAtUtc $IssuedAt `
        -LifetimeSeconds 300

    $b = Get-FreshnessHash `
        -Context $Context `
        -Action $TestActionName `
        -ProofHash $TestProofHash `
        -IssuedAtUtc $IssuedAt `
        -LifetimeSeconds 300

    if ($a -ne $b) {
        throw "HASH_NOT_DETERMINISTIC"
    }
} $false

# 02
Run-Test "Tenant manquant bloqué" {
    $x = @{}
    foreach ($k in $Context.Keys) { $x[$k] = $Context[$k] }
    $x.Remove("TenantId")

    Get-FreshnessHash -Context $x -Action $TestActionName -ProofHash $TestProofHash -IssuedAtUtc $IssuedAt -LifetimeSeconds 300
} $true

# 03
Run-Test "Client manquant bloqué" {
    $x = @{}
    foreach ($k in $Context.Keys) { $x[$k] = $Context[$k] }
    $x.Remove("ClientId")

    Get-FreshnessHash -Context $x -Action $TestActionName -ProofHash $TestProofHash -IssuedAtUtc $IssuedAt -LifetimeSeconds 300
} $true

# 04
Run-Test "Project manquant bloqué" {
    $x = @{}
    foreach ($k in $Context.Keys) { $x[$k] = $Context[$k] }
    $x.Remove("ProjectId")

    Get-FreshnessHash -Context $x -Action $TestActionName -ProofHash $TestProofHash -IssuedAtUtc $IssuedAt -LifetimeSeconds 300
} $true

# 05
Run-Test "Execution manquante bloquée" {
    $x = @{}
    foreach ($k in $Context.Keys) { $x[$k] = $Context[$k] }
    $x.Remove("ExecutionId")

    Get-FreshnessHash -Context $x -Action $TestActionName -ProofHash $TestProofHash -IssuedAtUtc $IssuedAt -LifetimeSeconds 300
} $true

# 06
Run-Test "User manquant bloqué" {
    $x = @{}
    foreach ($k in $Context.Keys) { $x[$k] = $Context[$k] }
    $x.Remove("UserId")

    Get-FreshnessHash -Context $x -Action $TestActionName -ProofHash $TestProofHash -IssuedAtUtc $IssuedAt -LifetimeSeconds 300
} $true

# 07
Run-Test "Action vide bloquée" {
    Get-FreshnessHash -Context $Context -Action "" -ProofHash $TestProofHash -IssuedAtUtc $IssuedAt -LifetimeSeconds 300
} $true

# 08
Run-Test "ProofHash vide bloquée" {
    Get-FreshnessHash -Context $Context -Action $TestActionName -ProofHash "" -IssuedAtUtc $IssuedAt -LifetimeSeconds 300
} $true

# 09
Run-Test "Durée invalide bloquée" {
    Get-FreshnessHash -Context $Context -Action $TestActionName -ProofHash $TestProofHash -IssuedAtUtc $IssuedAt -LifetimeSeconds 0
} $true

# 10
Run-Test "Enregistrement initial autorisé" {
    $r = Register-ProofFreshness `
        -Context $Context `
        -Action $TestActionName `
        -ProofHash $TestProofHash `
        -IssuedAtUtc $IssuedAt `
        -LifetimeSeconds 300

    if ($null -eq $r) {
        throw "REGISTER_FAILED"
    }
} $false

# 11
Run-Test "Fichier de preuve créé" {
    $File = Get-FreshnessFile `
        -Context $Context `
        -Action $TestActionName

    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        throw "PROOF_FILE_MISSING"
    }
} $false

# 12
Run-Test "Preuve fraîche valide" {
    $r = Test-ProofFreshness `
        -Context $Context `
        -Action $TestActionName `
        -ProofHash $TestProofHash

    if ($r.Valid -ne $true) {
        throw "FRESHNESS_INVALID:$($r.Reason)"
    }

    if ($r.Decision -ne "ALLOW") {
        throw "DECISION_NOT_ALLOW"
    }
} $false

# 13
Run-Test "ProofHash différent bloqué" {
    $r = Test-ProofFreshness `
        -Context $Context `
        -Action $TestActionName `
        -ProofHash "OTHER-PROOF"

    if ($r.Valid) {
        throw "PROOF_BYPASS"
    }
} $false

# 14
Run-Test "Action différente bloquée" {
    $r = Test-ProofFreshness `
        -Context $Context `
        -Action "OTHER_ACTION" `
        -ProofHash $TestProofHash

    if ($r.Valid) {
        throw "ACTION_BYPASS"
    }
} $false

# 15
Run-Test "Execution inconnue bloquée" {
    $x = @{}
    foreach ($k in $Context.Keys) { $x[$k] = $Context[$k] }
    $x.ExecutionId = "EXEC-UNKNOWN"

    $r = Test-ProofFreshness `
        -Context $x `
        -Action $TestActionName `
        -ProofHash $TestProofHash

    if ($r.Valid) {
        throw "EXECUTION_BYPASS"
    }
} $false

# 16
Run-Test "Preuve expirée bloquée" {
    $x = New-Context
    $x.ExecutionId = "EXEC-EXPIRED"

    Register-ProofFreshness `
        -Context $x `
        -Action $TestActionName `
        -ProofHash "EXPIRED-PROOF" `
        -IssuedAtUtc ([DateTime]::UtcNow.AddMinutes(-10)) `
        -LifetimeSeconds 60 | Out-Null

    $r = Test-ProofFreshness `
        -Context $x `
        -Action $TestActionName `
        -ProofHash "EXPIRED-PROOF"

    if ($r.Valid) {
        throw "EXPIRED_ALLOWED"
    }

    if ($r.Reason -ne "AUTHORIZATION_PROOF_EXPIRED") {
        throw "UNEXPECTED_REASON:$($r.Reason)"
    }
} $false

# 17
Run-Test "Preuve future bloquée" {
    $x = New-Context
    $x.ExecutionId = "EXEC-FUTURE"

    Register-ProofFreshness `
        -Context $x `
        -Action $TestActionName `
        -ProofHash "FUTURE-PROOF" `
        -IssuedAtUtc ([DateTime]::UtcNow.AddMinutes(5)) `
        -LifetimeSeconds 300 | Out-Null

    $r = Test-ProofFreshness `
        -Context $x `
        -Action $TestActionName `
        -ProofHash "FUTURE-PROOF"

    if ($r.Valid) {
        throw "FUTURE_ALLOWED"
    }

    if ($r.Reason -ne "AUTHORIZATION_PROOF_NOT_YET_VALID") {
        throw "UNEXPECTED_REASON:$($r.Reason)"
    }
} $false

# 18
Run-Test "Replay incohérent bloqué" {
    Register-ProofFreshness `
        -Context $Context `
        -Action $TestActionName `
        -ProofHash "OTHER-PROOF" `
        -IssuedAtUtc $IssuedAt `
        -LifetimeSeconds 300
} $true

# 19
Run-Test "Preuve verrouillée" {
    $File = Get-FreshnessFile `
        -Context $Context `
        -Action $TestActionName

    $Record = Get-Content `
        -LiteralPath $File `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

    if ($Record.Locked -ne $true) {
        throw "NOT_LOCKED"
    }
} $false

# 20
Run-Test "Expiration enregistrée" {
    $File = Get-FreshnessFile `
        -Context $Context `
        -Action $TestActionName

    $Record = Get-Content `
        -LiteralPath $File `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

    if ([string]::IsNullOrWhiteSpace([string]$Record.ExpiresAtUtc)) {
        throw "EXPIRATION_MISSING"
    }
} $false

# 21
Run-Test "Consommation autorisée une fois" {
    Consume-ProofFreshness `
        -Context $Context `
        -Action $TestActionName

    $File = Get-FreshnessFile `
        -Context $Context `
        -Action $TestActionName

    $Record = Get-Content `
        -LiteralPath $File `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

    if ($Record.Consumed -ne $true) {
        throw "CONSUMPTION_NOT_RECORDED"
    }
} $false

# 22
Run-Test "Replay après consommation bloqué" {
    Consume-ProofFreshness `
        -Context $Context `
        -Action $TestActionName
} $true

# 23
Run-Test "Preuve consommée refusée" {
    $r = Test-ProofFreshness `
        -Context $Context `
        -Action $TestActionName `
        -ProofHash $TestProofHash

    if ($r.Valid) {
        throw "CONSUMED_ALLOWED"
    }

    if ($r.Reason -ne "AUTHORIZATION_REPLAY_BLOCKED") {
        throw "UNEXPECTED_REASON:$($r.Reason)"
    }
} $false

# 24
Run-Test "Fail-closed preuve absente" {
    $x = New-Context
    $x.ExecutionId = "EXEC-NOT-REGISTERED"

    $r = Test-ProofFreshness `
        -Context $x `
        -Action $TestActionName `
        -ProofHash "UNKNOWN"

    if ($r.Decision -ne "BLOCK") {
        throw "FAIL_CLOSED_BROKEN"
    }
} $false

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-53" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL TESTS : {0}" -f $script:i)
Write-Host ("PASS        : {0}" -f $script:p) -ForegroundColor Green
Write-Host ("FAIL        : {0}" -f $script:f) -ForegroundColor Red
Write-Host ""

if (($script:i -eq 24) -and ($script:p -eq 24) -and ($script:f -eq 0)) {
    Write-Host "8A-53 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8A-53 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-53 - FIN" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"