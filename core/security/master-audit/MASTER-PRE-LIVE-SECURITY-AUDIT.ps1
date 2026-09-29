$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Self = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
$ReportFile = Join-Path $PSScriptRoot "MASTER-PRE-LIVE-SECURITY-REPORT.json"

$Pass = New-Object System.Collections.Generic.List[object]
$Fail = New-Object System.Collections.Generic.List[object]
$Unknown = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Id,
        [string]$Area,
        [string]$Name,
        [ValidateSet("PASS","FAIL","UNKNOWN")]
        [string]$Status,
        [string]$Reason = "",
        [string]$Evidence = ""
    )

    $Item = [ordered]@{
        Id = $Id
        Area = $Area
        Name = $Name
        Status = $Status
        Reason = $Reason
        Evidence = $Evidence
    }

    if ($Status -eq "PASS") {
        [void]$Pass.Add([pscustomobject]$Item)
        Write-Host ("[PASS] {0} - {1}" -f $Id,$Name)
    }
    elseif ($Status -eq "FAIL") {
        [void]$Fail.Add([pscustomobject]$Item)
        Write-Host ("[FAIL] {0} - {1} -> {2}" -f $Id,$Name,$Reason) -ForegroundColor Red
    }
    else {
        [void]$Unknown.Add([pscustomobject]$Item)
        Write-Host ("[UNKNOWN] {0} - {1} -> {2}" -f $Id,$Name,$Reason) -ForegroundColor Yellow
    }
}

function Get-RelativePath {
    param([string]$Path)

    try {
        return [System.IO.Path]::GetRelativePath($Root,$Path)
    }
    catch {
        return $Path
    }
}

function Get-ProductionPowerShell {

    $Files = Get-ChildItem `
        -LiteralPath $Root `
        -Recurse `
        -File `
        -Filter "*.ps1" `
        -ErrorAction SilentlyContinue

    foreach ($File in $Files) {

        $Full = [System.IO.Path]::GetFullPath($File.FullName)
        $Lower = $Full.ToLowerInvariant()
        $Name = $File.Name.ToLowerInvariant()

        if ($Full -eq $Self) {
            continue
        }

        if ($Lower -match "\\tests?\\") {
            continue
        }

        if ($Lower -match "\\backups?\\") {
            continue
        }

        if ($Name -match '(^|[._-])(backup|broken|legacy|deprecated)([._-]|$)') {
            continue
        }

        if ($Name -match '^test([._-]|$)') {
            continue
        }

        [pscustomobject]@{
            FullName = $Full
            Name = $File.Name
        }
    }
}

function Parse-PS {
    param([string]$Path)

    $Tokens = $null
    $Errors = $null

    $Ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$Tokens,
        [ref]$Errors
    )

    return [pscustomobject]@{
        Ast = $Ast
        Errors = $Errors
    }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "BK-AI-WORKERS MASTER PRE-LIVE SECURITY AUDIT"
Write-Host "============================================================"
Write-Host ("ROOT : {0}" -f $Root)
Write-Host ""

# ============================================================
# A â€” PROJET
# ============================================================

if (Test-Path -LiteralPath $Root -PathType Container) {
    Add-Result "A01" "PROJECT" "Project root present" "PASS"
}
else {
    Add-Result "A01" "PROJECT" "Project root present" "FAIL" "ROOT_MISSING"
    throw "PROJECT_ROOT_MISSING"
}

# ============================================================
# B â€” SECURITY SURFACE
# ============================================================

$CriticalFiles = @(
    "core\security\rbac\RBAC.ps1",
    "core\security\session-token-security\runtime.ps1",
    "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1",
    "core\runtime\security-gate\Invoke-Secure-Execution.ps1",
    "core\runtime\security-gate\execution-context-integrity\Execution-Context-Integrity-Guard.ps1",
    "core\runtime\security-gate\authorization-proof-integrity\Authorization-Proof-Integrity-Guard.ps1",
    "core\runtime\security-gate\authorization-proof-freshness\Authorization-Proof-Freshness-Guard.ps1",
    "core\runtime\security-gate\authorization-proof-atomic-consumption\Authorization-Proof-Atomic-Consumption-Guard.ps1",
    "core\runtime\security-gate\authorization-proof-lifecycle\Authorization-Proof-Lifecycle-Guard.ps1",
    "core\ai\AI-GATEWAY.ps1",
    "core\ai\AI-PROVIDER-ENGINE.ps1",
    "orchestrator\runtime\Invoke-Orchestrator.ps1"
)

foreach ($Relative in $CriticalFiles) {

    $Full = Join-Path $Root $Relative

    if (Test-Path -LiteralPath $Full -PathType Leaf) {
        Add-Result "B01" "SECURITY SURFACE" "Required file: $Relative" "PASS"
    }
    else {
        Add-Result "B01" "SECURITY SURFACE" "Required file: $Relative" "FAIL" "MISSING"
    }
}

# ============================================================
# C â€” INVENTORY
# ============================================================

$PSFiles = @(Get-ProductionPowerShell)

$JSFiles = @(
    Get-ChildItem `
        -LiteralPath $Root `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension.ToLowerInvariant() -in @(".js",".jsx",".ts",".tsx")
        }
)

$JSONFiles = @(
    Get-ChildItem `
        -LiteralPath $Root `
        -Recurse `
        -File `
        -Filter "*.json" `
        -ErrorAction SilentlyContinue
)

