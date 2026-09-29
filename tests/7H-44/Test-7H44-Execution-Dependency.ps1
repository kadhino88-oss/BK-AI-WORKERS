$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-dependency\EXECUTION-DEPENDENCY-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-dependency\state\dependencies.json"

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

Reset-DependencyState | Out-Null

# 1
$config = Get-DependencyConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Dependency Manager valide"

# 2
Assert-Pass (
    $config.dependencyManagerEnabled -eq $true -and
    $config.prerequisiteChecksEnabled -eq $true -and
    $config.cycleDetectionEnabled -eq $true
) "dependency manager et guards actifs"

# 3
Assert-Pass (
    $config.strictMode -eq $true -and
    $config.requireTenantIsolation -eq $true
) "mode strict et isolation tenant actifs"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$execA = New-DependencyExecution `
    -ExecutionId "exec-A" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A"

Assert-Pass (
    $execA.ExecutionId -eq "exec-A" -and
    $execA.Status -eq "WAITING"
) "execution A correctement creee"

# 6
$execB = New-DependencyExecution `
    -ExecutionId "exec-B" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-B"

Assert-Pass (
    $execB.ExecutionId -eq "exec-B"
) "execution B correctement creee"

# 7
$execC = New-DependencyExecution `
    -ExecutionId "exec-C" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-C"

Assert-Pass (
    $execC.ExecutionId -eq "exec-C"
) "execution C correctement creee"

# 8
Save-DependencyExecution -Execution $execA | Out-Null
Save-DependencyExecution -Execution $execB | Out-Null
Save-DependencyExecution -Execution $execC | Out-Null

Assert-Pass (
    $null -ne (
        Get-DependencyExecution `
            -ExecutionId "exec-A" `
            -TenantId "tenant-A"
    )
) "executions correctement persistees"

# 9
$addAB = Add-ExecutionDependency `
    -ExecutionId "exec-B" `
    -TenantId "tenant-A" `
    -DependencyId "exec-A"

Assert-Pass (
    $addAB.Added -eq $true
) "dependance B vers A correctement ajoutee"

# 10
$depsB = @(
    Get-ExecutionDependencies `
        -ExecutionId "exec-B" `
        -TenantId "tenant-A"
)

Assert-Pass (
    $depsB.Count -eq 1 -and
    $depsB[0] -eq "exec-A"
) "dependance B correctement relue"

# 11
$readyB1 = Test-ExecutionReady `
    -ExecutionId "exec-B" `
    -TenantId "tenant-A"

Assert-Pass (
    $readyB1 -eq $false
) "B correctement bloquee tant que A n'est pas terminee"

# 12
Set-DependencyExecutionStatus `
    -ExecutionId "exec-A" `
    -TenantId "tenant-A" `
    -Status "COMPLETED" | Out-Null

$readyB2 = Test-ExecutionReady `
    -ExecutionId "exec-B" `
    -TenantId "tenant-A"

Assert-Pass (
    $readyB2 -eq $true
) "B devient prete apres completion de A"

# 13
Set-DependencyExecutionStatus `
    -ExecutionId "exec-B" `
    -TenantId "tenant-A" `
    -Status "COMPLETED" | Out-Null

$addBC = Add-ExecutionDependency `
    -ExecutionId "exec-C" `
    -TenantId "tenant-A" `
    -DependencyId "exec-B"

Assert-Pass (
    $addBC.Added -eq $true
) "dependance C vers B correctement ajoutee"

# 14
$readyC1 = Test-ExecutionReady `
    -ExecutionId "exec-C" `
    -TenantId "tenant-A"

Assert-Pass (
    $readyC1 -eq $true
) "C prete apres completion de B"

# 15
$duplicate = Add-ExecutionDependency `
    -ExecutionId "exec-C" `
    -TenantId "tenant-A" `
    -DependencyId "exec-B"

Assert-Pass (
    $duplicate.Added -eq $false
) "dependance duplicate correctement bloquee"

# 16
$selfDependency = Add-ExecutionDependency `
    -ExecutionId "exec-A" `
    -TenantId "tenant-A" `
    -DependencyId "exec-A"

Assert-Pass (
    $selfDependency.Added -eq $false
) "auto-dependance correctement bloquee"

# 17
$missingDependency = Add-ExecutionDependency `
    -ExecutionId "exec-C" `
    -TenantId "tenant-A" `
    -DependencyId "unknown"

Assert-Pass (
    $missingDependency.Added -eq $false
) "dependency inconnue correctement bloquee"

# 18
$execX = New-DependencyExecution `
    -ExecutionId "exec-X" `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-X"

Save-DependencyExecution -Execution $execX | Out-Null

$crossTenant = Add-ExecutionDependency `
    -ExecutionId "exec-C" `
    -TenantId "tenant-A" `
    -DependencyId "exec-X"

Assert-Pass (
    $crossTenant.Added -eq $false
) "dependance cross-tenant correctement bloquee"

# 19
$wrongTenantRead = Get-DependencyExecution `
    -ExecutionId "exec-X" `
    -TenantId "tenant-A"

Assert-Pass (
    $null -eq $wrongTenantRead
) "lecture cross-tenant correctement isolee"

# 20
$cycleCandidate = Add-ExecutionDependency `
    -ExecutionId "exec-A" `
    -TenantId "tenant-A" `
    -DependencyId "exec-B"

Assert-Pass (
    $cycleCandidate.Added -eq $false -and
    $cycleCandidate.Reason -match "Cycle"
) "cycle de dependance correctement detecte"

# 21
$failedExec = New-DependencyExecution `
    -ExecutionId "exec-F" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-F"

Save-DependencyExecution -Execution $failedExec | Out-Null

Set-DependencyExecutionStatus `
    -ExecutionId "exec-F" `
    -TenantId "tenant-A" `
    -Status "FAILED" | Out-Null

$failedReady = Test-ExecutionReady `
    -ExecutionId "exec-F" `
    -TenantId "tenant-A"

Assert-Pass (
    $failedReady -eq $false
) "execution FAILED correctement exclue de l'admission"

# 22
$badContext = $false

try {
    New-DependencyExecution `
        -ExecutionId "" `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" | Out-Null
}
catch {
    $badContext = $true
}

Assert-Pass $badContext `
    "execution id vide correctement bloquee"

# 23
$raw = ""

if (Test-Path -LiteralPath $StatePath) {

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat Dependency Manager sans secret"

# 24
Reset-DependencyState | Out-Null

Assert-Pass (
    $null -eq (
        Get-DependencyExecution `
            -ExecutionId "exec-A"
    )
) "reset Dependency Manager correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-44" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Dependency & Prerequisite Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"