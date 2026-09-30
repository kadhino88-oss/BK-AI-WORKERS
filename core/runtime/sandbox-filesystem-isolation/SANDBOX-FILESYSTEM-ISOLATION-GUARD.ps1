$ErrorActionPreference = "Stop"

$script:FsStateDir = Join-Path $PSScriptRoot "state"
$script:FsStateFile = Join-Path $script:FsStateDir "filesystem-isolation-state.json"

function Initialize-SandboxFilesystemIsolation {

    New-Item -ItemType Directory -Force -Path $script:FsStateDir | Out-Null

    $SandboxRoot = Join-Path $PSScriptRoot "workspace"

    New-Item -ItemType Directory -Force -Path $SandboxRoot | Out-Null

    $State = [ordered]@{
        Schema = "BK-AI-WORKERS-SANDBOX-FILESYSTEM-ISOLATION"
        Version = "1.0"
        Mode = "SANDBOX"
        SandboxRoot = $SandboxRoot
        ExternalWriteAllowed = $false
        PathTraversalAllowed = $false
        AbsolutePathAllowed = $false
        UNCPathAllowed = $false
        OtherVolumeAllowed = $false
        Records = @()
    }

    [System.IO.File]::WriteAllText(
        $script:FsStateFile,
        ($State | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    return $State
}

function Get-SandboxFilesystemIsolationState {

    if (-not (Test-Path -LiteralPath $script:FsStateFile -PathType Leaf)) {
        return Initialize-SandboxFilesystemIsolation
    }

    $Raw = Get-Content -LiteralPath $script:FsStateFile -Raw -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "FILESYSTEM_STATE_EMPTY"
    }

    return ($Raw | ConvertFrom-Json)
}

function Test-SandboxFilesystemPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Operation = "WRITE"
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "FILESYSTEM_PATH_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        throw "FILESYSTEM_OPERATION_REQUIRED"
    }

    $State = Get-SandboxFilesystemIsolationState

    if ($State.Mode -ne "SANDBOX") {
        throw "FILESYSTEM_SANDBOX_MODE_INVALID"
    }

    if ($State.ExternalWriteAllowed -ne $false) {
        throw "EXTERNAL_WRITE_CONFIGURATION_INVALID"
    }

    if ($State.PathTraversalAllowed -ne $false) {
        throw "PATH_TRAVERSAL_CONFIGURATION_INVALID"
    }

    if ($State.AbsolutePathAllowed -ne $false) {
        throw "ABSOLUTE_PATH_CONFIGURATION_INVALID"
    }

    if ($State.UNCPathAllowed -ne $false) {
        throw "UNC_PATH_CONFIGURATION_INVALID"
    }

    if ($State.OtherVolumeAllowed -ne $false) {
        throw "OTHER_VOLUME_CONFIGURATION_INVALID"
    }

    $Normalized = $Path.Replace("/", "\")

    if ($Normalized -match "(^|\\)\.\.(\\|$)") {
        throw "SANDBOX_PATH_TRAVERSAL_FORBIDDEN"
    }

    if ($Normalized -match "^[A-Za-z]:\\") {
        throw "SANDBOX_ABSOLUTE_PATH_FORBIDDEN"
    }

    if ($Normalized -match "^\\\\") {
        throw "SANDBOX_UNC_PATH_FORBIDDEN"
    }

    if ($Normalized -match "^[A-Za-z]:") {
        throw "SANDBOX_OTHER_VOLUME_FORBIDDEN"
    }

    $AllowedRoot = [System.IO.Path]::GetFullPath($State.SandboxRoot).TrimEnd("\")

    try {
        $Candidate = [System.IO.Path]::GetFullPath(
            (Join-Path $State.SandboxRoot $Normalized)
        )
    }
    catch {
        throw "SANDBOX_PATH_INVALID"
    }

    if (
        ($Candidate -ne $AllowedRoot) -and
        (-not $Candidate.StartsWith($AllowedRoot + "\", [System.StringComparison]::OrdinalIgnoreCase))
    ) {
        throw "SANDBOX_PATH_OUTSIDE_ROOT"
    }

    return [pscustomobject]@{
        Decision = "ALLOW"
        Valid = $true
        SandboxRoot = $AllowedRoot
        ResolvedPath = $Candidate
        Operation = $Operation.ToUpperInvariant()
        ExternalWriteAllowed = $false
        TraversalAllowed = $false
        Reason = "SANDBOX_PATH_ISOLATED"
    }
}

function Assert-SandboxFilesystemPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Operation = "WRITE"
    )

    return Test-SandboxFilesystemPath `
        -Path $Path `
        -Operation $Operation
}