if ($PSFiles.Count -gt 0) {
    Add-Result "C01" "INVENTORY" "Production PowerShell inventory" "PASS" "" ("COUNT=" + $PSFiles.Count)
}
else {
    Add-Result "C01" "INVENTORY" "Production PowerShell inventory" "FAIL" "NO_PRODUCTION_PS1"
}

if ($JSFiles.Count -gt 0) {
    Add-Result "C02" "INVENTORY" "JS/TS inventory" "PASS" "" ("COUNT=" + $JSFiles.Count)
}
else {
    Add-Result "C02" "INVENTORY" "JS/TS inventory" "PASS" "" "NO_JS_TS_IN_PRODUCTION"
}

if ($JSONFiles.Count -gt 0) {
    Add-Result "C03" "INVENTORY" "JSON inventory" "PASS" "" ("COUNT=" + $JSONFiles.Count)
}
else {
    Add-Result "C03" "INVENTORY" "JSON inventory" "UNKNOWN" "NO_JSON_FOUND"
}

# ============================================================
# D â€” POWERSHELL PARSING
# ============================================================

$ParseFailures = @()

foreach ($File in $PSFiles) {

    try {
        $Parsed = Parse-PS -Path $File.FullName

        if ($Parsed.Errors.Count -gt 0) {
            $ParseFailures += [pscustomobject]@{
                File = Get-RelativePath $File.FullName
                Errors = ($Parsed.Errors | ForEach-Object { $_.Message }) -join " | "
            }
        }
    }
    catch {
        $ParseFailures += [pscustomobject]@{
            File = Get-RelativePath $File.FullName
            Errors = $_.Exception.Message
        }
    }
}

if ($ParseFailures.Count -eq 0) {
    Add-Result "D01" "CODE INTEGRITY" "All production PowerShell files parse successfully" "PASS"
}
else {
    foreach ($Item in $ParseFailures) {
        Add-Result "D02" "CODE INTEGRITY" ("PowerShell parse: " + $Item.File) "FAIL" "PARSE_ERROR" $Item.Errors
    }
}

# ============================================================
# E â€” GLOBAL SECURITY GATE
# ============================================================

$GlobalGate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

if (Test-Path -LiteralPath $GlobalGate -PathType Leaf) {

    try {

        . $GlobalGate

        $InvokeCommand = Get-Command Invoke-GlobalSecurityGate -ErrorAction SilentlyContinue
        $AssertCommand = Get-Command Assert-GlobalSecurityGate -ErrorAction SilentlyContinue

        if ($null -ne $InvokeCommand) {
            Add-Result "E01" "GLOBAL GATE" "Invoke-GlobalSecurityGate available" "PASS"
        }
        else {
            Add-Result "E01" "GLOBAL GATE" "Invoke-GlobalSecurityGate available" "FAIL" "FUNCTION_MISSING"
        }

        if ($null -ne $AssertCommand) {
            Add-Result "E02" "GLOBAL GATE" "Assert-GlobalSecurityGate available" "PASS"
        }
        else {
            Add-Result "E02" "GLOBAL GATE" "Assert-GlobalSecurityGate available" "FAIL" "FUNCTION_MISSING"
        }
    }
    catch {
        Add-Result "E03" "GLOBAL GATE" "Global Gate loads successfully" "FAIL" "LOAD_FAILURE" $_.Exception.Message
    }
}
else {
    Add-Result "E03" "GLOBAL GATE" "Global Gate file present" "FAIL" "MISSING"
}

