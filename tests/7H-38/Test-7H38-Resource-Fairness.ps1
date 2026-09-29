$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\resource-fairness\RESOURCE-FAIRNESS-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\resource-fairness\state\fairness-state.json"

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

Reset-FairnessState | Out-Null

# 1
$config = Get-ResourceFairnessConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Resource Fairness valide"

# 2
Assert-Pass (
    $config.fairnessEnabled -eq $true -and
    $config.tenantIsolationEnabled -eq $true
) "fairness et isolation tenant actives"

# 3
Assert-Pass (
    $config.defaultWeight -eq 1 -and
    $config.minWeight -eq 1 -and
    $config.maxWeight -eq 100
) "poids fairness correctement configures"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$keyA = New-FairnessKey `
    -Scope tenant `
    -TenantId "tenant-A"

Assert-Pass (
    $keyA -like "tenant:*"
) "cle tenant correctement generee"

# 6
$keyB = New-FairnessKey `
    -Scope tenant `
    -TenantId "tenant-B"

Assert-Pass (
    $keyA -ne $keyB
) "isolation tenant correctement appliquee"

# 7
$defaultWeight = Get-FairnessWeight -Key $keyA

Assert-Pass (
    $defaultWeight -eq 1
) "poids par defaut correctement applique"

# 8
$newWeight = Set-FairnessWeight `
    -Key $keyA `
    -Weight 5

Assert-Pass (
    $newWeight -eq 5 -and
    (Get-FairnessWeight -Key $keyA) -eq 5
) "poids personnalise correctement enregistre"

# 9
$decision = Test-FairnessAdmission `
    -Key $keyA `
    -RequestedUnits 1 `
    -CurrentGlobalUsage 0

Assert-Pass (
    $decision.Allowed -eq $true -and
    $decision.Weight -eq 5
) "admission fairness correctement autorisee"

# 10
$grant = Grant-FairnessUsage `
    -Key $keyA `
    -Units 3

Assert-Pass (
    $grant.Granted -eq $true -and
    $grant.Usage -eq 3 -and
    $grant.Grants -eq 1
) "usage fairness correctement enregistree"

# 11
$entry = Get-FairnessEntry -Key $keyA

Assert-Pass (
    $entry.Usage -eq 3 -and
    $entry.Weight -eq 5
) "etat fairness correctement relu"

# 12
$denialsBefore = (Get-FairnessEntry -Key $keyA).Denials

$denial = Register-FairnessDenial -Key $keyA

Assert-Pass (
    $denial -eq ($denialsBefore + 1)
) "denial fairness correctement comptabilise"

# 13
$release = Release-FairnessUsage `
    -Key $keyA `
    -Units 2

Assert-Pass (
    $release -eq 1
) "liberation usage correctement appliquee"

# 14
$releasedAll = Release-FairnessUsage `
    -Key $keyA `
    -Units 50

Assert-Pass (
    $releasedAll -eq 0
) "usage ne devient jamais negatif"

# 15
$badWeight = $false

try {
    Set-FairnessWeight `
        -Key $keyA `
        -Weight 0 | Out-Null
}
catch {
    $badWeight = $true
}

Assert-Pass $badWeight `
    "poids hors plage correctement bloque"

# 16
$badUnits = $false

try {
    Grant-FairnessUsage `
        -Key $keyA `
        -Units 0 | Out-Null
}
catch {
    $badUnits = $true
}

Assert-Pass $badUnits `
    "usage invalide correctement bloque"

# 17
$badTenant = $false

try {
    New-FairnessKey `
        -Scope tenant `
        -TenantId "" | Out-Null
}
catch {
    $badTenant = $true
}

Assert-Pass $badTenant `
    "contexte tenant incomplet correctement bloque"

# 18
$clientA = New-FairnessKey `
    -Scope client `
    -ClientId "client-A"

$clientB = New-FairnessKey `
    -Scope client `
    -ClientId "client-B"

Assert-Pass (
    $clientA -ne $clientB
) "isolation client correctement appliquee"

# 19
$projectA = New-FairnessKey `
    -Scope project `
    -ProjectId "project-A"

Assert-Pass (
    $projectA -like "project:*"
) "cle project correctement generee"

# 20
$workerA = New-FairnessKey `
    -Scope worker `
    -WorkerId "worker-A"

Assert-Pass (
    $workerA -like "worker:*"
) "cle worker correctement generee"

# 21
$report = @(Get-FairnessReport)

Assert-Pass (
    $report.Count -ge 1
) "rapport fairness correctement genere"

# 22
$raw = ""

if (Test-Path -LiteralPath $StatePath) {

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat fairness sans secret"

# 23
Reset-FairnessState | Out-Null

Assert-Pass (
    (Get-FairnessReport).Count -eq 0
) "reset Resource Fairness correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-38" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Resource Fairness & Tenant Isolation Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"