[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$GatePath = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"
$ContextPath = Join-Path $Root "core\runtime\security-gate\execution-context-integrity\Execution-Context-Integrity-Guard.ps1"
$SessionPath = Join-Path $Root "core\security\session-token-security\runtime.ps1"
$AuthorizationGatewayPath = Join-Path $Root "core\security\authorization-gateway\Authorization-Gateway.ps1"

foreach ($Path in @(
    $GatePath,
    $ContextPath,
    $SessionPath,
    $AuthorizationGatewayPath
)) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "SECURITY_DEPENDENCY_MISSING:$Path"
    }
}

. $GatePath
. $ContextPath
. $SessionPath
. $AuthorizationGatewayPath

function Invoke-AISecureAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Parameters
    )

    $Required = @(
        "TokenId",
        "Token",
        "SessionId",
        "UserId",
        "TenantId",
        "ClientId",
        "ProjectId",
        "ExecutionId",
        "Action",
        "Environment",
        "Mode"
    )

    foreach ($Name in $Required) {
        if (-not $Parameters.ContainsKey($Name)) {
            throw "SECURITY_CONTEXT_INCOMPLETE:$Name"
        }

        if ([string]::IsNullOrWhiteSpace([string]$Parameters[$Name])) {
            throw "SECURITY_CONTEXT_EMPTY:$Name"
        }
    }

    if ($Parameters.ContainsKey("DirectProviderExecution") -and
        [bool]$Parameters.DirectProviderExecution) {
        throw "DIRECT_PROVIDER_EXECUTION_FORBIDDEN"
    }

    if ($Parameters.ContainsKey("DirectConnectorExecution") -and
        [bool]$Parameters.DirectConnectorExecution) {
        throw "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
    }

    if ($Parameters.ContainsKey("SecretsPresent") -and
        [bool]$Parameters.SecretsPresent) {
        throw "SECRETS_FORBIDDEN"
    }

    $TokenResult = Test-SessionSecurityToken `
        -TokenId $Parameters.TokenId `
        -Token $Parameters.Token `
        -SessionId $Parameters.SessionId `
        -UserId $Parameters.UserId `
        -TenantId $Parameters.TenantId `
        -ClientId $Parameters.ClientId

    if ($null -eq $TokenResult -or
        $TokenResult.Success -ne $true -or
        $TokenResult.Status -ne "VALID") {
        throw "SESSION_TOKEN_INVALID:$($TokenResult.Reason)"
    }

    if ([string]$TokenResult.UserId -ne [string]$Parameters.UserId) {
        throw "TOKEN_IDENTITY_MISMATCH:USER"
    }

    if ([string]$TokenResult.TenantId -ne [string]$Parameters.TenantId) {
        throw "TOKEN_IDENTITY_MISMATCH:TENANT"
    }

    if ([string]$TokenResult.ClientId -ne [string]$Parameters.ClientId) {
        throw "TOKEN_IDENTITY_MISMATCH:CLIENT"
    }

    if ([string]$TokenResult.ProjectId -ne [string]$Parameters.ProjectId) {
        throw "TOKEN_IDENTITY_MISMATCH:PROJECT"
    }

    $AuthorizationResult = Authorize-Request `
        -UserId $TokenResult.UserId `
        -SessionId $TokenResult.SessionId `
        -Action $Parameters.Action `
        -TenantId $TokenResult.TenantId `
        -ClientId $TokenResult.ClientId `
        -ProjectId $TokenResult.ProjectId `
        -TokenId $Parameters.TokenId `
        -Token $Parameters.Token

    if ($null -eq $AuthorizationResult) {
        throw "AUTHORIZATION_GATEWAY_NO_RESULT"
    }

    if ($AuthorizationResult.Decision -ne "ALLOW" -or
        $AuthorizationResult.Success -ne $true) {
        throw "AUTHORIZATION_BLOCKED:$($AuthorizationResult.Reason)"
    }

    $Context = @{
        TenantId    = $TokenResult.TenantId
        ClientId    = $TokenResult.ClientId
        ProjectId   = $TokenResult.ProjectId
        ExecutionId = $Parameters.ExecutionId
        UserId      = $TokenResult.UserId
    }

    $ExistingContext = Test-ExecutionContext -Context $Context

    if ($ExistingContext.Valid -ne $true) {
        Register-ExecutionContext -Context $Context | Out-Null
        $ExistingContext = Test-ExecutionContext -Context $Context
    }

    if ($ExistingContext.Valid -ne $true) {
        throw "EXECUTION_CONTEXT_BLOCKED:$($ExistingContext.Reason)"
    }

    $GateParameters = @{
        TenantId = $TokenResult.TenantId
        ClientId = $TokenResult.ClientId
        ProjectId = $TokenResult.ProjectId
        ExecutionId = $Parameters.ExecutionId
        UserId = $TokenResult.UserId
        Environment = $Parameters.Environment
        Mode = $Parameters.Mode

        SessionValid = $true
        RBACAuthorized = $true
        ScopeValid = $true
        AuthorizationValid = $true

        DirectConnectorExecution = $false
        DirectProviderExecution = $false
        SecretsPresent = $false

        HumanApproval = $false
        ProductionFlag = $false
    }

    foreach ($Name in @(
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
    )) {
        if ($Parameters.ContainsKey($Name)) {
            $GateParameters[$Name] = [bool]$Parameters[$Name]
        }
    }

    $GateResult = Invoke-GlobalSecurityGate @GateParameters

    if ($null -eq $GateResult) {
        throw "GLOBAL_SECURITY_GATE_NO_RESULT"
    }

    if ($GateResult.Decision -ne "ALLOW" -or
        $GateResult.Authorized -ne $true) {
        throw "GLOBAL_SECURITY_GATE_BLOCKED:$($GateResult.Reason)"
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Authorized = $true
        SessionValid = $true
        RBACAuthorized = $true
        ScopeValid = $true
        AuthorizationValid = $true
        ContextValid = $true
        ContextHash = $ExistingContext.ContextHash
        TokenId = $TokenResult.TokenId
        SessionId = $TokenResult.SessionId
        UserId = $TokenResult.UserId
        TenantId = $TokenResult.TenantId
        ClientId = $TokenResult.ClientId
        ProjectId = $TokenResult.ProjectId
        Authorization = $AuthorizationResult
        Gate = $GateResult
    }
}