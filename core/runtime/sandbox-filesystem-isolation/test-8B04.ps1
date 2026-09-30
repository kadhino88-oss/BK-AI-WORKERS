$ErrorActionPreference = "Stop"

$Module = Join-Path $PSScriptRoot "SANDBOX-FILESYSTEM-ISOLATION-GUARD.ps1"

. $Module

Initialize-SandboxFilesystemIsolation | Out-Null

$script:Total = 0
$script:Pass = 0
$script:Fail = 0

function Run-Test {
    param(
        [string]$TestName,
        [scriptblock]$TestAction,
        [bool]$ExpectThrow
    )

    $script:Total++

    try {
        & $TestAction | Out-Null

        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [FAIL] {1}" -f $script:Total,$TestName)
            $script:Fail++
        }
        else {
            Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$TestName)
            $script:Pass++
        }
    }
    catch {
        if ($ExpectThrow) {
            Write-Host ("[{0:00}] [PASS] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Pass++
        }
        else {
            Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$TestName,$_.Exception.Message)
            $script:Fail++
        }
    }
}

# 01
Run-Test "Module present" {
    if (-not (Test-Path -LiteralPath $Module -PathType Leaf)) {
        throw "MODULE_MISSING"
    }
} $false

# 02
Run-Test "State SANDBOX" {
    $s = Get-SandboxFilesystemIsolationState
    if ($s.Mode -ne "SANDBOX") { throw "BAD_MODE" }
} $false

# 03
Run-Test "External write disabled" {
    $s = Get-SandboxFilesystemIsolationState
    if ($s.ExternalWriteAllowed -ne $false) { throw "EXTERNAL_WRITE_ENABLED" }
} $false

# 04
Run-Test "Traversal disabled" {
    $s = Get-SandboxFilesystemIsolationState
    if ($s.PathTraversalAllowed -ne $false) { throw "TRAVERSAL_ENABLED" }
} $false

# 05
Run-Test "Absolute paths disabled" {
    $s = Get-SandboxFilesystemIsolationState
    if ($s.AbsolutePathAllowed -ne $false) { throw "ABSOLUTE_PATH_ENABLED" }
} $false

# 06
Run-Test "UNC paths disabled" {
    $s = Get-SandboxFilesystemIsolationState
    if ($s.UNCPathAllowed -ne $false) { throw "UNC_ENABLED" }
} $false

# 07
Run-Test "Other volumes disabled" {
    $s = Get-SandboxFilesystemIsolationState
    if ($s.OtherVolumeAllowed -ne $false) { throw "OTHER_VOLUME_ENABLED" }
} $false

# 08
Run-Test "Relative sandbox path accepted" {
    $r = Test-SandboxFilesystemPath -Path "workspace\file.txt"
    if ($r.Decision -ne "ALLOW") { throw "VALID_PATH_BLOCKED" }
} $false

# 09
Run-Test "Nested sandbox path accepted" {
    $r = Test-SandboxFilesystemPath -Path "workspace\data\output.json"
    if ($r.Valid -ne $true) { throw "NESTED_PATH_BLOCKED" }
} $false

# 10
Run-Test "Parent traversal blocked" {
    Test-SandboxFilesystemPath -Path "..\secret.txt"
} $true

# 11
Run-Test "Embedded traversal blocked" {
    Test-SandboxFilesystemPath -Path "workspace\..\secret.txt"
} $true

# 12
Run-Test "Deep traversal blocked" {
    Test-SandboxFilesystemPath -Path "workspace\a\b\..\..\..\secret.txt"
} $true

# 13
Run-Test "Absolute C path blocked" {
    Test-SandboxFilesystemPath -Path "C:\secret.txt"
} $true

# 14
Run-Test "Absolute D path blocked" {
    Test-SandboxFilesystemPath -Path "D:\secret.txt"
} $true

# 15
Run-Test "UNC path blocked" {
    Test-SandboxFilesystemPath -Path "\\server\share\secret.txt"
} $true

# 16
Run-Test "Other volume syntax blocked" {
    Test-SandboxFilesystemPath -Path "D:secret.txt"
} $true

# 17
Run-Test "Empty path blocked" {
    Test-SandboxFilesystemPath -Path ""
} $true

# 18
Run-Test "Empty operation blocked" {
    Test-SandboxFilesystemPath `
        -Path "workspace\file.txt" `
        -Operation ""
} $true

# 19
Run-Test "Read operation structurally accepted" {
    $r = Test-SandboxFilesystemPath `
        -Path "workspace\read.json" `
        -Operation "READ"

    if ($r.Decision -ne "ALLOW") {
        throw "READ_BLOCKED"
    }
} $false

# 20
Run-Test "Write operation structurally accepted inside sandbox" {
    $r = Test-SandboxFilesystemPath `
        -Path "workspace\write.json" `
        -Operation "WRITE"

    if ($r.Decision -ne "ALLOW") {
        throw "WRITE_PATH_BLOCKED"
    }
} $false

# 21
Run-Test "Delete operation path remains isolated" {
    $r = Test-SandboxFilesystemPath `
        -Path "workspace\delete.json" `
        -Operation "DELETE"

    if ($r.Decision -ne "ALLOW") {
        throw "DELETE_PATH_INVALID"
    }
} $false

# 22
Run-Test "Resolved path remains inside sandbox root" {
    $r = Test-SandboxFilesystemPath -Path "workspace\output\data.json"

    if (-not (
        $r.ResolvedPath.StartsWith(
            [System.IO.Path]::GetFullPath($r.SandboxRoot).TrimEnd("\") + "\",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )) {
        throw "PATH_ESCAPED_SANDBOX_ROOT"
    }
} $false

# 23
Run-Test "Assert blocks traversal" {
    Assert-SandboxFilesystemPath -Path "workspace\..\outside.txt"
} $true

# 24
Run-Test "Fail-closed external escape" {
    Assert-SandboxFilesystemPath -Path "..\..\..\outside.txt"
} $true

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B-04"
Write-Host "============================================================"
Write-Host ("TOTAL TESTS : {0}" -f $script:Total)
Write-Host ("PASS        : {0}" -f $script:Pass)
Write-Host ("FAIL        : {0}" -f $script:Fail)
Write-Host ""

if (($script:Total -eq 24) -and ($script:Pass -eq 24) -and ($script:Fail -eq 0)) {
    Write-Host "8B-04 : VALIDEE - 24/24" -ForegroundColor Green
}
else {
    Write-Host "8B-04 : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B-04 - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"