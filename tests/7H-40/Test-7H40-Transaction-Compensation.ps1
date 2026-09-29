$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\transaction-compensation\TRANSACTION-COMPENSATION-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\transaction-compensation\state\transactions.json"

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

Reset-TransactionState | Out-Null

# 1
$config = Get-TransactionConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Transaction Manager valide"

# 2
Assert-Pass (
    $config.transactionsEnabled -eq $true -and
    $config.compensationEnabled -eq $true
) "transactions et compensation actives"

# 3
Assert-Pass (
    $config.maxSteps -eq 100 -and
    $config.maxTransactions -eq 5000
) "limites transaction correctement configurees"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$tx = New-Transaction `
    -TransactionId "tx-001" `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A"

Assert-Pass (
    $tx.TransactionId -eq "tx-001" -and
    $tx.Status -eq "OPEN"
) "transaction correctement creee"

# 6
$save = Save-Transaction -Transaction $tx

Assert-Pass (
    $save -eq $true
) "transaction correctement persistee"

# 7
$loaded = Get-Transaction `
    -TransactionId "tx-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $null -ne $loaded -and
    $loaded.TenantId -eq "tenant-A"
) "transaction correctement relue"

# 8
$step1 = Add-TransactionStep `
    -Transaction $tx `
    -StepId "step-001" `
    -Operation "operation-1" `
    -CompensationAction "undo-operation-1"

$tx = $step1

Assert-Pass (
    @($tx.Steps).Count -eq 1
) "premiere etape correctement ajoutee"

# 9
$step2 = Add-TransactionStep `
    -Transaction $tx `
    -StepId "step-002" `
    -Operation "operation-2" `
    -CompensationAction "undo-operation-2"

$tx = $step2

Assert-Pass (
    @($tx.Steps).Count -eq 2
) "deuxieme etape correctement ajoutee"

# 10
Save-Transaction -Transaction $tx | Out-Null

Assert-Pass (
    @((Get-Transaction -TransactionId "tx-001").Steps).Count -eq 2
) "etapes transaction correctement persistees"

# 11
$completed1 = Complete-TransactionStep `
    -TransactionId "tx-001" `
    -TenantId "tenant-A" `
    -StepId "step-001"

Assert-Pass (
    $completed1 -eq $true
) "premiere etape correctement completee"

# 12
$readyBefore = Test-TransactionReadyForCommit `
    -Transaction (Get-Transaction -TransactionId "tx-001")

Assert-Pass (
    $readyBefore -eq $false
) "commit correctement bloque avant completion totale"

# 13
$completed2 = Complete-TransactionStep `
    -TransactionId "tx-001" `
    -TenantId "tenant-A" `
    -StepId "step-002"

Assert-Pass (
    $completed2 -eq $true
) "deuxieme etape correctement completee"

# 14
$readyAfter = Test-TransactionReadyForCommit `
    -Transaction (Get-Transaction -TransactionId "tx-001")

Assert-Pass (
    $readyAfter -eq $true
) "transaction prete pour commit"

# 15
$committed = Commit-Transaction `
    -TransactionId "tx-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $committed -eq $true
) "commit transaction correctement execute"

# 16
$committedTx = Get-Transaction -TransactionId "tx-001"

Assert-Pass (
    $committedTx.Status -eq "COMMITTED"
) "etat COMMITTED correctement persiste"

# 17
$tx2 = New-Transaction `
    -TransactionId "tx-002" `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-B"

Add-TransactionStep `
    -Transaction $tx2 `
    -StepId "step-201" `
    -Operation "operation-failed" `
    -CompensationAction "undo-failed-operation" | Out-Null

Save-Transaction -Transaction $tx2 | Out-Null

# 18
$wrongTenant = Test-TransactionTenantIsolation `
    -TransactionId "tx-002" `
    -TenantId "tenant-A"

Assert-Pass (
    $wrongTenant -eq $false
) "acces cross-tenant correctement bloque"

# 19
$rollback = Rollback-Transaction `
    -TransactionId "tx-002" `
    -TenantId "tenant-B"

Assert-Pass (
    $rollback -eq $true
) "rollback transaction correctement execute"

# 20
$compensated = Invoke-TransactionCompensation `
    -TransactionId "tx-002" `
    -TenantId "tenant-B"

Assert-Pass (
    $compensated -eq $true
) "compensation transaction correctement executee"

# 21
$tx2Final = Get-Transaction `
    -TransactionId "tx-002" `
    -TenantId "tenant-B"

$compensatedSteps = @(
    $tx2Final.Steps |
    Where-Object Status -eq "COMPENSATED"
).Count

Assert-Pass (
    $tx2Final.Status -eq "COMPENSATED" -and
    $compensatedSteps -eq 0
) "transaction sans etape completee reste correctement tracee apres compensation"

# 22
$bad = $false

try {

    New-Transaction `
        -TransactionId "" `
        -ExecutionId "exec-bad" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" | Out-Null
}
catch {
    $bad = $true
}

Assert-Pass $bad `
    "transaction id vide correctement bloquee"

# 23
$secretState = ""

if (Test-Path -LiteralPath $StatePath) {

    $secretState = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $secretState -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat transaction sans secret"

# 24
$duplicate = $false

try {

    New-Transaction `
        -TransactionId "tx-001" `
        -ExecutionId "exec-dup" `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" | Out-Null
}
catch {
    $duplicate = $true
}

Assert-Pass $duplicate `
    "transaction duplicate correctement bloquee"

# 25
Reset-TransactionState | Out-Null

Assert-Pass (
    $null -eq (Get-Transaction -TransactionId "tx-001")
) "reset Transaction Manager correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-40" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Transaction & Compensation Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"