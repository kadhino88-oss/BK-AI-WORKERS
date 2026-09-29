$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Gateway = Join-Path $Root "core\ai\AI-GATEWAY.ps1"
$SecureEntry = Join-Path $Root "core\ai\AI-SECURE-ENTRY-GUARD.ps1"
$Gate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "GATEWAY / PROVIDER WORKER TEST" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($Path in @($Gateway,$SecureEntry,$Gate)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "REQUIRED_FILE_MISSING:$Path"
    }
}

$GatewayText = Get-Content -LiteralPath $Gateway -Raw -Encoding UTF8
$SecureText = Get-Content -LiteralPath $SecureEntry -Raw -Encoding UTF8
$GateText = Get-Content -LiteralPath $Gate -Raw -Encoding UTF8

$Checks = @(
    [pscustomobject]@{
        Name = "Gateway appelle Global Security Gate"
        Pass = ($GatewayText -match "Invoke-GlobalSecurityGate")
    },
    [pscustomobject]@{
        Name = "Gateway exige SessionValid"
        Pass = ($GatewayText -match "SESSION_PROOF_REQUIRED")
    },
    [pscustomobject]@{
        Name = "Gateway bloque Provider direct"
        Pass = ($GatewayText -match "DIRECT_PROVIDER_EXECUTION_FORBIDDEN")
    },
    [pscustomobject]@{
        Name = "Secure Entry appelle Global Security Gate"
        Pass = ($SecureText -match "Invoke-GlobalSecurityGate")
    },
    [pscustomobject]@{
        Name = "Gate contient Provider authorization"
        Pass = ($GateText -match "ProviderAuthorized")
    }
)

$Pass = 0
$Fail = 0
$Index = 0

foreach ($Check in $Checks) {

    $Index++

    if ($Check.Pass) {
        Write-Host ("[{0:00}] [PASS] {1}" -f $Index,$Check.Name) -ForegroundColor Green
        $Pass++
    }
    else {
        Write-Host ("[{0:00}] [FAIL] {1}" -f $Index,$Check.Name) -ForegroundColor Red
        $Fail++
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT GATEWAY / PROVIDER WORKER TEST" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL : {0}" -f $Index)
Write-Host ("PASS  : {0}" -f $Pass) -ForegroundColor Green
Write-Host ("FAIL  : {0}" -f $Fail) -ForegroundColor Red
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"