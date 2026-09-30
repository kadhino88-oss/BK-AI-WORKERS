$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "HEALTH-DIAGNOSTICS-CONFIG.json"
$StatePath = Join-Path $StateDir "health-state.json"

function Get-HealthDiagnosticsConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Health Diagnostics introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function New-HealthCheckResult {
    param(
        [string]$Component,
        [ValidateSet("HEALTHY","DEGRADED","UNHEALTHY","UNKNOWN")]
        [string]$Status,
        [string]$Message,
        [double]$DurationMs = 0
    )

    if ([string]::IsNullOrWhiteSpace($Component)) {
        throw "Component requis."
    }

    if ($Component.Length -gt 200) {
        throw "Component trop long."
    }

    if ($Component -match '[\r\n]') {
        throw "Component invalide."
    }

    if ([string]::IsNullOrWhiteSpace($Message)) {
        throw "Message requis."
    }

    if ($Message.Length -gt 500) {
        throw "Message trop long."
    }

    if ($Message -match '[\r\n]') {
        throw "Message invalide."
    }

    if ($DurationMs -lt 0) {
        throw "DurationMs invalide."
    }

    return [ordered]@{
        CheckId = [Guid]::NewGuid().ToString()
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        Component = $Component
        Status = $Status
        Message = $Message
        DurationMs = [math]::Round($DurationMs,2)
    }
}

function Invoke-HealthCheck {
    param(
        [string]$Component,
        [scriptblock]$Check
    )

    if ([string]::IsNullOrWhiteSpace($Component)) {
        throw "Component requis."
    }

    if ($null -eq $Check) {
        throw "Check requis."
    }

    $start = Get-Date

    try {

        $result = & $Check

        $elapsed = ((Get-Date) - $start).TotalMilliseconds

        if ($null -eq $result) {

            return New-HealthCheckResult `
                -Component $Component `
                -Status "UNKNOWN" `
                -Message "Aucun résultat fourni." `
                -DurationMs $elapsed
        }

        if ($result -is [bool]) {

            if ($result) {

                return New-HealthCheckResult `
                    -Component $Component `
                    -Status "HEALTHY" `
                    -Message "Contrôle réussi." `
                    -DurationMs $elapsed
            }

            return New-HealthCheckResult `
                -Component $Component `
                -Status "UNHEALTHY" `
                -Message "Contrôle échoué." `
                -DurationMs $elapsed
        }

        if ($result.PSObject.Properties.Name -contains "Status") {

            $status = [string]$result.Status

            if ($status -notin @(
                "HEALTHY",
                "DEGRADED",
                "UNHEALTHY",
                "UNKNOWN"
            )) {
                $status = "UNKNOWN"
            }

            $message = "Contrôle terminé."

            if ($result.PSObject.Properties.Name -contains "Message") {
                $message = [string]$result.Message
            }

            return New-HealthCheckResult `
                -Component $Component `
                -Status $status `
                -Message $message `
                -DurationMs $elapsed
        }

        return New-HealthCheckResult `
            -Component $Component `
            -Status "HEALTHY" `
            -Message "Contrôle terminé avec résultat." `
            -DurationMs $elapsed

    }
    catch {

        $elapsed = ((Get-Date) - $start).TotalMilliseconds

        return New-HealthCheckResult `
            -Component $Component `
            -Status "UNHEALTHY" `
            -Message $_.Exception.Message `
            -DurationMs $elapsed
    }
}

function Test-PathHealth {
    param(
        [string]$Path,
        [string]$Component
    )

    return Invoke-HealthCheck `
        -Component $Component `
        -Check {

            if (Test-Path -LiteralPath $Path) {
                return $true
            }

            throw "Chemin introuvable."
        }
}

function Test-ConfigurationHealth {

    $config = Get-HealthDiagnosticsConfig

    $required = @(
        "version",
        "system",
        "enabled",
        "healthChecksEnabled",
        "diagnosticsEnabled",
        "captureSecrets",
        "capturePayloads",
        "liveExecutionEnabled"
    )

    foreach ($name in $required) {

        if ($config.PSObject.Properties.Name -notcontains $name) {
            throw "Champ de configuration manquant : $name"
        }
    }

    if ($config.version -ne "1.0") {
        throw "Version de configuration invalide."
    }

    if ($config.system -ne "BK-AI-WORKERS") {
        throw "Identité système invalide."
    }

    if ($config.captureSecrets -ne $false) {
        throw "captureSecrets doit rester FALSE."
    }

    if ($config.capturePayloads -ne $false) {
        throw "capturePayloads doit rester FALSE."
    }

    if ($config.liveExecutionEnabled -ne $false) {
        throw "liveExecutionEnabled doit rester FALSE."
    }

    return $true
}

