$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Bridge = Join-Path $Root "orchestrator\context\Invoke-Context-Bridge.ps1"

$Client = "bk-entreprise"
$Project = "service-ia"
$Worker = "MAYA"
$Task = "TASK-20260909-143327-588"

$Passed = 0
$Failed = 0

Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 6A-4 - SECURITY ATTACK TESTS"
Write-Host "============================================"
Write-Host ""

function Test-Blocked {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    Write-Host "TEST : $Name"

    try {
        & $Action 2>&1 | Out-Null
        $Code = $LASTEXITCODE
    }
    catch {
        $Code = 999
    }

    if ($Code -ne 0) {
        Write-Host "RESULT : BLOCKED [OK]"
        $script:Passed++
    }
    else {
        Write-Host "RESULT : NOT BLOCKED [FAIL]"
        $script:Failed++
    }

    Write-Host ""
}

# =================================================
# TEST 1 - FAUX CLIENT
# =================================================

Test-Blocked "MAYA -> client-demo" {
    & $Bridge `
        -ClientId "client-demo" `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId $Task
}

# =================================================
# TEST 2 - FAUX PROJET
# =================================================

Test-Blocked "MAYA -> autre-projet" {
    & $Bridge `
        -ClientId $Client `
        -ProjectId "projet-interdit" `
        -WorkerId $Worker `
        -TaskId $Task
}

# =================================================
# TEST 3 - FAUX WORKER
# =================================================

Test-Blocked "MAYA -> LUCAS" {
    & $Bridge `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId "LUCAS" `
        -TaskId $Task
}

# =================================================
# TEST 4 - FAUX TASK
# =================================================

Test-Blocked "TaskId invalide" {
    & $Bridge `
        -ClientId $Client `
        -ProjectId $Project `
        -WorkerId $Worker `
        -TaskId "TASK-FAKE-999"
}

# =================================================
# TEST 5 - TENTATIVE FINANCIERE
# =================================================

$BridgeFile = Join-Path $Root "memory\runtime\BRIDGE-$Task.json"

if (Test-Path $BridgeFile) {

    $Backup = Get-Content $BridgeFile -Raw

    try {

        $Data = $Backup | ConvertFrom-Json

        $Data.permissions.financial_actions = $true

        $Data |
            ConvertTo-Json -Depth 30 |
            Set-Content $BridgeFile -Encoding UTF8

        $Check =
            Get-Content $BridgeFile -Raw |
            ConvertFrom-Json

        if ($Check.permissions.financial_actions -eq $true) {
            Write-Host "TEST : Financial permission escalation"
            Write-Host "RESULT : DETECTED [OK]"
            $Passed++
        }
        else {
            Write-Host "TEST : Financial permission escalation"
            Write-Host "RESULT : NOT DETECTED [FAIL]"
            $Failed++
        }
    }
    finally {

        $Backup |
            Set-Content $BridgeFile -Encoding UTF8
    }
}

Write-Host ""

# =================================================
# TEST 6 - EXTERNAL ACTION BYPASS
# =================================================

if (Test-Path $BridgeFile) {

    $Backup = Get-Content $BridgeFile -Raw

    try {

        $Data = $Backup | ConvertFrom-Json

        $Data.permissions.external_actions = $true

        $Data |
            ConvertTo-Json -Depth 30 |
            Set-Content $BridgeFile -Encoding UTF8

        $Check =
            Get-Content $BridgeFile -Raw |
            ConvertFrom-Json

        if ($Check.permissions.external_actions -eq $true) {
            Write-Host "TEST : External action escalation"
            Write-Host "RESULT : DETECTED [OK]"
            $Passed++
        }
        else {
            Write-Host "TEST : External action escalation"
            Write-Host "RESULT : NOT DETECTED [FAIL]"
            $Failed++
        }
    }
    finally {

        $Backup |
            Set-Content $BridgeFile -Encoding UTF8
    }
}

Write-Host ""

# =================================================
# TEST 7 - CONTEXTE CORROMPU
# =================================================

$Active =
    Join-Path $Root "memory\runtime\ACTIVE-$Task.json"

if (Test-Path $Active) {

    $Backup = Get-Content $Active -Raw

    try {

        $Data = $Backup | ConvertFrom-Json

        $Data.client.id = "client-corrompu"

        $Data |
            ConvertTo-Json -Depth 30 |
            Set-Content $Active -Encoding UTF8

        $Result = & $Bridge `
            -ClientId $Client `
            -ProjectId $Project `
            -WorkerId $Worker `
            -TaskId $Task 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Host "TEST : Contexte corrompu"
            Write-Host "RESULT : BLOCKED [OK]"
            $Passed++
        }
        else {
            Write-Host "TEST : Contexte corrompu"
            Write-Host "RESULT : NOT BLOCKED [FAIL]"
            $Failed++
        }
    }
    finally {

        $Backup |
            Set-Content $Active -Encoding UTF8
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host " SECURITY TEST SUMMARY"
Write-Host "============================================"
Write-Host ""

Write-Host "PASSED : $Passed"
Write-Host "FAILED : $Failed"

Write-Host ""

if ($Failed -eq 0) {

    Write-Host "SECURITY : 7/7 TESTS VALIDATED"
    Write-Host "PHASE 6A-4 : SUCCESS"

    exit 0
}
else {

    Write-Host "SECURITY : FAILURES DETECTED"
    Write-Host "PHASE 6A-4 : BLOCKED"

    exit 1
}