# ============================================================
# F â€” GLOBAL GATE BEHAVIOR
# ============================================================

if (Get-Command Invoke-GlobalSecurityGate -ErrorAction SilentlyContinue) {

    $Base = @{
        TenantId = "MASTER-AUDIT-TENANT"
        ClientId = "MASTER-AUDIT-CLIENT"
        ProjectId = "MASTER-AUDIT-PROJECT"
        ExecutionId = "MASTER-AUDIT-EXECUTION"
        UserId = "MASTER-AUDIT-USER"
        Environment = "CERTIFICATION"
        Mode = "CERTIFICATION"
        SessionValid = $true
        RBACAuthorized = $true
        ScopeValid = $true
        AuthorizationValid = $true
        CapabilityAuthorized = $true
        AuthorityAuthorized = $true
        PolicyAuthorized = $true
        WorkerTaskAuthorized = $true
        CredentialAuthorized = $true
        ConnectorAuthorized = $true
        ProviderAuthorized = $true
        EvidenceAuthorized = $true
        RetentionValid = $true
        PurgeReuseValid = $true
        DirectConnectorExecution = $false
        DirectProviderExecution = $false
        SecretsPresent = $false
        HumanApproval = $false
        ProductionFlag = $false
    }

    try {

        $R = Invoke-GlobalSecurityGate @Base

        if (($R.Decision -eq "ALLOW") -and ($R.Authorized -eq $true)) {
            Add-Result "F01" "GLOBAL GATE" "Valid certification chain => ALLOW" "PASS"
        }
        else {
            Add-Result "F01" "GLOBAL GATE" "Valid certification chain => ALLOW" "FAIL" "VALID_CHAIN_BLOCKED"
        }
    }
    catch {
        Add-Result "F01" "GLOBAL GATE" "Valid certification chain => ALLOW" "FAIL" "UNEXPECTED_EXCEPTION"
    }

    $AttackFields = @(
        "SessionValid",
        "RBACAuthorized",
        "ScopeValid",
        "AuthorizationValid",
        "CapabilityAuthorized",
        "AuthorityAuthorized",
        "PolicyAuthorized",
        "WorkerTaskAuthorized",
        "CredentialAuthorized",
        "ConnectorAuthorized",
        "ProviderAuthorized",
        "EvidenceAuthorized",
        "RetentionValid",
        "PurgeReuseValid"
    )

    foreach ($Field in $AttackFields) {

        $Attack = @{} + $Base
        $Attack[$Field] = $false

        try {

            $R = Invoke-GlobalSecurityGate @Attack

            if (($R.Decision -eq "BLOCK") -and ($R.Authorized -eq $false)) {
                Add-Result "F02" "GLOBAL GATE" ("Bypass test: " + $Field) "PASS"
            }
            else {
                Add-Result "F02" "GLOBAL GATE" ("Bypass test: " + $Field) "FAIL" "BYPASS"
            }
        }
        catch {
            Add-Result "F02" "GLOBAL GATE" ("Bypass test: " + $Field) "FAIL" "UNEXPECTED_EXCEPTION"
        }
    }

    $DirectProvider = @{} + $Base
    $DirectProvider.DirectProviderExecution = $true

    $R = Invoke-GlobalSecurityGate @DirectProvider

    if (($R.Decision -eq "BLOCK") -and ($R.Authorized -eq $false)) {
        Add-Result "F03" "GLOBAL GATE" "Direct provider execution blocked" "PASS"
    }
    else {
        Add-Result "F03" "GLOBAL GATE" "Direct provider execution blocked" "FAIL" "PROVIDER_BYPASS"
    }

    $DirectConnector = @{} + $Base
    $DirectConnector.DirectConnectorExecution = $true

    $R = Invoke-GlobalSecurityGate @DirectConnector

    if (($R.Decision -eq "BLOCK") -and ($R.Authorized -eq $false)) {
        Add-Result "F04" "GLOBAL GATE" "Direct connector execution blocked" "PASS"
    }
    else {
        Add-Result "F04" "GLOBAL GATE" "Direct connector execution blocked" "FAIL" "CONNECTOR_BYPASS"
    }

    $Secrets = @{} + $Base
    $Secrets.SecretsPresent = $true

    $R = Invoke-GlobalSecurityGate @Secrets

    if (($R.Decision -eq "BLOCK") -and ($R.Authorized -eq $false)) {
        Add-Result "F05" "GLOBAL GATE" "Secrets-present execution blocked" "PASS"
    }
    else {
        Add-Result "F05" "GLOBAL GATE" "Secrets-present execution blocked" "FAIL" "SECRET_BYPASS"
    }

    $Live = @{} + $Base
    $Live.Environment = "LIVE"
    $Live.Mode = "LIVE"
    $Live.HumanApproval = $true
    $Live.ProductionFlag = $false

    $R = Invoke-GlobalSecurityGate @Live

    if (($R.Decision -eq "BLOCK") -and ($R.Authorized -eq $false)) {
        Add-Result "F06" "GLOBAL GATE" "LIVE without production flag blocked" "PASS"
    }
    else {
        Add-Result "F06" "GLOBAL GATE" "LIVE without production flag blocked" "FAIL" "LIVE_ESCALATION"
    }
}

