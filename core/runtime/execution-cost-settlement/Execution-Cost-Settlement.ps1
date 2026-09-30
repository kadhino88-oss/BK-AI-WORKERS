Set-StrictMode -Version Latest

$Script:SettlementRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:SettlementConfigPath = Join-Path $Script:SettlementRoot "config.json"
$Script:SettlementStatePath  = Join-Path $Script:SettlementRoot "state\settlements.json"

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

function Get-SettlementConfig {
    if (-not (Test-Path $Script:SettlementConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:SettlementConfigPath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-SettlementField {
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

function Get-SettlementStore {
    if (-not (Test-Path $Script:SettlementStatePath)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $Script:SettlementStatePath -Encoding UTF8

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

function Save-SettlementStore {
    param(
        [array]$Records
    )

    $Config = Get-SettlementConfig
    $Max = [int]$Config.maxSettlements
    $Array = @($Records)

    if ($Array.Count -gt $Max) {
        throw "Nombre maximum de settlements depasse."
    }

    if ($Array.Count -eq 0) {
        $Json = "[]"
    }
    else {
        $Json = ConvertTo-Json -InputObject $Array -Depth 30
    }

    [System.IO.File]::WriteAllText(
        $Script:SettlementStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-Settlement {
    param(
        [string]$SettlementId
    )

    if ([string]::IsNullOrWhiteSpace($SettlementId)) {
        throw "SettlementId requis."
    }

    $Records = @(Get-SettlementStore)

    foreach ($Record in $Records) {
        if (
            [string](Get-SettlementField $Record "SettlementId") -eq $SettlementId
        ) {
            return $Record
        }
    }

    return $null
}

function Get-AuthorizationRuntime {
    $Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cost-gateway\Execution-Cost-Gateway.ps1"

    if (-not (Test-Path $Path)) {
        throw "7H-49 runtime introuvable."
    }

    . $Path
}

function Get-BudgetRuntime {
    $Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-budget\Execution-Budget.ps1"

    if (-not (Test-Path $Path)) {
        throw "7H-46 runtime introuvable."
    }

    . $Path
}

function Get-LedgerRuntime {
    $Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-cost-ledger\Execution-Cost-Ledger.ps1"

    if (-not (Test-Path $Path)) {
        throw "7H-47 runtime introuvable."
    }

    . $Path
}

function Test-SettlementAuthorization {
    param(
        [string]$AuthorizationId,
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$BudgetId
    )

    Get-AuthorizationRuntime

    $Authorization = Get-Authorization $AuthorizationId

    if ($null -eq $Authorization) {
        return [ordered]@{
            Allowed = $false
            Reason  = "AUTHORIZATION_NOT_FOUND"
        }
    }

    if ([string](Get-SettlementField $Authorization "ExecutionId") -ne $ExecutionId) {
        return [ordered]@{
            Allowed = $false
            Reason  = "EXECUTION_MISMATCH"
        }
    }

    if ([string](Get-SettlementField $Authorization "TenantId") -ne $TenantId) {
        return [ordered]@{
            Allowed = $false
            Reason  = "TENANT_MISMATCH"
        }
    }

    if ([string](Get-SettlementField $Authorization "ClientId") -ne $ClientId) {
        return [ordered]@{
            Allowed = $false
            Reason  = "CLIENT_MISMATCH"
        }
    }

    if ([string](Get-SettlementField $Authorization "ProjectId") -ne $ProjectId) {
        return [ordered]@{
            Allowed = $false
            Reason  = "PROJECT_MISMATCH"
        }
    }

    if ([string](Get-SettlementField $Authorization "BudgetId") -ne $BudgetId) {
        return [ordered]@{
            Allowed = $false
            Reason  = "BUDGET_MISMATCH"
        }
    }

    if ([string](Get-SettlementField $Authorization "Decision") -ne "ALLOW") {
        return [ordered]@{
            Allowed = $false
            Reason  = "AUTHORIZATION_NOT_ALLOWED"
        }
    }

    return [ordered]@{
        Allowed = $true
        Reason  = "AUTHORIZED"
    }
}

function Start-CostSettlement {
    param(
        [string]$SettlementId,
        [string]$AuthorizationId,
        [string]$ExecutionId,
        [string]$BudgetId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId
    )

    $Config = Get-SettlementConfig

    if (-not $Config.enabled -or -not $Config.settlementEnabled) {
        throw "Settlement disabled."
    }

    if ([string]::IsNullOrWhiteSpace($SettlementId)) {
        throw "SettlementId requis."
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        throw "AuthorizationId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($BudgetId)) {
        throw "BudgetId requis."
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

    $Existing = Get-Settlement $SettlementId

    if ($null -ne $Existing) {
        return [ordered]@{
            Success      = $false
            Status       = "DUPLICATE"
            SettlementId = $SettlementId
        }
    }

    $AuthCheck = Test-SettlementAuthorization `
        -AuthorizationId $AuthorizationId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -BudgetId $BudgetId

    if (-not $AuthCheck.Allowed) {
        return [ordered]@{
            Success      = $false
            Status       = "BLOCKED"
            Reason       = $AuthCheck.Reason
            SettlementId = $SettlementId
        }
    }

    $Record = [ordered]@{
        SettlementId   = $SettlementId
        AuthorizationId = $AuthorizationId
        ExecutionId    = $ExecutionId
        BudgetId       = $BudgetId
        TenantId       = $TenantId
        ClientId       = $ClientId
        ProjectId      = $ProjectId
        Status         = "STARTED"
        ReservedAmount = [decimal]0
        ActualAmount   = [decimal]0
        Currency       = ""
        Reconciled     = $false
        EventId        = ""
        CreatedAtUtc   = [DateTimeOffset]::UtcNow.ToString("o")
        UpdatedAtUtc   = [DateTimeOffset]::UtcNow.ToString("o")
        SimulationOnly = $true
    }

    $Records = @(Get-SettlementStore)
    $Records = @($Records) + @($Record)

    Save-SettlementStore $Records

    return $Record
}

function Reserve-SettlementCost {
    param(
        [string]$SettlementId,
        [decimal]$Amount
    )

    if ($Amount -le 0) {
        throw "Reservation amount invalide."
    }

    $Settlement = Get-Settlement $SettlementId

    if ($null -eq $Settlement) {
        throw "Settlement introuvable."
    }

    if ([string](Get-SettlementField $Settlement "Status") -ne "STARTED") {
        throw "Settlement non reservable."
    }

    Get-BudgetRuntime

    $BudgetId = [string](Get-SettlementField $Settlement "BudgetId")
    $ExecutionId = [string](Get-SettlementField $Settlement "ExecutionId")

    $Result = Reserve-Budget `
        -BudgetId $BudgetId `
        -ExecutionId $ExecutionId `
        -Cost $Amount

    if ($Result.Status -ne "RESERVED") {
        return [ordered]@{
            Success      = $false
            Status       = "BLOCKED"
            Reason       = [string]$Result.Reason
            SettlementId = $SettlementId
        }
    }

    $Settlement.ReservedAmount = $Amount
    $Settlement.Status = "RESERVED"
    $Settlement.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    $Records = @(Get-SettlementStore)

    for ($Index = 0; $Index -lt $Records.Count; $Index++) {
        if (
            [string](Get-SettlementField $Records[$Index] "SettlementId") -eq
            $SettlementId
        ) {
            $Records[$Index] = $Settlement
            break
        }
    }

    Save-SettlementStore $Records

    return $Settlement
}

function Finalize-CostSettlement {
    param(
        [string]$SettlementId,
        [decimal]$ActualAmount,
        [string]$EventId,
        [string]$Provider = "",
        [string]$Operation = "",
        [string]$WorkerId = ""
    )

    $Config = Get-SettlementConfig

    if (-not $Config.reconciliationRequired) {
        throw "Reconciliation requirement disabled."
    }

    if ($ActualAmount -lt 0) {
        throw "ActualAmount invalide."
    }

    if ([string]::IsNullOrWhiteSpace($EventId)) {
        throw "EventId requis."
    }

    $Settlement = Get-Settlement $SettlementId

    if ($null -eq $Settlement) {
        throw "Settlement introuvable."
    }

    if ([string](Get-SettlementField $Settlement "Status") -ne "RESERVED") {
        throw "Settlement non finalisable."
    }

    Get-LedgerRuntime
    Get-BudgetRuntime

    $ExecutionId = [string](Get-SettlementField $Settlement "ExecutionId")
    $TenantId = [string](Get-SettlementField $Settlement "TenantId")
    $ClientId = [string](Get-SettlementField $Settlement "ClientId")
    $ProjectId = [string](Get-SettlementField $Settlement "ProjectId")
    $Currency = "UNIT"

    $CostEvent = New-CostEvent `
        -EventId $EventId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -Amount $ActualAmount `
        -Currency $Currency `
        -Provider $Provider `
        -Operation $Operation

    $LedgerResult = Add-CostEvent $CostEvent

    if (
        $LedgerResult.Status -ne "RECORDED" -and
        $LedgerResult.Status -ne "DUPLICATE"
    ) {
        throw "Cost event non enregistre."
    }

    $ExpectedAmount = [decimal](Get-SettlementField $Settlement "ReservedAmount")

    $Reconciliation = Reconcile-ExecutionCost `
        -ExecutionId $ExecutionId `
        -ExpectedAmount $ExpectedAmount

    if (-not $Reconciliation.Reconciled) {

        Release-BudgetReservation `
            -BudgetId ([string](Get-SettlementField $Settlement "BudgetId")) `
            -ExecutionId $ExecutionId | Out-Null

        $Settlement.Status = "BLOCKED"
        $Settlement.ActualAmount = $ActualAmount
        $Settlement.Currency = $Currency
        $Settlement.Reconciled = $false
        $Settlement.EventId = $EventId
        $Settlement.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

        $Records = @(Get-SettlementStore)

        for ($Index = 0; $Index -lt $Records.Count; $Index++) {
            if (
                [string](Get-SettlementField $Records[$Index] "SettlementId") -eq
                $SettlementId
            ) {
                $Records[$Index] = $Settlement
                break
            }
        }

        Save-SettlementStore $Records

        return $Settlement
    }

    Commit-BudgetReservation `
        -BudgetId ([string](Get-SettlementField $Settlement "BudgetId")) `
        -ExecutionId $ExecutionId | Out-Null

    $Settlement.Status = "FINALIZED"
    $Settlement.ActualAmount = $ActualAmount
    $Settlement.Currency = $Currency
    $Settlement.Reconciled = $true
    $Settlement.EventId = $EventId
    $Settlement.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    $Records = @(Get-SettlementStore)

    for ($Index = 0; $Index -lt $Records.Count; $Index++) {
        if (
            [string](Get-SettlementField $Records[$Index] "SettlementId") -eq
            $SettlementId
        ) {
            $Records[$Index] = $Settlement
            break
        }
    }

    Save-SettlementStore $Records

    return $Settlement
}

function Reset-CostSettlements {
    Save-SettlementStore @()
    return "RESET"
}