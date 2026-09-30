$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Gateway = Join-Path $Root "core\ai\AI-GATEWAY.ps1"
$Provider = Join-Path $Root "core\ai\AI-PROVIDER-ENGINE.ps1"
$SecureEntry = Join-Path $Root "core\ai\AI-SECURE-ENTRY-GUARD.ps1"
$GlobalGate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"
$SecureExecution = Join-Path $Root "core\runtime\security-gate\Invoke-Secure-Execution.ps1"

$script:Index = 0
$script:Pass = 0
$script:Fail = 0

function Check {
    param(
        [string]$Name,
        [bool]$Condition
    )

    $script:Index++

    if ($Condition) {
        Write-Host ("[{0:00}] [PASS] {1}" -f $script:Index,$Name) -ForegroundColor Green
        $script:Pass++
    }
    else {
        Write-Host ("[{0:00}] [FAIL] {1}" -f $script:Index,$Name) -ForegroundColor Red
        $script:Fail++
    }
}

function Is-ExcludedPath {
    param(
        [string]$Path
    )

    $normalized = $Path.Replace('/','\')

    if ($normalized -match '\\backups\\') {
        return $true
    }

    if ($normalized -match '\\backup\\') {
        return $true
    }

    if ($normalized -match '\\archive\\') {
        return $true
    }

    if ($normalized -match '\\diagnostics\\') {
        return $true
    }

    if ($normalized -match '\\checks\\') {
        return $true
    }

    $leaf = Split-Path -Leaf $normalized

    if ($leaf -match '^test-') {
        return $true
    }

    if ($leaf -match 'WORKER-TEST') {
        return $true
    }

    return $false
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-50A - EXECUTION PATH INTEGRITY AUDIT" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 01-15 — COMPONENTS + SECURE ENTRY
# ============================================================

Check "AI-GATEWAY present" (
    Test-Path -LiteralPath $Gateway -PathType Leaf
)

Check "AI-PROVIDER-ENGINE present" (
    Test-Path -LiteralPath $Provider -PathType Leaf
)

Check "AI-SECURE-ENTRY-GUARD present" (
    Test-Path -LiteralPath $SecureEntry -PathType Leaf
)

Check "Global Security Gate present" (
    Test-Path -LiteralPath $GlobalGate -PathType Leaf
)

Check "Secure Execution present" (
    Test-Path -LiteralPath $SecureExecution -PathType Leaf
)

$GatewayText = Get-Content -LiteralPath $Gateway -Raw -Encoding UTF8
$ProviderText = Get-Content -LiteralPath $Provider -Raw -Encoding UTF8
$SecureText = Get-Content -LiteralPath $SecureEntry -Raw -Encoding UTF8
$GateText = Get-Content -LiteralPath $GlobalGate -Raw -Encoding UTF8
$SecureExecutionText = Get-Content -LiteralPath $SecureExecution -Raw -Encoding UTF8

Check "Gateway appelle Global Security Gate" (
    $GatewayText -match "Invoke-GlobalSecurityGate"
)

Check "Provider appelle Global Security Gate" (
    $ProviderText -match "Invoke-GlobalSecurityGate"
)

Check "Secure Entry appelle Global Security Gate" (
    $SecureText -match "Invoke-GlobalSecurityGate"
)

Check "Secure Execution référence Global Security Gate" (
    $SecureExecutionText -match "Global-Security-Enforcement-Gate"
)

Check "Gateway exige SessionValid" (
    $GatewayText -match "SESSION_PROOF_REQUIRED"
)

Check "Provider exige SessionValid" (
    $ProviderText -match "SESSION_PROOF_REQUIRED"
)

Check "Gateway bloque Provider direct" (
    $GatewayText -match "DIRECT_PROVIDER_EXECUTION_FORBIDDEN"
)

Check "Provider bloque Provider direct" (
    $ProviderText -match "DIRECT_PROVIDER_EXECUTION_FORBIDDEN"
)

Check "Secrets bloqués côté Gateway/Provider" (
    ($GatewayText -match "SECRETS_FORBIDDEN") -and
    ($ProviderText -match "SECRETS_FORBIDDEN")
)

# ============================================================
# 16 — CONTEXTE SECURISE
# ============================================================

Check "Secure Entry exige le contexte Tenant/Client/Project/Execution/User" (
    ($SecureText -match "TenantId") -and
    ($SecureText -match "ClientId") -and
    ($SecureText -match "ProjectId") -and
    ($SecureText -match "ExecutionId") -and
    ($SecureText -match "UserId")
)

# ============================================================
# 17 — APPELS DIRECTS REELS
# ============================================================

$SearchRoots = @(
    (Join-Path $Root "orchestrator"),
    (Join-Path $Root "core\runtime"),
    (Join-Path $Root "core\ai")
)

$DirectExecutionHits = @()

foreach ($SearchRoot in $SearchRoots) {

    if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        continue
    }

    $Files = Get-ChildItem `
        -LiteralPath $SearchRoot `
        -Recurse `
        -File `
        -Filter "*.ps1" `
        -ErrorAction SilentlyContinue

    foreach ($File in $Files) {

        # EXCLUSION AVANT LECTURE DU FICHIER
        if (Is-ExcludedPath $File.FullName) {
            continue
        }

        $Lines = Get-Content -LiteralPath $File.FullName -Encoding UTF8

        for ($i = 0; $i -lt $Lines.Count; $i++) {

            $Line = $Lines[$i].Trim()

            if ([string]::IsNullOrWhiteSpace($Line)) {
                continue
            }

            if ($Line -match '^\s*#') {
                continue
            }

            # Références de chemins et opérations de lecture :
            # ce ne sont PAS des appels d'exécution.
            if (
                ($Line -match 'Join-Path') -or
                ($Line -match 'Test-Path') -or
                ($Line -match 'Get-Content') -or
                ($Line -match 'Set-Content') -or
                ($Line -match 'Copy-Item') -or
                ($Line -match 'Out-File') -or
                ($Line -match 'Path\s*=')
            ) {
                continue
            }

            $IsProviderExecution = (
                ($Line -match '^\s*&\s+.*Provider') -or
                ($Line -match '^\s*\.\s+.*Provider') -or
                ($Line -match '^\s*Start-Process\s+.*Provider') -or
                ($Line -match '^\s*Invoke-Expression\s+.*Provider')
            )

            $IsGatewayExecution = (
                ($Line -match '^\s*&\s+.*AI-GATEWAY') -or
                ($Line -match '^\s*\.\s+.*AI-GATEWAY') -or
                ($Line -match '^\s*Start-Process\s+.*AI-GATEWAY') -or
                ($Line -match '^\s*Invoke-Expression\s+.*AI-GATEWAY')
            )

            $IsConnectorExecution = (
                ($Line -match '^\s*&\s+.*CONNECTOR-EXECUTION-GATEWAY') -or
                ($Line -match '^\s*\.\s+.*CONNECTOR-EXECUTION-GATEWAY') -or
                ($Line -match '^\s*Start-Process\s+.*CONNECTOR-EXECUTION-GATEWAY') -or
                ($Line -match '^\s*Invoke-Expression\s+.*CONNECTOR-EXECUTION-GATEWAY')
            )

            if ($IsProviderExecution -or $IsGatewayExecution -or $IsConnectorExecution) {

                $AllowedInternal =
                    ($File.FullName -eq $Gateway) -or
                    ($File.FullName -eq $Provider) -or
                    ($File.FullName -eq $SecureEntry) -or
                    ($File.FullName -eq $SecureExecution)

                if (-not $AllowedInternal) {

                    $DirectExecutionHits += [pscustomobject]@{
                        File = $File.FullName
                        Line = $i + 1
                        Code = $Line
                    }
                }
            }
        }
    }
}

$DirectExecutionHits = @(
    $DirectExecutionHits |
    Sort-Object File,Line,Code -Unique
)

Check "Aucun appel direct Provider/Gateway/Connector hors portes sécurisées" (
    $DirectExecutionHits.Count -eq 0
)

if ($DirectExecutionHits.Count -gt 0) {

    Write-Host ""
    Write-Host "APPELS D'EXECUTION DIRECTS DETECTES :" -ForegroundColor Red

    foreach ($Hit in $DirectExecutionHits) {
        Write-Host ""
        Write-Host $Hit.File -ForegroundColor Yellow
        Write-Host ("L{0}: {1}" -f $Hit.Line,$Hit.Code) -ForegroundColor Red
    }
}

# ============================================================
# 18 — ORCHESTRATOR / RUNTIME
# ============================================================

$BypassHits = @()

foreach ($SearchRoot in @(
    (Join-Path $Root "orchestrator"),
    (Join-Path $Root "core\runtime")
)) {

    if (-not (Test-Path -LiteralPath $SearchRoot -PathType Container)) {
        continue
    }

    $Files = Get-ChildItem `
        -LiteralPath $SearchRoot `
        -Recurse `
        -File `
        -Filter "*.ps1" `
        -ErrorAction SilentlyContinue

    foreach ($File in $Files) {

        if (Is-ExcludedPath $File.FullName) {
            continue
        }

        if (
            ($File.FullName -eq $Gateway) -or
            ($File.FullName -eq $Provider) -or
            ($File.FullName -eq $SecureEntry) -or
            ($File.FullName -eq $SecureExecution)
        ) {
            continue
        }

        $Text = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if (
            ($Text -match '^\s*&\s+.*AI-PROVIDER-ENGINE') -or
            ($Text -match '^\s*\.\s+.*AI-PROVIDER-ENGINE') -or
            ($Text -match '^\s*&\s+.*AI-GATEWAY') -or
            ($Text -match '^\s*\.\s+.*AI-GATEWAY')
        ) {
            $BypassHits += $File.FullName
        }
    }
}

$BypassHits = @(
    $BypassHits |
    Sort-Object -Unique
)

Check "Orchestrator/Runtime sans appel direct moteur AI" (
    $BypassHits.Count -eq 0
)

if ($BypassHits.Count -gt 0) {

    Write-Host ""
    Write-Host "BYPASS ORCHESTRATOR/RUNTIME :" -ForegroundColor Red

    foreach ($Hit in $BypassHits) {
        Write-Host $Hit -ForegroundColor Red
    }
}

# ============================================================
# 19-30 — GLOBAL SECURITY CHAIN
# ============================================================

Check "Gate contient SESSION" ($GateText -match "SessionValid")
Check "Gate contient RBAC" ($GateText -match "RBACAuthorized")
Check "Gate contient SCOPE" ($GateText -match "ScopeValid")
Check "Gate contient AUTHORIZATION" ($GateText -match "AuthorizationValid")
Check "Gate contient CAPABILITY" ($GateText -match "CapabilityAuthorized")
Check "Gate contient AUTHORITY" ($GateText -match "AuthorityAuthorized")
Check "Gate contient POLICY" ($GateText -match "PolicyAuthorized")
Check "Gate contient WORKER_TASK" ($GateText -match "WorkerTaskAuthorized")
Check "Gate contient CREDENTIAL" ($GateText -match "CredentialAuthorized")
Check "Gate contient CONNECTOR" ($GateText -match "ConnectorAuthorized")
Check "Gate contient PROVIDER" ($GateText -match "ProviderAuthorized")
Check "Gate contient EVIDENCE" ($GateText -match "EvidenceAuthorized")
Check "Gate contient RETENTION" ($GateText -match "RetentionValid")
Check "Gate contient PURGE_REUSE" ($GateText -match "PurgeReuseValid")

# ============================================================
# 31-35 — FAIL CLOSED
# ============================================================

Check "Gateway refuse SessionValid=false par défaut" (
    $GatewayText -match '\$SessionValid\s*=\s*\$false'
)

Check "Provider refuse SessionValid=false par défaut" (
    $ProviderText -match '\$SessionValid\s*=\s*\$false'
)

Check "Gateway refuse DirectProviderExecution" (
    $GatewayText -match "DIRECT_PROVIDER_EXECUTION_FORBIDDEN"
)

Check "Provider refuse DirectConnectorExecution" (
    $ProviderText -match "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
)

Check "Gateway refuse DirectConnectorExecution" (
    $GatewayText -match "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
)

# ============================================================
# RESULTAT
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-50A" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL CHECKS : {0}" -f $script:Index)
Write-Host ("PASS         : {0}" -f $script:Pass) -ForegroundColor Green
Write-Host ("FAIL         : {0}" -f $script:Fail) -ForegroundColor Red
Write-Host ""

if (($script:Index -eq 36) -and ($script:Pass -eq 36) -and ($script:Fail -eq 0)) {
    Write-Host "8A-50A : VALIDEE - 36/36" -ForegroundColor Green
}
else {
    Write-Host "8A-50A : NON VALIDEE" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-50A - FIN" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"