$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$ThisAuditFile = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)

$Checks = @(
    @{
        Name = "8B-01 Sandbox Execution Runtime"
        Path = "core\runtime\sandbox-execution\SANDBOX-EXECUTION-RUNTIME.ps1"
    },
    @{
        Name = "8B-02 Sandbox Live Isolation"
        Path = "core\runtime\sandbox-isolation\SANDBOX-LIVE-ISOLATION-GUARD.ps1"
    },
    @{
        Name = "8B-03 Sandbox Network External IO"
        Path = "core\runtime\sandbox-network-guard\SANDBOX-NETWORK-EXTERNAL-IO-GUARD.ps1"
    },
    @{
        Name = "8B-04 Sandbox Filesystem Isolation"
        Path = "core\runtime\sandbox-filesystem-isolation\SANDBOX-FILESYSTEM-ISOLATION-GUARD.ps1"
    },
    @{
        Name = "8B-05 Sandbox Process Guard"
        Path = "core\runtime\sandbox-process-guard\SANDBOX-PROCESS-CHILD-PROCESS-GUARD.ps1"
    },
    @{
        Name = "8B-06 Sandbox Secrets Guard"
        Path = "core\runtime\sandbox-secrets-guard\SANDBOX-MEMORY-SECRETS-GUARD.ps1"
    },
    @{
        Name = "8B-07 Sandbox Resource Guard"
        Path = "core\runtime\sandbox-resource-guard\SANDBOX-RESOURCE-QUOTA-GUARD.ps1"
    },
    @{
        Name = "8B-08 Sandbox Timeout Guard"
        Path = "core\runtime\sandbox-timeout-guard\SANDBOX-TIMEOUT-DEADLINE-GUARD.ps1"
    },
    @{
        Name = "8B-09 Sandbox Output Guard"
        Path = "core\runtime\sandbox-output-guard\SANDBOX-OUTPUT-DATA-EXFILTRATION-GUARD.ps1"
    }
)

$Total = 0
$Pass = 0
$Fail = 0

function Check {
    param(
        [string]$Name,
        [bool]$Condition,
        [string]$Reason
    )

    $script:Total++

    if ($Condition) {
        Write-Host ("[{0:00}] [PASS] {1}" -f $script:Total,$Name)
        $script:Pass++
    }
    else {
        Write-Host ("[{0:00}] [FAIL] {1} -> {2}" -f $script:Total,$Name,$Reason)
        $script:Fail++
    }
}

function Get-RuntimeFiles {

    Get-ChildItem `
        -LiteralPath (Join-Path $Root "core\runtime") `
        -Recurse `
        -File `
        -Filter "*.ps1" `
        -ErrorAction SilentlyContinue |
        Where-Object {

            $Full = [System.IO.Path]::GetFullPath($_.FullName)

            $Full -ne $ThisAuditFile -and
            $Full -notmatch "\\backups?\\"
        }
}

Write-Host ""
Write-Host "============================================================"
Write-Host "8B GLOBAL SANDBOX INTEGRATION AUDIT"
Write-Host "============================================================"

# ============================================================
# 1. MODULES
# ============================================================

foreach ($Item in $Checks) {

    $FullPath = Join-Path $Root $Item.Path
    $Exists = Test-Path -LiteralPath $FullPath -PathType Leaf

    Check `
        -Name "$($Item.Name) - module present" `
        -Condition $Exists `
        -Reason "MODULE_MISSING"

    if ($Exists) {

        $Content = Get-Content -LiteralPath $FullPath -Raw -Encoding UTF8

        Check `
            -Name "$($Item.Name) - SANDBOX enforced" `
            -Condition ($Content -match "\bSANDBOX\b") `
            -Reason "SANDBOX_REFERENCE_MISSING"

        Check `
            -Name "$($Item.Name) - fail-closed protection" `
            -Condition (
                ($Content -match "\bthrow\b") -or
                ($Content -match "FORBIDDEN") -or
                ($Content -match "BLOCK")
            ) `
            -Reason "FAIL_CLOSED_SIGNAL_MISSING"
    }
}

