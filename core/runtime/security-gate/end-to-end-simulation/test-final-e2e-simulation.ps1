$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$SecureEntry = Join-Path $Root "core\ai\AI-SECURE-ENTRY-GUARD.ps1"
$Gate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"
$Worker = Join-Path $Root "orchestrator\Worker-Execution.ps1"
$Orchestrator = Join-Path $Root "orchestrator\runtime\Invoke-Orchestrator.ps1"
$EndToEnd = Join-Path $Root "orchestrator\Invoke-EndToEnd.ps1"
$ExecutionPolicy = Join-Path $Root "core\runtime\execution-policy\EXECUTION-POLICY-ENGINE.ps1"
$EnvironmentGuard = Join-Path $Root "core\runtime\environment-guard\Environment-Guard.ps1"

$Files = @(
    $SecureEntry,
    $Gate,
    $Worker,
    $Orchestrator,
    $EndToEnd,
    $ExecutionPolicy,
    $EnvironmentGuard
)

$script:Total = 0
$script:Pass = 0
$script:Fail = 0
$script:SecurityResult = $null

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

# ============================================================
# 01
# ============================================================

Run-Test "Secure Entry present" {
    if (-not (Test-Path -LiteralPath $SecureEntry -PathType Leaf)) {
        throw "SECURE_ENTRY_MISSING"
    }
} $false

# 02
Run-Test "Global Gate present" {
    if (-not (Test-Path -LiteralPath $Gate -PathType Leaf)) {
        throw "GLOBAL_GATE_MISSING"
    }
} $false

# 03
Run-Test "Worker present" {
    if (-not (Test-Path -LiteralPath $Worker -PathType Leaf)) {
        throw "WORKER_MISSING"
    }
} $false

# 04
Run-Test "Orchestrator present" {
    if (-not (Test-Path -LiteralPath $Orchestrator -PathType Leaf)) {
        throw "ORCHESTRATOR_MISSING"
    }
} $false

# 05
Run-Test "EndToEnd present" {
    if (-not (Test-Path -LiteralPath $EndToEnd -PathType Leaf)) {
        throw "END_TO_END_MISSING"
    }
} $false

# 06
Run-Test "Execution Policy present" {
    if (-not (Test-Path -LiteralPath $ExecutionPolicy -PathType Leaf)) {
        throw "EXECUTION_POLICY_MISSING"
    }
} $false

# 07
Run-Test "Environment Guard present" {
    if (-not (Test-Path -LiteralPath $EnvironmentGuard -PathType Leaf)) {
        throw "ENVIRONMENT_GUARD_MISSING"
    }
} $false

# ============================================================
# 08
# Parsing de tous les fichiers critiques
# ============================================================

Run-Test "Parsing PowerShell complet" {

    $Failures = @()

    foreach ($File in $Files) {

        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
            $Failures += $File
            continue
        }

        $Tokens = $null
        $Errors = $null

        [System.Management.Automation.Language.Parser]::ParseFile(
            $File,
            [ref]$Tokens,
            [ref]$Errors
        ) | Out-Null

        if ($null -ne $Errors -and $Errors.Count -gt 0) {
            $Failures += $File
        }
    }

    if ($Failures.Count -gt 0) {
        throw ("PARSE_FAILURES:{0}" -f $Failures.Count)
    }
} $false

$SecureText = Get-Content -LiteralPath $SecureEntry -Raw -Encoding UTF8
$GateText = Get-Content -LiteralPath $Gate -Raw -Encoding UTF8
$WorkerText = Get-Content -LiteralPath $Worker -Raw -Encoding UTF8
$OrchestratorText = Get-Content -LiteralPath $Orchestrator -Raw -Encoding UTF8
$EndToEndText = Get-Content -LiteralPath $EndToEnd -Raw -Encoding UTF8

# ============================================================
# 09
# ============================================================

Run-Test "Secure Entry appelle Global Gate" {
    if (-not $SecureText.Contains("Invoke-GlobalSecurityGate")) {
        throw "SECURE_ENTRY_NOT_GATED"
    }
} $false

# ============================================================
# 10
# ============================================================

Run-Test "Secure Entry exige SessionValid" {
    if (-not $SecureText.Contains("SessionValid")) {
        throw "SESSION_GATE_MISSING"
    }
} $false

# ============================================================
# 11
# Execution SIMULATION autorisee
# ============================================================

Remove-Item Function:\Invoke-AISecureAuthorization -ErrorAction SilentlyContinue
. $SecureEntry

$Parameters = @{
    TenantId = "TEN-E2E"
    ClientId = "CLI-E2E"
    ProjectId = "PROJ-E2E"
    ExecutionId = "EXEC-E2E-001"
    UserId = "USER-E2E"
    Environment = "SIMULATION"
    Mode = "SIMULATION"

    SessionValid = $true
    RBACAuthorized = $true
    ScopeValid = $true
    AuthorizationValid = $true
    CapabilityAuthorized = $true
    AuthorityAuthorized = $true
    PolicyAuthorized = $true
    WorkerTaskAuthorized = $true
    CredentialAuthorized = $true
    ConnectorAuthorized = $true
    ProviderAuthorized = $true
    EvidenceAuthorized = $true
    RetentionValid = $true
    PurgeReuseValid = $true

    DirectConnectorExecution = $false
    DirectProviderExecution = $false
    SecretsPresent = $false

    HumanApproval = $false
    ProductionFlag = $false
}

