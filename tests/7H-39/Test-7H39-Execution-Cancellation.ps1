$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cancellation\EXECUTION-CANCELLATION-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cancellation\state\execution-leases.json"

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

Reset-ExecutionCancellationState | Out-Null

# 1
$config = Get-ExecutionCancellationConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Execution Cancellation valide"

# 2
Assert-Pass (
    $config.cancellationEnabled -eq $true -and
    $config.leaseEnabled -eq $true
) "cancellation et lease actives"

# 3
Assert-Pass (
    $config.leaseSeconds -eq 60 -and
    $config.renewalGraceSeconds -eq 15
) "parametres lease correctement configures"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$lease = New-ExecutionLease `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -OwnerId "owner-A"

Assert-Pass (
    $lease.ExecutionId -eq "exec-001" -and
    $lease.Status -eq "ACTIVE" -and
    $lease.LeaseToken
) "lease correctement generee"

# 6
$acquire = Acquire-ExecutionLease -Lease $lease

Assert-Pass (
    $acquire.Acquired -eq $true
) "lease correctement acquise"

# 7
$duplicate = Acquire-ExecutionLease -Lease $lease

Assert-Pass (
    $duplicate.Acquired -eq $false
) "double acquisition correctement bloquee"

# 8
$loaded = Get-ExecutionLease -ExecutionId "exec-001"

Assert-Pass (
    $null -ne $loaded -and
    $loaded.OwnerId -eq "owner-A"
) "lease correctement relue"

# 9
$valid = Test-ExecutionLease `
    -ExecutionId "exec-001" `
    -OwnerId "owner-A" `
    -LeaseToken $lease.LeaseToken

Assert-Pass (
    $valid.Valid -eq $true
) "lease valide correctement detectee"

# 10
$wrongOwner = Test-ExecutionLease `
    -ExecutionId "exec-001" `
    -OwnerId "owner-B" `
    -LeaseToken $lease.LeaseToken

Assert-Pass (
    $wrongOwner.Valid -eq $false
) "owner incorrect correctement bloque"

# 11
$renew = Renew-ExecutionLease `
    -ExecutionId "exec-001" `
    -OwnerId "owner-A" `
    -LeaseToken $lease.LeaseToken

Assert-Pass (
    $renew.Renewed -eq $true
) "renouvellement lease correctement execute"

# 12
$request = Request-ExecutionCancellation `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $request.Requested -eq $true
) "demande d'annulation correctement enregistree"

# 13
$afterRequest = Get-ExecutionLease -ExecutionId "exec-001"

Assert-Pass (
    $afterRequest.CancellationRequested -eq $true
) "indicateur cancellation correctement persiste"

# 14
$cancel = Confirm-ExecutionCancellation `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -OwnerId "owner-A" `
    -LeaseToken $lease.LeaseToken

Assert-Pass (
    $cancel.Cancelled -eq $true
) "annulation execution correctement confirmee"

# 15
$cancelledLease = Get-ExecutionLease -ExecutionId "exec-001"

Assert-Pass (
    $cancelledLease.Status -eq "CANCELLED"
) "etat CANCELLED correctement persiste"

# 16
$releaseAttempt = Release-ExecutionLease `
    -ExecutionId "exec-001" `
    -OwnerId "owner-A" `
    -LeaseToken $lease.LeaseToken

Assert-Pass (
    $releaseAttempt.Released -eq $false
) "release d'une lease deja annulee correctement protegee"

# 17
$lease2 = New-ExecutionLease `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-B" `
    -OwnerId "owner-B"

Acquire-ExecutionLease -Lease $lease2 | Out-Null

$wrongTenant = Request-ExecutionCancellation `
    -ExecutionId "exec-002" `
    -TenantId "tenant-A"

Assert-Pass (
    $wrongTenant.Requested -eq $false
) "annulation cross-tenant correctement bloquee"

# 18
$notRequested = Confirm-ExecutionCancellation `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -OwnerId "owner-B" `
    -LeaseToken $lease2.LeaseToken

Assert-Pass (
    $notRequested.Cancelled -eq $false
) "confirmation sans demande correctement bloquee"

# 19
$released = Release-ExecutionLease `
    -ExecutionId "exec-002" `
    -OwnerId "owner-B" `
    -LeaseToken $lease2.LeaseToken

Assert-Pass (
    $released.Released -eq $true
) "lease active correctement liberee"

# 20
$badContext = $false

try {
    New-ExecutionLease `
        -ExecutionId "" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -OwnerId "owner-X" | Out-Null
}
catch {
    $badContext = $true
}

Assert-Pass $badContext `
    "execution id vide correctement bloque"

# 21
$raw = ""

if (Test-Path -LiteralPath $StatePath) {

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat execution lease sans secret"

# 22
Reset-ExecutionCancellationState | Out-Null

Assert-Pass (
    $null -eq (Get-ExecutionLease -ExecutionId "exec-001")
) "reset Execution Cancellation correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-39" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Cancellation & Lease Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"