$RuntimeFiles = @(Get-RuntimeFiles)

# ============================================================
# 2. DANGEROUS EXECUTABLE PRIMITIVES
# ============================================================

$PrimitiveRules = @(
    @{
        Name = "Invoke-WebRequest"
        Regex = '^\s*(?:&\s*)?Invoke-WebRequest(?:\s|$)'
    },
    @{
        Name = "Invoke-RestMethod"
        Regex = '^\s*(?:&\s*)?Invoke-RestMethod(?:\s|$)'
    },
    @{
        Name = "Start-Process"
        Regex = '^\s*(?:&\s*)?Start-Process(?:\s|$)'
    },
    @{
        Name = "Start-BitsTransfer"
        Regex = '^\s*(?:&\s*)?Start-BitsTransfer(?:\s|$)'
    },
    @{
        Name = "System.Net.Http"
        Regex = '^\s*\$[A-Za-z0-9_]+\s*=\s*New-Object\s+System\.Net\.Http'
    },
    @{
        Name = "System.Net.Sockets"
        Regex = '^\s*\$[A-Za-z0-9_]+\s*=\s*New-Object\s+System\.Net\.Sockets'
    },
    @{
        Name = "System.Diagnostics.Process"
        Regex = '^\s*\$[A-Za-z0-9_]+\s*=\s*New-Object\s+System\.Diagnostics\.Process'
    }
)

