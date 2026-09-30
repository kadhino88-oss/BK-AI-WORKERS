$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Module = Join-Path $Root "core\runtime\security-gate\execution-context-integrity\Execution-Context-Integrity-Guard.ps1"
$SecureEntry = Join-Path $Root "core\ai\AI-SECURE-ENTRY-GUARD.ps1"
$State = Join-Path $Root "core\runtime\security-gate\execution-context-integrity\state\bindings.json"

. $Module

$script:i = 0
$script:p = 0
$script:f = 0

function T {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [bool]$ExpectThrow
    )

    $script:i++

    try {
        & $Action | Out-Null

        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:i,$Name) -ForegroundColor Red
            $script:f++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:i,$Name) -ForegroundColor Green
            $script:p++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1} -> {2}" -f $script:i,$Name,$_.Exception.Message) -ForegroundColor Green
            $script:p++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:i,$Name,$_.Exception.Message) -ForegroundColor Red
            $script:f++
        }
    }
}

function New-Context {
    return @{
        TenantId = "TEN-51"
        ClientId = "CLI-51"
        ProjectId = "PROJ-51"
        ExecutionId = "EXEC-51-" + [guid]::NewGuid().ToString("N")
        UserId = "USER-51"
    }
}

Reset-ExecutionContexts

# CONTEXTE UNIQUE DE REFERENCE
$Reference = New-Context

T "Module présent" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

T "Champs identité complets acceptés" {
    Get-ExecutionContextHash -Context $Reference
} $false

T "Hash déterministe" {
    $a = Get-ExecutionContextHash -Context $Reference
    $b = Get-ExecutionContextHash -Context $Reference
    if ($a -ne $b) {
        throw "HASH_NOT_DETERMINISTIC"
    }
} $false

T "Tenant manquant bloqué" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.Remove("TenantId")
    Get-ExecutionContextHash -Context $c
} $true

T "Client manquant bloqué" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.Remove("ClientId")
    Get-ExecutionContextHash -Context $c
} $true

T "Project manquant bloqué" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.Remove("ProjectId")
    Get-ExecutionContextHash -Context $c
} $true

T "Execution manquante bloquée" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.Remove("ExecutionId")
    Get-ExecutionContextHash -Context $c
} $true

T "User manquant bloqué" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.Remove("UserId")
    Get-ExecutionContextHash -Context $c
} $true

T "Enregistrement initial autorisé" {
    Register-ExecutionContext -Context $Reference
} $false

T "Contexte enregistré valide" {
    $r = Test-ExecutionContext -Context $Reference
    if ($r.Valid -ne $true -or $r.Decision -ne "ALLOW") {
        throw "CONTEXT_NOT_VALID"
    }
} $false

T "Modification Tenant bloquée" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.TenantId = "TEN-OTHER"
    $r = Test-ExecutionContext -Context $c
    if ($r.Valid -eq $true) {
        throw "TENANT_BYPASS"
    }
} $false

T "Modification Client bloquée" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.ClientId = "CLI-OTHER"
    $r = Test-ExecutionContext -Context $c
    if ($r.Valid -eq $true) {
        throw "CLIENT_BYPASS"
    }
} $false

T "Modification Project bloquée" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.ProjectId = "PROJ-OTHER"
    $r = Test-ExecutionContext -Context $c
    if ($r.Valid -eq $true) {
        throw "PROJECT_BYPASS"
    }
} $false

T "Modification User bloquée" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.UserId = "USER-OTHER"
    $r = Test-ExecutionContext -Context $c
    if ($r.Valid -eq $true) {
        throw "USER_BYPASS"
    }
} $false

T "ExecutionId inconnue bloquée" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.ExecutionId = "EXEC-UNKNOWN"
    $r = Test-ExecutionContext -Context $c
    if ($r.Valid -eq $true) {
        throw "EXECUTION_BYPASS"
    }
} $false

T "ExecutionId enregistrée incohérente bloquée" {
    $c = @{}
    foreach ($k in $Reference.Keys) { $c[$k] = $Reference[$k] }
    $c.UserId = "USER-OTHER"

    $r = Test-ExecutionContext -Context $c

    if ($r.Valid -eq $true) {
        throw "MISMATCH_ACCEPTED"
    }

    if ($r.Reason -ne "EXECUTION_CONTEXT_MISMATCH") {
        throw "UNEXPECTED_REASON:$($r.Reason)"
    }
} $false

T "Contexte vide bloqué" {
    Test-ExecutionContext -Context @{}
} $true

T "Etat JSON créé" {
    if (-not (Test-Path -LiteralPath $State -PathType Leaf)) {
        throw "STATE_MISSING"
    }
} $false

T "Secure Entry contient ExecutionId" {
    $t = Get-Content -LiteralPath $SecureEntry -Raw -Encoding UTF8
    if ($t -notmatch "ExecutionId") {
        throw "EXECUTION_ID_NOT_BOUND"
    }
} $false

T "Secure Entry contient TenantId" {
    $t = Get-Content -LiteralPath $SecureEntry -Raw -Encoding UTF8
    if ($t -notmatch "TenantId") {
        throw "TENANT_NOT_BOUND"
    }
} $false

T "Secure Entry contient ContextHash" {
    $t = Get-Content -LiteralPath $SecureEntry -Raw -Encoding UTF8
    if ($t -notmatch "ContextHash") {
        throw "CONTEXT_HASH_NOT_RETURNED"
    }
} $false

T "Secure Entry fail-closed contexte incomplet" {
    $t = Get-Content -LiteralPath $SecureEntry -Raw -Encoding UTF8
    if ($t -notmatch "GLOBAL_SECURITY_CONTEXT_INCOMPLETE") {
        throw "FAIL_CLOSED_MISSING"
    }
} $false

T "Hash enregistré non vide" {
    $records = Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
    $record = @($records.bindings | Where-Object { $_.ExecutionId -eq $Reference.ExecutionId })
    if ($record.Count -ne 1) {
        throw "REFERENCE_RECORD_MISSING"
    }
    if ([string]::IsNullOrWhiteSpace([string]$record[0].ContextHash)) {
        throw "CONTEXT_HASH_EMPTY"
    }
} $false

T "Etat verrouillé" {
    $r = Test-ExecutionContext -Context $Reference
    if ($r.Valid -ne $true) {
        throw "REFERENCE_CONTEXT_INVALID"
    }
    $records = Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
    $record = @($records.bindings | Where-Object { $_.ExecutionId -eq $Reference.ExecutionId })
    if ($record.Count -ne 1) {
        throw "REFERENCE_RECORD_COUNT:$($record.Count)"
    }
    if ($record[0].Locked -ne $true) {
        throw "CONTEXT_NOT_LOCKED"
    }
} $false

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-51" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL TESTS : {0}" -f $script:i)
Write-Host ("PASS        : {0}" -f $script:p) -ForegroundColor Green
Write-Host ("FAIL        : {0}" -f $script:f) -ForegroundColor Red
Write-Host ""

if (($script:i -eq 24) -and ($script:p -eq 24) -and ($script:f -eq 0)) {
    Write-Host "8A-51 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8A-51 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-51 - FIN" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"