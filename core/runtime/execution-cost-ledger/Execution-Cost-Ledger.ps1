Set-StrictMode -Version Latest

$Script:LedgerRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:LedgerConfigPath = Join-Path $Script:LedgerRoot "config.json"
$Script:LedgerStatePath  = Join-Path $Script:LedgerRoot "state\ledger.json"

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

function Get-CostConfig {
    if (-not (Test-Path $Script:LedgerConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:LedgerConfigPath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-CostField {
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

function Get-CostLedger {
    if (-not (Test-Path $Script:LedgerStatePath)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $Script:LedgerStatePath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    if ($Raw.Trim() -eq "null") {
        return @()
    }

    $Object = $Raw | ConvertFrom-Json
    $Plain = Convert-ToPlainHashtable $Object

    # IMPORTANT :
    # Toujours retourner un tableau.
    # 0 entrée  => @()
    # 1 entrée  => @($Plain)
    # N entrées => tableau
    if ($null -eq $Plain) {
        return @()
    }

    return @($Plain)
}

function Save-CostLedger {
    param(
        [array]$Ledger
    )

    $Config = Get-CostConfig
    $MaxEntries = [int]$Config.maxEntries

    $LedgerArray = @($Ledger)

    if ($LedgerArray.Count -gt $MaxEntries) {
        throw "Nombre maximum d'evenements depasse."
    }

    if ($LedgerArray.Count -eq 0) {
        $Json = "[]"
    }
    else {
        # InputObject force ConvertTo-Json à conserver le tableau.
        $Json = ConvertTo-Json -InputObject $LedgerArray -Depth 30
    }

    [System.IO.File]::WriteAllText(
        $Script:LedgerStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Assert-CostContext {
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

function New-CostEvent {
    param(
        [string]$EventId,
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [decimal]$Amount,
        [string]$Currency = "UNIT",
        [string]$Provider = "",
        [string]$Operation = ""
    )

    $Config = Get-CostConfig

    if (-not $Config.enabled -or -not $Config.ledgerEnabled) {
        throw "Cost ledger disabled."
    }

    Assert-CostContext `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "EventId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ($Amount -lt 0) {
        throw "Amount invalide."
    }

    if ([string]::IsNullOrWhiteSpace($Currency)) {
        throw "Currency requise."
    }

    return [ordered]@{
        EventId       = $EventId
        ExecutionId   = $ExecutionId
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        WorkerId      = $WorkerId
        Amount        = $Amount
        Currency      = $Currency
        Provider      = $Provider
        Operation     = $Operation
        RecordedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
        Status        = "RECORDED"
    }
}

function Add-CostEvent {
    param(
        [System.Collections.IDictionary]$Event
    )

    $Config = Get-CostConfig

    if (-not $Config.idempotencyEnabled) {
        throw "Idempotency disabled."
    }

    # IMPORTANT :
    # Force toujours un tableau.
    $Ledger = @(Get-CostLedger)

    $EventId = [string](Get-CostField $Event "EventId")

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "EventId requis."
    }

    foreach ($Existing in $Ledger) {
        if ([string](Get-CostField $Existing "EventId") -eq $EventId) {
            return [ordered]@{
                Success = $false
                Status  = "DUPLICATE"
                EventId = $EventId
            }
        }
    }

    $Normalized = New-CostEvent `
        -EventId $EventId `
        -ExecutionId ([string](Get-CostField $Event "ExecutionId")) `
        -TenantId ([string](Get-CostField $Event "TenantId")) `
        -ClientId ([string](Get-CostField $Event "ClientId")) `
        -ProjectId ([string](Get-CostField $Event "ProjectId")) `
        -WorkerId ([string](Get-CostField $Event "WorkerId")) `
        -Amount ([decimal](Get-CostField $Event "Amount" 0)) `
        -Currency ([string](Get-CostField $Event "Currency" $Config.currency)) `
        -Provider ([string](Get-CostField $Event "Provider" "")) `
        -Operation ([string](Get-CostField $Event "Operation" ""))

    # Toujours ajouter un élément au tableau.
    $Ledger = @($Ledger) + @($Normalized)

    Save-CostLedger -Ledger $Ledger

    return [ordered]@{
        Success = $true
        Status  = "RECORDED"
        EventId = $EventId
    }
}

function Get-CostEvent {
    param(
        [string]$EventId
    )

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "EventId requis."
    }

    $Ledger = @(Get-CostLedger)

    foreach ($Event in $Ledger) {
        if ([string](Get-CostField $Event "EventId") -eq $EventId) {
            return $Event
        }
    }

    return $null
}

function Get-ExecutionCostTotal {
    param(
        [string]$ExecutionId
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    $Ledger = @(Get-CostLedger)
    [decimal]$Total = 0

    foreach ($Event in $Ledger) {
        if ([string](Get-CostField $Event "ExecutionId") -eq $ExecutionId) {
            $Total += [decimal](Get-CostField $Event "Amount" 0)
        }
    }

    return $Total
}

function Get-ProjectCostTotal {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId
    )

    Assert-CostContext `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    $Ledger = @(Get-CostLedger)
    [decimal]$Total = 0

    foreach ($Event in $Ledger) {
        if (
            [string](Get-CostField $Event "TenantId") -eq $TenantId -and
            [string](Get-CostField $Event "ClientId") -eq $ClientId -and
            [string](Get-CostField $Event "ProjectId") -eq $ProjectId
        ) {
            $Total += [decimal](Get-CostField $Event "Amount" 0)
        }
    }

    return $Total
}

function Reconcile-ExecutionCost {
    param(
        [string]$ExecutionId,
        [decimal]$ExpectedAmount
    )

    $Config = Get-CostConfig

    if (-not $Config.reconciliationEnabled) {
        throw "Reconciliation disabled."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ($ExpectedAmount -lt 0) {
        throw "ExpectedAmount invalide."
    }

    $ActualAmount = Get-ExecutionCostTotal $ExecutionId
    $Difference = $ActualAmount - $ExpectedAmount
    $Tolerance = [decimal]$Config.tolerance

    $Reconciled = [Math]::Abs([double]$Difference) -le [double]$Tolerance

    return [ordered]@{
        ExecutionId = $ExecutionId
        Expected    = $ExpectedAmount
        Actual      = $ActualAmount
        Difference  = $Difference
        Tolerance   = $Tolerance
        Reconciled  = $Reconciled
        Status      = if ($Reconciled) { "MATCHED" } else { "MISMATCH" }
    }
}

function Test-CostIsolation {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [decimal]$Expected
    )

    $Actual = Get-ProjectCostTotal `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    return $Actual -eq $Expected
}

function Reset-CostLedger {
    Save-CostLedger -Ledger @()
    return "RESET"
}