$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$ThisFile = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)

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

function Test-RequiredFile {
    param(
        [string]$RelativePath
    )

    $Path = Join-Path $Root $RelativePath

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Result "Required file: $RelativePath" "PASS"
        return $true
    }

    Result "Required file: $RelativePath" "FAIL" "MISSING"
    return $false
}

function Get-ProductionScripts {

    $RuntimeFiles = Get-ChildItem `
        -LiteralPath $Root `
        -Recurse `
        -File `
        -Filter "*.ps1" `
        -ErrorAction SilentlyContinue

    foreach ($File in $RuntimeFiles) {

        $Full = [System.IO.Path]::GetFullPath($File.FullName)
        $Name = $File.Name.ToLowerInvariant()
        $Path = $Full.ToLowerInvariant()

        if ($Full -eq $ThisFile) {
            continue
        }

        if ($Path -match '\\tests?\\') {
            continue
        }

        if ($Path -match '\\backups?\\') {
            continue
        }

        if ($Name -match '(^|[._-])(backup|broken|legacy)([._-]|$)') {
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

function Get-Ast {
    param(
        [string]$Path
    )

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
Write-Host "BK-AI-WORKERS PRE-LIVE RED-TEAM SECURITY AUDIT"
Write-Host "============================================================"

# ============================================================
# 01-12 : CRITICAL SECURITY SURFACE
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

foreach ($File in $CriticalFiles) {
    Test-RequiredFile $File | Out-Null
}

# ============================================================
# 13 : PRODUCTION INVENTORY
# ============================================================

$ProductionFiles = @(Get-ProductionScripts)

if ($ProductionFiles.Count -gt 0) {
    Result "Production script inventory available" "PASS"
}
else {
    Result "Production script inventory available" "FAIL" "NO_FILES"
}

# ============================================================
# 14+ : PARSING INTEGRITY
# ============================================================

$ParseFailureCount = 0

foreach ($File in $ProductionFiles) {

    try {
        $Parsed = Get-Ast -Path $File.FullName

        if ($Parsed.Errors.Count -eq 0) {
            continue
        }

        $ParseFailureCount++
    }
    catch {
        $ParseFailureCount++
    }
}

if ($ParseFailureCount -eq 0) {
    Result "All production PowerShell files parse successfully" "PASS"
}
else {
    Result "All production PowerShell files parse successfully" "FAIL" "$ParseFailureCount PARSE_ERRORS"
}

# ============================================================
# EXECUTABLE PRIMITIVE ANALYSIS
# ============================================================

$DangerousCommands = @(
    "Invoke-WebRequest",
    "Invoke-RestMethod",
    "Start-Process",
    "Start-BitsTransfer"
)

$CommandFindings = @()

foreach ($File in $ProductionFiles) {

    try {
        $Parsed = Get-Ast -Path $File.FullName

        if ($Parsed.Errors.Count -gt 0) {
            continue
        }

        $Commands = $Parsed.Ast.FindAll({
            param($Node)

            return ($Node -is [System.Management.Automation.Language.CommandAst])
        }, $true)

        foreach ($Command in $Commands) {

            if ($Command.CommandElements.Count -eq 0) {
                continue
            }

            $First = $Command.CommandElements[0]

            if ($First -is [System.Management.Automation.Language.StringConstantExpressionAst]) {

                $CommandName = $First.Value

                if ($DangerousCommands -contains $CommandName) {

                    $CommandFindings += [pscustomobject]@{
                        File = $File.FullName
                        Command = $CommandName
                        Text = $Command.Extent.Text
                    }
                }
            }
        }
    }
    catch {
        continue
    }
}

# Security/runtime paths that MUST NOT directly perform network/process execution.
$CriticalExecutionRoots = @(
    (Join-Path $Root "core\security"),
    (Join-Path $Root "core\runtime\security-gate"),
    (Join-Path $Root "orchestrator")
)

$CriticalFindings = @()

foreach ($Finding in $CommandFindings) {

    $IsCritical = $false

    foreach ($CriticalRoot in $CriticalExecutionRoots) {

        $RootFull = [System.IO.Path]::GetFullPath($CriticalRoot).ToLowerInvariant()
        $FileFull = [System.IO.Path]::GetFullPath($Finding.File).ToLowerInvariant()

        if ($FileFull.StartsWith($RootFull)) {
            $IsCritical = $true
            break
        }
    }

    if ($IsCritical) {
        $CriticalFindings += $Finding
    }
}

foreach ($Command in $DangerousCommands) {

    $Matches = @(
        $CriticalFindings |
        Where-Object { $_.Command -eq $Command }
    )

    if ($Matches.Count -eq 0) {
        Result "No direct $Command in critical security/orchestrator paths" "PASS"
    }
    else {
        Write-Host ""
        Write-Host "CRITICAL EXECUTABLE CALLS : $Command" -ForegroundColor Yellow

        foreach ($Match in $Matches) {
            Write-Host ("FILE : {0}" -f $Match.File)
            Write-Host ("CODE : {0}" -f $Match.Text)
        }

        Result "No direct $Command in critical security/orchestrator paths" "FAIL" "DIRECT_EXECUTION_FOUND"
    }
}

# ============================================================
# .NET DIRECT NETWORK / PROCESS CONSTRUCTION
# ============================================================

$DangerousTypes = @(
    "System.Net.Http",
    "System.Net.Sockets",
    "System.Net.WebClient",
    "System.Net.HttpWebRequest",
    "System.Diagnostics.Process"
)

foreach ($TypeName in $DangerousTypes) {

    $Findings = @()

    foreach ($File in $ProductionFiles) {

        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if (
            ($Content -match "(?i)\bNew-Object\s+$([regex]::Escape($TypeName))\b") -or
            ($Content -match "(?i)\b$([regex]::Escape($TypeName))::") -or
            ($Content -match "(?i)\[$([regex]::Escape($TypeName))\]")
        ) {
            $Findings += $File.FullName
        }
    }

    $CriticalTypeFindings = @()

    foreach ($File in $Findings) {

        foreach ($CriticalRoot in $CriticalExecutionRoots) {

            $RootFull = [System.IO.Path]::GetFullPath($CriticalRoot).ToLowerInvariant()
            $FileFull = [System.IO.Path]::GetFullPath($File).ToLowerInvariant()

            if ($FileFull.StartsWith($RootFull)) {
                $CriticalTypeFindings += $File
                break
            }
        }
    }

    if ($CriticalTypeFindings.Count -eq 0) {
        Result "No direct $TypeName in critical security/orchestrator paths" "PASS"
    }
    else {
        Result "No direct $TypeName in critical security/orchestrator paths" "FAIL" "DANGEROUS_TYPE_FOUND"
    }
}

# ============================================================
# DYNAMIC CODE EXECUTION
# ============================================================

$DynamicPatterns = @(
    "Invoke-Expression",
    "\biex\b",
    "FromBase64String",
    "\[ScriptBlock\]::Create",
    "\bAdd-Type\b"
)

foreach ($Pattern in $DynamicPatterns) {

    $Findings = @()

    foreach ($File in $ProductionFiles) {

        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if ($Content -match $Pattern) {
            $Findings += $File.FullName
        }
    }

    if ($Findings.Count -eq 0) {
        Result "No suspicious dynamic execution: $Pattern" "PASS"
    }
    else {
        Result "No suspicious dynamic execution: $Pattern" "FAIL" "DYNAMIC_EXECUTION_FOUND"
    }
}

# ============================================================
# GLOBAL SECURITY GATE CONTRACT
# ============================================================

$GlobalGate = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

if (Test-Path -LiteralPath $GlobalGate -PathType Leaf) {

    try {
        . $GlobalGate

        $HasInvoke = $null -ne (Get-Command Invoke-GlobalSecurityGate -ErrorAction SilentlyContinue)
        $HasAssert = $null -ne (Get-Command Assert-GlobalSecurityGate -ErrorAction SilentlyContinue)

        if ($HasInvoke) {
            Result "Global Gate Invoke function available" "PASS"
        }
        else {
            Result "Global Gate Invoke function available" "FAIL" "MISSING"
        }

        if ($HasAssert) {
            Result "Global Gate Assert function available" "PASS"
        }
        else {
            Result "Global Gate Assert function available" "FAIL" "MISSING"
        }

        $Base = @{
            TenantId = "REDTEAM-TENANT"
            ClientId = "REDTEAM-CLIENT"
            ProjectId = "REDTEAM-PROJECT"
            ExecutionId = "REDTEAM-EXECUTION"
            UserId = "REDTEAM-USER"
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

        $Valid = Invoke-GlobalSecurityGate @Base

        if ($Valid.Decision -eq "ALLOW") {
            Result "Global Gate valid chain => ALLOW" "PASS"
        }
        else {
            Result "Global Gate valid chain => ALLOW" "FAIL" "EXPECTED_ALLOW"
        }

        $Attack = @{} + $Base
        $Attack.SessionValid = $false

        $Blocked = Invoke-GlobalSecurityGate @Attack

        if (($Blocked.Decision -eq "BLOCK") -and ($Blocked.Authorized -eq $false)) {
            Result "Global Gate invalid session => BLOCK" "PASS"
        }
        else {
            Result "Global Gate invalid session => BLOCK" "FAIL" "SESSION_BYPASS"
        }

        $Attack = @{} + $Base
        $Attack.DirectProviderExecution = $true

        $Blocked = Invoke-GlobalSecurityGate @Attack

        if (($Blocked.Decision -eq "BLOCK") -and ($Blocked.Authorized -eq $false)) {
            Result "Global Gate direct provider execution => BLOCK" "PASS"
        }
        else {
            Result "Global Gate direct provider execution => BLOCK" "FAIL" "PROVIDER_BYPASS"
        }

        $Attack = @{} + $Base
        $Attack.DirectConnectorExecution = $true

        $Blocked = Invoke-GlobalSecurityGate @Attack

        if (($Blocked.Decision -eq "BLOCK") -and ($Blocked.Authorized -eq $false)) {
            Result "Global Gate direct connector execution => BLOCK" "PASS"
        }
        else {
            Result "Global Gate direct connector execution => BLOCK" "FAIL" "CONNECTOR_BYPASS"
        }

        $Attack = @{} + $Base
        $Attack.SecretsPresent = $true

        $Blocked = Invoke-GlobalSecurityGate @Attack

        if (($Blocked.Decision -eq "BLOCK") -and ($Blocked.Authorized -eq $false)) {
            Result "Global Gate secrets-present execution => BLOCK" "PASS"
        }
        else {
            Result "Global Gate secrets-present execution => BLOCK" "FAIL" "SECRET_BYPASS"
        }
    }
    catch {
        Result "Global Gate runtime red-team validation" "FAIL" $_.Exception.Message
    }
}
else {
    Result "Global Gate runtime red-team validation" "FAIL" "GATE_MISSING"
}

# ============================================================
# LIVE ESCALATION
# ============================================================

try {

    $Live = @{} + $Base
    $Live.Environment = "LIVE"
    $Live.Mode = "LIVE"
    $Live.HumanApproval = $true
    $Live.ProductionFlag = $false

    $LiveResult = Invoke-GlobalSecurityGate @Live

    if (($LiveResult.Decision -eq "BLOCK") -and
        ($LiveResult.Authorized -eq $false)) {

        Result "LIVE without production flag => BLOCK" "PASS"
    }
    else {
        Result "LIVE without production flag => BLOCK" "FAIL" "LIVE_ESCALATION"
    }
}
catch {
    Result "LIVE without production flag => BLOCK" "FAIL" "UNEXPECTED_EXCEPTION"
}

# ============================================================
# AI GATEWAY / PROVIDER BOUNDARY
# ============================================================

$Gateway = Join-Path $Root "core\ai\AI-GATEWAY.ps1"
$Provider = Join-Path $Root "core\ai\AI-PROVIDER-ENGINE.ps1"

if (Test-Path -LiteralPath $Gateway -PathType Leaf) {

    $GatewayContent = Get-Content -LiteralPath $Gateway -Raw -Encoding UTF8

    if ($GatewayContent -match "Invoke-GlobalSecurityGate") {
        Result "AI Gateway integrated with Global Security Gate" "PASS"
    }
    else {
        Result "AI Gateway integrated with Global Security Gate" "FAIL" "GATE_REFERENCE_MISSING"
    }

    if (($GatewayContent -match "DirectProviderExecution") -and
        ($GatewayContent -match "DirectConnectorExecution")) {

        Result "AI Gateway explicit direct-execution controls" "PASS"
    }
    else {
        Result "AI Gateway explicit direct-execution controls" "UNKNOWN" "NOT_FULLY_DEMONSTRATED"
    }
}
else {
    Result "AI Gateway security boundary" "FAIL" "GATEWAY_MISSING"
}

if (Test-Path -LiteralPath $Provider -PathType Leaf) {

    $ProviderContent = Get-Content -LiteralPath $Provider -Raw -Encoding UTF8

    if (
        ($ProviderContent -match "Invoke-GlobalSecurityGate") -or
        ($ProviderContent -match "Assert-GlobalSecurityGate") -or
        ($ProviderContent -match "LIVE_PROVIDER")
    ) {
        Result "AI Provider Engine security boundary detected" "PASS"
    }
    else {
        Result "AI Provider Engine security boundary detected" "UNKNOWN" "NOT_FULLY_DEMONSTRATED"
    }
}
else {
    Result "AI Provider Engine security boundary" "FAIL" "PROVIDER_MISSING"
}

# ============================================================
# MULTI-TENANT SECURITY SURFACE
# ============================================================

$IdentityRoots = @(
    "core\security",
    "core\runtime\security-gate",
    "core\ai",
    "orchestrator"
)

foreach ($RelativeRoot in $IdentityRoots) {

    $Path = Join-Path $Root $RelativeRoot

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Result "Identity security surface: $RelativeRoot" "FAIL" "MISSING"
        continue
    }

    $AllContent = ""

    Get-ChildItem `
        -LiteralPath $Path `
        -Recurse `
        -File `
        -Filter "*.ps1" `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch "\\tests?\\|\\backups?\\"
        } |
        ForEach-Object {
            $AllContent += "`n" + (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8)
        }

    $IdentityFound =
        ($AllContent -match "TenantId") -and
        ($AllContent -match "ClientId") -and
        ($AllContent -match "ProjectId") -and
        ($AllContent -match "ExecutionId")

    if ($IdentityFound) {
        Result "Tenant/client/project/execution identity controls: $RelativeRoot" "PASS"
    }
    else {
        Result "Tenant/client/project/execution identity controls: $RelativeRoot" "UNKNOWN" "NOT_FULLY_DEMONSTRATED"
    }
}

