param(
    [Parameter(Mandatory=$true)]
    [string]$Client,

    [Parameter(Mandatory=$true)]
    [string]$Project,

    [Parameter(Mandatory=$true)]
    [string]$Request
)

$ErrorActionPreference = "Continue"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$RuntimePath = Join-Path $Root "memory\runtime"
$NewContext = Join-Path $Root "memory\New-Context.ps1"
$BuildContext = Join-Path $Root "memory\engine\Build-Context.ps1"
$LoadMemory = Join-Path $Root "memory\engine\Load-Hierarchical-Memory.ps1"
$ContextBridge = Join-Path $Root "orchestrator\context\Invoke-Context-Bridge.ps1"
$EndToEnd = Join-Path $Root "orchestrator\Invoke-EndToEnd.ps1"
$MayaEngine = Join-Path $Root "workers\maya\MAYA-Intelligence.ps1"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " ORCHESTRATOR COMMAND INTERFACE"
Write-Host " PHASE 7C"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT  : $Client"
Write-Host "PROJECT : $Project"
Write-Host "REQUEST : $Request"
Write-Host ""

# ROUTING
$requestLower = $Request.ToLowerInvariant()
$Worker = "NOAH"

if ($requestLower -match "vente|commercial|prospect|lead|prospection") {
    $Worker = "ALEX"
}
elseif ($requestLower -match "marketing|campagne|growth|publicité|publicite|acquisition") {
    $Worker = "MAYA"
}
elseif ($requestLower -match "design|logo|visuel|créatif|creatif|graphisme|flyer") {
    $Worker = "LEA"
}
elseif ($requestLower -match "seo|référencement|referencement|site web|website|wordpress") {
    $Worker = "LUCAS"
}
elseif ($requestLower -match "réseau social|reseau social|instagram|facebook|tiktok|contenu|publication|post") {
    $Worker = "EMMA"
}
elseif ($requestLower -match "sécurité|securite|cybersécurité|cybersecurite|serveur|informatique|infrastructure") {
    $Worker = "SAM"
}
elseif ($requestLower -match "trading|forex|mt5|risque|marché|marche") {
    $Worker = "ATLAS"
}

Write-Host "ROUTING : $Worker"
Write-Host ""

# FINANCIAL BOUNDARY
$financial = $requestLower -match "payer|paiement|virement|rembourser|investir|acheter|dépense|depense|transférer|transferer"

if ($financial) {
    Write-Host "FINANCIAL BOUNDARY : DETECTED"
    Write-Host "STATUS : NEEDS_HUMAN"
    Write-Host "AUTHORIZATION : KADER_APPROVAL"
    Write-Host "ACTION : BLOCKED"
    exit 20
}

# SYSTEM CHECK
Write-Host "SYSTEM CHECK"
Write-Host "------------"

$requiredFiles = @(
    $NewContext,
    $BuildContext,
    $LoadMemory,
    $ContextBridge,
    $EndToEnd
)

if ($Worker -eq "MAYA") {
    $requiredFiles += $MayaEngine
}

foreach ($file in $requiredFiles) {
    if (-not (Test-Path $file)) {
        Write-Host "MISSING : $file"
        exit 30
    }
}

if (-not (Test-Path $RuntimePath)) {
    New-Item -ItemType Directory -Path $RuntimePath -Force | Out-Null
}

Write-Host "FILES : OK"
Write-Host ""

# CONTEXT
Write-Host "CONTEXT : CREATING"
Write-Host ""

$startTime = Get-Date

& $NewContext -ClientId $Client -ProjectId $Project -WorkerId $Worker -Objective $Request

$contextFile = Get-ChildItem -Path $RuntimePath -Filter "CTX-*.json" -File |
    Where-Object { $_.LastWriteTime -ge $startTime } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $contextFile) {
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : CONTEXT FILE NOT FOUND"
    exit 31
}

$contextPath = $contextFile.FullName
$context = Get-Content $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$taskId = [string]$context.task_id

if ([string]::IsNullOrWhiteSpace($taskId)) {
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : TASK ID MISSING"
    exit 33
}

Write-Host ""
Write-Host "CONTEXT : CREATED"
Write-Host "TASK ID : $taskId"
Write-Host ""

