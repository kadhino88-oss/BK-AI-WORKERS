$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Gateway = Join-Path $Root "core\ai\AI-GATEWAY.ps1"
$Provider = Join-Path $Root "core\ai\AI-PROVIDER-ENGINE.ps1"
$EntryGuard = Join-Path $Root "core\ai\AI-SECURE-ENTRY-GUARD.ps1"
$Gate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

$Tests = @()

function Add-Test {
    param(
        [string]$Name,
        [bool]$Pass,
        [string]$Detail
    )

    $script:Tests += [pscustomobject]@{
        Name = $Name
        Pass = $Pass
        Detail = $Detail
    }
}

Add-Test "01-GATE-PRESENT" `
    (Test-Path -LiteralPath $Gate -PathType Leaf) `
    "Gate présent"

Add-Test "02-ENTRY-GUARD-PRESENT" `
    (Test-Path -LiteralPath $EntryGuard -PathType Leaf) `
    "Entry Guard présent"

Add-Test "03-GATEWAY-PRESENT" `
    (Test-Path -LiteralPath $Gateway -PathType Leaf) `
    "Gateway présent"

Add-Test "04-PROVIDER-PRESENT" `
    (Test-Path -LiteralPath $Provider -PathType Leaf) `
    "Provider présent"

$GatewayText = Get-Content -LiteralPath $Gateway -Raw -Encoding UTF8
$ProviderText = Get-Content -LiteralPath $Provider -Raw -Encoding UTF8
$EntryText = Get-Content -LiteralPath $EntryGuard -Raw -Encoding UTF8

Add-Test "05-GATEWAY-USES-ENTRY-GUARD" `
    ($GatewayText -match "AI-SECURE-ENTRY-GUARD") `
    "Gateway doit charger Entry Guard"

Add-Test "06-GATEWAY-USES-SECURITY-AUTH" `
    ($GatewayText -match "Invoke-AISecureAuthorization") `
    "Gateway doit appeler l'autorisation sécurisée"

Add-Test "07-PROVIDER-USES-ENTRY-GUARD" `
    ($ProviderText -match "AI-SECURE-ENTRY-GUARD") `
    "Provider doit charger Entry Guard"

Add-Test "08-PROVIDER-USES-SECURITY-AUTH" `
    ($ProviderText -match "Invoke-AISecureAuthorization") `
    "Provider doit appeler l'autorisation sécurisée"

Add-Test "09-DIRECT-PROVIDER-BLOCK" `
    ($EntryText -match "DIRECT_PROVIDER_EXECUTION_FORBIDDEN") `
    "Blocage direct Provider"

Add-Test "10-DIRECT-CONNECTOR-BLOCK" `
    ($EntryText -match "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN") `
    "Blocage direct Connector"

Add-Test "11-SECRETS-BLOCK" `
    ($EntryText -match "SECRETS_FORBIDDEN") `
    "Blocage secrets"

Add-Test "12-FAIL-CLOSED" `
    ($EntryText -match "GLOBAL_SECURITY_GATE_BLOCKED") `
    "Blocage par défaut"

$DirectProviderOutsideEntry = @(
    Get-ChildItem `
        -LiteralPath (Join-Path $Root "core") `
        -Recurse `
        -File `
        -Filter "*.ps1" `
        -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notmatch "\\backups\\" -and
        $_.Name -notmatch "(?i)test" -and
        $_.FullName -ne $EntryGuard
    } |
    Select-String -Pattern '&\s*\$openaiAdapter|&\s*\$anthropicAdapter' `
        -SimpleMatch:$false `
        -ErrorAction SilentlyContinue
)

Add-Test "13-ADAPTER-CALLS-LIMITED" `
    ($DirectProviderOutsideEntry.Count -eq 0) `
    "Aucun appel adapter direct hors surface sécurisée"

Add-Test "14-ENTRYGUARD-LOADS-GATE" `
    ($EntryText -match "Global-Security-Enforcement-Gate") `
    "Entry Guard charge le Gate"

Add-Test "15-ENTRYGUARD-ASSERTS-ALLOW" `
    ($EntryText -match 'Decision -ne "ALLOW"') `
    "ALLOW obligatoire"

Add-Test "16-AUTHORIZED-REQUIRED" `
    ($EntryText -match 'Authorized -ne \$true') `
    "Authorized=true obligatoire"

$Passed = @($Tests | Where-Object Pass)
$Failed = @($Tests | Where-Object { -not $_.Pass })

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-49J — RESULTATS" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($t in $Tests) {
    if ($t.Pass) {
        Write-Host "[PASS] $($t.Name) — $($t.Detail)" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $($t.Name) — $($t.Detail)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "TOTAL TESTS : $($Tests.Count)" -ForegroundColor Yellow
Write-Host "PASS        : $($Passed.Count)" -ForegroundColor Green
Write-Host "FAIL        : $($Failed.Count)" -ForegroundColor Red
Write-Host ""

if ($Failed.Count -eq 0) {
    Write-Host "8A-49J : STRUCTURE SECURISEE" -ForegroundColor Green
}
else {
    Write-Host "8A-49J : NON VALIDEE" -ForegroundColor Red
}

Read-Host "Appuie sur Entree pour fermer"