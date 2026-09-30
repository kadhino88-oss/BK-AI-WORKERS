param(
    [string]$ContextPath
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ContextPath)) {
    Write-Host "ContextPath obligatoire." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $ContextPath)) {
    Write-Host "Contexte introuvable : $ContextPath" -ForegroundColor Red
    exit 1
}

try {
    $Raw = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8
    $Context = $Raw | ConvertFrom-Json
}
catch {
    Write-Host "JSON invalide." -ForegroundColor Red
    exit 1
}

$Errors = @()

# ============================================================
# CHAMPS OBLIGATOIRES
# ============================================================

$RequiredFields = @(
    "schema",
    "version",
    "executionId",
    "correlationId",
    "tenantId",
    "clientId",
    "projectId",
    "workerId",
    "skillId",
    "taskId",
    "toolId",
    "action",
    "mode",
    "createdAt"
)

foreach ($Field in $RequiredFields) {

    if (-not ($Context.PSObject.Properties.Name -contains $Field)) {

        $Errors += "Champ absent : $Field"
        continue
    }

    $Value = $Context.$Field

    if ($null -eq $Value) {

        $Errors += "Champ nul : $Field"
        continue
    }

    if (
        $Value -is [string] -and
        [string]::IsNullOrWhiteSpace([string]$Value)
    ) {

        $Errors += "Champ vide : $Field"
    }
}

# ============================================================
# SECURITE
# ============================================================

if ($Context.security.tenantIsolation -ne $true) {
    $Errors += "tenantIsolation invalide"
}

if ($Context.security.clientIsolation -ne $true) {
    $Errors += "clientIsolation invalide"
}

if ($Context.security.projectIsolation -ne $true) {
    $Errors += "projectIsolation invalide"
}

if ($Context.security.authorizationRequired -ne $true) {
    $Errors += "authorizationRequired invalide"
}

if ($Context.security.secretExposureToWorker -ne $false) {
    $Errors += "secretExposureToWorker doit être FALSE"
}

# ============================================================
# FINANCE
# ============================================================

if ($Context.financial.autonomousCommitAllowed -ne $false) {
    $Errors += "autonomousCommitAllowed doit être FALSE"
}

# ============================================================
# DETECTION RECURSIVE DES CHAMPS SENSIBLES
# ============================================================

$SensitiveFieldNames = @(
    "api_key",
    "apikey",
    "api-key",
    "secret",
    "password",
    "credential",
    "credentials",
    "access_token",
    "refresh_token",
    "private_key",
    "client_secret",
    "token"
)

function Inspect-Object {
    param(
        [object]$Value,
        [string]$Path = "root"
    )

    if ($null -eq $Value) {
        return
    }

    # --------------------------------------------------------
    # OBJET
    # --------------------------------------------------------

    if (
        $Value -is [System.Collections.IDictionary]
    ) {

        foreach ($Key in $Value.Keys) {

            $CurrentPath = "$Path.$Key"
            $KeyLower = ([string]$Key).ToLowerInvariant()

            if ($SensitiveFieldNames -contains $KeyLower) {

                $script:Errors += `
                    "Champ sensible interdit : $CurrentPath"

            }

            Inspect-Object `
                -Value $Value[$Key] `
                -Path $CurrentPath
        }

        return
    }

    # --------------------------------------------------------
    # TABLEAU / COLLECTION
    # --------------------------------------------------------

    if (
        $Value -is [System.Collections.IEnumerable] -and
        -not ($Value -is [string])
    ) {

        $Index = 0

        foreach ($Item in $Value) {

            Inspect-Object `
                -Value $Item `
                -Path "$Path[$Index]"

            $Index++
        }

        return
    }

    # --------------------------------------------------------
    # OBJET JSON ConvertFrom-Json
    # --------------------------------------------------------

    $Properties = $Value.PSObject.Properties

    foreach ($Property in $Properties) {

        $Name = [string]$Property.Name
        $NameLower = $Name.ToLowerInvariant()
        $CurrentPath = "$Path.$Name"

        if ($SensitiveFieldNames -contains $NameLower) {

            $script:Errors += `
                "Champ sensible interdit : $CurrentPath"
        }

        Inspect-Object `
            -Value $Property.Value `
            -Path $CurrentPath
    }
}

Inspect-Object -Value $Context

# ============================================================
# DETECTION DES VALEURS DE SECRET CONNUES
# ============================================================

$ForbiddenValuePatterns = @(
    '^sk-[A-Za-z0-9]{10,}$',
    '^Bearer\s+[A-Za-z0-9\-_\.]+$',
    '^AKIA[A-Z0-9]{16}$'
)

function Inspect-SecretValues {
    param(
        [object]$Value,
        [string]$Path = "root"
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [string]) {

        foreach ($Pattern in $ForbiddenValuePatterns) {

            if ([regex]::IsMatch($Value, $Pattern)) {

                $script:Errors += `
                    "Valeur potentiellement secrète détectée : $Path"
            }
        }

        return
    }

    if (
        $Value -is [System.Collections.IEnumerable] -and
        -not ($Value -is [string])
    ) {

        $Index = 0

        foreach ($Item in $Value) {

            Inspect-SecretValues `
                -Value $Item `
                -Path "$Path[$Index]"

            $Index++
        }

        return
    }

    foreach ($Property in $Value.PSObject.Properties) {

        Inspect-SecretValues `
            -Value $Property.Value `
            -Path "$Path.$($Property.Name)"
    }
}

Inspect-SecretValues -Value $Context

# ============================================================
# AFFICHAGE
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       7H-13 EXECUTION CONTEXT" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "ExecutionId : $($Context.executionId)"
Write-Host "Correlation : $($Context.correlationId)"
Write-Host "Tenant      : $($Context.tenantId)"
Write-Host "Client      : $($Context.clientId)"
Write-Host "Projet      : $($Context.projectId)"
Write-Host "Worker      : $($Context.workerId)"
Write-Host "Skill       : $($Context.skillId)"
Write-Host "Task        : $($Context.taskId)"
Write-Host "Tool        : $($Context.toolId)"
Write-Host "Action      : $($Context.action)"
Write-Host "Mode        : $($Context.mode)"
Write-Host ""

if ($Errors.Count -gt 0) {

    Write-Host "RESULTAT : FAIL" -ForegroundColor Red
    Write-Host ""

    foreach ($ErrorItem in $Errors) {
        Write-Host "ERROR : $ErrorItem" -ForegroundColor Red
    }

    Write-Host ""
    exit 1
}

Write-Host "RESULTAT : PASS" -ForegroundColor Green
Write-Host "Contexte d'execution valide." -ForegroundColor Green
Write-Host ""

exit 0