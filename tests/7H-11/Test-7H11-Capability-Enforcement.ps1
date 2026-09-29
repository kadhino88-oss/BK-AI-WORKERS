$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Enforcer = Join-Path $Root "core\permissions\capability-matrix\CAPABILITY-ENFORCER.ps1"
$Router = Join-Path $Root "core\tools\TOOL-ROUTER-ENFORCED.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "      7H-11 CAPABILITY ENFORCEMENT TESTS" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $Enforcer)) {
    throw "Enforcer introuvable."
}

if (-not (Test-Path -LiteralPath $Router)) {
    throw "Router enforced introuvable."
}

$Tests = @(
    @{
        Name = "MAYA CRM READ - AUTORISE"
        Worker = "MAYA"
        Skill = "CRM_AUTOMATION"
        Tool = "CRM"
        Action = "READ"
        Expected = "AUTHORIZED"
    },
    @{
        Name = "MAYA CRM UPDATE - AUTORISE"
        Worker = "MAYA"
        Skill = "CRM_AUTOMATION"
        Tool = "CRM"
        Action = "UPDATE"
        Expected = "AUTHORIZED"
    },
    @{
        Name = "LUCAS WORDPRESS PUBLISH - AUTORISE"
        Worker = "LUCAS"
        Skill = "WEBMASTER"
        Tool = "WORDPRESS"
        Action = "PUBLISH"
        Expected = "AUTHORIZED"
    },
    @{
        Name = "SAM CRM UPDATE - REFUSE"
        Worker = "SAM"
        Skill = "SECURITY"
        Tool = "CRM"
        Action = "UPDATE"
        Expected = "DENIED"
    },
    @{
        Name = "NOAH SECURITY SCANNER EXECUTE - REFUSE"
        Worker = "NOAH"
        Skill = "ADMINISTRATION"
        Tool = "SECURITY_SCANNER"
        Action = "EXECUTE"
        Expected = "DENIED"
    },
    @{
        Name = "MAYA WORDPRESS PUBLISH - REFUSE"
        Worker = "MAYA"
        Skill = "STRATEGIE"
        Tool = "WORDPRESS"
        Action = "PUBLISH"
        Expected = "DENIED"
    },
    @{
        Name = "FINANCIAL COMMIT - HUMAIN"
        Worker = "MAYA"
        Skill = "STRATEGIE"
        Tool = "PAYMENTS"
        Action = "FINANCIAL_COMMIT"
        Expected = "NEEDS_HUMAN"
    }
)

$Passed = 0
$Failed = 0

foreach ($Test in $Tests) {

    Write-Host ""
    Write-Host "TEST : $($Test.Name)" -ForegroundColor White

    $Result = & $Enforcer `
        -WorkerId $Test.Worker `
        -SkillId $Test.Skill `
        -ToolId $Test.Tool `
        -Action $Test.Action `
        -ClientId "CLIENT-DEMO-001" `
        -ProjectId "PROJECT-DEMO-001" `
        -Mode "SIMULATION"

    if ($null -eq $Result) {
        Write-Host "FAIL : aucune reponse." -ForegroundColor Red
        $Failed++
        continue
    }

    Write-Host "Decision : $($Result.decision)"
    Write-Host "Status   : $($Result.status)"
    Write-Host "Raison   : $($Result.reason)"

    if ($Result.decision -eq $Test.Expected) {
        Write-Host "PASS" -ForegroundColor Green
        $Passed++
    }
    else {
        Write-Host "FAIL - Attendu : $($Test.Expected)" -ForegroundColor Red
        $Failed++
    }
}

# ------------------------------------------------------------
# TEST ISOLATION
# ------------------------------------------------------------

Write-Host ""
Write-Host "TEST : CLIENTID VIDE - REFUSE" -ForegroundColor White

$IsolationResult = & $Enforcer `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ClientId "" `
    -ProjectId "PROJECT-DEMO-001" `
    -Mode "SIMULATION"

if ($IsolationResult.status -eq "BLOCKED") {
    Write-Host "PASS" -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ------------------------------------------------------------
# TEST PROJECTID VIDE
# ------------------------------------------------------------

Write-Host ""
Write-Host "TEST : PROJECTID VIDE - REFUSE" -ForegroundColor White

$ProjectResult = & $Enforcer `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ClientId "CLIENT-DEMO-001" `
    -ProjectId "" `
    -Mode "SIMULATION"

if ($ProjectResult.status -eq "BLOCKED") {
    Write-Host "PASS" -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ------------------------------------------------------------
# RESULTAT
# ------------------------------------------------------------

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-11" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

Write-Host "PASS : $Passed" -ForegroundColor Green
Write-Host "FAIL : $Failed" -ForegroundColor Red
Write-Host ""

if ($Failed -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Capability Enforcement opérationnel." -ForegroundColor Green
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1