# ACTIVE CONTEXT
Write-Host "ACTIVE CONTEXT : BUILDING"
Write-Host ""

& $BuildContext -ClientId $Client -ProjectId $Project -WorkerId $Worker -TaskId $taskId

$activeContext = Get-ChildItem -Path $RuntimePath -Filter "ACTIVE-*.json" -File |
    Where-Object { $_.LastWriteTime -ge $startTime } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $activeContext) {
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : ACTIVE CONTEXT NOT FOUND"
    exit 35
}

Write-Host "ACTIVE CONTEXT : READY"
Write-Host ""

# MEMORY
Write-Host "MEMORY : LOADING"
Write-Host ""

& $LoadMemory -ClientId $Client -ProjectId $Project -WorkerId $Worker -TaskId $taskId

$memoryObject = Get-ChildItem -Path $RuntimePath -Filter "HIERARCHICAL-*.json" -File |
    Where-Object { $_.LastWriteTime -ge $startTime } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $memoryObject) {
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : MEMORY FILE NOT FOUND"
    exit 37
}

$memoryPath = $memoryObject.FullName

Write-Host "MEMORY : LOADED"
Write-Host ""

# BRIDGE
Write-Host "CONTEXT BRIDGE : VALIDATING"
Write-Host ""

& $ContextBridge -ClientId $Client -ProjectId $Project -WorkerId $Worker -TaskId $taskId

$bridgeObject = Get-ChildItem -Path $RuntimePath -Filter "BRIDGE-*.json" -File |
    Where-Object { $_.LastWriteTime -ge $startTime } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $bridgeObject) {
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : BRIDGE FILE NOT FOUND"
    exit 39
}

$bridgePath = $bridgeObject.FullName

Write-Host "CONTEXT BRIDGE : READY"
Write-Host ""

# MAYA INTELLIGENCE
if ($Worker -eq "MAYA") {

    Write-Host "============================================"
    Write-Host " MAYA INTELLIGENCE ENGINE"
    Write-Host "============================================"
    Write-Host ""

    & $MayaEngine -Request $Request -ClientId $Client -ProjectId $Project -WorkerId "MAYA" -TaskId $taskId -ContextPath $bridgePath -MemoryPath $memoryPath

    $mayaResultPath = Join-Path $RuntimePath "MAYA-$taskId.json"

    if (-not (Test-Path $mayaResultPath)) {
        Write-Host ""
        Write-Host "MAYA : ERROR"
        Write-Host "REASON : MAYA RESULT NOT FOUND"
        exit 46
    }

    $mayaResult = Get-Content $mayaResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

    Write-Host ""
    Write-Host "MAYA STATUS : $($mayaResult.status)"
    Write-Host "OBJECTIVE TYPE : $($mayaResult.objective_type)"
    Write-Host "NEXT ACTION : $($mayaResult.next_action)"
    Write-Host ""
}

# END TO END
Write-Host "ORCHESTRATOR : EXECUTION"
Write-Host ""

& $EndToEnd -ContextPath $bridgePath -Objective $Request

# FINAL RESULT
$resultPath = Join-Path $RuntimePath "RESULT-$taskId.json"

if (-not (Test-Path $resultPath)) {
    Write-Host ""
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : RESULT FILE NOT FOUND"
    exit 42
}

$result = Get-Content $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Host ""
Write-Host "============================================"
Write-Host " FINAL RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT : $Client"
Write-Host "PROJECT: $Project"
Write-Host "WORKER : $Worker"
Write-Host "TASK   : $taskId"
Write-Host "STATUS : $($result.status)"
Write-Host ""

if ($result.status -eq "SUCCESS") {
    Write-Host "ORCHESTRATOR : SUCCESS"
    Write-Host "TASK : CLOSED"
}
elseif ($result.status -eq "NEEDS_HUMAN") {
    Write-Host "ORCHESTRATOR : NEEDS_HUMAN"
    Write-Host "ACTION : KADER"
}
elseif ($result.status -eq "BLOCKED") {
    Write-Host "ORCHESTRATOR : BLOCKED"
}
else {
    Write-Host "ORCHESTRATOR : $($result.status)"
}

Write-Host ""
Write-Host "RESULT FILE : $resultPath"
Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 7C COMPLETE"
Write-Host "============================================"
Write-Host ""

exit 0