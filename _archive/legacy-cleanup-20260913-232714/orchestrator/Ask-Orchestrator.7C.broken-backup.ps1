param(
[Parameter(Mandatory=$true)]
[string]$Client,
[Parameter(Mandatory=$true)]
[string]$Project,

[Parameter(Mandatory=$true)]
[string]$Request
)

$ErrorActionPreference = "Continue"

# ============================================================

# BK AI WORKERS

# ORCHESTRATOR COMMAND INTERFACE

# PHASE 7C

# MAYA INTELLIGENCE INTEGRATION

# ============================================================

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$RuntimePath   = Join-Path $Root "memory\runtime"
$NewContext    = Join-Path $Root "memory\New-Context.ps1"
$BuildContext  = Join-Path $Root "memory\engine\Build-Context.ps1"
$LoadMemory    = Join-Path $Root "memory\engine\Load-Hierarchical-Memory.ps1"
$ContextBridge = Join-Path $Root "orchestrator\context\Invoke-Context-Bridge.ps1"
$EndToEnd      = Join-Path $Root "orchestrator\Invoke-EndToEnd.ps1"
$MayaEngine    = Join-Path $Root "workers\maya\MAYA-Intelligence.ps1"

# ============================================================

# HEADER

# ============================================================

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " ORCHESTRATOR COMMAND INTERFACE"
Write-Host " PHASE 7C"
Write-Host " MAYA INTELLIGENCE"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT  : $Client"
Write-Host "PROJECT : $Project"
Write-Host ""
Write-Host "REQUEST :"
Write-Host $Request
Write-Host ""

# ============================================================

# ROUTING

# ============================================================

$RequestLower = $Request.ToLowerInvariant()

$Worker = "NOAH"

if (
$RequestLower -match "vente" -or
$RequestLower -match "commercial" -or
$RequestLower -match "prospect" -or
$RequestLower -match "client" -or
$RequestLower -match "lead" -or
$RequestLower -match "prospection"
) {
$Worker = "ALEX"
}
elseif (
$RequestLower -match "marketing" -or
$RequestLower -match "campagne" -or
$RequestLower -match "growth" -or
$RequestLower -match "publicité" -or
$RequestLower -match "publicite" -or
$RequestLower -match "acquisition"
) {
$Worker = "MAYA"
}
elseif (
$RequestLower -match "design" -or
$RequestLower -match "logo" -or
$RequestLower -match "visuel" -or
$RequestLower -match "créatif" -or
$RequestLower -match "creatif" -or
$RequestLower -match "graphisme" -or
$RequestLower -match "flyer"
) {
$Worker = "LEA"
}
elseif (
$RequestLower -match "seo" -or
$RequestLower -match "référencement" -or
$RequestLower -match "referencement" -or
$RequestLower -match "site web" -or
$RequestLower -match "website" -or
$RequestLower -match "wordpress"
) {
$Worker = "LUCAS"
}
elseif (
$RequestLower -match "réseau social" -or
$RequestLower -match "reseau social" -or
$RequestLower -match "instagram" -or
$RequestLower -match "facebook" -or
$RequestLower -match "tiktok" -or
$RequestLower -match "contenu" -or
$RequestLower -match "publication" -or
$RequestLower -match "post"
) {
$Worker = "EMMA"
}
elseif (
$RequestLower -match "sécurité" -or
$RequestLower -match "securite" -or
$RequestLower -match "cybersécurité" -or
$RequestLower -match "cybersecurite" -or
$RequestLower -match "serveur" -or
$RequestLower -match "informatique" -or
$RequestLower -match "infrastructure"
) {
$Worker = "SAM"
}
elseif (
$RequestLower -match "trading" -or
$RequestLower -match "forex" -or
$RequestLower -match "mt5" -or
$RequestLower -match "risque" -or
$RequestLower -match "marché" -or
$RequestLower -match "marche"
) {
$Worker = "ATLAS"
}

Write-Host "ROUTING : $Worker"
Write-Host ""

# ============================================================

# FINANCIAL BOUNDARY

# ============================================================

$FinancialRequest = (
$RequestLower -match "payer" -or
$RequestLower -match "paiement" -or
$RequestLower -match "virement" -or
$RequestLower -match "rembourser" -or
$RequestLower -match "investir" -or
$RequestLower -match "acheter" -or
$RequestLower -match "dépense" -or
$RequestLower -match "depense" -or
$RequestLower -match "transférer" -or
$RequestLower -match "transferer"
)

if ($FinancialRequest) {
Write-Host "ROUTING : KADER"
Write-Host ""
Write-Host "FINANCIAL BOUNDARY : DETECTED"
Write-Host "STATUS : NEEDS_HUMAN"
Write-Host "AUTHORIZATION : KADER_APPROVAL"
Write-Host "ACTION : BLOCKED"
Write-Host ""

exit 20
}

