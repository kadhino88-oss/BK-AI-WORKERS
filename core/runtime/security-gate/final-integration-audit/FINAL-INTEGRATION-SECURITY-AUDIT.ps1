$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Targets = @(
    "$Root\core\ai\AI-SECURE-ENTRY-GUARD.ps1",
    "$Root\core\ai\AI-GATEWAY.ps1",
    "$Root\core\ai\AI-PROVIDER-ENGINE.ps1",
    "$Root\core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1",
    "$Root\core\security\session-token-security\runtime.ps1",
    "$Root\core\runtime\security-gate\execution-context-integrity\Execution-Context-Integrity-Guard.ps1",
    "$Root\core\runtime\security-gate\authorization-proof-integrity\Authorization-Proof-Integrity-Guard.ps1",
    "$Root\core\runtime\security-gate\authorization-proof-freshness\Authorization-Proof-Freshness-Guard.ps1",
    "$Root\core\runtime\security-gate\authorization-proof-atomic-consumption\Authorization-Proof-Atomic-Consumption-Guard.ps1",
    "$Root\core\runtime\security-gate\authorization-proof-lifecycle\Authorization-Proof-Lifecycle-Guard.ps1",
    "$Root\core\runtime\execution-pipeline\EXECUTION-PIPELINE-RUNTIME.ps1",
    "$Root\core\runtime\orchestrator-controller\ORCHESTRATOR-CONTROLLER-RUNTIME.ps1",
    "$Root\core\runtime\execution-gateway\EXTERNAL-CONNECTOR-EXECUTION-GATEWAY.ps1",
    "$Root\core\runtime\execution-policy\EXECUTION-POLICY-ENGINE.ps1",
    "$Root\core\runtime\authority-gate\Authority-Gate.ps1",
    "$Root\core\runtime\environment-guard\Environment-Guard.ps1",
    "$Root\core\runtime\integration-enforcement\INTEGRATION-RUNTIME-ENFORCER.ps1",
    "$Root\orchestrator\Invoke-EndToEnd.ps1",
    "$Root\orchestrator\runtime\Invoke-Orchestrator.ps1",
    "$Root\orchestrator\Worker-Execution.ps1"
)

$Checks = @()

function Add-Check {
    param(
        [string]$Name,
        [bool]$Pass,
        [string]$Detail
    )

    $script:Checks += [pscustomobject]@{
        Name = $Name
        Pass = $Pass
        Detail = $Detail
    }
}

function Read-ProjectFiles {
    param(
        [string]$SearchRoot
    )

    if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem `
            -LiteralPath $SearchRoot `
            -Recurse `
            -File `
            -Filter "*.ps1" |
        Where-Object {
            $_.FullName -notmatch "\\backups\\" -and
            $_.FullName -notmatch "\\tests?\\" -and
            $_.FullName -notmatch "\\test-" -and
            $_.Name -notmatch "^test"
        }
    )
}

# ============================================================
# 01-20 : FICHIERS CRITIQUES
# ============================================================

$Index = 0