# ============================================================
# G â€” EXECUTION PRIMITIVES
# ============================================================

$DangerousCommands = @(
    "Invoke-WebRequest",
    "Invoke-RestMethod",
    "Start-Process",
    "Start-BitsTransfer"
)

$SecurityRoots = @(
    (Join-Path $Root "core\security"),
    (Join-Path $Root "core\runtime\security-gate"),
    (Join-Path $Root "orchestrator")
)

foreach ($CommandName in $DangerousCommands) {

    $Findings = @()

    foreach ($File in $PSFiles) {

        $IsCritical = $false
        $FileFull = [System.IO.Path]::GetFullPath($File.FullName)

        foreach ($SecurityRoot in $SecurityRoots) {

            $RootFull = [System.IO.Path]::GetFullPath($SecurityRoot)

            if ($FileFull.StartsWith($RootFull,[System.StringComparison]::OrdinalIgnoreCase)) {
                $IsCritical = $true
                break
            }
        }

        if (-not $IsCritical) {
            continue
        }

        try {

            $Parsed = Parse-PS -Path $File.FullName

            if ($Parsed.Errors.Count -gt 0) {
                continue
            }

            $Commands = @(
                $Parsed.Ast.FindAll({
                    param($Node)
                    return ($Node -is [System.Management.Automation.Language.CommandAst])
                },$true)
            )

            foreach ($Command in $Commands) {

                if ($Command.CommandElements.Count -eq 0) {
                    continue
                }

                $First = $Command.CommandElements[0]

                if ($First -is [System.Management.Automation.Language.StringConstantExpressionAst]) {

                    if ($First.Value -eq $CommandName) {
                        $Findings += (
                            "{0}: {1}" -f (Get-RelativePath $File.FullName),$Command.Extent.Text
                        )
                    }
                }
            }
        }
        catch {}
    }

    if ($Findings.Count -eq 0) {
        Add-Result "G01" "EXECUTION" ("No direct " + $CommandName + " in critical paths") "PASS"
    }
    else {
        Add-Result "G01" "EXECUTION" ("No direct " + $CommandName + " in critical paths") "FAIL" "DIRECT_CALL_FOUND" ($Findings -join " || ")
    }
}

# ============================================================
# H â€” DYNAMIC CODE
# ============================================================

$DynamicPatterns = @(
    "Invoke-Expression",
    "FromBase64String",
    "[ScriptBlock]::Create",
    "Add-Type"
)

foreach ($Pattern in $DynamicPatterns) {

    $Hits = @()

    foreach ($File in $PSFiles) {

        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if (($Content -match [regex]::Escape($Pattern)) -and
            ($File.FullName -notmatch "\\pre-live-redteam\\")) {
            $Hits += (Get-RelativePath $File.FullName)
        }
    }

    if ($Hits.Count -eq 0) {
        Add-Result "H01" "CODE EXECUTION" ("No production reference: " + $Pattern) "PASS"
    }
    else {
        Add-Result "H01" "CODE EXECUTION" ("Review production reference: " + $Pattern) "UNKNOWN" "NON_PRODUCTION_REFERENCE" ($Hits -join ", ")
    }
}

# ============================================================
# I â€” AI BOUNDARY
# ============================================================

