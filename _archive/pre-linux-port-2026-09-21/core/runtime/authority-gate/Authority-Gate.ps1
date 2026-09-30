Set-StrictMode -Version Latest

$Script:GateRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:GateConfigPath = Join-Path $Script:GateRoot "config.json"
$Script:GateStatePath = Join-Path $Script:GateRoot "state\authority-requests.json"

function Convert-ToPlainHashtable {
    param($InputObject)

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

function Get-AuthorityConfig {
    if (-not (Test-Path $Script:GateConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:GateConfigPath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-AuthorityField {
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

function Get-AuthorityRequests {
    if (-not (Test-Path $Script:GateStatePath)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $Script:GateStatePath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    if ($Raw.Trim() -eq "null") {
        return @()
    }

    $Object = $Raw | ConvertFrom-Json
    $Plain = Convert-ToPlainHashtable $Object

    if ($null -eq $Plain) {
        return @()
    }

    return @($Plain)
}

function Save-AuthorityRequests {
    param(
        [array]$Requests
    )

    $Config = Get-AuthorityConfig
    $Max = [int]$Config.maxRequests
    $Array = @($Requests)

    if ($Array.Count -gt $Max) {
        throw "Nombre maximum de demandes depasse."
    }

    if ($Array.Count -eq 0) {
        $Json = "[]"
    }
    else {
        $Json = ConvertTo-Json -InputObject $Array -Depth 30
    }

    [System.IO.File]::WriteAllText(
        $Script:GateStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-AuthorityRequest {
    param(
        [string]$RequestId
    )

    if ([string]::IsNullOrWhiteSpace($RequestId)) {
        throw "RequestId requis."
    }

    $Requests = @(Get-AuthorityRequests)

    foreach ($Request in $Requests) {
        if (
            [string](Get-AuthorityField $Request "RequestId") -eq $RequestId
        ) {
            return $Request
        }
    }

    return $null
}

function Get-RiskClass {
    param(
        [string]$ActionType
    )

    if ([string]::IsNullOrWhiteSpace($ActionType)) {
        throw "ActionType requis."
    }

    switch ($ActionType.ToUpperInvariant()) {

        "READ" {
            return "LOW"
        }

        "ANALYZE" {
            return "LOW"
        }

        "GENERATE" {
            return "LOW"
        }

        "EMAIL" {
            return "MEDIUM"
        }

        "PUBLISH" {
            return "MEDIUM"
        }

        "DELETE" {
            return "HIGH"
        }

        "PAYMENT" {
            return "CRITICAL"
        }

        "TRANSFER" {
            return "CRITICAL"
        }

        "REFUND" {
            return "CRITICAL"
        }

        "INVEST" {
            return "CRITICAL"
        }

        default {
            return "HIGH"
        }
    }
}

function New-AuthorityRequest {
    param(
        [string]$RequestId,
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$ActionType,
        [string]$Description = ""
    )

    $Config = Get-AuthorityConfig

    if (-not $Config.enabled -or -not $Config.authorityGateEnabled) {
        throw "Authority gate disabled."
    }

    if ([string]::IsNullOrWhiteSpace($RequestId)) {
        throw "RequestId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "ClientId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "ProjectId requis."
    }

    if ([string]::IsNullOrWhiteSpace($WorkerId)) {
        throw "WorkerId requis."
    }

    $Existing = Get-AuthorityRequest $RequestId

    if ($null -ne $Existing) {
        return [ordered]@{
            Success = $false
            Status = "DUPLICATE"
            RequestId = $RequestId
        }
    }

    $RiskClass = Get-RiskClass $ActionType

    $Decision = "APPROVAL_REQUIRED"

    if ($RiskClass -eq "LOW") {
        $Decision = "ALLOW_SIMULATION"
    }

    $Now = [DateTimeOffset]::UtcNow
    $Expiry = $Now.AddSeconds(
        [double]$Config.approvalExpirySeconds
    )

    $Record = [ordered]@{
        RequestId = $RequestId
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        ActionType = $ActionType
        Description = $Description
        RiskClass = $RiskClass
        Decision = $Decision
        ApprovalStatus = if ($RiskClass -eq "LOW") {
            "NOT_REQUIRED"
        }
        else {
            "PENDING"
        }
        Approver = ""
        ApprovedAtUtc = ""
        ExpiresAtUtc = $Expiry.ToString("o")
        SimulationOnly = $true
        CreatedAtUtc = $Now.ToString("o")
        UpdatedAtUtc = $Now.ToString("o")
    }

    $Requests = @(Get-AuthorityRequests)
    $Requests = @($Requests) + @($Record)

    Save-AuthorityRequests $Requests

    return $Record
}

function Approve-AuthorityRequest {
    param(
        [string]$RequestId,
        [string]$Approver
    )

    $Config = Get-AuthorityConfig

    if (-not $Config.humanApprovalRequired) {
        throw "Human approval disabled."
    }

    if ([string]::IsNullOrWhiteSpace($Approver)) {
        throw "Approver requis."
    }

    $Requests = @(Get-AuthorityRequests)
    $FoundIndex = -1

    for ($Index = 0; $Index -lt $Requests.Count; $Index++) {

        if (
            [string](Get-AuthorityField $Requests[$Index] "RequestId") -eq $RequestId
        ) {
            $FoundIndex = $Index
            break
        }
    }

    if ($FoundIndex -lt 0) {
        throw "RequestId introuvable."
    }

    $Current = Convert-ToPlainHashtable $Requests[$FoundIndex]

    $RiskClass = [string](Get-AuthorityField $Current "RiskClass")

    if ($RiskClass -eq "LOW") {
        throw "Approbation non requise pour cette action."
    }

    $ApprovalStatus = [string](Get-AuthorityField $Current "ApprovalStatus")

    if ($ApprovalStatus -eq "APPROVED") {
        return [ordered]@{
            Success = $false
            Status = "DUPLICATE_APPROVAL"
            RequestId = $RequestId
        }
    }

    $ExpiryText = [string](Get-AuthorityField $Current "ExpiresAtUtc")

    $Expiry = [DateTimeOffset]::Parse($ExpiryText)
    $Now = [DateTimeOffset]::UtcNow

    if ($Now -gt $Expiry) {
        $Current.Decision = "BLOCK"
        $Current.ApprovalStatus = "EXPIRED"
        $Current.UpdatedAtUtc = $Now.ToString("o")

        $Requests[$FoundIndex] = $Current
        Save-AuthorityRequests $Requests

        return $Current
    }

    $Current.Decision = "APPROVED"
    $Current.ApprovalStatus = "APPROVED"
    $Current.Approver = $Approver
    $Current.ApprovedAtUtc = $Now.ToString("o")
    $Current.UpdatedAtUtc = $Now.ToString("o")

    $Requests[$FoundIndex] = $Current
    Save-AuthorityRequests $Requests

    return $Current
}

function Test-AuthorityExecution {
    param(
        [string]$RequestId
    )

    $Config = Get-AuthorityConfig
    $Request = Get-AuthorityRequest $RequestId

    if ($null -eq $Request) {
        return [ordered]@{
            Allowed = $false
            Decision = "BLOCK"
            Reason = "REQUEST_NOT_FOUND"
        }
    }

    if ($Config.liveExecutionEnabled -eq $false) {
        return [ordered]@{
            Allowed = $true
            Decision = "SIMULATION_ONLY"
            Reason = "LIVE_EXECUTION_DISABLED"
            RequestId = $RequestId
        }
    }

    $RiskClass = [string](Get-AuthorityField $Request "RiskClass")

    if ($RiskClass -eq "LOW") {
        return [ordered]@{
            Allowed = $true
            Decision = "ALLOW"
            Reason = "LOW_RISK"
            RequestId = $RequestId
        }
    }

    $ApprovalStatus = [string](Get-AuthorityField $Request "ApprovalStatus")

    if ($ApprovalStatus -ne "APPROVED") {
        return [ordered]@{
            Allowed = $false
            Decision = "BLOCK"
            Reason = "HUMAN_APPROVAL_REQUIRED"
            RequestId = $RequestId
        }
    }

    $ExpiryText = [string](Get-AuthorityField $Request "ExpiresAtUtc")
    $Expiry = [DateTimeOffset]::Parse($ExpiryText)

    if ([DateTimeOffset]::UtcNow -gt $Expiry) {
        return [ordered]@{
            Allowed = $false
            Decision = "BLOCK"
            Reason = "APPROVAL_EXPIRED"
            RequestId = $RequestId
        }
    }

    return [ordered]@{
        Allowed = $true
        Decision = "ALLOW"
        Reason = "HUMAN_APPROVAL_VALID"
        RequestId = $RequestId
    }
}

function Reset-AuthorityRequests {
    Save-AuthorityRequests @()
    return "RESET"
}