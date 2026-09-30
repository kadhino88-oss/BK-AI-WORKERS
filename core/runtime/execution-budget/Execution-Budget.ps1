Set-StrictMode -Version Latest

$Script:BudgetRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:BudgetConfigPath = Join-Path $Script:BudgetRoot "config.json"
$Script:BudgetStatePath  = Join-Path $Script:BudgetRoot "state\budgets.json"

function Convert-ToPlainHashtable {
    param(
        $InputObject
    )
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
        $ArrayResult = @()

        foreach ($Item in $InputObject) {
            $ArrayResult += ,(Convert-ToPlainHashtable $Item)
        }

        return $ArrayResult
    }

    if ($InputObject -is [pscustomobject]) {
        $Result = [ordered]@{}

        foreach ($Property in $InputObject.PSObject.Properties) {
            $Result[$Property.Name] = Convert-ToPlainHashtable $Property.Value
        }

        return $Result
    }

    return $InputObject
}

function Get-BudgetConfig {
    if (-not (Test-Path $Script:BudgetConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:BudgetConfigPath -Encoding UTF8
    $Object = $Raw | ConvertFrom-Json

    return Convert-ToPlainHashtable $Object
}

function Get-BudgetField {
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

function Get-BudgetMap {
    if (-not (Test-Path $Script:BudgetStatePath)) {
        return [ordered]@{}
    }

    $Raw = Get-Content -Raw -Path $Script:BudgetStatePath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return [ordered]@{}
    }

    $Object = $Raw | ConvertFrom-Json
    $Map = Convert-ToPlainHashtable $Object

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map
    }

    return [ordered]@{}
}

function Save-BudgetMap {
    param(
        [System.Collections.IDictionary]$Map
    )

    $Config = Get-BudgetConfig
    $MaxEntries = [int]$Config.maxEntries

    if ($Map.Count -gt $MaxEntries) {
        throw "Nombre maximum de budgets depasse."
    }

    $Json = $Map | ConvertTo-Json -Depth 30

    [System.IO.File]::WriteAllText(
        $Script:BudgetStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Convert-ToBudgetRecord {
    param(
        $Record
    )

    $Reservations = [ordered]@{}
    $RawReservations = Get-BudgetField $Record "Reservations"

    if ($RawReservations -is [System.Collections.IDictionary]) {
        foreach ($Key in $RawReservations.Keys) {
            $Reservation = $RawReservations[$Key]

            $Reservations[[string]$Key] = [ordered]@{
                Cost         = [decimal](Get-BudgetField $Reservation "Cost" 0)
                Status       = [string](Get-BudgetField $Reservation "Status" "RESERVED")
                CreatedAtUtc = [string](Get-BudgetField $Reservation "CreatedAtUtc" "")
            }
        }
    }

    return [ordered]@{
        BudgetId     = [string](Get-BudgetField $Record "BudgetId" "")
        Scope        = [string](Get-BudgetField $Record "Scope" "")
        TenantId     = [string](Get-BudgetField $Record "TenantId" "")
        ClientId     = [string](Get-BudgetField $Record "ClientId" "")
        ProjectId    = [string](Get-BudgetField $Record "ProjectId" "")
        WorkerId     = [string](Get-BudgetField $Record "WorkerId" "")
        Limit        = [decimal](Get-BudgetField $Record "Limit" 0)
        Reserved     = [decimal](Get-BudgetField $Record "Reserved" 0)
        Consumed     = [decimal](Get-BudgetField $Record "Consumed" 0)
        Available    = [decimal](Get-BudgetField $Record "Available" 0)
        Currency     = [string](Get-BudgetField $Record "Currency" "UNIT")
        Status       = [string](Get-BudgetField $Record "Status" "AVAILABLE")
        Reservations = $Reservations
        CreatedAtUtc = [string](Get-BudgetField $Record "CreatedAtUtc" "")
        UpdatedAtUtc = [string](Get-BudgetField $Record "UpdatedAtUtc" "")
    }
}

function Assert-BudgetContext {
    param(
        [string]$Scope,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId
    )

    if ([string]::IsNullOrWhiteSpace($Scope)) {
        throw "Scope requis."
    }

    $NormalizedScope = $Scope.ToUpperInvariant()

    switch ($NormalizedScope) {

        "TENANT" {
            if ([string]::IsNullOrWhiteSpace($TenantId)) {
                throw "TenantId requis."
            }
        }

        "CLIENT" {
            if ([string]::IsNullOrWhiteSpace($TenantId)) {
                throw "TenantId requis."
            }

            if ([string]::IsNullOrWhiteSpace($ClientId)) {
                throw "ClientId requis."
            }
        }

        "PROJECT" {
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

        default {
            throw "Scope invalide."
        }
    }
}

function New-BudgetAccount {
    param(
        [string]$Scope,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [decimal]$Limit = 0,
        [string]$Currency = "UNIT"
    )

    $Config = Get-BudgetConfig

    if (-not $Config.enabled) {
        throw "Budget manager disabled."
    }

    if (-not $Config.budgetManagerEnabled) {
        throw "Budget manager disabled."
    }

    Assert-BudgetContext `
        -Scope $Scope `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ($Limit -lt 0) {
        throw "Limit invalide."
    }

    $MaxGlobalBudget = [decimal]$Config.maxGlobalBudget

    if ($Limit -gt $MaxGlobalBudget) {
        throw "Limit superieure au maximum global."
    }

    $NormalizedScope = $Scope.ToUpperInvariant()

    if ($Limit -eq 0) {

        switch ($NormalizedScope) {

            "TENANT" {
                $Limit = [decimal]$Config.defaultTenantBudget
            }

            "CLIENT" {
                $Limit = [decimal]$Config.defaultClientBudget
            }

            "PROJECT" {
                $Limit = [decimal]$Config.defaultProjectBudget
            }
        }
    }

    $Now = [DateTimeOffset]::UtcNow.ToString("o")

    return [ordered]@{
        BudgetId     = [guid]::NewGuid().ToString("N")
        Scope        = $NormalizedScope
        TenantId     = $TenantId
        ClientId     = $ClientId
        ProjectId    = $ProjectId
        WorkerId     = $WorkerId
        Limit        = $Limit
        Reserved     = [decimal]0
        Consumed     = [decimal]0
        Available    = $Limit
        Currency     = $Currency
        Status       = "AVAILABLE"
        Reservations = [ordered]@{}
        CreatedAtUtc = $Now
        UpdatedAtUtc = $Now
    }
}

function Save-BudgetAccount {
    param(
        [System.Collections.IDictionary]$Account
    )

    $BudgetId = [string](Get-BudgetField $Account "BudgetId")

    if ([string]::IsNullOrWhiteSpace($BudgetId)) {
        throw "BudgetId requis."
    }

    $Map = Get-BudgetMap
    $Map[$BudgetId] = (Convert-ToBudgetRecord $Account)

    Save-BudgetMap $Map

    return Get-BudgetAccount $BudgetId
}

function Get-BudgetAccount {
    param(
        [string]$BudgetId
    )

    if ([string]::IsNullOrWhiteSpace($BudgetId)) {
        throw "BudgetId requis."
    }

    $Map = Get-BudgetMap

    if (-not $Map.Contains($BudgetId)) {
        return $null
    }

    return Convert-ToBudgetRecord $Map[$BudgetId]
}

function Set-BudgetLimit {
    param(
        [string]$BudgetId,
        [decimal]$Limit
    )

    $Config = Get-BudgetConfig

    if ($Limit -lt 0) {
        throw "Limit invalide."
    }

    if ($Limit -gt [decimal]$Config.maxGlobalBudget) {
        throw "Limit superieure au maximum global."
    }

    $Map = Get-BudgetMap

    if (-not $Map.Contains($BudgetId)) {
        throw "Budget introuvable."
    }

    $Account = Convert-ToBudgetRecord $Map[$BudgetId]

    $CommittedValue = $Account.Consumed + $Account.Reserved

    if ($Limit -lt $CommittedValue) {
        throw "Nouvelle limite inferieure aux engagements."
    }

    $Account.Limit = $Limit
    $Account.Available = $Limit - $Account.Consumed - $Account.Reserved
    $Account.Status = if ($Account.Available -gt 0) { "AVAILABLE" } else { "EXHAUSTED" }
    $Account.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    $Map[$BudgetId] = $Account
    Save-BudgetMap $Map

    return $Account
}

function Get-BudgetStatus {
    param(
        [string]$BudgetId
    )

    $Account = Get-BudgetAccount $BudgetId

    if ($null -eq $Account) {
        throw "Budget introuvable."
    }

    return [ordered]@{
        BudgetId  = $Account.BudgetId
        Scope     = $Account.Scope
        TenantId  = $Account.TenantId
        ClientId  = $Account.ClientId
        ProjectId = $Account.ProjectId
        Limit     = $Account.Limit
        Reserved  = $Account.Reserved
        Consumed  = $Account.Consumed
        Available = $Account.Available
        Status    = $Account.Status
        Currency  = $Account.Currency
    }
}

function Test-BudgetAdmission {
    param(
        [string]$BudgetId,
        [decimal]$Cost
    )

    if ($Cost -lt 0) {
        throw "Cost invalide."
    }

    $Account = Get-BudgetAccount $BudgetId

    if ($null -eq $Account) {
        throw "Budget introuvable."
    }

    $Allowed = $Account.Available -ge $Cost

    return [ordered]@{
        Allowed   = $Allowed
        Reason    = if ($Allowed) { "BUDGET_AVAILABLE" } else { "BUDGET_EXCEEDED" }
        BudgetId  = $BudgetId
        Requested = $Cost
        Available = $Account.Available
    }
}

function Reserve-Budget {
    param(
        [string]$BudgetId,
        [string]$ExecutionId,
        [decimal]$Cost
    )

    $Config = Get-BudgetConfig

    if (-not $Config.reservationEnabled) {
        throw "Reservation disabled."
    }

    if ($Cost -le 0) {
        throw "Cost invalide."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    $Map = Get-BudgetMap

    if (-not $Map.Contains($BudgetId)) {
        throw "Budget introuvable."
    }

    $Account = Convert-ToBudgetRecord $Map[$BudgetId]

    if ($Account.Reservations.Contains($ExecutionId)) {
        throw "Reservation deja existante."
    }

    if ($Account.Available -lt $Cost) {
        return [ordered]@{
            Success     = $false
            Status      = "BLOCKED"
            Reason      = "BUDGET_EXCEEDED"
            BudgetId    = $BudgetId
            ExecutionId = $ExecutionId
        }
    }

    $Account.Reservations[$ExecutionId] = [ordered]@{
        Cost         = $Cost
        Status       = "RESERVED"
        CreatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }

    $Account.Reserved += $Cost
    $Account.Available = $Account.Limit - $Account.Consumed - $Account.Reserved
    $Account.Status = if ($Account.Available -gt 0) { "AVAILABLE" } else { "EXHAUSTED" }
    $Account.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    $Map[$BudgetId] = $Account
    Save-BudgetMap $Map

    return [ordered]@{
        Success     = $true
        Status      = "RESERVED"
        BudgetId    = $BudgetId
        ExecutionId = $ExecutionId
        Cost        = $Cost
    }
}

function Commit-BudgetReservation {
    param(
        [string]$BudgetId,
        [string]$ExecutionId
    )

    $Map = Get-BudgetMap

    if (-not $Map.Contains($BudgetId)) {
        throw "Budget introuvable."
    }

    $Account = Convert-ToBudgetRecord $Map[$BudgetId]

    if (-not $Account.Reservations.Contains($ExecutionId)) {
        throw "Reservation introuvable."
    }

    $Reservation = $Account.Reservations[$ExecutionId]
    $Cost = [decimal](Get-BudgetField $Reservation "Cost" 0)

    $Account.Reserved -= $Cost
    $Account.Consumed += $Cost
    $Account.Reservations.Remove($ExecutionId)
    $Account.Available = $Account.Limit - $Account.Consumed - $Account.Reserved
    $Account.Status = if ($Account.Available -gt 0) { "AVAILABLE" } else { "EXHAUSTED" }
    $Account.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    $Map[$BudgetId] = $Account
    Save-BudgetMap $Map

    return [ordered]@{
        Success     = $true
        Status      = "COMMITTED"
        Cost        = $Cost
        BudgetId    = $BudgetId
        ExecutionId = $ExecutionId
    }
}

function Release-BudgetReservation {
    param(
        [string]$BudgetId,
        [string]$ExecutionId
    )

    $Map = Get-BudgetMap

    if (-not $Map.Contains($BudgetId)) {
        throw "Budget introuvable."
    }

    $Account = Convert-ToBudgetRecord $Map[$BudgetId]

    if (-not $Account.Reservations.Contains($ExecutionId)) {
        throw "Reservation introuvable."
    }

    $Reservation = $Account.Reservations[$ExecutionId]
    $Cost = [decimal](Get-BudgetField $Reservation "Cost" 0)

    $Account.Reserved -= $Cost
    $Account.Reservations.Remove($ExecutionId)
    $Account.Available = $Account.Limit - $Account.Consumed - $Account.Reserved
    $Account.Status = if ($Account.Available -gt 0) { "AVAILABLE" } else { "EXHAUSTED" }
    $Account.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    $Map[$BudgetId] = $Account
    Save-BudgetMap $Map

    return [ordered]@{
        Success     = $true
        Status      = "RELEASED"
        Cost        = $Cost
        BudgetId    = $BudgetId
        ExecutionId = $ExecutionId
    }
}

function Register-BudgetConsumption {
    param(
        [string]$BudgetId,
        [decimal]$Cost
    )

    $Config = Get-BudgetConfig

    if (-not $Config.costTrackingEnabled) {
        throw "Cost tracking disabled."
    }

    if ($Cost -le 0) {
        throw "Cost invalide."
    }

    $Map = Get-BudgetMap

    if (-not $Map.Contains($BudgetId)) {
        throw "Budget introuvable."
    }

    $Account = Convert-ToBudgetRecord $Map[$BudgetId]

    if ($Account.Available -lt $Cost) {
        return [ordered]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "BUDGET_EXCEEDED"
        }
    }

    $Account.Consumed += $Cost
    $Account.Available = $Account.Limit - $Account.Consumed - $Account.Reserved
    $Account.Status = if ($Account.Available -gt 0) { "AVAILABLE" } else { "EXHAUSTED" }
    $Account.UpdatedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")

    $Map[$BudgetId] = $Account
    Save-BudgetMap $Map

    return [ordered]@{
        Success  = $true
        Status   = "CONSUMED"
        Cost     = $Cost
        BudgetId = $BudgetId
    }
}

function Reset-BudgetState {
    $Empty = [ordered]@{}
    Save-BudgetMap $Empty
    return "RESET"
}