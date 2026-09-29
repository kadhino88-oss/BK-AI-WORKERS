$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\health-diagnostics\HEALTH-DIAGNOSTICS-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\health-diagnostics\state\health-state.json"

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

Reset-HealthState | Out-Null

# 1
$config = Get-HealthDiagnosticsConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Health Diagnostics valide"

# 2
Assert-Pass (
    $config.healthChecksEnabled -eq $true -and
    $config.diagnosticsEnabled -eq $true
) "health checks et diagnostics actives"

# 3
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false
) "capture sensible desactivee"

# 4
Assert-Pass (
    $config.liveExecutionEnabled -eq $false
) "LIVE execution desactivee"

# 5
$result = New-HealthCheckResult `
    -Component "test-component" `
    -Status "HEALTHY" `
    -Message "ok" `
    -DurationMs 25

Assert-Pass (
    $result.CheckId -and
    $result.Component -eq "test-component" -and
    $result.Status -eq "HEALTHY" -and
    $result.DurationMs -eq 25
) "resultat de health check correctement genere"

# 6
$resultBool = Invoke-HealthCheck `
    -Component "boolean-test" `
    -Check { $true }

Assert-Pass (
    $resultBool.Status -eq "HEALTHY"
) "health check booléen positif correctement interprete"

# 7
$resultFalse = Invoke-HealthCheck `
    -Component "boolean-fail-test" `
    -Check { $false }

Assert-Pass (
    $resultFalse.Status -eq "UNHEALTHY"
) "health check booléen negatif correctement interprete"

# 8
$resultException = Invoke-HealthCheck `
    -Component "exception-test" `
    -Check {
        throw "controlled failure"
    }

Assert-Pass (
    $resultException.Status -eq "UNHEALTHY" -and
    $resultException.Message -match "controlled failure"
) "exception correctement convertie en diagnostic"

# 9
$pathCheck = Test-PathHealth `
    -Path $Runtime `
    -Component "runtime-file"

Assert-Pass (
    $pathCheck.Status -eq "HEALTHY"
) "controle du fichier runtime correctement execute"

# 10
$configCheck = Invoke-HealthCheck `
    -Component "configuration" `
    -Check {
        Test-ConfigurationHealth
    }

Assert-Pass (
    $configCheck.Status -eq "HEALTHY"
) "controle de configuration correctement execute"

# 11
$runtimeChecks = @(Test-RuntimeHealth)

Assert-Pass (
    $runtimeChecks.Count -ge 3 -and
    (@($runtimeChecks | Where-Object Status -eq "HEALTHY").Count -ge 3)
) "diagnostics runtime correctement executes"

# 12
$dependencyChecks = @(Test-DependencyHealth)

Assert-Pass (
    $dependencyChecks.Count -eq 3 -and
    (@($dependencyChecks | Where-Object Status -eq "HEALTHY").Count -eq 3)
) "diagnostics dependances correctement executes"

# 13
$systemHealth = Get-SystemHealth

Assert-Pass (
    $systemHealth.OverallStatus -eq "HEALTHY"
) "etat global du systeme correctement determine"

# 14
Assert-Pass (
    $systemHealth.Healthy -gt 0 -and
    $systemHealth.Unhealthy -eq 0
) "compteurs de sante correctement calcules"

# 15
Assert-Pass (
    Test-Path -LiteralPath $StatePath
) "etat de sante persiste"

# 16
$saved = Get-SavedHealthState

Assert-Pass (
    $null -ne $saved -and
    $saved.OverallStatus -eq "HEALTHY"
) "etat de sante persiste correctement relu"

# 17
$raw = Get-Content `
    -LiteralPath $StatePath `
    -Raw `
    -Encoding UTF8

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat de sante sans secret"

# 18
$invalidBlocked = $false

try {

    New-HealthCheckResult `
        -Component "invalid" `
        -Status "HEALTHY" `
        -Message "invalid" `
        -DurationMs (-1) | Out-Null
}
catch {
    $invalidBlocked = $true
}

Assert-Pass $invalidBlocked `
    "duree negative correctement bloquee"

# 19
$invalidComponent = $false

try {

    New-HealthCheckResult `
        -Component "" `
        -Status "HEALTHY" `
        -Message "invalid" `
        -DurationMs 1 | Out-Null
}
catch {
    $invalidComponent = $true
}

Assert-Pass $invalidComponent `
    "composant vide correctement bloque"

# 20
$invalidMessage = $false

try {

    New-HealthCheckResult `
        -Component "component" `
        -Status "HEALTHY" `
        -Message "" `
        -DurationMs 1 | Out-Null
}
catch {
    $invalidMessage = $true
}

Assert-Pass $invalidMessage `
    "message vide correctement bloque"

# 21
$customStatus = Invoke-HealthCheck `
    -Component "structured-test" `
    -Check {
        [pscustomobject]@{
            Status = "DEGRADED"
            Message = "controlled degraded state"
        }
    }

Assert-Pass (
    $customStatus.Status -eq "DEGRADED" -and
    $customStatus.Message -eq "controlled degraded state"
) "etat DEGRADED correctement interprete"

# 22
Reset-HealthState | Out-Null

Assert-Pass (
    -not (Test-Path -LiteralPath $StatePath)
) "reset Health Diagnostics correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-33" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Health Check & Runtime Diagnostics Manager operationnel." -ForegroundColor Green
    exit 0
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
    exit 1
}