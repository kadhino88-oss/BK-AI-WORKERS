$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\admission-control\ADMISSION-CONTROL-RUNTIME.ps1"

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

Reset-AdmissionState | Out-Null

# 1
$config = Get-AdmissionControlConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Admission Control valide"

# 2
Assert-Pass (
    $config.admissionControlEnabled -eq $true -and
    $config.backpressureEnabled -eq $true
) "admission control et backpressure actives"

# 3
Assert-Pass (
    $config.maxGlobalInFlight -eq 10 -and
    $config.maxTenantInFlight -eq 5 -and
    $config.maxClientInFlight -eq 3
) "capacites globales correctement configurees"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$keyTenantA = New-AdmissionKey `
    -Scope tenant `
    -TenantId "tenant-A"

Assert-Pass (
    $keyTenantA -like "tenant:*"
) "cle tenant correctement generee"

# 6
$keyTenantB = New-AdmissionKey `
    -Scope tenant `
    -TenantId "tenant-B"

Assert-Pass (
    $keyTenantA -ne $keyTenantB
) "isolation des cles tenant correctement appliquee"

# 7
$initialDecision = Test-Admission `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -ConnectorId "connector-A" `
    -ProviderId "provider-A" `
    -Priority 50

Assert-Pass (
    $initialDecision.Allowed -eq $true
) "admission initiale autorisee"

# 8
$entered = Enter-ExecutionAdmission `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -ConnectorId "connector-A" `
    -ProviderId "provider-A" `
    -Priority 50

Assert-Pass (
    $entered.Entered -eq $true -and
    $entered.Keys.Count -eq 7
) "execution correctement admise"

# 9
$globalCount = Get-AdmissionCount `
    -Key (New-AdmissionKey -Scope global)

Assert-Pass (
    $globalCount -eq 1
) "compteur global correctement incremente"

# 10
$tenantCount = Get-AdmissionCount `
    -Key $keyTenantA

Assert-Pass (
    $tenantCount -eq 1
) "compteur tenant correctement incremente"

# 11
$status = Get-AdmissionStatus `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -ConnectorId "connector-A" `
    -ProviderId "provider-A"

Assert-Pass (
    @($status).Count -eq 7
) "statut multi-scope correctement fourni"

# 12
$released = Leave-ExecutionAdmission `
    -Keys $entered.Keys

Assert-Pass (
    $released -eq $true
) "execution correctement liberee"

# 13
$globalAfterRelease = Get-AdmissionCount `
    -Key (New-AdmissionKey -Scope global)

Assert-Pass (
    $globalAfterRelease -eq 0
) "compteur global correctement decremente"

# 14
$blockKey = New-AdmissionKey `
    -Scope tenant `
    -TenantId "tenant-block"

for ($i = 0; $i -lt 5; $i++) {
    Enter-AdmissionSlot -Key $blockKey | Out-Null
}

$blocked = Test-Admission `
    -TenantId "tenant-block" `
    -ClientId "client-block" `
    -ProjectId "project-block" `
    -WorkerId "worker-block" `
    -ConnectorId "connector-block" `
    -ProviderId "provider-block" `
    -Priority 50

Assert-Pass (
    $blocked.Allowed -eq $false -and
    $blocked.Scope -eq "tenant"
) "surcharge tenant correctement bloquee"

# 15
$priorityDecision = Test-Admission `
    -TenantId "tenant-block" `
    -ClientId "client-block" `
    -ProjectId "project-block" `
    -WorkerId "worker-block" `
    -ConnectorId "connector-block" `
    -ProviderId "provider-block" `
    -Priority 95

Assert-Pass (
    $priorityDecision.Allowed -eq $true -and
    $priorityDecision.Bypassed -eq $true
) "priorite critique correctement autorisee"

# 16
$otherTenantDecision = Test-Admission `
    -TenantId "tenant-other" `
    -ClientId "client-other" `
    -ProjectId "project-other" `
    -WorkerId "worker-other" `
    -ConnectorId "connector-other" `
    -ProviderId "provider-other" `
    -Priority 50

Assert-Pass (
    $otherTenantDecision.Allowed -eq $true
) "autre tenant non impacte par la surcharge"

# 17
$badPriority = $false

try {

    Test-Admission `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -ConnectorId "connector-A" `
        -ProviderId "provider-A" `
        -Priority 101 | Out-Null
}
catch {
    $badPriority = $true
}

Assert-Pass $badPriority `
    "priorite hors plage correctement bloquee"

# 18
$badContext = $false

try {

    New-AdmissionKey `
        -Scope project `
        -ProjectId "" | Out-Null
}
catch {
    $badContext = $true
}

Assert-Pass $badContext `
    "contexte project incomplet correctement bloque"

# 19
$leaveUnknown = Leave-AdmissionSlot `
    -Key "unknown-key"

Assert-Pass (
    $leaveUnknown -eq 0
) "liberation d'une cle inconnue correctement geree"

# 20
$statePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\admission-control\state\admission-state.json"

$raw = ""

if (Test-Path -LiteralPath $statePath) {

    $raw = Get-Content `
        -LiteralPath $statePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat Admission Control sans secret"

# 21
$clientKeyA = New-AdmissionKey `
    -Scope client `
    -ClientId "client-A"

$clientKeyB = New-AdmissionKey `
    -Scope client `
    -ClientId "client-B"

Assert-Pass (
    $clientKeyA -ne $clientKeyB
) "isolation client correctement appliquee"

# 22
Reset-AdmissionState | Out-Null

$resetCount = Get-AdmissionCount `
    -Key $blockKey

Assert-Pass (
    $resetCount -eq 0
) "reset Admission Control correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-37" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Backpressure & Admission Control Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"