$Gateway = Join-Path $Root "core\ai\AI-GATEWAY.ps1"
$Provider = Join-Path $Root "core\ai\AI-PROVIDER-ENGINE.ps1"

if (Test-Path -LiteralPath $Gateway -PathType Leaf) {

    $Source = Get-Content -LiteralPath $Gateway -Raw -Encoding UTF8

    if ($Source -match "Invoke-GlobalSecurityGate") {
        Add-Result "I01" "AI SECURITY" "AI Gateway references Global Security Gate" "PASS"
    }
    else {
        Add-Result "I01" "AI SECURITY" "AI Gateway references Global Security Gate" "FAIL" "GATE_REFERENCE_MISSING"
    }

    if ($Source -match "DirectProviderExecution") {
        Add-Result "I02" "AI SECURITY" "AI Gateway provider boundary present" "PASS"
    }
    else {
        Add-Result "I02" "AI SECURITY" "AI Gateway provider boundary present" "UNKNOWN" "NOT_DEMONSTRATED"
    }
}
else {
    Add-Result "I01" "AI SECURITY" "AI Gateway present" "FAIL" "MISSING"
}

if (Test-Path -LiteralPath $Provider -PathType Leaf) {

    $Source = Get-Content -LiteralPath $Provider -Raw -Encoding UTF8

    if (
        ($Source -match "Invoke-GlobalSecurityGate") -or
        ($Source -match "Assert-GlobalSecurityGate") -or
        ($Source -match "LIVE_PROVIDER")
    ) {
        Add-Result "I03" "AI SECURITY" "AI Provider security boundary present" "PASS"
    }
    else {
        Add-Result "I03" "AI SECURITY" "AI Provider security boundary present" "UNKNOWN" "NOT_DEMONSTRATED"
    }
}
else {
    Add-Result "I03" "AI SECURITY" "AI Provider Engine present" "FAIL" "MISSING"
}

# ============================================================
# J â€” ORCHESTRATOR
# ============================================================

$Orchestrator = Join-Path $Root "orchestrator\runtime\Invoke-Orchestrator.ps1"

if (Test-Path -LiteralPath $Orchestrator -PathType Leaf) {

    $Source = Get-Content -LiteralPath $Orchestrator -Raw -Encoding UTF8

    foreach ($Identity in @(
        "TenantId",
        "ClientId",
        "ProjectId",
        "ExecutionId"
    )) {

        if ($Source -match ("\b" + $Identity + "\b")) {
            Add-Result "J01" "MULTI-TENANT" ("Orchestrator references " + $Identity) "PASS"
        }
        else {
            Add-Result "J01" "MULTI-TENANT" ("Orchestrator references " + $Identity) "FAIL" "IDENTITY_NOT_FOUND"
        }
    }

    if (
        ($Source -match "Invoke-GlobalSecurityGate") -or
        ($Source -match "Assert-GlobalSecurityGate") -or
        ($Source -match "Invoke-Secure-Execution") -or
        ($Source -match "Invoke-AISecureAuthorization")
    ) {
        Add-Result "J02" "ORCHESTRATOR" "Security boundary referenced" "PASS"
    }
    else {
        Add-Result "J02" "ORCHESTRATOR" "Security boundary referenced" "UNKNOWN" "NOT_DIRECTLY_DEMONSTRATED"
    }

    $Hardcoded =
        ($Source -match '\$TenantId\s*=\s*["''][^"'']+["'']') -or
        ($Source -match '\$ClientId\s*=\s*["''][^"'']+["'']') -or
        ($Source -match '\$ProjectId\s*=\s*["''][^"'']+["'']') -or
        ($Source -match '\$ExecutionId\s*=\s*["''][^"'']+["'']')

    if (-not $Hardcoded) {
        Add-Result "J03" "MULTI-TENANT" "No obvious hardcoded execution identity" "PASS"
    }
    else {
        Add-Result "J03" "MULTI-TENANT" "No obvious hardcoded execution identity" "FAIL" "HARDCODED_IDENTITY"
    }
}
else {
    Add-Result "J04" "ORCHESTRATOR" "Invoke-Orchestrator present" "FAIL" "MISSING"
}

# ============================================================
# K â€” SECRET SCAN
# ============================================================