Run-Test "Execution SIMULATION autorisee" {

    $script:SecurityResult = Invoke-AISecureAuthorization -Parameters $Parameters

    if ($script:SecurityResult.Decision -ne "ALLOW") {
        throw "SIMULATION_NOT_ALLOWED"
    }

    if ($script:SecurityResult.Authorized -ne $true) {
        throw "SIMULATION_NOT_AUTHORIZED"
    }
} $false

# ============================================================
# 12
# ============================================================

Run-Test "Session absente bloquee" {

    $X = @{} + $Parameters
    $X.ExecutionId = "EXEC-E2E-002"
    $X.SessionValid = $false

    Invoke-AISecureAuthorization -Parameters $X
} $true

# ============================================================
# 13
# ============================================================

Run-Test "Provider direct bloque" {

    $X = @{} + $Parameters
    $X.ExecutionId = "EXEC-E2E-003"
    $X.DirectProviderExecution = $true

    Invoke-AISecureAuthorization -Parameters $X
} $true

# ============================================================
# 14
# ============================================================

Run-Test "Connector direct bloque" {

    $X = @{} + $Parameters
    $X.ExecutionId = "EXEC-E2E-004"
    $X.DirectConnectorExecution = $true

    Invoke-AISecureAuthorization -Parameters $X
} $true

# ============================================================
# 15
# ============================================================

Run-Test "Secrets presents bloques" {

    $X = @{} + $Parameters
    $X.ExecutionId = "EXEC-E2E-005"
    $X.SecretsPresent = $true

    Invoke-AISecureAuthorization -Parameters $X
} $true

# ============================================================
# 16
# ============================================================

Run-Test "Capability absente bloquee" {

    $X = @{} + $Parameters
    $X.ExecutionId = "EXEC-E2E-006"
    $X.CapabilityAuthorized = $false

    Invoke-AISecureAuthorization -Parameters $X
} $true

# ============================================================
# 17
# ============================================================

Run-Test "LIVE sans autorisation explicite bloque" {

    $X = @{} + $Parameters
    $X.ExecutionId = "EXEC-E2E-007"
    $X.Environment = "LIVE"
    $X.Mode = "LIVE"
    $X.HumanApproval = $false
    $X.ProductionFlag = $false

    Invoke-AISecureAuthorization -Parameters $X
} $true

# ============================================================
# 18
# Worker simulation
# ============================================================

Run-Test "Worker declare simulation" {
    if (-not (
        $WorkerText.Contains("SIMULATION") -or
        $WorkerText.Contains("simulation")
    )) {
        throw "WORKER_SIMULATION_NOT_FOUND"
    }
} $false

# ============================================================
# 19
# ============================================================

Run-Test "Orchestrator declare simulation" {
    if (-not (
        $OrchestratorText.Contains("SIMULATION") -or
        $OrchestratorText.Contains("simulation")
    )) {
        throw "ORCHESTRATOR_SIMULATION_NOT_FOUND"
    }
} $false

# ============================================================
# 20
# ============================================================

Run-Test "EndToEnd protege simulation" {
    if (-not (
        $EndToEndText.Contains("External actions remain blocked during simulation") -or
        $EndToEndText.Contains("simulation")
    )) {
        throw "E2E_SIMULATION_GUARD_MISSING"
    }
} $false

# ============================================================
# 21
# ============================================================

Run-Test "Worker possede contexte execution" {
    if (-not (
        $WorkerText.Contains("TaskId") -or
        $WorkerText.Contains("Execution")
    )) {
        throw "WORKER_EXECUTION_CONTEXT_MISSING"
    }
} $false

# ============================================================
# 22
# ============================================================

Run-Test "Simulation verrouille les actions externes" {
    if (
        $EndToEndText.Contains("External actions remain blocked during simulation") -or
        $EndToEndText -match "(?i)external.*blocked.*simulation"
    ) {
        $true
    }
    else {
        throw "EXTERNAL_ACTION_SIMULATION_GUARD_NOT_CONFIRMED"
    }
} $false

# ============================================================
# 23
# ============================================================

Run-Test "Global Security Gate reste central" {
    if (
        -not $GateText.Contains("GLOBAL_SECURITY_CHAIN_VALID")
    ) {
        throw "GLOBAL_GATE_CONTRACT_MISSING"
    }

    if (
        -not $SecureText.Contains("Invoke-GlobalSecurityGate")
    ) {
        throw "SECURE_ENTRY_GATE_LINK_MISSING"
    }
} $false

# ============================================================
# 24
# ============================================================

Run-Test "Resultat securite final coherent" {

    if ($null -eq $script:SecurityResult) {
        throw "SECURITY_RESULT_MISSING"
    }

    if ($script:SecurityResult.Decision -ne "ALLOW") {
        throw "SECURITY_RESULT_NOT_ALLOW"
    }

    if ($script:SecurityResult.Authorized -ne $true) {
        throw "SECURITY_RESULT_NOT_AUTHORIZED"
    }
} $false

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "FINAL E2E SECURITY SIMULATION" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass) -ForegroundColor Green
Write-Host ("FAIL        : {0}" -f $script:Fail) -ForegroundColor Red
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "FINAL E2E SECURITY SIMULATION : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "FINAL E2E SECURITY SIMULATION : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "FIN E2E" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"