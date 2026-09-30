$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "Authorization-Proof-Lifecycle-Guard.ps1"

. $Module

$script:Total = 0
$script:Pass = 0
$script:Fail = 0
$script:LifecycleResult = $null

function Run-Test {
    param(
        [string]$TestName,
        [scriptblock]$TestAction,
        [bool]$ExpectThrow
    )

    $script:Total++

    try {
        & $TestAction | Out-Null

        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:Total,$TestName)
            $script:Fail++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$TestName)
            $script:Pass++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Pass++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Fail++
        }
    }
}

Reset-ProofFreshness
Reset-AtomicConsumption

$Context = @{
    TenantId = "TEN-55"
    ClientId = "CLI-55"
    ProjectId = "PROJ-55"
    ExecutionId = "EXEC-55"
    UserId = "USER-55"
}

$OperationName = "AI_EXECUTION"
$ProofHash = "PROOF-55"
$IssuedAtUtc = [DateTime]::UtcNow.AddSeconds(-5)

Register-ProofFreshness `
    -Context $Context `
    -Action $OperationName `
    -ProofHash $ProofHash `
    -IssuedAtUtc $IssuedAtUtc `
    -LifetimeSeconds 300 | Out-Null

Register-AtomicProof `
    -TenantId $Context.TenantId `
    -ClientId $Context.ClientId `
    -ProjectId $Context.ProjectId `
    -ExecutionId $Context.ExecutionId `
    -UserId $Context.UserId `
    -OperationName $OperationName `
    -ProofHash $ProofHash | Out-Null

# 01
Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

# 02
Run-Test "Freshness valide avant lifecycle" {
    $Result = Test-ProofFreshness `
        -Context $Context `
        -Action $OperationName `
        -ProofHash $ProofHash

    if ($Result.Decision -ne "ALLOW") {
        throw "FRESHNESS_NOT_VALID"
    }

    if ($Result.Valid -ne $true) {
        throw "FRESHNESS_INVALID"
    }
} $false

# 03
Run-Test "Atomic proof disponible" {
    $Result = Test-AtomicProof `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash

    if ($Result.Decision -ne "ALLOW") {
        throw "ATOMIC_NOT_AVAILABLE"
    }
} $false

# 04
Run-Test "Lifecycle complet autorise" {
    $script:LifecycleResult = Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash

    if ($script:LifecycleResult.Decision -ne "ALLOW") {
        throw "LIFECYCLE_NOT_ALLOWED"
    }
} $false

# 05
Run-Test "Lifecycle confirme freshness" {
    if ($null -eq $script:LifecycleResult) {
        throw "LIFECYCLE_RESULT_MISSING"
    }

    if ($script:LifecycleResult.FreshnessValidated -ne $true) {
        throw "FRESHNESS_FLAG_MISSING"
    }
} $false

# 06
Run-Test "Lifecycle confirme atomicite" {
    if ($null -eq $script:LifecycleResult) {
        throw "LIFECYCLE_RESULT_MISSING"
    }

    if ($script:LifecycleResult.AtomicValidated -ne $true) {
        throw "ATOMIC_FLAG_MISSING"
    }
} $false

# 07
Run-Test "Lifecycle confirme consommation" {
    if ($null -eq $script:LifecycleResult) {
        throw "LIFECYCLE_RESULT_MISSING"
    }

    if ($script:LifecycleResult.AtomicConsumed -ne $true) {
        throw "CONSUMPTION_FLAG_MISSING"
    }
} $false

# 08
Run-Test "Replay bloque apres lifecycle" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash
} $true

# 09
Run-Test "Tenant vide bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId "" `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash "OTHER-55"
} $true

# 10
Run-Test "Client vide bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId "" `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash "OTHER-55"
} $true

# 11
Run-Test "Project vide bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId "" `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash "OTHER-55"
} $true

# 12
Run-Test "Execution vide bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId "" `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash "OTHER-55"
} $true

# 13
Run-Test "User vide bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId "" `
        -OperationName $OperationName `
        -ProofHash "OTHER-55"
} $true

# 14
Run-Test "Operation vide bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName "" `
        -ProofHash "OTHER-55"
} $true

# 15
Run-Test "ProofHash vide bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash ""
} $true

# 16
Run-Test "ProofHash incoherent bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash "OTHER-PROOF"
} $true

# 17
Run-Test "Operation incoherente bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName "OTHER_OPERATION" `
        -ProofHash $ProofHash
} $true

# 18
Run-Test "Execution inconnue bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId "UNKNOWN_EXECUTION" `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash
} $true

# 19
Run-Test "Tenant incoherent bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId "OTHER_TENANT" `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash
} $true

# 20
Run-Test "Client incoherent bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId "OTHER_CLIENT" `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash
} $true

# 21
Run-Test "Project incoherent bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId "OTHER_PROJECT" `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash
} $true

# 22
Run-Test "User incoherent bloque" {
    Invoke-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId "OTHER_USER" `
        -OperationName $OperationName `
        -ProofHash $ProofHash
} $true

# 23
Run-Test "Assert lifecycle refuse replay" {
    Assert-ProofLifecycleGuard `
        -TenantId $Context.TenantId `
        -ClientId $Context.ClientId `
        -ProjectId $Context.ProjectId `
        -ExecutionId $Context.ExecutionId `
        -UserId $Context.UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash
} $true

# 24
Run-Test "Fail-closed preuve absente" {
    $Unknown = @{
        TenantId = "TEN-55-X"
        ClientId = "CLI-55-X"
        ProjectId = "PROJ-55-X"
        ExecutionId = "EXEC-55-X"
        UserId = "USER-55-X"
        OperationName = "UNKNOWN_OPERATION"
        ProofHash = "UNKNOWN_PROOF"
    }

    Invoke-ProofLifecycleGuard @Unknown
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8A-55"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8A-55 : VALIDEE - 24/24"
}
else {
    Write-Host "8A-55 : NON VALIDEE"
}

Write-Host "============================================================"
Write-Host "8A-55 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"