Set-StrictMode -Version Latest

$Script:GuardRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:GuardConfigPath = Join-Path $Script:GuardRoot "config.json"
$Script:GuardStatePath = Join-Path $Script:GuardRoot "state/environment.json"

function Convert-ToPlainHashtable {
    param($InputObject)
    # PowerShell 7 convertit les dates ISO en [datetime] (recursion infinie via .Date) ;
    # Windows PowerShell 5.1 les laissait en texte : on renvoie le meme texte ISO.
    if ($InputObject -is [datetime]) { return $InputObject.ToString("o") }
    if ($InputObject -is [datetimeoffset]) { return $InputObject.ToString("o") }


    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $Result = [ordered]@{}

        foreach ($Key in $InputObject.Keys) {
            $Result[[string]$Key] =
                Convert-ToPlainHashtable $InputObject[$Key]
        }

        return $Result
    }

    if (
        ($InputObject -is [System.Collections.IEnumerable]) -and
        -not ($InputObject -is [string])
    ) {
        $Array = @()

        foreach ($Item in $InputObject) {
            $Array += ,(Convert-ToPlainHashtable $Item)
        }

        return $Array
    }

    if ($InputObject -is [pscustomobject]) {
        $Result = [ordered]@{}

        foreach ($Property in $InputObject.PSObject.Properties) {
            $Result[$Property.Name] =
                Convert-ToPlainHashtable $Property.Value
        }

        return $Result
    }

    return $InputObject
}

function Get-EnvironmentConfig {
    if (-not (Test-Path $Script:GuardConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:GuardConfigPath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-EnvironmentField {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
    }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -ne $Property) {
        return $Property.Value
    }

    return $Default
}

function Get-EnvironmentState {
    if (-not (Test-Path $Script:GuardStatePath)) {
        return [ordered]@{
            Environment = "SIMULATION"
            LiveEnabled = $false
            ProductionFlag = $false
            HumanApproval = $false
            UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        }
    }

    $Raw = Get-Content -Raw -Path $Script:GuardStatePath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return [ordered]@{
            Environment = "SIMULATION"
            LiveEnabled = $false
            ProductionFlag = $false
            HumanApproval = $false
            UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        }
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Save-EnvironmentState {
    param(
        [System.Collections.IDictionary]$State
    )

    $Json = ConvertTo-Json -InputObject $State -Depth 20

    [System.IO.File]::WriteAllText(
        $Script:GuardStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Reset-EnvironmentState {

    $State = [ordered]@{
        Environment = "SIMULATION"
        LiveEnabled = $false
        ProductionFlag = $false
        HumanApproval = $false
        UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }

    Save-EnvironmentState $State

    return $State
}

function Set-ExecutionEnvironment {
    param(
        [string]$Environment
    )

    $Config = Get-EnvironmentConfig

    if (-not $Config.enabled -or -not $Config.environmentGuardEnabled) {
        throw "Environment guard disabled."
    }

    if ([string]::IsNullOrWhiteSpace($Environment)) {
        throw "Environment requis."
    }

    $Normalized = $Environment.ToUpperInvariant()

    if (
        $Normalized -ne "SIMULATION" -and
        $Normalized -ne "SANDBOX" -and
        $Normalized -ne "LIVE"
    ) {
        throw "Environment invalide."
    }

    $State = Get-EnvironmentState

    if ($Normalized -eq "SIMULATION") {
        $State.Environment = "SIMULATION"
        $State.LiveEnabled = $false
        $State.ProductionFlag = $false
        $State.HumanApproval = $false
    }

    if ($Normalized -eq "SANDBOX") {
        if (-not $Config.sandboxEnabled) {
            throw "Sandbox disabled."
        }

        $State.Environment = "SANDBOX"
        $State.LiveEnabled = $false
        $State.ProductionFlag = $false
        $State.HumanApproval = $false
    }

    if ($Normalized -eq "LIVE") {
        if (-not $Config.liveEnabled) {
            throw "Live environment disabled by configuration."
        }

        if (-not $Config.requireExplicitLiveEnable) {
            throw "Explicit live enablement missing."
        }

        $State.Environment = "LIVE"
        $State.LiveEnabled = $true
    }

    $State.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    Save-EnvironmentState $State

    return $State
}

function Enable-LiveExecution {
    param(
        [string]$Approver,
        [string]$ProductionFlag
    )

    $Config = Get-EnvironmentConfig
    $State = Get-EnvironmentState

    if (-not $Config.liveEnabled) {
        throw "Live execution disabled by configuration."
    }

    if (-not $Config.requireHumanApprovalForLive) {
        throw "Human approval requirement disabled."
    }

    if ([string]::IsNullOrWhiteSpace($Approver)) {
        throw "Approver requis."
    }

    if ($ProductionFlag -ne "BK-AI-PRODUCTION-ENABLE") {
        throw "Production flag invalide."
    }

    if ($State.Environment -ne "LIVE") {
        throw "Environment LIVE requis."
    }

    $State.LiveEnabled = $true
    $State.ProductionFlag = $true
    $State.HumanApproval = $true
    $State.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    $State.Approver = $Approver
    $State.ApprovedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    Save-EnvironmentState $State

    return $State
}

function Disable-LiveExecution {

    $State = Get-EnvironmentState

    $State.Environment = "SIMULATION"
    $State.LiveEnabled = $false
    $State.ProductionFlag = $false
    $State.HumanApproval = $false
    $State.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    if ($State.Contains("Approver")) {
        $State.Remove("Approver")
    }

    if ($State.Contains("ApprovedAtUtc")) {
        $State.Remove("ApprovedAtUtc")
    }

    Save-EnvironmentState $State

    return $State
}

function Test-ExecutionEnvironment {
    param(
        [string]$ActionType,
        [bool]$RequiresLive = $true
    )

    $State = Get-EnvironmentState

    if ($State.Environment -eq "SIMULATION") {
        return [ordered]@{
            Allowed = $true
            Decision = "SIMULATION"
            Reason = "SIMULATION_MODE"
            Environment = "SIMULATION"
        }
    }

    if ($State.Environment -eq "SANDBOX") {
        return [ordered]@{
            Allowed = $true
            Decision = "SANDBOX"
            Reason = "SANDBOX_MODE"
            Environment = "SANDBOX"
        }
    }

    if ($State.Environment -ne "LIVE") {
        return [ordered]@{
            Allowed = $false
            Decision = "BLOCK"
            Reason = "UNKNOWN_ENVIRONMENT"
            Environment = [string]$State.Environment
        }
    }

    if (-not $RequiresLive) {
        return [ordered]@{
            Allowed = $true
            Decision = "LIVE"
            Reason = "LIVE_NOT_REQUIRED"
            Environment = "LIVE"
        }
    }

    if ($State.LiveEnabled -ne $true) {
        return [ordered]@{
            Allowed = $false
            Decision = "BLOCK"
            Reason = "LIVE_DISABLED"
            Environment = "LIVE"
        }
    }

    if ($State.ProductionFlag -ne $true) {
        return [ordered]@{
            Allowed = $false
            Decision = "BLOCK"
            Reason = "PRODUCTION_FLAG_REQUIRED"
            Environment = "LIVE"
        }
    }

    if ($State.HumanApproval -ne $true) {
        return [ordered]@{
            Allowed = $false
            Decision = "BLOCK"
            Reason = "HUMAN_APPROVAL_REQUIRED"
            Environment = "LIVE"
        }
    }

    return [ordered]@{
        Allowed = $true
        Decision = "LIVE"
        Reason = "LIVE_AUTHORIZED"
        Environment = "LIVE"
    }
}