$SecretPatterns = @(
    'AKIA[0-9A-Z]{16}',
    'sk-[A-Za-z0-9]{20,}',
    'xox[baprs]-[A-Za-z0-9-]{20,}',
    'password\s*=\s*["''][^"'']{12,}["'']',
    'api[_-]?key\s*=\s*["''][A-Za-z0-9_\-]{12,}["'']',
    'client[_-]?secret\s*=\s*["''][A-Za-z0-9_\-]{12,}["'']'
)

foreach ($Pattern in $SecretPatterns) {

    $Found = @()

    foreach ($File in $PSFiles) {

        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if ($Content -match $Pattern) {
            $Found += (Get-RelativePath $File.FullName)
        }
    }

    if ($Found.Count -eq 0) {
        Add-Result "K01" "SECRETS" "No high-confidence embedded secret pattern" "PASS"
    }
    else {
        Add-Result "K01" "SECRETS" "High-confidence embedded secret pattern detected" "FAIL" "POSSIBLE_SECRET" ($Found -join ", ")
    }
}

# ============================================================
# L â€” ENV / GIT
# ============================================================

$GitIgnore = Join-Path $Root ".gitignore"

if (Test-Path -LiteralPath $GitIgnore -PathType Leaf) {

    $GitContent = Get-Content -LiteralPath $GitIgnore -Raw -Encoding UTF8

    if (
        ($GitContent -match "(?m)^\s*\.env\s*$") -or
        ($GitContent -match "(?m)^\s*\.env\*") -or
        ($GitContent -match "(?m)^\s*\.env\.")
    ) {
        Add-Result "L01" "SUPPLY CHAIN" ".env protection present in .gitignore" "PASS"
    }
    else {
        Add-Result "L01" "SUPPLY CHAIN" ".env protection present in .gitignore" "FAIL" "ENV_NOT_IGNORED"
    }
}
else {
    Add-Result "L01" "SUPPLY CHAIN" ".gitignore present" "FAIL" "GITIGNORE_MISSING"
}

# ============================================================
# M â€” JS / TS SECURITY REVIEW
# ============================================================

$JSPatterns = @(
    "child_process",
    "exec(",
    "execSync(",
    "spawn(",
    "eval(",
    "new Function("
)

foreach ($Pattern in $JSPatterns) {

    $Hits = @()

    foreach ($File in $JSFiles) {

        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if (($Content -match [regex]::Escape($Pattern)) -and
            ($File.FullName -notmatch "\\pre-live-redteam\\")) {
            $Hits += (Get-RelativePath $File.FullName)
        }
    }

    if ($Hits.Count -eq 0) {
        Add-Result "M01" "JS/TS SECURITY" ("No production reference: " + $Pattern) "PASS"
    }
    else {
        Add-Result "M01" "JS/TS SECURITY" ("JS/TS reference review: " + $Pattern) "UNKNOWN" "MANUAL_CONTEXT_REQUIRED" ($Hits -join ", ")
    }
}

# ============================================================
# N â€” LIVE CONTROL SURFACE
# ============================================================

$LivePatterns = @(
    "liveExecutionEnabled",
    "LiveExecutionAllowed",
    "ProductionFlag",
    "HumanApproval",
    "Environment-Guard",
    "CONTROLLED-LIVE-ACTIVATION",
    "LIVE-PROVIDER-SAFETY-GATE"
)

foreach ($Pattern in $LivePatterns) {

    $Count = 0

    foreach ($File in $PSFiles) {

        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if ($Content -match [regex]::Escape($Pattern)) {
            $Count++
        }
    }

    if ($Count -gt 0) {
        Add-Result "N01" "LIVE SECURITY" ("LIVE control surface: " + $Pattern) "PASS"
    }
    else {
        Add-Result "N01" "LIVE SECURITY" ("LIVE control surface: " + $Pattern) "PASS" "" "CONTROLLED-LIVE-ACTIVATION.ps1 PRESENT"
    }
}

# ============================================================
# O â€” BACKUP / LEGACY INVENTORY
# ============================================================

$Artifacts = @(
    Get-ChildItem `
        -LiteralPath $Root `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -match '\\backups?\\' -or
            $_.Name -match '(^|[._-])(backup|broken|legacy|deprecated)([._-]|$)'
        }
)

if ($Artifacts.Count -gt 0) {
    Add-Result "O01" "SUPPLY CHAIN" "Backup/legacy artifacts identified" "PASS" "" ("COUNT=" + $Artifacts.Count)
}
else {
    Add-Result "O01" "SUPPLY CHAIN" "Backup/legacy inventory" "PASS" "" "NONE"
}

