Set-StrictMode -Version Latest

$Script:GatewayRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:GatewayConfigPath = Join-Path $Script:GatewayRoot "config.json"
$Script:GatewayStatePath  = Join-Path $Script:GatewayRoot "state\authorizations.json"

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

function Get-GatewayConfig {
    if (-not (Test-Path $Script:GatewayConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:GatewayConfigPath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-GatewayField {
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

function Get-AuthorizationStore {
    if (-not (Test-Path $Script:GatewayStatePath)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $Script:GatewayStatePath -Encoding UTF8

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

function Save-AuthorizationStore {
    param(
        [array]$Records
    )

    $Config = Get-GatewayConfig
    $Max = [int]$Config.maxAuthorizations
    $Array = @($Records)

    if ($Array.Count -gt $Max) {
        throw "Nombre maximum d'autorisations depasse."
    }

    if ($Array.Count -eq 0) {
        $Json = "[]"
    }
    else {
        $Json = ConvertTo-Json -InputObject $Array -Depth 30
    }

    [System.IO.File]::WriteAllText(
        $Script:GatewayStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Assert-GatewayContext {
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

function Get-RateRuntime {
    $Path = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-rate-card\Execution-Rate-Card.ps1"

    if (-not (Test-Path $Path)) {
        throw "7H-48 runtime introuvable."
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

function Get-Authorization {
    param(
        [string]$AuthorizationId
    )

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        throw "AuthorizationId requis."
    }

    $Records = @(Get-AuthorizationStore)

    foreach ($Record in $Records) {
        if (
            [string](Get-GatewayField $Record "AuthorizationId") -eq $AuthorizationId
        ) {
            return $Record
        }
    }

    return $null
}

function Authorize-ExecutionCost {
    param(
        [string]$AuthorizationId,
        [string]$ExecutionId,
        [string]$BudgetId,
        [string]$Provider,
        [string]$Operation,
        [decimal]$Units,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId
    )

    $Config = Get-GatewayConfig

    if (-not $Config.enabled -or -not $Config.authorizationEnabled) {
        throw "Cost authorization disabled."
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

    Assert-GatewayContext `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ($Units -lt 0) {
        throw "Units invalides."
    }

    $Existing = Get-Authorization $AuthorizationId

    if ($null -ne $Existing) {
        return [ordered]@{
            Success         = $false
            Decision        = "DUPLICATE"
            AuthorizationId = $AuthorizationId
            ExecutionId     = $ExecutionId
            BudgetId        = $BudgetId
        }
    }

    # --------------------------------------------------------
    # 7H-48 — RATE CARD
    # --------------------------------------------------------

    Get-RateRuntime

    $CostResult = Calculate-ExecutionCost `
        -Provider $Provider `
        -Operation $Operation `
        -Units $Units `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ($CostResult.Status -ne "CALCULATED") {

        $Blocked = [ordered]@{
            AuthorizationId = $AuthorizationId
            ExecutionId     = $ExecutionId
            BudgetId        = $BudgetId
            TenantId        = $TenantId
            ClientId        = $ClientId
            ProjectId       = $ProjectId
            Provider        = $Provider
            Operation       = $Operation
            Units           = $Units
            Decision        = "BLOCK"
            Reason          = "RATE_NOT_FOUND"
            EstimatedCost   = [decimal]0
            Currency        = ""
            CreatedAtUtc    = [DateTimeOffset]::UtcNow.ToString("o")
            SimulationOnly  = $true
        }

        $Records = @(Get-AuthorizationStore)
        $Records = @($Records) + @($Blocked)

        Save-AuthorizationStore $Records

        return $Blocked
    }

    [decimal]$EstimatedCost = [decimal]$CostResult.Amount
    $Currency = [string]$CostResult.Currency

    # --------------------------------------------------------
    # 7H-46 — BUDGET CHECK
    # --------------------------------------------------------

    Get-BudgetRuntime

    $BudgetAccount = Get-BudgetAccount $BudgetId

    if ($null -eq $BudgetAccount) {

        $Blocked = [ordered]@{
            AuthorizationId = $AuthorizationId
            ExecutionId     = $ExecutionId
            BudgetId        = $BudgetId
            TenantId        = $TenantId
            ClientId        = $ClientId
            ProjectId       = $ProjectId
            Provider        = $Provider
            Operation       = $Operation
            Units           = $Units
            Decision        = "BLOCK"
            Reason          = "BUDGET_NOT_FOUND"
            EstimatedCost   = $EstimatedCost
            Currency        = $Currency
            CreatedAtUtc    = [DateTimeOffset]::UtcNow.ToString("o")
            SimulationOnly  = $true
        }

        $Records = @(Get-AuthorizationStore)
        $Records = @($Records) + @($Blocked)

        Save-AuthorizationStore $Records

        return $Blocked
    }

    # --------------------------------------------------------
    # ISOLATION BUDGET
    # --------------------------------------------------------

    if (
        [string]$BudgetAccount.TenantId -ne $TenantId
    ) {
        $Decision = "BLOCK"
        $Reason = "TENANT_MISMATCH"
    }
    elseif (
        [string](Get-GatewayField $BudgetAccount "Scope") -eq "CLIENT" -and
        [string]$BudgetAccount.ClientId -ne $ClientId
    ) {
        $Decision = "BLOCK"
        $Reason = "CLIENT_MISMATCH"
    }
    elseif (
        [string](Get-GatewayField $BudgetAccount "Scope") -eq "PROJECT" -and
        [string]$BudgetAccount.ClientId -ne $ClientId
    ) {
        $Decision = "BLOCK"
        $Reason = "CLIENT_MISMATCH"
    }
    elseif (
        [string](Get-GatewayField $BudgetAccount "Scope") -eq "PROJECT" -and
        [string]$BudgetAccount.ProjectId -ne $ProjectId
    ) {
        $Decision = "BLOCK"
        $Reason = "PROJECT_MISMATCH"
    }
    else {

        $Admission = Test-BudgetAdmission `
            -BudgetId $BudgetId `
            -Cost $EstimatedCost

        if ($Admission.Allowed -eq $true) {
            $Decision = "ALLOW"
            $Reason = "BUDGET_AVAILABLE"
        }
        else {
            $Decision = "BLOCK"
            $Reason = [string]$Admission.Reason
        }
    }

    $Record = [ordered]@{
        AuthorizationId = $AuthorizationId
        ExecutionId     = $ExecutionId
        BudgetId        = $BudgetId
        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        Provider        = $Provider
        Operation       = $Operation
        Units           = $Units
        EstimatedCost   = $EstimatedCost
        Currency        = $Currency
        Decision        = $Decision
        Reason          = $Reason
        CreatedAtUtc    = [DateTimeOffset]::UtcNow.ToString("o")
        SimulationOnly  = $true
    }

    $Records = @(Get-AuthorizationStore)
    $Records = @($Records) + @($Record)

    Save-AuthorizationStore $Records

    return $Record
}

function Reset-Authorizations {
    Save-AuthorizationStore @()
    return "RESET"
}