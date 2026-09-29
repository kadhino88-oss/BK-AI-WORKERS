$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\circuit-breaker\CIRCUIT-BREAKER-RUNTIME.ps1"

. $Runtime

$pass = 0
$fail = 0

function Assert-Pass {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        Write-Host "PASS : $Message" -ForegroundColor Green
        $script:pass++
    }
    else {
        Write-Host "FAIL : $Message" -ForegroundColor Red
        $script:fail++
    }
}

Reset-CircuitState | Out-Null

# 1
$config = Get-CircuitBreakerConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Circuit Breaker valide"

# 2
Assert-Pass (
    $config.circuitBreakerEnabled -eq $true -and
    $config.failureThreshold -eq 3 -and
    $config.successThreshold -eq 2
) "seuils Circuit Breaker correctement configures"

# 3
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 4
$keyA = New-CircuitKey `
    -Scope tenant `
    -TenantId "tenant-A"

Assert-Pass (
    $keyA -like "tenant:*"
) "cle tenant correctement generee"

# 5
$keyB = New-CircuitKey `
    -Scope tenant `
    -TenantId "tenant-B"

Assert-Pass (
    $keyA -ne $keyB
) "isolation des cles correctement appliquee"

# 6
$initial = Get-CircuitState -Key $keyA

Assert-Pass (
    $initial.State -eq "CLOSED" -and
    $initial.FailureCount -eq 0
) "etat initial CLOSED correctement etabli"

# 7
$access1 = Test-CircuitAccess -Key $keyA

Assert-Pass (
    $access1.Allowed -eq $true -and
    $access1.State -eq "CLOSED"
) "acces autorise sur circuit ferme"

# 8
$failure1 = Register-CircuitFailure -Key $keyA

Assert-Pass (
    $failure1.State -eq "CLOSED" -and
    $failure1.FailureCount -eq 1
) "premier echec correctement enregistre"

# 9
$failure2 = Register-CircuitFailure -Key $keyA

Assert-Pass (
    $failure2.State -eq "CLOSED" -and
    $failure2.FailureCount -eq 2
) "deuxieme echec correctement enregistre"

# 10
$failure3 = Register-CircuitFailure -Key $keyA

Assert-Pass (
    $failure3.State -eq "OPEN" -and
    $failure3.Opened -eq $true
) "troisieme echec ouvre correctement le circuit"

# 11
$blocked = Test-CircuitAccess -Key $keyA

Assert-Pass (
    $blocked.Allowed -eq $false -and
    $blocked.State -eq "OPEN"
) "acces bloque lorsque circuit ouvert"

# 12
$otherAccess = Test-CircuitAccess -Key $keyB

Assert-Pass (
    $otherAccess.Allowed -eq $true -and
    $otherAccess.State -eq "CLOSED"
) "autre tenant non impacte"

# 13
$config.cooldownSeconds = 0

$config |
    ConvertTo-Json -Depth 10 |
    Set-Content `
        -LiteralPath "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\circuit-breaker\CIRCUIT-BREAKER-CONFIG.json" `
        -Encoding UTF8

$halfOpen = Test-CircuitAccess -Key $keyA

Assert-Pass (
    $halfOpen.Allowed -eq $true -and
    $halfOpen.State -eq "HALF_OPEN"
) "passage HALF_OPEN apres cooldown"

# 14
$success1 = Register-CircuitSuccess -Key $keyA

Assert-Pass (
    $success1.State -eq "HALF_OPEN" -and
    $success1.SuccessCount -eq 1
) "premier succes HALF_OPEN correctement enregistre"

# 15
$success2 = Register-CircuitSuccess -Key $keyA

Assert-Pass (
    $success2.State -eq "CLOSED" -and
    $success2.Recovered -eq $true
) "recuperation complete et fermeture du circuit"

# 16
$recovered = Test-CircuitAccess -Key $keyA

Assert-Pass (
    $recovered.Allowed -eq $true -and
    $recovered.State -eq "CLOSED"
) "acces restaure apres recuperation"

# 17
$workerKey = New-CircuitKey `
    -Scope worker `
    -WorkerId "worker-A"

$workerFailure = Register-CircuitFailure `
    -Key $workerKey

Assert-Pass (
    $workerFailure.FailureCount -eq 1 -and
    $workerFailure.State -eq "CLOSED"
) "circuit worker correctement gere"

# 18
$badKey = $false

try {
    New-CircuitKey `
        -Scope project `
        -ProjectId "" | Out-Null
}
catch {
    $badKey = $true
}

Assert-Pass $badKey `
    "contexte incomplet correctement bloque"

# 19
$badFailure = $false

try {
    Set-CircuitState `
        -Key $keyA `
        -State "CLOSED" `
        -FailureCount (-1) | Out-Null
}
catch {
    $badFailure = $true
}

Assert-Pass $badFailure `
    "compteur negatif correctement bloque"

# 20
$rawState = ""

$statePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\circuit-breaker\state\circuit-state.json"

if (Test-Path -LiteralPath $statePath) {
    $rawState = Get-Content `
        -LiteralPath $statePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $rawState -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat Circuit Breaker sans secret"

# 21
$tenantIsolated = New-CircuitKey `
    -Scope client `
    -ClientId "client-A"

$tenantOther = New-CircuitKey `
    -Scope client `
    -ClientId "client-B"

Assert-Pass (
    $tenantIsolated -ne $tenantOther
) "isolation client correctement appliquee"

# 22
Reset-CircuitState | Out-Null

$resetState = Get-CircuitState -Key $keyA

Assert-Pass (
    $resetState.State -eq "CLOSED" -and
    $resetState.FailureCount -eq 0
) "reset Circuit Breaker correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-35" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Circuit Breaker & Failure Protection Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"