foreach ($Rule in $PrimitiveRules) {

    $Violations = @()

    foreach ($File in $RuntimeFiles) {

        $Lines = Get-Content -LiteralPath $File.FullName -Encoding UTF8
        $LineNumber = 0

        foreach ($Line in $Lines) {

            $LineNumber++

            $Trimmed = $Line.Trim()

            if ([string]::IsNullOrWhiteSpace($Trimmed)) {
                continue
            }

            if ($Trimmed.StartsWith("#")) {
                continue
            }

            $WithoutComment = $Trimmed -replace '\s+#.*$',''

            if ($WithoutComment -match $Rule.Regex) {

                $Violations += [pscustomobject]@{
                    File = $File.FullName
                    Line = $LineNumber
                    Code = $WithoutComment
                }
            }
        }
    }

    Check `
        -Name "Executable primitive audit: $($Rule.Name)" `
        -Condition ($Violations.Count -eq 0) `
        -Reason "EXECUTABLE_PRIMITIVE_DETECTED"
}

# ============================================================
# 3. REAL BACKUP EXECUTION DEPENDENCY
# ============================================================
# IMPORTANT :
# Une simple chaîne contenant "backups" n'est PAS une dépendance.
# On vérifie uniquement :
# - dot-sourcing d'un chemin backup
# - Import-Module d'un chemin backup
# - invocation (&) d'un chemin backup
# - variable explicitement affectée à un chemin backup puis utilisée
# ============================================================

$BackupViolations = @()

foreach ($File in $RuntimeFiles) {

    $Lines = Get-Content -LiteralPath $File.FullName -Encoding UTF8
    $LineNumber = 0

    foreach ($Line in $Lines) {

        $LineNumber++

        $Trimmed = $Line.Trim()

        if ([string]::IsNullOrWhiteSpace($Trimmed)) {
            continue
        }

        if ($Trimmed.StartsWith("#")) {
            continue
        }

        $CodeLine = $Trimmed -replace '\s+#.*$',''

        # Dot-source explicite
        if ($CodeLine -match '^\.\s+["'']?[^"'']*[\\/]+backups?[\\/][^"'']*["'']?') {

            $BackupViolations += [pscustomobject]@{
                File = $File.FullName
                Line = $LineNumber
                Code = $CodeLine
                Type = "DOT_SOURCE"
            }

            continue
        }

        # Import-Module explicite
        if ($CodeLine -match '(?i)\bImport-Module\b.*[\\/]+backups?[\\/]' -or
            $CodeLine -match '(?i)-ModuleInfo.*[\\/]+backups?[\\/]') {

            $BackupViolations += [pscustomobject]@{
                File = $File.FullName
                Line = $LineNumber
                Code = $CodeLine
                Type = "IMPORT_MODULE"
            }

            continue
        }

        # Invocation explicite
        if ($CodeLine -match '^\&\s+["'']?[^"'']*[\\/]+backups?[\\/][^"'']*["'']?') {

            $BackupViolations += [pscustomobject]@{
                File = $File.FullName
                Line = $LineNumber
                Code = $CodeLine
                Type = "EXECUTION"
            }

            continue
        }

        # Affectation directe d'un chemin backup à une variable
        if ($CodeLine -match '^\$[A-Za-z0-9_]+\s*=\s*["''][^"'']*[\\/]+backups?[\\/][^"'']*["'']$') {

            $BackupViolations += [pscustomobject]@{
                File = $File.FullName
                Line = $LineNumber
                Code = $CodeLine
                Type = "BACKUP_PATH_ASSIGNMENT"
            }
        }
    }
}

if ($BackupViolations.Count -gt 0) {

    Write-Host ""
    Write-Host "DEPENDANCES BACKUP REELLES DETECTEES :" -ForegroundColor Yellow

    foreach ($Violation in $BackupViolations) {
        Write-Host ("FILE : {0}" -f $Violation.File)
        Write-Host ("LINE : {0}" -f $Violation.Line)
        Write-Host ("TYPE : {0}" -f $Violation.Type)
        Write-Host ("CODE : {0}" -f $Violation.Code)
        Write-Host ""
    }
}

Check `
    -Name "No executable runtime dependency on backup directories" `
    -Condition ($BackupViolations.Count -eq 0) `
    -Reason "EXECUTABLE_BACKUP_DEPENDENCY"

# ============================================================
# 4. STATE FILES
# ============================================================

$StatePaths = @(
    "core\runtime\sandbox-execution",
    "core\runtime\sandbox-isolation",
    "core\runtime\sandbox-network-guard",
    "core\runtime\sandbox-filesystem-isolation",
    "core\runtime\sandbox-process-guard",
    "core\runtime\sandbox-secrets-guard",
    "core\runtime\sandbox-resource-guard",
    "core\runtime\sandbox-timeout-guard",
    "core\runtime\sandbox-output-guard"
)

foreach ($RelativePath in $StatePaths) {

    $Full = Join-Path $Root $RelativePath

    $StateFiles = @(
        Get-ChildItem `
            -LiteralPath $Full `
            -Recurse `
            -File `
            -Filter "*.json" `
            -ErrorAction SilentlyContinue
    )

    Check `
        -Name "State path present: $RelativePath" `
        -Condition ($StateFiles.Count -gt 0) `
        -Reason "STATE_FILE_MISSING"
}

# ============================================================
# 5. AUDIT SELF-INTEGRITY
# ============================================================

$ResolvedSelf = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)

Check `
    -Name "Audit self-exclusion valid" `
    -Condition ($ResolvedSelf -eq $ThisAuditFile) `
    -Reason "AUDIT_SELF_EXCLUSION_INVALID"

# ============================================================
# RESULT
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host "RESULTAT 8B GLOBAL"
Write-Host "============================================================"
Write-Host ("TOTAL CHECKS : {0}" -f $Total)
Write-Host ("PASS         : {0}" -f $Pass)
Write-Host ("FAIL         : {0}" -f $Fail)
Write-Host ""

if (($Fail -eq 0) -and ($Total -gt 0)) {
    Write-Host "8B GLOBAL : VALIDEE" -ForegroundColor Green
}
else {
    Write-Host "8B GLOBAL : NON VALIDEE" -ForegroundColor Red
}

Write-Host "============================================================"
Write-Host "8B GLOBAL AUDIT - FIN"
Write-Host "============================================================"

Read-Host "Appuie sur Entree pour fermer"