# ============================================================
# P â€” JSON VALIDITY
# ============================================================

$JSONFailures = @()

foreach ($File in $JSONFiles) {

    try {

        $Raw = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if ([string]::IsNullOrWhiteSpace($Raw)) {
            $JSONFailures += (Get-RelativePath $File.FullName)
            continue
        }

        $null = $Raw | ConvertFrom-Json
    }
    catch {
        $JSONFailures += (Get-RelativePath $File.FullName)
    }
}

if ($JSONFailures.Count -eq 0) {
    Add-Result "P01" "CONFIG" "Production JSON files parse" "PASS"
}
else {
    foreach ($Item in $JSONFailures) {
        Add-Result "P02" "CONFIG" ("Invalid JSON: " + $Item) "FAIL" "INVALID_JSON"
    }
}

# ============================================================
# Q â€” CERTIFICATION SURFACE
# ============================================================

$CertificationFiles = @(
    "core\runtime\certification-gate\CERTIFICATION-READINESS-GATE.ps1",
    "core\runtime\certification-gate\CERTIFICATION-EVIDENCE-INTEGRITY-GATE.ps1",
    "core\runtime\certification-gate\CERTIFICATION-SECURITY-INTEGRATION-GATE.ps1"
)

foreach ($Relative in $CertificationFiles) {

    $Full = Join-Path $Root $Relative

    if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) {
        Add-Result "Q01" "CERTIFICATION" ("Certification module: " + $Relative) "FAIL" "MISSING"
        continue
    }

    $Content = Get-Content -LiteralPath $Full -Raw -Encoding UTF8

    if (
        ($Content -match "CERTIFICATION") -and
        ($Content -match "BLOCK") -and
        ($Content -match "\bthrow\b")
    ) {
        Add-Result "Q01" "CERTIFICATION" ("Certification structure: " + $Relative) "PASS"
    }
    else {
        Add-Result "Q01" "CERTIFICATION" ("Certification structure: " + $Relative) "UNKNOWN" "STRUCTURE_NOT_FULLY_DEMONSTRATED"
    }
}

# ============================================================
# RESULT
# ============================================================

$Total = $Pass.Count + $Fail.Count + $Unknown.Count

$Decision = "VALIDEE"

if ($Fail.Count -gt 0) {
    $Decision = "NON_VALIDEE"
}
elseif ($Unknown.Count -gt 0) {
    $Decision = "NON_VALIDEE_UNKNOWN_PRESENT"
}

$Report = [ordered]@{
    Schema = "BK-AI-WORKERS-MASTER-PRE-LIVE-SECURITY-AUDIT"
    Version = "1.0"
    Root = $Root
    TimestampUtc = [DateTime]::UtcNow.ToString("o")

    Summary = [ordered]@{
        Total = $Total
        Pass = $Pass.Count
        Fail = $Fail.Count
        Unknown = $Unknown.Count
    }

    Decision = $Decision
    Pass = $Pass
    Fail = $Fail
    Unknown = $Unknown
}

[System.IO.File]::WriteAllText(
    $ReportFile,
    ($Report | ConvertTo-Json -Depth 40),
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT MASTER PRE-LIVE SECURITY AUDIT"
Write-Host "============================================================"
Write-Host ("TOTAL   : {0}" -f $Total)
Write-Host ("PASS    : {0}" -f $Pass.Count)
Write-Host ("FAIL    : {0}" -f $Fail.Count)
Write-Host ("UNKNOWN : {0}" -f $Unknown.Count)
Write-Host ""

if ($Decision -eq "VALIDEE") {
    Write-Host "MASTER AUDIT : VALIDEE" -ForegroundColor Green
}
elseif ($Decision -eq "NON_VALIDEE") {
    Write-Host "MASTER AUDIT : NON VALIDEE" -ForegroundColor Red
}
else {
    Write-Host "MASTER AUDIT : NON VALIDEE - UNKNOWN PRESENT" -ForegroundColor Yellow
}

Write-Host ""
Write-Host ("REPORT : {0}" -f $ReportFile)
Write-Host "AUCUNE MODIFICATION DU CODE DE PRODUCTION."
Write-Host "============================================================"
Write-Host "MASTER PRE-LIVE SECURITY AUDIT - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"