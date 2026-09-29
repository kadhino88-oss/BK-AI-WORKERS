$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$File = Join-Path $Root "orchestrator\runtime\Invoke-Orchestrator.ps1"

$Total = 0
$Pass = 0
$Fail = 0
$Unknown = 0

function Result {
    param(
        [string]$Name,
        [ValidateSet("PASS","FAIL","UNKNOWN")]
        [string]$Status,
        [string]$Reason = ""
    )

    $script:Total++

    switch ($Status) {
        "PASS" {
            $script:Pass++
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$Name)
        }
        "FAIL" {
            $script:Fail++
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$Name,$Reason)
        }
        "UNKNOWN" {
            $script:Unknown++
            Write-Host ("[{0:00}] [UNKNOWN] {1} -> {2}" -f $script:Total,$Name,$Reason)
        }
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "ORCHESTRATOR IDENTITY RED-TEAM AUDIT"
Write-Host "============================================================"

# 01
if (Test-Path -LiteralPath $File -PathType Leaf) {
    Result "Invoke-Orchestrator present" "PASS"
}
else {
    Result "Invoke-Orchestrator present" "FAIL" "MISSING"
}

if (Test-Path -LiteralPath $File -PathType Leaf) {

    # 02
    $Tokens = $null
    $Errors = $null

    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $File,
        [ref]$Tokens,
        [ref]$Errors
    )

    if ($Errors.Count -eq 0) {
        Result "Invoke-Orchestrator parses" "PASS"
    }
    else {
        Result "Invoke-Orchestrator parses" "FAIL" "PARSE_ERROR"
    }

    $Source = Get-Content -LiteralPath $File -Raw -Encoding UTF8

    # 03-06 : identity declarations/usages
    foreach ($Identity in @("TenantId","ClientId","ProjectId","ExecutionId")) {

        $Found = $Source -match ("\b" + $Identity + "\b")

        if ($Found) {
            Result "Identity $Identity present" "PASS"
        }
        else {
            Result "Identity $Identity present" "FAIL" "IDENTITY_NOT_FOUND"
        }
    }

    # 07 : security boundary
    if (
        ($Source -match "Invoke-GlobalSecurityGate") -or
        ($Source -match "Assert-GlobalSecurityGate") -or
        ($Source -match "Invoke-Secure-Execution") -or
        ($Source -match "Invoke-AISecureAuthorization")
    ) {
        Result "Security boundary referenced" "PASS"
    }
    else {
        Result "Security boundary referenced" "UNKNOWN" "NOT_DIRECTLY_DEMONSTRATED"
    }

    # 08 : capability/security context
    if (
        ($Source -match "CapabilityAuthorized") -or
        ($Source -match "AuthorizationValid") -or
        ($Source -match "ScopeValid")
    ) {
        Result "Authorization context referenced" "PASS"
    }
    else {
        Result "Authorization context referenced" "UNKNOWN" "NOT_DIRECTLY_DEMONSTRATED"
    }

    # 09 : tenant/client/project/execution appear in same source
    if (
        ($Source -match "TenantId") -and
        ($Source -match "ClientId") -and
        ($Source -match "ProjectId") -and
        ($Source -match "ExecutionId")
    ) {
        Result "Complete execution identity surface present" "PASS"
    }
    else {
        Result "Complete execution identity surface present" "FAIL" "INCOMPLETE_IDENTITY_SURFACE"
    }

    # 10 : hardcoded identity detection
    $Hardcoded = (
        ($Source -match '\$TenantId\s*=\s*["''][^"'']+["'']') -or
        ($Source -match '\$ClientId\s*=\s*["''][^"'']+["'']') -or
        ($Source -match '\$ProjectId\s*=\s*["''][^"'']+["'']') -or
        ($Source -match '\$ExecutionId\s*=\s*["''][^"'']+["'']')
    )

    if (-not $Hardcoded) {
        Result "No obvious hardcoded execution identity" "PASS"
    }
    else {
        Result "No obvious hardcoded execution identity" "FAIL" "HARDCODED_IDENTITY"
    }

    # 11-14 : AST variables
    foreach ($Identity in @("TenantId","ClientId","ProjectId","ExecutionId")) {

        $Matches = @(
            $Ast.FindAll({
                param($Node)

                if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
                    return ($Node.VariablePath.UserPath -eq $Identity)
                }

                return $false
            }, $true)
        )

        if ($Matches.Count -gt 0) {
            Result "AST variable usage: $Identity" "PASS"
        }
        else {
            Result "AST variable usage: $Identity" "FAIL" "VARIABLE_NOT_FOUND"
        }
    }

    # 15-18 : security-sensitive AST commands
    $SecurityCommands = @(
        "Invoke-GlobalSecurityGate",
        "Assert-GlobalSecurityGate",
        "Invoke-Secure-Execution",
        "Invoke-AISecureAuthorization"
    )

    foreach ($CommandName in $SecurityCommands) {

        $Found = @(
            $Ast.FindAll({
                param($Node)

                if ($Node -is [System.Management.Automation.Language.CommandAst]) {

                    if ($Node.CommandElements.Count -gt 0) {

                        $First = $Node.CommandElements[0]

                        if ($First -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            return ($First.Value -eq $CommandName)
                        }
                    }
                }

                return $false
            }, $true)
        )

        if ($Found.Count -gt 0) {
            Result "Security command AST: $CommandName" "PASS"
        }
        else {
            Result "Security command AST: $CommandName" "UNKNOWN" "NOT_DIRECTLY_CALLED"
        }
    }

    # 19 : direct process/network primitives
    $Dangerous = @(
        "Invoke-WebRequest",
        "Invoke-RestMethod",
        "Start-Process",
        "Start-BitsTransfer"
    )

    $DangerousFound = @()

    foreach ($CommandName in $Dangerous) {

        $Found = @(
            $Ast.FindAll({
                param($Node)

                if ($Node -is [System.Management.Automation.Language.CommandAst]) {

                    if ($Node.CommandElements.Count -gt 0) {

                        $First = $Node.CommandElements[0]

                        if ($First -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            return ($First.Value -eq $CommandName)
                        }
                    }
                }

                return $false
            }, $true)
        )

        if ($Found.Count -gt 0) {
            $DangerousFound += $CommandName
        }
    }

    if ($DangerousFound.Count -eq 0) {
        Result "No direct network/process primitive" "PASS"
    }
    else {
        Result "No direct network/process primitive" "FAIL" ($DangerousFound -join ",")
    }

    # 20 : dynamic execution
    if (
        ($Source -notmatch "\bInvoke-Expression\b") -and
        ($Source -notmatch "(?m)^\s*\biex\b") -and
        ($Source -notmatch "FromBase64String") -and
        ($Source -notmatch "\[ScriptBlock\]::Create") -and
        ($Source -notmatch "\bAdd-Type\b")
    ) {
        Result "No obvious dynamic code execution" "PASS"
    }
    else {
        Result "No obvious dynamic code execution" "FAIL" "DYNAMIC_EXECUTION_PATTERN"
    }

    # 21 : source cannot self-authorize LIVE by literal production switch
    if (
        ($Source -notmatch '\$ProductionFlag\s*=\s*\$true') -and
        ($Source -notmatch '\$LiveExecutionAllowed\s*=\s*\$true')
    ) {
        Result "No obvious hardcoded LIVE enablement" "PASS"
    }
    else {
        Result "No obvious hardcoded LIVE enablement" "FAIL" "LIVE_ENABLEMENT_PATTERN"
    }

    # 22 : four identities appear in a callable function context
    $Functions = @(
        $Ast.FindAll({
            param($Node)
            return ($Node -is [System.Management.Automation.Language.FunctionDefinitionAst])
        }, $true)
    )

    $IdentityAwareFunction = $false

    foreach ($Function in $Functions) {

        $Text = $Function.Extent.Text

        if (
            ($Text -match "\bTenantId\b") -and
            ($Text -match "\bClientId\b") -and
            ($Text -match "\bProjectId\b") -and
            ($Text -match "\bExecutionId\b")
        ) {
            $IdentityAwareFunction = $true
            break
        }
    }

    if ($IdentityAwareFunction) {
        Result "Identity-aware callable function detected" "PASS"
    }
    else {
        Result "Identity-aware callable function detected" "UNKNOWN" "FUNCTION_BOUNDARY_NOT_DEMONSTRATED"
    }

    # 23 : execution path must not contain explicit backup reference
    if ($Source -match '(?i)[\\/]+backups?[\\/]') {
        Result "No backup dependency in orchestrator" "FAIL" "BACKUP_REFERENCE_FOUND"
    }
    else {
        Result "No backup dependency in orchestrator" "PASS"
    }

    # 24 : final multi-tenant isolation evidence
    if (
        ($Source -match "TenantId") -and
        ($Source -match "ClientId") -and
        ($Source -match "ProjectId") -and
        ($Source -match "ExecutionId") -and
        (
            ($Source -match "Invoke-GlobalSecurityGate") -or
            ($Source -match "Invoke-Secure-Execution") -or
            ($Source -match "Invoke-AISecureAuthorization")
        )
    ) {
        Result "Orchestrator identity/security integration surface" "PASS"
    }
    else {
        Result "Orchestrator identity/security integration surface" "UNKNOWN" "INTEGRATION_NOT_FULLY_DEMONSTRATED"
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT ORCHESTRATOR IDENTITY AUDIT"
Write-Host "============================================================"
Write-Host ("TOTAL CHECKS : {0}" -f $Total)
Write-Host ("PASS         : {0}" -f $Pass)
Write-Host ("FAIL         : {0}" -f $Fail)
Write-Host ("UNKNOWN      : {0}" -f $Unknown)
Write-Host ""

if (($Fail -eq 0) -and ($Unknown -eq 0) -and ($Total -eq 24)) {
    Write-Host "ORCHESTRATOR IDENTITY : VALIDEE - 24/24" -ForegroundColor Green
}
elseif ($Fail -gt 0) {
    Write-Host "ORCHESTRATOR IDENTITY : NON VALIDEE" -ForegroundColor Red
}
else {
    Write-Host "ORCHESTRATOR IDENTITY : NON VALIDEE - UNKNOWN PRESENT" -ForegroundColor Yellow
}

Write-Host "============================================================"
Write-Host "ORCHESTRATOR IDENTITY AUDIT - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"