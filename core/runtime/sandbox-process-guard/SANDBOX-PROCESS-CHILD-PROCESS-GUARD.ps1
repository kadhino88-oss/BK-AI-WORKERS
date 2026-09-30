$ErrorActionPreference = "Stop"

$script:ProcessStateDir = Join-Path $PSScriptRoot "state"
$script:ProcessStateFile = Join-Path $script:ProcessStateDir "process-guard-state.json"

function Initialize-SandboxProcessGuard {

    New-Item -ItemType Directory -Force -Path $script:ProcessStateDir | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-PROCESS-GUARD"
        Version = "1.0"
        Mode = "SANDBOX"
        ProcessSpawnAllowed = $false
        ChildProcessAllowed = $false
        ShellExecutionAllowed = $false
        PowerShellExecutionAllowed = $false
        CommandExecutionAllowed = $false
        ExternalBinaryAllowed = $false
        ScriptExecutionAllowed = $false
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:ProcessStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxProcessGuardState {

    if (-not (Test-Path -LiteralPath $script:ProcessStateFile -PathType Leaf)) {
        return Initialize-SandboxProcessGuard
    }

    $Raw = Get-Content -LiteralPath $script:ProcessStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "PROCESS_GUARD_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-SandboxProcessRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestProcessSpawn = $false,
        [bool]$RequestChildProcess = $false,
        [bool]$RequestShell = $false,
        [bool]$RequestPowerShell = $false,
        [bool]$RequestCommand = $false,
        [bool]$RequestExternalBinary = $false,
        [bool]$RequestScriptExecution = $false
    )

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "PROCESS_ENVIRONMENT_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        throw "PROCESS_MODE_REQUIRED"
    }

    $EnvUpper = $Environment.ToUpperInvariant()
    $ModeUpper = $Mode.ToUpperInvariant()

    if ($EnvUpper -ne "SANDBOX") {
        throw "SANDBOX_ENVIRONMENT_REQUIRED"
    }

    if ($ModeUpper -ne "SANDBOX") {
        throw "SANDBOX_MODE_REQUIRED"
    }

    $State = Get-SandboxProcessGuardState

    if ($State.Mode -ne "SANDBOX") {
        throw "PROCESS_GUARD_MODE_INVALID"
    }

    if ($State.ProcessSpawnAllowed -ne $false) {
        throw "PROCESS_SPAWN_CONFIGURATION_INVALID"
    }

    if ($State.ChildProcessAllowed -ne $false) {
        throw "CHILD_PROCESS_CONFIGURATION_INVALID"
    }

    if ($State.ShellExecutionAllowed -ne $false) {
        throw "SHELL_CONFIGURATION_INVALID"
    }

    if ($State.PowerShellExecutionAllowed -ne $false) {
        throw "POWERSHELL_CONFIGURATION_INVALID"
    }

    if ($State.CommandExecutionAllowed -ne $false) {
        throw "COMMAND_CONFIGURATION_INVALID"
    }

    if ($State.ExternalBinaryAllowed -ne $false) {
        throw "EXTERNAL_BINARY_CONFIGURATION_INVALID"
    }

    if ($State.ScriptExecutionAllowed -ne $false) {
        throw "SCRIPT_EXECUTION_CONFIGURATION_INVALID"
    }

    if ($RequestProcessSpawn) {
        throw "SANDBOX_PROCESS_SPAWN_FORBIDDEN"
    }

    if ($RequestChildProcess) {
        throw "SANDBOX_CHILD_PROCESS_FORBIDDEN"
    }

    if ($RequestShell) {
        throw "SANDBOX_SHELL_EXECUTION_FORBIDDEN"
    }

    if ($RequestPowerShell) {
        throw "SANDBOX_POWERSHELL_EXECUTION_FORBIDDEN"
    }

    if ($RequestCommand) {
        throw "SANDBOX_COMMAND_EXECUTION_FORBIDDEN"
    }

    if ($RequestExternalBinary) {
        throw "SANDBOX_EXTERNAL_BINARY_FORBIDDEN"
    }

    if ($RequestScriptExecution) {
        throw "SANDBOX_SCRIPT_EXECUTION_FORBIDDEN"
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Isolated = $true
        Environment = "SANDBOX"
        Mode = "SANDBOX"
        ProcessSpawnAllowed = $false
        ChildProcessAllowed = $false
        ShellExecutionAllowed = $false
        PowerShellExecutionAllowed = $false
        CommandExecutionAllowed = $false
        ExternalBinaryAllowed = $false
        ScriptExecutionAllowed = $false
        Reason = "SANDBOX_PROCESS_ISOLATED"
    }
}

function Assert-SandboxProcessRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$RequestProcessSpawn = $false,
        [bool]$RequestChildProcess = $false,
        [bool]$RequestShell = $false,
        [bool]$RequestPowerShell = $false,
        [bool]$RequestCommand = $false,
        [bool]$RequestExternalBinary = $false,
        [bool]$RequestScriptExecution = $false
    )

    return Test-SandboxProcessRequest @PSBoundParameters
}