# ============================================================
# SECRET PATTERN SCAN
# ============================================================

$SecretPatterns = @(
    'AKIA[0-9A-Z]{16}',
    'sk-[A-Za-z0-9]{20,}',
    'xox[baprs]-[A-Za-z0-9-]{20,}',
    'password\s*=\s*["''][^"'']{8,}["'']',
    'api[_-]?key\s*=\s*["''][^"'']{8,}["'']',
    'client[_-]?secret\s*=\s*["''][^"'']{8,}["'']'
)

foreach ($Pattern in $SecretPatterns) {

    $Found = $false

    foreach ($File in $ProductionFiles) {

        $Content = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8

        if ($Content -match $Pattern) {
            $Found = $true
            break
        }
    }

    if (-not $Found) {
        Result "No high-confidence embedded secret pattern" "PASS"
    }
    else {
        Result "No high-confidence embedded secret pattern" "FAIL" "POSSIBLE_SECRET"
    }
}

# ============================================================
# FINAL DECISION
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT PRE-LIVE RED-TEAM"
Write-Host "============================================================"
Write-Host ("TOTAL CHECKS : {0}" -f $Total)
Write-Host ("PASS         : {0}" -f $Pass)
Write-Host ("FAIL         : {0}" -f $Fail)
Write-Host ("UNKNOWN      : {0}" -f $Unknown)
Write-Host ""

if (($Fail -eq 0) -and ($Unknown -eq 0) -and ($Total -gt 0)) {

    Write-Host "PRE-LIVE RED-TEAM : VALIDEE" -ForegroundColor Green
}
elseif ($Fail -gt 0) {

    Write-Host "PRE-LIVE RED-TEAM : NON VALIDEE" -ForegroundColor Red
}
else {

    Write-Host "PRE-LIVE RED-TEAM : NON VALIDEE - UNKNOWN PRESENT" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "AUCUNE ACTIVATION LIVE EFFECTUEE."
Write-Host "============================================================"
Write-Host "PRE-LIVE RED-TEAM AUDIT - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"