# ============================================================

# SYSTEM CHECK

# ============================================================

Write-Host "SYSTEM CHECK"
Write-Host "------------"

$RequiredFiles = @(
$NewContext,
$BuildContext,
$LoadMemory,
$ContextBridge,
$EndToEnd
)

if ($Worker -eq "MAYA") {
$RequiredFiles += $MayaEngine
}

foreach ($File in $RequiredFiles) {
if (-not (Test-Path $File)) {

    Write-Host "MISSING : $File"
    Write-Host ""
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : REQUIRED FILE MISSING"

    exit 30
}
}

if (-not (Test-Path $RuntimePath)) {
New-Item `
    -ItemType Directory `
    -Path $RuntimePath `
    -Force |
    Out-Null
}

Write-Host "FILES : OK"
Write-Host ""

# ============================================================

# CONTEXT CREATION

# ============================================================

Write-Host "CONTEXT : CREATING"
Write-Host ""

$StartTime = Get-Date

& $NewContext `r
    -ClientId $Client`
-ProjectId $Project `r
    -WorkerId $Worker`
-Objective $Request

$ContextFile = Get-ChildItem `r
    -Path $RuntimePath`
-Filter "CTX-*.json" `r
    -File`
-ErrorAction SilentlyContinue |
Where-Object {
$_.LastWriteTime -ge $StartTime
} |
Sort-Object LastWriteTime -Descending |
Select-Object -First 1

if ($null -eq $ContextFile) {
Write-Host ""
Write-Host "STATUS : ERROR"
Write-Host "REASON : CONTEXT FILE NOT FOUND"

exit 31
}

$ContextPath = $ContextFile.FullName

Write-Host ""
Write-Host "CONTEXT : CREATED"
Write-Host "FILE    : $ContextPath"
Write-Host ""

# ============================================================

# READ CONTEXT

# ============================================================

try {
$Context = Get-Content `
    -Path $ContextPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
}
catch {
Write-Host "STATUS : ERROR"
Write-Host "REASON : INVALID CONTEXT JSON"

exit 32
}

$TaskId = [string]$Context.task_id

if ([string]::IsNullOrWhiteSpace($TaskId)) {
Write-Host "STATUS : ERROR"
Write-Host "REASON : TASK ID MISSING"

exit 33
}

Write-Host "TASK ID : $TaskId"
Write-Host ""

# ============================================================

# BUILD ACTIVE CONTEXT

# ============================================================

Write-Host "ACTIVE CONTEXT : BUILDING"
Write-Host ""

& $BuildContext `r
    -ClientId $Client`
-ProjectId $Project `r
    -WorkerId $Worker`
-TaskId $TaskId

$ActiveContextFile = Get-ChildItem `r
    -Path $RuntimePath`
-Filter "ACTIVE-*.json" `r
    -File`
-ErrorAction SilentlyContinue |
Where-Object {
$_.LastWriteTime -ge $StartTime
} |
Sort-Object LastWriteTime -Descending |
Select-Object -First 1

if ($null -eq $ActiveContextFile) {
Write-Host ""
Write-Host "STATUS : ERROR"
Write-Host "REASON : ACTIVE CONTEXT NOT FOUND"

exit 35
}

$ActiveContextPath = $ActiveContextFile.FullName

Write-Host ""
Write-Host "ACTIVE CONTEXT : READY"
Write-Host "FILE           : $ActiveContextPath"
Write-Host ""

# ============================================================

# LOAD HIERARCHICAL MEMORY

# ============================================================

Write-Host "MEMORY : LOADING"
Write-Host ""

& $LoadMemory `r
    -ClientId $Client`
-ProjectId $Project `r
    -WorkerId $Worker`
-TaskId $TaskId

$MemoryFileObject = Get-ChildItem `r
    -Path $RuntimePath`
-Filter "HIERARCHICAL-*.json" `r
    -File`
-ErrorAction SilentlyContinue |
Where-Object {
$_.LastWriteTime -ge $StartTime
} |
Sort-Object LastWriteTime -Descending |
Select-Object -First 1

if ($null -eq $MemoryFileObject) {
Write-Host ""
Write-Host "STATUS : ERROR"
Write-Host "REASON : HIERARCHICAL MEMORY NOT FOUND"

exit 37
}

$MemoryFile = $MemoryFileObject.FullName

Write-Host ""
Write-Host "MEMORY : LOADED"
Write-Host "FILE   : $MemoryFile"
Write-Host ""

# ============================================================

# CONTEXT BRIDGE

# ============================================================

Write-Host "CONTEXT BRIDGE : VALIDATING"
Write-Host ""

& $ContextBridge `r
    -ClientId $Client`
-ProjectId $Project `r
    -WorkerId $Worker`
-TaskId $TaskId

$BridgeFileObject = Get-ChildItem `r
    -Path $RuntimePath`
