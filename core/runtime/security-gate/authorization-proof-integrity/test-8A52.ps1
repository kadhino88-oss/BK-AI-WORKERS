$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Module = Join-Path $Root "core\runtime\security-gate\authorization-proof-integrity\Authorization-Proof-Integrity-Guard.ps1"
$State = Join-Path $Root "core\runtime\security-gate\authorization-proof-integrity\state\authorization-proofs.json"

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

function C {
    return @{
        TenantId = "TEN-52"
        ClientId = "CLI-52"
        ProjectId = "PROJ-52"
        ExecutionId = "EXEC-52-" + [guid]::NewGuid().ToString("N")
        UserId = "USER-52"
    }
}

Reset-AuthorizationProofs

$c = C

T "Module présent" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) { throw "MODULE_MISSING" }
} $false

T "Hash autorisation déterministe" {
    $a = Get-AuthorizationProofHash -Context $c -Decision "ALLOW" -Action "AI_EXECUTION"
    $b = Get-AuthorizationProofHash -Context $c -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($a -ne $b) { throw "HASH_NON_DETERMINISTIC" }
} $false

T "Tenant manquant bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.Remove("TenantId")
    Get-AuthorizationProofHash -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
} $true

T "Client manquant bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.Remove("ClientId")
    Get-AuthorizationProofHash -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
} $true

T "Project manquant bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.Remove("ProjectId")
    Get-AuthorizationProofHash -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
} $true

T "Execution manquante bloquée" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.Remove("ExecutionId")
    Get-AuthorizationProofHash -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
} $true

T "User manquant bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.Remove("UserId")
    Get-AuthorizationProofHash -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
} $true

T "Decision manquante bloquée" {
    Get-AuthorizationProofHash -Context $c -Decision "" -Action "AI_EXECUTION"
} $true

T "Action manquante bloquée" {
    Get-AuthorizationProofHash -Context $c -Decision "ALLOW" -Action ""
} $true

T "Refus non enregistrable" {
    Register-AuthorizationProof -Context $c -Decision "BLOCK" -Action "AI_EXECUTION"
} $true

T "Preuve ALLOW enregistrée" {
    Register-AuthorizationProof -Context $c -Decision "ALLOW" -Action "AI_EXECUTION"
} $false

T "Preuve valide" {
    $r = Test-AuthorizationProof -Context $c -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($r.Valid -ne $true -or $r.Decision -ne "ALLOW") { throw "PROOF_INVALID" }
} $false

T "Execution inconnue bloquée" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.ExecutionId = "EXEC-UNKNOWN"
    $r = Test-AuthorizationProof -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($r.Valid) { throw "UNKNOWN_EXECUTION_ALLOWED" }
} $false

T "Tenant modifié bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.TenantId = "TEN-OTHER"
    $r = Test-AuthorizationProof -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($r.Valid) { throw "TENANT_BYPASS" }
} $false

T "Client modifié bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.ClientId = "CLI-OTHER"
    $r = Test-AuthorizationProof -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($r.Valid) { throw "CLIENT_BYPASS" }
} $false

T "Project modifié bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.ProjectId = "PROJ-OTHER"
    $r = Test-AuthorizationProof -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($r.Valid) { throw "PROJECT_BYPASS" }
} $false

T "User modifié bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.UserId = "USER-OTHER"
    $r = Test-AuthorizationProof -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($r.Valid) { throw "USER_BYPASS" }
} $false

T "Action modifiée bloquée" {
    $r = Test-AuthorizationProof -Context $c -Decision "ALLOW" -Action "OTHER_ACTION"
    if ($r.Valid) { throw "ACTION_BYPASS" }
} $false

T "Decision BLOCK non valide" {
    $r = Test-AuthorizationProof -Context $c -Decision "BLOCK" -Action "AI_EXECUTION"
    if ($r.Valid) { throw "BLOCK_ACCEPTED" }
} $false

T "Preuve verrouillée" {
    $data = Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
    $record = @($data.proofs | Where-Object { $_.ExecutionId -eq $c.ExecutionId })
    if ($record.Count -ne 1 -or $record[0].Locked -ne $true) { throw "PROOF_NOT_LOCKED" }
} $false

T "Hash enregistré présent" {
    $data = Get-Content -LiteralPath $State -Raw -Encoding UTF8 | ConvertFrom-Json
    $record = @($data.proofs | Where-Object { $_.ExecutionId -eq $c.ExecutionId })
    if ([string]::IsNullOrWhiteSpace([string]$record[0].ProofHash)) { throw "HASH_EMPTY" }
} $false

T "Doublon cohérent réutilise la preuve" {
    $a = Register-AuthorizationProof -Context $c -Decision "ALLOW" -Action "AI_EXECUTION"
    $b = Register-AuthorizationProof -Context $c -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($a.ProofHash -ne $b.ProofHash) { throw "REUSE_HASH_MISMATCH" }
} $false

T "Doublon incohérent bloqué" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.UserId = "USER-OTHER"
    Register-AuthorizationProof -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
} $true

T "Etat JSON présent" {
    if (-not (Test-Path -LiteralPath $State -PathType Leaf)) { throw "STATE_MISSING" }
} $false

T "Fail-closed preuve absente" {
    $x = @{}; foreach ($k in $c.Keys) { $x[$k] = $c[$k] }
    $x.ExecutionId = "EXEC-NOT-REGISTERED"
    $r = Test-AuthorizationProof -Context $x -Decision "ALLOW" -Action "AI_EXECUTION"
    if ($r.Decision -ne "BLOCK") { throw "FAIL_CLOSED_BROKEN" }
} $false

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-52" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ("TOTAL TESTS : {0}" -f $script:i)
Write-Host ("PASS        : {0}" -f $script:p) -ForegroundColor Green
Write-Host ("FAIL        : {0}" -f $script:f) -ForegroundColor Red
Write-Host ""

if (($script:i -eq 24) -and ($script:p -eq 24) -and ($script:f -eq 0)) {
    Write-Host "8A-52 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8A-52 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "8A-52 - FIN" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"