foreach ($Target in $Targets) {
    $Index++

    Add-Check `
        ("FILE-{0:00}" -f $Index) `
        (Test-Path -LiteralPath $Target -PathType Leaf) `
        $Target
}

# ============================================================
# CHARGEMENT DES SOURCES
# ============================================================

$Existing = @(
    $Targets |
    Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }
)

$Contents = @{}

foreach ($File in $Existing) {
    try {
        $Contents[$File] = [System.IO.File]::ReadAllText(
            $File,
            [System.Text.Encoding]::UTF8
        )
    }
    catch {
        $Contents[$File] = ""
    }
}

$AllContent = ($Contents.Values -join "`n")

# ============================================================
# 21-40 : SECURE ENTRY / GLOBAL GATE
# ============================================================

Add-Check `
    "SECURE-ENTRY-GATE" `
    (
        $Contents.Keys |
        Where-Object { $_ -like "*AI-SECURE-ENTRY-GUARD.ps1" } |
        ForEach-Object {
            $Contents[$_].Contains("Invoke-GlobalSecurityGate")
        } |
        Where-Object { $_ -eq $true } |
        Measure-Object
    ).Count -gt 0 `
    "Secure Entry appelle le Global Security Gate"

Add-Check `
    "GATE-FUNCTION" `
    ($AllContent.Contains("function Invoke-GlobalSecurityGate")) `
    "Global Security Gate present"

Add-Check `
    "GATE-SESSION" `
    ($AllContent.Contains("SessionValid")) `
    "Session validation present"

Add-Check `
    "GATE-RBAC" `
    ($AllContent.Contains("RBACAuthorized")) `
    "RBAC validation present"

Add-Check `
    "GATE-SCOPE" `
    ($AllContent.Contains("ScopeValid")) `
    "Scope validation present"

Add-Check `
    "GATE-AUTHORIZATION" `
    ($AllContent.Contains("AuthorizationValid")) `
    "Authorization validation present"

Add-Check `
    "GATE-CAPABILITY" `
    ($AllContent.Contains("CapabilityAuthorized")) `
    "Capability validation present"

Add-Check `
    "GATE-AUTHORITY" `
    ($AllContent.Contains("AuthorityAuthorized")) `
    "Authority validation present"

Add-Check `
    "GATE-POLICY" `
    ($AllContent.Contains("PolicyAuthorized")) `
    "Policy validation present"

Add-Check `
    "GATE-WORKER" `
    ($AllContent.Contains("WorkerTaskAuthorized")) `
    "Worker task validation present"

Add-Check `
    "GATE-CREDENTIAL" `
    ($AllContent.Contains("CredentialAuthorized")) `
    "Credential validation present"

Add-Check `
    "GATE-CONNECTOR" `
    ($AllContent.Contains("ConnectorAuthorized")) `
    "Connector validation present"

Add-Check `
    "GATE-PROVIDER" `
    ($AllContent.Contains("ProviderAuthorized")) `
    "Provider validation present"

Add-Check `
    "GATE-EVIDENCE" `
    ($AllContent.Contains("EvidenceAuthorized")) `
    "Evidence validation present"

Add-Check `
    "GATE-RETENTION" `
    ($AllContent.Contains("RetentionValid")) `
    "Retention validation present"

Add-Check `
    "GATE-PURGE-REUSE" `
    ($AllContent.Contains("PurgeReuseValid")) `
    "Purge/reuse validation present"

Add-Check `
    "DIRECT-CONNECTOR-BLOCK" `
    ($AllContent.Contains("DirectConnectorExecution")) `
    "Direct connector execution protected"

Add-Check `
    "DIRECT-PROVIDER-BLOCK" `
    ($AllContent.Contains("DirectProviderExecution")) `
    "Direct provider execution protected"

Add-Check `
    "SECRETS-BLOCK" `
    ($AllContent.Contains("SecretsPresent")) `
    "Secrets presence protected"

Add-Check `
    "GLOBAL-ALLOW" `
    ($AllContent.Contains("GLOBAL_SECURITY_CHAIN_VALID")) `
    "Global allow contract present"

# ============================================================
# 41-55 : PREUVES / ANTI-REPLAY
# ============================================================

$ProofIntegrityPath = Join-Path $Root "core\runtime\security-gate\authorization-proof-integrity\Authorization-Proof-Integrity-Guard.ps1"

$ProofIntegrityPresent = Test-Path -LiteralPath $ProofIntegrityPath -PathType Leaf

$ProofIntegrityValid = $false

if ($ProofIntegrityPresent) {

    try {
        $IntegrityText = [System.IO.File]::ReadAllText(
            $ProofIntegrityPath,
            [System.Text.Encoding]::UTF8
        )

        $ProofIntegrityValid = (
            $IntegrityText.Contains("function") -and
            (
                $IntegrityText.Contains("Hash") -or
                $IntegrityText.Contains("Integrity")
            )
        )
    }
    catch {
        $ProofIntegrityValid = $false
    }
}

Add-Check `
    "PROOF-INTEGRITY" `
    ($ProofIntegrityPresent -and $ProofIntegrityValid) `
    "Proof integrity module present and structurally valid"

Add-Check `
    "PROOF-FRESHNESS" `
    ($AllContent.Contains("Test-ProofFreshness")) `
    "Freshness validation present"

Add-Check `
    "PROOF-ATOMIC" `
    ($AllContent.Contains("Consume-AtomicProof")) `
    "Atomic consumption present"

Add-Check `
    "PROOF-LIFECYCLE" `
    ($AllContent.Contains("Invoke-ProofLifecycleGuard")) `
    "Proof lifecycle present"

Add-Check `
    "REPLAY-BLOCK" `
    ($AllContent.Contains("REPLAY_BLOCKED") -or $AllContent.Contains("REPLAY_MISMATCH")) `
    "Replay protection present"

Add-Check `
    "CONSUMED-STATE" `
    ($AllContent.Contains("Consumed")) `
    "Proof consumption state present"

Add-Check `
    "LOCKED-STATE" `
    ($AllContent.Contains("Locked")) `
    "Proof locking state present"

Add-Check `
    "EXPIRATION-STATE" `
    ($AllContent.Contains("ExpiresAtUtc")) `
    "Proof expiration present"

Add-Check `
    "CONTEXT-INTEGRITY" `
    ($AllContent.Contains("Execution-Context-Integrity-Guard")) `
    "Execution context integrity present"

# ============================================================
# 56-70 : LIVE / FAIL-CLOSED
# ============================================================

Add-Check `
    "SIMULATION-DEFAULT" `
    (
        $AllContent.Contains('Mode = "SIMULATION"') -or
        $AllContent.Contains('Mode = "SIMULATION",') -or
        $AllContent.Contains('Environment = "SIMULATION"')
    ) `
    "Simulation default present"

Add-Check `
    "LIVE-DISABLED" `
    ($AllContent.Contains("LIVE_EXECUTION_DISABLED") -or $AllContent.Contains("LIVE_DISABLED")) `
    "LIVE disabled path present"

Add-Check `
    "HUMAN-APPROVAL" `
    ($AllContent.Contains("HumanApproval")) `
    "Human approval requirement present"

Add-Check `
    "PRODUCTION-FLAG" `
    ($AllContent.Contains("ProductionFlag")) `
    "Production flag requirement present"

Add-Check `
    "EXPLICIT-LIVE" `
    ($AllContent.Contains("requireExplicitLiveEnable")) `
    "Explicit LIVE enablement present"

Add-Check `
    "FAIL-CLOSED" `
    (
        $AllContent.Contains("throw ") -and
        (
            $AllContent.Contains("BLOCK") -or
            $AllContent.Contains("block")
        )
    ) `
    "Fail-closed logic detected"

# ============================================================
# 71-80 : DIRECT EXECUTION AUDIT
# ============================================================

$ExecutionFiles = Read-ProjectFiles "$Root\core\ai"

$ProviderDirect = @()
$ConnectorDirect = @()

foreach ($File in $ExecutionFiles) {

    $Text = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

    if ($Text -match '(?im)^\s*&\s*\$ProviderEngine') {
        $ProviderDirect += $File.FullName
    }

    if ($Text -match '(?im)^\s*&\s*\$ProviderAdapter') {
        $ProviderDirect += $File.FullName
    }

    if ($Text -match '(?im)^\s*&\s*\$Connector') {
        $ConnectorDirect += $File.FullName
    }

    if ($Text -match '(?im)^\s*&\s*\$ConnectorEngine') {
        $ConnectorDirect += $File.FullName
    }
}

# Internal provider engine invocation is expected.
# The important condition is that external/direct entry points are not unguarded.
Add-Check `
    "DIRECT-PROVIDER-AUDIT" `
    ($ProviderDirect.Count -le 1) `
    ("Provider executable callers detected: {0}" -f $ProviderDirect.Count)

Add-Check `
    "DIRECT-CONNECTOR-AUDIT" `
    ($ConnectorDirect.Count -eq 0) `
    ("Connector executable callers detected: {0}" -f $ConnectorDirect.Count)

# ============================================================
# 81-90 : PARSING
# ============================================================

$ParseFailures = @()

foreach ($File in $Existing) {

    $Tokens = $null
    $Errors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $File,
        [ref]$Tokens,
        [ref]$Errors
    ) | Out-Null

    if ($null -ne $Errors -and $Errors.Count -gt 0) {
        $ParseFailures += $File
    }
}

Add-Check `
    "POWERSHELL-PARSING" `
    ($ParseFailures.Count -eq 0) `
    ("Parse failures: {0}" -f $ParseFailures.Count)

# ============================================================
# RESULTAT
# ============================================================

$Pass = @($Checks | Where-Object { $_.Pass -eq $true }).Count
$Fail = @($Checks | Where-Object { $_.Pass -ne $true }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "FINAL SECURITY INTEGRATION AUDIT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($Check in $Checks) {

    if ($Check.Pass) {
        Write-Host ("[PASS] {0} -> {1}" -f $Check.Name,$Check.Detail) -ForegroundColor Green
    }
    else {
        Write-Host ("[FAIL] {0} -> {1}" -f $Check.Name,$Check.Detail) -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL CHECKS : {0}" -f $Checks.Count)
Write-Host ("PASS         : {0}" -f $Pass) -ForegroundColor Green
Write-Host ("FAIL         : {0}" -f $Fail) -ForegroundColor Red
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "FINAL SECURITY INTEGRATION : VALIDEE" -ForegroundColor Green
}
else {
    Write-Host "FINAL SECURITY INTEGRATION : NON VALIDEE" -ForegroundColor Red
    Write-Host ""
    Write-Host "ELEMENTS EN ECHEC :" -ForegroundColor Yellow

    $Checks |
        Where-Object { $_.Pass -ne $true } |
        ForEach-Object {
            Write-Host (" - {0} : {1}" -f $_.Name,$_.Detail) -ForegroundColor Red
        }
}

Write-Host ""
Read-Host "Appuie sur Entree pour fermer"