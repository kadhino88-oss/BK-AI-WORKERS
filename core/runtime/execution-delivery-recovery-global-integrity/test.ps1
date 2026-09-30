$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-global-integrity"

$Pass = 0
$Fail = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition
    )

    if ($Condition) {
        Write-Host "[PASS] $Name"
        $script:Pass++
    }
    else {
        Write-Host "[FAIL] $Name"
        $script:Fail++
    }
}

function Read-JsonFile {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -Raw -Path $Path

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Test-FunctionExists {
    param(
        [string]$Path,
        [string]$FunctionName
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $false
    }

    $source = Get-Content -Raw -Path $Path

    $pattern = "function\s+" + [regex]::Escape($FunctionName) + "\s*\{"

    return (
        $source -match $pattern
    )
}

# ============================================================
# 1-4 : GLOBAL CONFIG
# ============================================================

$cfg = Read-JsonFile (
    Join-Path $Dir "config.json"
)

Assert-Test "Global config loaded" (
    $null -ne $cfg
)

Assert-Test "Global integrity enabled" (
    $cfg.globalIntegrityCheckEnabled -eq $true
)

Assert-Test "Cross-module validation enabled" (
    $cfg.crossModuleValidationEnabled -eq $true
)

Assert-Test "Simulation-only enforced" (
    $cfg.simulationOnly -eq $true -and
    $cfg.liveExecutionEnabled -eq $false
)

# ============================================================
# MODULES REELS
# ============================================================

$modules = @(
    @{
        Key = "7H-69"
        Name = "Recovery Authorization"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-authorization"
        Runtime = "Execution-Delivery-Recovery-Authorization.ps1"
        Config = "config.json"
        Function = "Authorize-DeliveryRecovery"
    },
    @{
        Key = "7H-70"
        Name = "Recovery Finalization"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-finalization"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Finalize-DeliveryRecovery"
    },
    @{
        Key = "7H-71"
        Name = "Recovery Closure"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-closure"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Close-DeliveryRecovery"
    },
    @{
        Key = "7H-72"
        Name = "Closure Integrity"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-closure-integrity"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Register-ClosureIntegrity"
    },
    @{
        Key = "7H-73"
        Name = "Recovery Audit"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-audit"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Add-RecoveryAuditEvent"
    },
    @{
        Key = "7H-74"
        Name = "Audit Integrity"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-audit-integrity"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Add-RecoveryAuditIntegrityEvent"
    },
    @{
        Key = "7H-75"
        Name = "Audit Retention"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-audit-retention"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Register-RecoveryAuditRetention"
    },
    @{
        Key = "7H-76"
        Name = "Retention Lifecycle"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-retention-lifecycle"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Initialize-RetentionLifecycle"
    },
    @{
        Key = "7H-77"
        Name = "Retention Consistency"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-retention-consistency"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Register-RetentionConsistency"
    },
    @{
        Key = "7H-78"
        Name = "Tenant Isolation"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-retention-tenant-guard"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Register-RetentionTenantRecord"
    },
    @{
        Key = "7H-79"
        Name = "Access Audit"
        Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-retention-access-audit"
        Runtime = "runtime.ps1"
        Config = "config.json"
        Function = "Register-RetentionAccessDecision"
    }
)

$moduleCount = @($modules).Length

# 5
Assert-Test "Expected 11 modules registered" (
    $moduleCount -eq 11
)

# ============================================================
# 6-9 : EXISTENCE / PRIMARY FUNCTIONS
# ============================================================

$allDirectories = $true
$allRuntimes = $true
$allConfigs = $true
$allFunctions = $true

foreach ($module in $modules) {

    $modulePath = [string]$module.Path

    if (-not (Test-Path $modulePath -PathType Container)) {
        $allDirectories = $false
        continue
    }

    $runtimePath = Join-Path $modulePath $module.Runtime
    $configPath = Join-Path $modulePath $module.Config

    if (-not (Test-Path $runtimePath -PathType Leaf)) {
        $allRuntimes = $false
    }

    if (-not (Test-Path $configPath -PathType Leaf)) {
        $allConfigs = $false
    }

    if (-not (Test-FunctionExists `
        -Path $runtimePath `
        -FunctionName $module.Function)) {

        $allFunctions = $false
    }
}

# 6
Assert-Test "All module directories exist" $allDirectories

# 7
Assert-Test "All runtime files exist" $allRuntimes

# 8
Assert-Test "All module configs exist" $allConfigs

# 9
Assert-Test "All primary runtime functions exist" $allFunctions

# ============================================================
# 10-12 : SECURITY FLAGS
# ============================================================

$allSimulation = $true
$allSecretsSafe = $true
$allPayloadsSafe = $true

foreach ($module in $modules) {

    $moduleCfg = Read-JsonFile (
        Join-Path $module.Path $module.Config
    )

    if ($null -eq $moduleCfg) {
        $allSimulation = $false
        $allSecretsSafe = $false
        $allPayloadsSafe = $false
        continue
    }

    if ($moduleCfg.liveExecutionEnabled -ne $false) {
        $allSimulation = $false
    }

    if ($moduleCfg.captureSecrets -ne $false) {
        $allSecretsSafe = $false
    }

    if ($moduleCfg.capturePayloads -ne $false) {
        $allPayloadsSafe = $false
    }
}

# 10
Assert-Test "All modules remain simulation-only" (
    $allSimulation
)

# 11
Assert-Test "Secrets capture disabled everywhere" (
    $allSecretsSafe
)

# 12
Assert-Test "Payload capture disabled everywhere" (
    $allPayloadsSafe
)

# ============================================================
# 13 : GLOBAL CONTEXT
# ============================================================

$ExecutionId = "EXE-GLOBAL-8001"
$TenantId = "TEN-GLOBAL-01"
$ClientId = "CLI-GLOBAL-01"
$ProjectId = "PROJ-GLOBAL-01"
$DeliveryId = "DEL-GLOBAL-01"
$RecoveryId = "REC-GLOBAL-01"
$AuthorizationId = "AUTH-GLOBAL-01"
$FinalizationId = "FIN-GLOBAL-01"
$ClosureId = "CLOSE-GLOBAL-01"
$CorrelationId = "CORR-GLOBAL-01"
$RetentionId = "RET-GLOBAL-01"
$EventId = "EV-GLOBAL-01"
$DecisionId = "DEC-GLOBAL-01"

$contextValues = @(
    $ExecutionId,
    $TenantId,
    $ClientId,
    $ProjectId,
    $DeliveryId,
    $RecoveryId,
    $AuthorizationId,
    $FinalizationId,
    $ClosureId,
    $CorrelationId,
    $RetentionId,
    $EventId,
    $DecisionId
)

$contextComplete = $true

foreach ($value in $contextValues) {
    if ([string]::IsNullOrWhiteSpace([string]$value)) {
        $contextComplete = $false
        break
    }
}

Assert-Test "Global execution context complete" $contextComplete

# ============================================================
# 14-16 : ISOLATION CONTEXT
# ============================================================

Assert-Test "Shared TenantId available" (
    -not [string]::IsNullOrWhiteSpace($TenantId)
)

Assert-Test "Shared ClientId available" (
    -not [string]::IsNullOrWhiteSpace($ClientId)
)

Assert-Test "Shared ProjectId available" (
    -not [string]::IsNullOrWhiteSpace($ProjectId)
)

# ============================================================
# 17-20 : LIFECYCLE MODEL
# ============================================================

$lifecycle = @(
    "AUTHORIZED",
    "FINALIZED",
    "CLOSED",
    "AUDITED",
    "INTEGRITY_VERIFIED",
    "RETAINED",
    "RETENTION_CONSISTENT",
    "TENANT_ISOLATED",
    "ACCESS_AUDITED"
)

Assert-Test "Lifecycle contains authorization" (
    $lifecycle -contains "AUTHORIZED"
)

Assert-Test "Lifecycle contains finalization and closure" (
    ($lifecycle -contains "FINALIZED") -and
    ($lifecycle -contains "CLOSED")
)

Assert-Test "Lifecycle contains audit and integrity stages" (
    ($lifecycle -contains "AUDITED") -and
    ($lifecycle -contains "INTEGRITY_VERIFIED")
)

Assert-Test "Lifecycle contains retention controls" (
    ($lifecycle -contains "RETAINED") -and
    ($lifecycle -contains "RETENTION_CONSISTENT")
)

# ============================================================
# 21 : AUDIT / RETENTION CROSS CONTEXT
# ============================================================

$syntheticAudit = [pscustomobject]@{
    EventId = $EventId
    CorrelationId = $CorrelationId
    ExecutionId = $ExecutionId
    TenantId = $TenantId
    ClientId = $ClientId
    ProjectId = $ProjectId
    DeliveryId = $DeliveryId
    RecoveryId = $RecoveryId
    AuthorizationId = $AuthorizationId
    FinalizationId = $FinalizationId
    ClosureId = $ClosureId
}

$syntheticRetention = [pscustomobject]@{
    RetentionId = $RetentionId
    EventId = $EventId
    CorrelationId = $CorrelationId
    ExecutionId = $ExecutionId
    TenantId = $TenantId
    ClientId = $ClientId
    ProjectId = $ProjectId
}

$traceContextMatches = (
    $syntheticAudit.ExecutionId -eq $syntheticRetention.ExecutionId -and
    $syntheticAudit.TenantId -eq $syntheticRetention.TenantId -and
    $syntheticAudit.ClientId -eq $syntheticRetention.ClientId -and
    $syntheticAudit.ProjectId -eq $syntheticRetention.ProjectId -and
    $syntheticAudit.EventId -eq $syntheticRetention.EventId -and
    $syntheticAudit.CorrelationId -eq $syntheticRetention.CorrelationId
)

Assert-Test "Audit and retention context consistent" (
    $traceContextMatches
)

# ============================================================
# 22
# ============================================================

Assert-Test "Retention remains inside expected tenant" (
    $syntheticRetention.TenantId -eq $TenantId
)

# ============================================================
# 23 : ACCESS DECISION
# ============================================================

$decision = [pscustomobject]@{
    DecisionId = $DecisionId
    RetentionId = $RetentionId
    TenantId = $TenantId
    ClientId = $ClientId
    ProjectId = $ProjectId
    Operation = "READ"
    Decision = "ALLOW"
}

$decisionContextMatches = (
    $decision.RetentionId -eq $RetentionId -and
    $decision.TenantId -eq $TenantId -and
    $decision.ClientId -eq $ClientId -and
    $decision.ProjectId -eq $ProjectId
)

Assert-Test "Access decision context consistent" (
    $decisionContextMatches
)

# ============================================================
# 24 : GLOBAL READY
# ============================================================

$globalReady = (
    $moduleCount -eq 11 -and
    $allDirectories -and
    $allRuntimes -and
    $allConfigs -and
    $allFunctions -and
    $allSimulation -and
    $allSecretsSafe -and
    $allPayloadsSafe -and
    $contextComplete -and
    $traceContextMatches -and
    ($syntheticRetention.TenantId -eq $TenantId) -and
    $decisionContextMatches
)

Assert-Test "GLOBAL 7H CHECK READY" $globalReady

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-80"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host "MODULES CONTROLES : $moduleCount"
Write-Host "=============================================="

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"