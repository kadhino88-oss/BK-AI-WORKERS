Set-StrictMode -Version Latest

$Script:RateRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:RateConfigPath = Join-Path $Script:RateRoot "config.json"
$Script:RateStatePath  = Join-Path $Script:RateRoot "state\rate-cards.json"

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

function Get-RateConfig {
    if (-not (Test-Path $Script:RateConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:RateConfigPath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-RateField {
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

function Get-RateCards {
    if (-not (Test-Path $Script:RateStatePath)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $Script:RateStatePath -Encoding UTF8

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

function Save-RateCards {
    param(
        [array]$Cards
    )

    $Config = Get-RateConfig
    $MaxCards = [int]$Config.maxRateCards

    $CardArray = @($Cards)

    if ($CardArray.Count -gt $MaxCards) {
        throw "Nombre maximum de rate cards depasse."
    }

    if ($CardArray.Count -eq 0) {
        $Json = "[]"
    }
    else {
        $Json = ConvertTo-Json -InputObject $CardArray -Depth 30
    }

    [System.IO.File]::WriteAllText(
        $Script:RateStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Assert-RateContext {
    param(
        [string]$Provider,
        [string]$Operation
    )

    if ([string]::IsNullOrWhiteSpace($Provider)) {
        throw "Provider requis."
    }

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        throw "Operation requise."
    }
}

function New-RateCard {
    param(
        [string]$Provider,
        [string]$Operation,
        [decimal]$UnitRate,
        [string]$UnitType = "UNIT",
        [string]$Currency = "UNIT",
        [string]$Scope = "GLOBAL",
        [string]$TenantId = "",
        [string]$ClientId = "",
        [string]$ProjectId = "",
        [bool]$Enabled = $true
    )

    $Config = Get-RateConfig

    if (-not $Config.enabled) {
        throw "Rate manager disabled."
    }

    if (-not $Config.rateCardEnabled) {
        throw "Rate card manager disabled."
    }

    Assert-RateContext `
        -Provider $Provider `
        -Operation $Operation

    if ($UnitRate -lt 0) {
        throw "UnitRate invalide."
    }

    if ($UnitRate -gt [decimal]$Config.maxUnitRate) {
        throw "UnitRate superieur au maximum."
    }

    if ([string]::IsNullOrWhiteSpace($UnitType)) {
        throw "UnitType requis."
    }

    if ([string]::IsNullOrWhiteSpace($Currency)) {
        throw "Currency requise."
    }

    $NormalizedScope = $Scope.ToUpperInvariant()

    if (
        $NormalizedScope -ne "GLOBAL" -and
        $NormalizedScope -ne "TENANT" -and
        $NormalizedScope -ne "CLIENT" -and
        $NormalizedScope -ne "PROJECT"
    ) {
        throw "Scope invalide."
    }

    if ($NormalizedScope -eq "TENANT") {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            throw "TenantId requis."
        }
    }

    if ($NormalizedScope -eq "CLIENT") {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            throw "TenantId requis."
        }

        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            throw "ClientId requis."
        }
    }

    if ($NormalizedScope -eq "PROJECT") {
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

    $Now = [DateTimeOffset]::UtcNow.ToString("o")

    return [ordered]@{
        RateId       = [guid]::NewGuid().ToString("N")
        Provider     = $Provider
        Operation    = $Operation
        UnitRate     = [decimal]$UnitRate
        UnitType     = $UnitType
        Currency     = $Currency
        Scope        = $NormalizedScope
        TenantId     = $TenantId
        ClientId     = $ClientId
        ProjectId    = $ProjectId
        Enabled      = $Enabled
        Version      = 1
        CreatedAtUtc = $Now
        UpdatedAtUtc = $Now
    }
}

function Save-RateCard {
    param(
        [System.Collections.IDictionary]$Card
    )

    $RateId = [string](Get-RateField $Card "RateId")

    if ([string]::IsNullOrWhiteSpace($RateId)) {
        throw "RateId requis."
    }

    $Cards = @(Get-RateCards)

    foreach ($Existing in $Cards) {
        if ([string](Get-RateField $Existing "RateId") -eq $RateId) {
            throw "RateId deja existant."
        }
    }

    $NormalizedCard = Convert-ToPlainHashtable $Card
    $Cards = @($Cards) + @($NormalizedCard)

    Save-RateCards $Cards

    return Get-RateCard $RateId
}

function Get-RateCard {
    param(
        [string]$RateId
    )

    if ([string]::IsNullOrWhiteSpace($RateId)) {
        throw "RateId requis."
    }

    $Cards = @(Get-RateCards)

    foreach ($Card in $Cards) {
        if ([string](Get-RateField $Card "RateId") -eq $RateId) {
            return $Card
        }
    }

    return $null
}

function Find-RateCard {
    param(
        [string]$Provider,
        [string]$Operation,
        [string]$TenantId = "",
        [string]$ClientId = "",
        [string]$ProjectId = ""
    )

    Assert-RateContext `
        -Provider $Provider `
        -Operation $Operation

    $Cards = @(Get-RateCards)

    $Candidates = @()

    foreach ($Card in $Cards) {
        if (
            [string](Get-RateField $Card "Provider") -eq $Provider -and
            [string](Get-RateField $Card "Operation") -eq $Operation -and
            [bool](Get-RateField $Card "Enabled" $false) -eq $true
        ) {
            $Candidates += ,$Card
        }
    }

    $WantedScopes = @(
        @{
            Scope = "PROJECT"
            TenantId = $TenantId
            ClientId = $ClientId
            ProjectId = $ProjectId
        },
        @{
            Scope = "CLIENT"
            TenantId = $TenantId
            ClientId = $ClientId
            ProjectId = ""
        },
        @{
            Scope = "TENANT"
            TenantId = $TenantId
            ClientId = ""
            ProjectId = ""
        },
        @{
            Scope = "GLOBAL"
            TenantId = ""
            ClientId = ""
            ProjectId = ""
        }
    )

    foreach ($Wanted in $WantedScopes) {

        foreach ($Candidate in $Candidates) {

            if (
                [string](Get-RateField $Candidate "Scope") -eq $Wanted.Scope -and
                [string](Get-RateField $Candidate "TenantId") -eq $Wanted.TenantId -and
                [string](Get-RateField $Candidate "ClientId") -eq $Wanted.ClientId -and
                [string](Get-RateField $Candidate "ProjectId") -eq $Wanted.ProjectId
            ) {
                return $Candidate
            }
        }
    }

    return $null
}

function Calculate-ExecutionCost {
    param(
        [string]$Provider,
        [string]$Operation,
        [decimal]$Units,
        [string]$TenantId = "",
        [string]$ClientId = "",
        [string]$ProjectId = ""
    )

    $Config = Get-RateConfig

    if (-not $Config.costCalculationEnabled) {
        throw "Cost calculation disabled."
    }

    if ($Units -lt 0) {
        throw "Units invalides."
    }

    $Card = Find-RateCard `
        -Provider $Provider `
        -Operation $Operation `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId

    if ($null -eq $Card) {
        return [ordered]@{
            Success   = $false
            Status    = "RATE_NOT_FOUND"
            Provider  = $Provider
            Operation = $Operation
        }
    }

    $UnitRate = [decimal](Get-RateField $Card "UnitRate" 0)
    $DecimalUnits = [decimal]$Units

    # ========================================================
    # CALCUL DECIMAL STRICT
    # AUCUN DOUBLE
    # ========================================================

    [decimal]$Amount = $DecimalUnits * $UnitRate

    $Precision = [int]$Config.precision

    [decimal]$Amount = [decimal]::Round(
        $Amount,
        $Precision,
        [MidpointRounding]::AwayFromZero
    )

    return [ordered]@{
        Success     = $true
        Status      = "CALCULATED"
        RateId      = [string](Get-RateField $Card "RateId")
        Provider    = $Provider
        Operation   = $Operation
        Units       = $DecimalUnits
        UnitType    = [string](Get-RateField $Card "UnitType" "UNIT")
        UnitRate    = $UnitRate
        Amount      = $Amount
        Currency    = [string](Get-RateField $Card "Currency" $Config.defaultCurrency)
        TenantId    = $TenantId
        ClientId    = $ClientId
        ProjectId   = $ProjectId
    }
}

function Set-RateCardEnabled {
    param(
        [string]$RateId,
        [bool]$Enabled
    )

    $Cards = @(Get-RateCards)
    $FoundIndex = -1

    for ($Index = 0; $Index -lt $Cards.Count; $Index++) {

        $CurrentId = [string](Get-RateField $Cards[$Index] "RateId")

        if ($CurrentId -eq $RateId) {
            $FoundIndex = $Index
            break
        }
    }

    if ($FoundIndex -lt 0) {
        throw "RateId introuvable."
    }

    $CurrentCard = Convert-ToPlainHashtable $Cards[$FoundIndex]
    $UpdatedCard = [ordered]@{}

    foreach ($Key in $CurrentCard.Keys) {
        $UpdatedCard[$Key] = $CurrentCard[$Key]
    }

    $UpdatedCard["Enabled"] = $Enabled
    $UpdatedCard["UpdatedAtUtc"] = [DateTimeOffset]::UtcNow.ToString("o")

    $Cards[$FoundIndex] = $UpdatedCard

    Save-RateCards $Cards

    return Get-RateCard $RateId
}

function Reset-RateCards {
    Save-RateCards -Cards @()
    return "RESET"
}