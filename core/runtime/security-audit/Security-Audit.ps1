Set-StrictMode -Version Latest

$Script:AuditRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:AuditConfigPath = Join-Path $Script:AuditRoot "config.json"
$Script:AuditStatePath  = Join-Path $Script:AuditRoot "state\audit-events.json"

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
            $Result[[string]$Key] = Convert-ToPlainHashtable $InputObject[$Key]
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

function Get-AuditConfig {

    if (-not (Test-Path $Script:AuditConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content `
        -Raw `
        -Path $Script:AuditConfigPath `
        -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-AuditField {
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

function Get-AuditEvents {

    if (-not (Test-Path $Script:AuditStatePath)) {
        return @()
    }

    $Raw = Get-Content `
        -Raw `
        -Path $Script:AuditStatePath `
        -Encoding UTF8

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

function Save-AuditEvents {
    param(
        [array]$Events
    )

    $Config = Get-AuditConfig
    $MaxEvents = [int]$Config.maxEvents
    $Array = @($Events)

    if ($Array.Count -gt $MaxEvents) {
        throw "Nombre maximum d'evenements depasse."
    }

    if ($Array.Count -eq 0) {
        $Json = "[]"
    }
    else {
        $Json = ConvertTo-Json `
            -InputObject $Array `
            -Depth 30
    }

    [System.IO.File]::WriteAllText(
        $Script:AuditStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-AuditSHA256 {
    param(
        [string]$Content
    )

    if ($null -eq $Content) {
        throw "Content null."
    }

    $Bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $HashBytes = $Sha.ComputeHash($Bytes)
    }
    finally {
        $Sha.Dispose()
    }

    return (
        [System.BitConverter]::ToString($HashBytes)
    ).Replace("-", "").ToLowerInvariant()
}

function Assert-AuditContext {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId
    )

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "ClientId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "ProjectId requis."
    }
}

function Get-AuditCanonicalContent {
    param(
        $Event,
        [string]$PreviousHash
    )

    $Parts = @(
        [string](Get-AuditField $Event "EventId" ""),
        [string](Get-AuditField $Event "Sequence" 0),
        [string](Get-AuditField $Event "CorrelationId" ""),
        [string](Get-AuditField $Event "ExecutionId" ""),
        [string](Get-AuditField $Event "TenantId" ""),
        [string](Get-AuditField $Event "ClientId" ""),
        [string](Get-AuditField $Event "ProjectId" ""),
        [string](Get-AuditField $Event "WorkerId" ""),
        [string](Get-AuditField $Event "ActorType" ""),
        [string](Get-AuditField $Event "ActionType" ""),
        [string](Get-AuditField $Event "Severity" ""),
        [string](Get-AuditField $Event "Decision" ""),
        [string](Get-AuditField $Event "Reason" ""),
        [string](Get-AuditField $Event "Status" ""),
        [string](Get-AuditField $Event "CreatedAtUtc" ""),
        [string]$PreviousHash
    )

    return ($Parts -join "|")
}

function New-AuditEvent {
    param(
        [string]$EventId,
        [string]$CorrelationId,
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$ActorType,
        [string]$ActionType,
        [string]$Severity,
        [string]$Decision,
        [string]$Reason = "",
        [string]$Status = "RECORDED"
    )

    $Config = Get-AuditConfig

    if (-not $Config.enabled -or -not $Config.auditEnabled) {
        throw "Audit manager disabled."
    }

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "EventId requis."
    }

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        throw "CorrelationId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    Assert-AuditContext `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ([string]::IsNullOrWhiteSpace($WorkerId)) {
        throw "WorkerId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ActorType)) {
        throw "ActorType requis."
    }

    if ([string]::IsNullOrWhiteSpace($ActionType)) {
        throw "ActionType requis."
    }

    $AllowedActorTypes = @(
        "SYSTEM",
        "WORKER",
        "HUMAN",
        "ORCHESTRATOR"
    )

    if ($AllowedActorTypes -notcontains $ActorType.ToUpperInvariant()) {
        throw "ActorType invalide."
    }

    $AllowedSeverities = @(
        "INFO",
        "WARNING",
        "HIGH",
        "CRITICAL"
    )

    if ($AllowedSeverities -notcontains $Severity.ToUpperInvariant()) {
        throw "Severity invalide."
    }

    $AllowedDecisions = @(
        "ALLOW",
        "BLOCK",
        "ERROR",
        "PENDING"
    )

    if ($AllowedDecisions -notcontains $Decision.ToUpperInvariant()) {
        throw "Decision invalide."
    }

    return [ordered]@{
        EventId       = $EventId
        Sequence      = 0
        CorrelationId = $CorrelationId
        ExecutionId   = $ExecutionId
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        WorkerId      = $WorkerId
        ActorType     = $ActorType.ToUpperInvariant()
        ActionType    = $ActionType
        Severity      = $Severity.ToUpperInvariant()
        Decision      = $Decision.ToUpperInvariant()
        Reason        = $Reason
        Status        = $Status.ToUpperInvariant()
        PreviousHash  = ""
        EventHash     = ""
        CreatedAtUtc  = [DateTimeOffset]::UtcNow.ToString("o")
    }
}

