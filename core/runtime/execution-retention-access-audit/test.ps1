$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-retention-access-audit"

. (Join-Path $Dir "runtime.ps1")

$Pass = 0
$Fail = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition
    )

    if ($Condition) {
        Write-Host "[PASS] $Name"
        $script:Pass++
    }
    else {
        Write-Host "[FAIL] $Name"
        $script:Fail++
    }
}

$DecisionId  = "DEC-7901"
$RetentionId = "RET-7901"
$TenantId    = "TEN-01"
$ClientId    = "CLI-01"
$ProjectId   = "PROJ-01"

$null = Reset-RetentionAccessAudit

# 1
$cfg = Get-RetentionAccessAuditConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Access audit enabled" (
    $cfg.accessAuditEnabled -eq $true
)

# 3
Assert-Test "Decision trace enabled" (
    $cfg.decisionTraceEnabled -eq $true
)

# 4
Assert-Test "Duplicate decision protection enabled" (
    $cfg.allowDuplicateDecision -eq $false
)

# 5
$state = @(Get-RetentionAccessAuditRecords)

Assert-Test "Initial state empty" (
    $state.Length -eq 0
)

# 6
$valid = Test-RetentionAccessDecisionContext `
    -DecisionId $DecisionId `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "ALLOW"

Assert-Test "Valid decision context accepted" (
    $valid.Success -eq $true
)

# 7
$missingDecisionId = Test-RetentionAccessDecisionContext `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "ALLOW"

Assert-Test "Missing DecisionId blocked" (
    $missingDecisionId.Reason -eq "DECISION_ID_REQUIRED"
)

# 8
$missingTenant = Test-RetentionAccessDecisionContext `
    -DecisionId $DecisionId `
    -RetentionId $RetentionId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "ALLOW"

Assert-Test "Missing TenantId blocked" (
    $missingTenant.Reason -eq "TENANT_ID_REQUIRED"
)

# 9
$missingClient = Test-RetentionAccessDecisionContext `
    -DecisionId $DecisionId `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "ALLOW"

Assert-Test "Missing ClientId blocked" (
    $missingClient.Reason -eq "CLIENT_ID_REQUIRED"
)

# 10
$missingProject = Test-RetentionAccessDecisionContext `
    -DecisionId $DecisionId `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -Operation "READ" `
    -Decision "ALLOW"

Assert-Test "Missing ProjectId blocked" (
    $missingProject.Reason -eq "PROJECT_ID_REQUIRED"
)

# 11
$badOperation = Test-RetentionAccessDecisionContext `
    -DecisionId $DecisionId `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "EXECUTE" `
    -Decision "ALLOW"

Assert-Test "Invalid operation blocked" (
    $badOperation.Reason -eq "OPERATION_INVALID"
)

# 12
$badDecision = Test-RetentionAccessDecisionContext `
    -DecisionId $DecisionId `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "PENDING"

Assert-Test "Invalid decision blocked" (
    $badDecision.Reason -eq "DECISION_INVALID"
)

# 13
$registered = Register-RetentionAccessDecision `
    -DecisionId $DecisionId `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "ALLOW"

Assert-Test "Decision registered" (
    $registered.Success -eq $true
)

# 14
Assert-Test "Decision status recorded" (
    $registered.Status -eq "RECORDED"
)

# 15
$loaded = Get-RetentionAccessAuditRecord `
    -DecisionId $DecisionId

Assert-Test "Decision retrievable" (
    $null -ne $loaded
)

# 16
Assert-Test "Tenant preserved" (
    $loaded.TenantId -eq $TenantId
)

# 17
Assert-Test "Client preserved" (
    $loaded.ClientId -eq $ClientId
)

# 18
Assert-Test "Project preserved" (
    $loaded.ProjectId -eq $ProjectId
)

# 19
$trace = Test-RetentionAccessDecisionTrace `
    -DecisionId $DecisionId

Assert-Test "Decision trace valid" (
    $trace.Success -eq $true -and
    $trace.Decision -eq "ALLOW"
)

# 20
$duplicate = Register-RetentionAccessDecision `
    -DecisionId "DEC-7902" `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "ALLOW"

Assert-Test "Duplicate access decision blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# 21
$contradictory = Register-RetentionAccessDecision `
    -DecisionId "DEC-7903" `
    -RetentionId $RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Operation "READ" `
    -Decision "BLOCK"

Assert-Test "Contradictory decision blocked" (
    $contradictory.Status -eq "BLOCKED" -and
    $contradictory.Reason -eq "CONTRADICTORY_DECISION_BLOCKED"
)

# 22
$unknown = Test-RetentionAccessDecisionTrace `
    -DecisionId "UNKNOWN-DECISION"

Assert-Test "Unknown decision blocked" (
    $unknown.Reason -eq "DECISION_NOT_FOUND"
)

# 23
$records = @(Get-RetentionAccessAuditRecords)

Assert-Test "Exactly one decision persisted" (
    $records.Length -eq 1 -and
    $records[0].DecisionId -eq $DecisionId
)

# 24
$null = Reset-RetentionAccessAudit

$empty = @(Get-RetentionAccessAuditRecords)

Assert-Test "Access audit state reset" (
    $empty.Length -eq 0
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-79"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"