-Filter "BRIDGE-*.json" `r
    -File`
-ErrorAction SilentlyContinue |
Where-Object {
$_.LastWriteTime -ge $StartTime
} |
Sort-Object LastWriteTime -Descending |
Select-Object -First 1

if ($null -eq $BridgeFileObject) {
Write-Host ""
Write-Host "STATUS : ERROR"
Write-Host "REASON : BRIDGE FILE NOT FOUND"

exit 39
}

$BridgeFile = $BridgeFileObject.FullName

Write-Host ""
Write-Host "CONTEXT BRIDGE : READY"
Write-Host "FILE           : $BridgeFile"
Write-Host ""

# ============================================================

# MAYA INTELLIGENCE

# ============================================================

if ($Worker -eq "MAYA") {
Write-Host "============================================"
Write-Host " MAYA : INTELLIGENCE ENGINE"
Write-Host "============================================"
Write-Host ""

& $MayaEngine `
    -Request $Request `
    -ClientId $Client `
    -ProjectId $Project `
    -WorkerId "MAYA" `
    -TaskId $TaskId `
    -ContextPath $BridgeFile `
    -MemoryPath $MemoryFile

if ($LASTEXITCODE -ne 0) {

    Write-Host ""
    Write-Host "MAYA : ERROR"
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : MAYA INTELLIGENCE ENGINE FAILED"

    exit 45
}

$MayaResult = Get-ChildItem `
    -Path $RuntimePath `
    -Filter "MAYA-*.json" `
    -File `
    -ErrorAction SilentlyContinue |
    Where-Object {
        $_.LastWriteTime -ge $StartTime
    } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($null -eq $MayaResult) {

    Write-Host ""
    Write-Host "MAYA : ERROR"
    Write-Host "STATUS : ERROR"
    Write-Host "REASON : MAYA RESULT FILE NOT FOUND"

    exit 46
}

Write-Host ""
Write-Host "MAYA : INTELLIGENCE READY"
Write-Host "FILE : $($MayaResult.FullName)"
Write-Host ""

try {

    $MayaData = Get-Content `
        -Path $MayaResult.FullName `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json

    Write-Host "MAYA STATUS : $($MayaData.status)"
    Write-Host "OBJECTIVE TYPE : $($MayaData.objective_type)"
    Write-Host "NEXT ACTION : $($MayaData.next_action)"
    Write-Host ""

}
catch {

    Write-Host "MAYA : INVALID JSON"
    Write-Host "STATUS : ERROR"

    exit 47
}
}

# ============================================================

# END-TO-END EXECUTION

# ============================================================

Write-Host "ORCHESTRATOR : EXECUTION"
Write-Host ""

& $EndToEnd `r
    -ContextPath $BridgeFile`
-Objective $Request

# ============================================================

# FINAL RESULT

# ============================================================

Write-Host ""
Write-Host "RESULT : CHECKING"
Write-Host ""

$ResultFileObject = Get-ChildItem `r
    -Path $RuntimePath`
-Filter "RESULT-*.json" `r
    -File`
-ErrorAction SilentlyContinue |
Where-Object {
$_.LastWriteTime -ge $StartTime
} |
Sort-Object LastWriteTime -Descending |
Select-Object -First 1

if ($null -eq $ResultFileObject) {
Write-Host ""
Write-Host "STATUS : ERROR"
Write-Host "REASON : RESULT FILE NOT FOUND"

exit 42
}

$ResultFile = $ResultFileObject.FullName

try {
$Result = Get-Content `
    -Path $ResultFile `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json
}
catch {
Write-Host "STATUS : ERROR"
Write-Host "REASON : INVALID RESULT JSON"

exit 43
}

Write-Host ""
Write-Host "============================================"
Write-Host " FINAL RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT : $Client"
Write-Host "PROJECT: $Project"
Write-Host "WORKER : $Worker"
Write-Host "TASK   : $TaskId"
Write-Host "STATUS : $($Result.status)"
Write-Host ""

switch ($Result.status) {
"SUCCESS" {

    Write-Host "ORCHESTRATOR : SUCCESS"
    Write-Host "TASK         : CLOSED"
}

"PARTIAL_SUCCESS" {

    Write-Host "ORCHESTRATOR : PARTIAL_SUCCESS"
}

"NEEDS_HUMAN" {

    Write-Host "ORCHESTRATOR : NEEDS_HUMAN"
    Write-Host "ACTION       : KADER"
}

"BLOCKED" {

    Write-Host "ORCHESTRATOR : BLOCKED"
}

default {

    Write-Host "ORCHESTRATOR : $($Result.status)"
}
}

Write-Host ""
Write-Host "RESULT FILE : $ResultFile"
Write-Host ""

Write-Host "============================================"
Write-Host " PHASE 7C COMPLETE"
Write-Host "============================================"
Write-Host ""

exit 0