function Add-AuditEvent {
    param(
        [System.Collections.IDictionary]$Event
    )

    $Config = Get-AuditConfig

    if (-not $Config.hashChainEnabled) {
        throw "Hash chain disabled."
    }

    $Events = @(Get-AuditEvents)

    $EventId = [string](Get-AuditField $Event "EventId")

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "EventId requis."
    }

    foreach ($Existing in $Events) {

        if (
            [string](Get-AuditField $Existing "EventId") -eq
            $EventId
        ) {
            return [ordered]@{
                Success = $false
                Status  = "DUPLICATE"
                EventId = $EventId
            }
        }
    }

    $Sequence = $Events.Count + 1
    $PreviousHash = ""

    if ($Events.Count -gt 0) {
        $PreviousHash = [string](
            Get-AuditField $Events[$Events.Count - 1] "EventHash" ""
        )
    }

    $Normalized = Convert-ToPlainHashtable $Event

    $Normalized.Sequence = $Sequence
    $Normalized.PreviousHash = $PreviousHash

    $Canonical = Get-AuditCanonicalContent `
        -Event $Normalized `
        -PreviousHash $PreviousHash

    $Normalized.EventHash = Get-AuditSHA256 $Canonical

    $Events = @($Events) + @($Normalized)

    Save-AuditEvents $Events

    return $Normalized
}

function Get-AuditEvent {
    param(
        [string]$EventId
    )

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "EventId requis."
    }

    $Events = @(Get-AuditEvents)

    foreach ($Event in $Events) {

        if (
            [string](Get-AuditField $Event "EventId") -eq
            $EventId
        ) {
            return $Event
        }
    }

    return $null
}

function Find-AuditByCorrelationId {
    param(
        [string]$CorrelationId
    )

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        throw "CorrelationId requis."
    }

    $Events = @(Get-AuditEvents)
    $Matches = @()

    foreach ($Event in $Events) {

        if (
            [string](Get-AuditField $Event "CorrelationId") -eq
            $CorrelationId
        ) {
            $Matches += ,$Event
        }
    }

    return @($Matches)
}

function Test-AuditChain {
    $Events = @(Get-AuditEvents)

    if ($Events.Count -eq 0) {
        return [ordered]@{
            Valid   = $true
            Status  = "EMPTY"
            Checked = 0
            Error   = ""
        }
    }

    $ExpectedSequence = 1
    $PreviousHash = ""

    foreach ($Event in $Events) {

        $Sequence = [int](Get-AuditField $Event "Sequence" 0)

        if ($Sequence -ne $ExpectedSequence) {
            return [ordered]@{
                Valid   = $false
                Status  = "SEQUENCE_ERROR"
                Checked = $ExpectedSequence - 1
                Error   = "Sequence invalide."
            }
        }

        $StoredPreviousHash =
            [string](Get-AuditField $Event "PreviousHash" "")

        if ($StoredPreviousHash -ne $PreviousHash) {
            return [ordered]@{
                Valid   = $false
                Status  = "CHAIN_ERROR"
                Checked = $ExpectedSequence - 1
                Error   = "PreviousHash invalide."
            }
        }

        $Canonical = Get-AuditCanonicalContent `
            -Event $Event `
            -PreviousHash $PreviousHash

        $CalculatedHash = Get-AuditSHA256 $Canonical
        $StoredHash = [string](Get-AuditField $Event "EventHash" "")

        if ($CalculatedHash -ne $StoredHash) {
            return [ordered]@{
                Valid   = $false
                Status  = "HASH_ERROR"
                Checked = $ExpectedSequence - 1
                Error   = "EventHash invalide."
            }
        }

        $PreviousHash = $StoredHash
        $ExpectedSequence++
    }

    return [ordered]@{
        Valid   = $true
        Status  = "VALID"
        Checked = $Events.Count
        Error   = ""
    }
}

function Reset-AuditEvents {
    Save-AuditEvents @()
    return "RESET"
}