function Test-RuntimeHealth {

    $checks = @()

    $checks += Test-PathHealth `
        -Path $RuntimeRoot `
        -Component "health-diagnostics-runtime"

    $checks += Test-PathHealth `
        -Path $ConfigPath `
        -Component "health-diagnostics-config"

    $checks += Invoke-HealthCheck `
        -Component "powershell-runtime" `
        -Check {
            if ($PSVersionTable.PSVersion.Major -ge 5) {
                return $true
            }

            throw "Version PowerShell insuffisante."
        }

    $checks += Invoke-HealthCheck `
        -Component "state-directory" `
        -Check {
            New-Item `
                -ItemType Directory `
                -Force `
                -Path $StateDir | Out-Null

            if (Test-Path -LiteralPath $StateDir) {
                return $true
            }

            throw "State directory indisponible."
        }

    return @($checks)
}

function Test-DependencyHealth {

    $checks = @()

    $checks += Invoke-HealthCheck `
        -Component "json-engine" `
        -Check {
            $obj = '{"ok":true}' | ConvertFrom-Json

            if ($obj.ok -eq $true) {
                return $true
            }

            throw "JSON engine indisponible."
        }

    $checks += Invoke-HealthCheck `
        -Component "guid-engine" `
        -Check {
            $id = [Guid]::NewGuid()

            if ($id.ToString().Length -eq 36) {
                return $true
            }

            throw "GUID engine indisponible."
        }

    $checks += Invoke-HealthCheck `
        -Component "filesystem-engine" `
        -Check {
            $temp = Join-Path $StateDir "health-write-test.tmp"

            "health-test" |
                Set-Content `
                    -LiteralPath $temp `
                    -Encoding UTF8

            $ok = Test-Path -LiteralPath $temp

            if (Test-Path -LiteralPath $temp) {
                Remove-Item -LiteralPath $temp -Force
            }

            if ($ok) {
                return $true
            }

            throw "Filesystem indisponible."
        }

    return @($checks)
}

function Get-SystemHealth {

    $config = Get-HealthDiagnosticsConfig

    if (-not $config.enabled) {

        return [pscustomobject]@{
            OverallStatus = "UNKNOWN"
            CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            Checks = @()
            Healthy = 0
            Degraded = 0
            Unhealthy = 0
            Unknown = 1
        }
    }

    if (-not $config.healthChecksEnabled) {

        return [pscustomobject]@{
            OverallStatus = "UNKNOWN"
            CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
            Checks = @()
            Healthy = 0
            Degraded = 0
            Unhealthy = 0
            Unknown = 1
        }
    }

    $checks = @()

    if ($config.configurationChecksEnabled) {
        $checks += Invoke-HealthCheck `
            -Component "configuration" `
            -Check {
                Test-ConfigurationHealth
            }
    }

    if ($config.runtimeChecksEnabled) {
        $checks += Test-RuntimeHealth
    }

    if ($config.dependencyChecksEnabled) {
        $checks += Test-DependencyHealth
    }

    $healthy = @(
        $checks | Where-Object Status -eq "HEALTHY"
    ).Count

    $degraded = @(
        $checks | Where-Object Status -eq "DEGRADED"
    ).Count

    $unhealthy = @(
        $checks | Where-Object Status -eq "UNHEALTHY"
    ).Count

    $unknown = @(
        $checks | Where-Object Status -eq "UNKNOWN"
    ).Count

    if ($unhealthy -gt 0) {
        $overall = "UNHEALTHY"
    }
    elseif ($degraded -gt 0) {
        $overall = "DEGRADED"
    }
    elseif ($unknown -gt 0) {
        $overall = "UNKNOWN"
    }
    else {
        $overall = "HEALTHY"
    }

    $report = [pscustomobject]@{
        OverallStatus = $overall
        CheckedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Checks = @($checks)
        Healthy = $healthy
        Degraded = $degraded
        Unhealthy = $unhealthy
        Unknown = $unknown
    }

    Save-HealthState -HealthReport $report | Out-Null

    return $report
}

function Save-HealthState {
    param(
        [object]$HealthReport
    )

    if ($null -eq $HealthReport) {
        throw "HealthReport requis."
    }

    New-Item `
        -ItemType Directory `
        -Force `
        -Path $StateDir | Out-Null

    $HealthReport |
        ConvertTo-Json -Depth 8 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function Get-SavedHealthState {

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return $null
    }

    return Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Reset-HealthState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    return $true
}