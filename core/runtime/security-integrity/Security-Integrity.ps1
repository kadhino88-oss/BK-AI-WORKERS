Set-StrictMode -Version Latest

$Script:IntegrityRoot       = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script:IntegrityConfigPath = Join-Path $Script:IntegrityRoot "config.json"
$Script:IntegrityStatePath  = Join-Path $Script:IntegrityRoot "state\integrity-records.json"

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

function Get-IntegrityConfig {
    if (-not (Test-Path $Script:IntegrityConfigPath)) {
        throw "Configuration introuvable."
    }

    $Raw = Get-Content -Raw -Path $Script:IntegrityConfigPath -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        throw "Configuration vide."
    }

    return Convert-ToPlainHashtable ($Raw | ConvertFrom-Json)
}

function Get-IntegrityField {
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

function Get-IntegrityRecords {
    if (-not (Test-Path $Script:IntegrityStatePath)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $Script:IntegrityStatePath -Encoding UTF8

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

function Save-IntegrityRecords {
    param(
        [array]$Records
    )

    $Config = Get-IntegrityConfig
    $Max = [int]$Config.maxRecords
    $Array = @($Records)

    if ($Array.Count -gt $Max) {
        throw "Nombre maximum de records depasse."
    }

    if ($Array.Count -eq 0) {
        $Json = "[]"
    }
    else {
        $Json = ConvertTo-Json -InputObject $Array -Depth 30
    }

    [System.IO.File]::WriteAllText(
        $Script:IntegrityStatePath,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-SHA256 {
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

function Get-FileSHA256 {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path requis."
    }

    if (-not (Test-Path $Path)) {
        throw "Fichier introuvable."
    }

    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $Stream = [System.IO.File]::OpenRead($Path)

        try {
            $HashBytes = $Sha.ComputeHash($Stream)
        }
        finally {
            $Stream.Dispose()
        }
    }
    finally {
        $Sha.Dispose()
    }

    return (
        [System.BitConverter]::ToString($HashBytes)
    ).Replace("-", "").ToLowerInvariant()
}

function New-IntegrityRecord {
    param(
        [string]$RecordId,
        [string]$ResourceType,
        [string]$ResourceId,
        [string]$Content
    )

    $Config = Get-IntegrityConfig

    if (-not $Config.enabled -or -not $Config.integrityEnabled) {
        throw "Integrity manager disabled."
    }

    if ([string]::IsNullOrWhiteSpace($RecordId)) {
        throw "RecordId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ResourceType)) {
        throw "ResourceType requis."
    }

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        throw "ResourceId requis."
    }

    if ($null -eq $Content) {
        throw "Content requis."
    }

    $Records = @(Get-IntegrityRecords)

    foreach ($Existing in $Records) {
        if (
            [string](Get-IntegrityField $Existing "RecordId") -eq
            $RecordId
        ) {
            return [ordered]@{
                Success  = $false
                Status   = "DUPLICATE"
                RecordId = $RecordId
            }
        }
    }

    $Hash = Get-SHA256 $Content
    $Now = [DateTimeOffset]::UtcNow.ToString("o")

    return [ordered]@{
        RecordId     = $RecordId
        ResourceType = $ResourceType
        ResourceId   = $ResourceId
        Algorithm    = "SHA256"
        ContentHash  = $Hash
        ContentSize  = $Content.Length
        CreatedAtUtc = $Now
        UpdatedAtUtc = $Now
        Status       = "SEALED"
    }
}

function Save-IntegrityRecord {
    param(
        [System.Collections.IDictionary]$Record
    )

    $RecordId = [string](Get-IntegrityField $Record "RecordId")

    if ([string]::IsNullOrWhiteSpace($RecordId)) {
        throw "RecordId requis."
    }

    $Records = @(Get-IntegrityRecords)

    foreach ($Existing in $Records) {
        if (
            [string](Get-IntegrityField $Existing "RecordId") -eq
            $RecordId
        ) {
            throw "RecordId deja existant."
        }
    }

    $Normalized = Convert-ToPlainHashtable $Record
    $Records = @($Records) + @($Normalized)

    Save-IntegrityRecords $Records

    return $Normalized
}

function Get-IntegrityRecord {
    param(
        [string]$RecordId
    )

    if ([string]::IsNullOrWhiteSpace($RecordId)) {
        throw "RecordId requis."
    }

    $Records = @(Get-IntegrityRecords)

    foreach ($Record in $Records) {
        if (
            [string](Get-IntegrityField $Record "RecordId") -eq
            $RecordId
        ) {
            return $Record
        }
    }

    return $null
}

function Verify-Integrity {
    param(
        [string]$RecordId,
        [object]$Content
    )

    $Config = Get-IntegrityConfig

    if (-not $Config.integrityEnabled) {
        throw "Integrity verification disabled."
    }

    # ========================================================
    # 1 — IDENTIFIANT
    # ========================================================

    if ([string]::IsNullOrWhiteSpace($RecordId)) {
        return [ordered]@{
            Valid    = $false
            Decision = "BLOCK"
            Reason   = "RECORD_ID_MISSING"
            RecordId = $RecordId
        }
    }

    # ========================================================
    # 2 — RECORD
    # ========================================================

    $Record = Get-IntegrityRecord $RecordId

    if ($null -eq $Record) {
        return [ordered]@{
            Valid    = $false
            Decision = "BLOCK"
            Reason   = "RECORD_NOT_FOUND"
            RecordId = $RecordId
        }
    }

    # ========================================================
    # 3 — ALGORITHME
    # ========================================================

    if (
        [string](Get-IntegrityField $Record "Algorithm") -ne
        "SHA256"
    ) {
        return [ordered]@{
            Valid    = $false
            Decision = "BLOCK"
            Reason   = "ALGORITHM_MISMATCH"
            RecordId = $RecordId
        }
    }

    # ========================================================
    # 4 — CONTENU OBLIGATOIRE
    # AVANT TOUT HASH
    # ========================================================

    if ($null -eq $Content) {
        return [ordered]@{
            Valid    = $false
            Decision = "BLOCK"
            Reason   = "CONTENT_MISSING"
            RecordId = $RecordId
        }
    }

    $ContentText = [string]$Content

    if ([string]::IsNullOrEmpty($ContentText)) {
        return [ordered]@{
            Valid    = $false
            Decision = "BLOCK"
            Reason   = "CONTENT_MISSING"
            RecordId = $RecordId
        }
    }

    # ========================================================
    # 5 — HASH
    # ========================================================

    $ExpectedHash =
        [string](Get-IntegrityField $Record "ContentHash")

    $ActualHash = Get-SHA256 $ContentText

    if ($ExpectedHash -ne $ActualHash) {
        return [ordered]@{
            Valid        = $false
            Decision     = "BLOCK"
            Reason       = "TAMPERED"
            RecordId     = $RecordId
            ExpectedHash = $ExpectedHash
            ActualHash   = $ActualHash
        }
    }

    # ========================================================
    # 6 — TAILLE
    # ========================================================

    $ExpectedSize =
        [int](Get-IntegrityField $Record "ContentSize" 0)

    if ($ContentText.Length -ne $ExpectedSize) {
        return [ordered]@{
            Valid    = $false
            Decision = "BLOCK"
            Reason   = "SIZE_MISMATCH"
            RecordId = $RecordId
        }
    }

    # ========================================================
    # 7 — OK
    # ========================================================

    return [ordered]@{
        Valid    = $true
        Decision = "ALLOW"
        Reason   = "INTEGRITY_OK"
        RecordId = $RecordId
    }
}

function Seal-FileIntegrity {
    param(
        [string]$RecordId,
        [string]$ResourceType,
        [string]$ResourceId,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Path requis."
    }

    if (-not (Test-Path $Path)) {
        throw "Fichier introuvable."
    }

    $Content = Get-Content -Raw -Path $Path -Encoding UTF8

    return New-IntegrityRecord `
        -RecordId $RecordId `
        -ResourceType $ResourceType `
        -ResourceId $ResourceId `
        -Content $Content
}

function Verify-FileIntegrity {
    param(
        [string]$RecordId,
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return [ordered]@{
            Valid    = $false
            Decision = "BLOCK"
            Reason   = "FILE_NOT_FOUND"
            RecordId = $RecordId
        }
    }

    $Content = Get-Content -Raw -Path $Path -Encoding UTF8

    return Verify-Integrity `
        -RecordId $RecordId `
        -Content $Content
}

function Reset-IntegrityRecords {
    Save-IntegrityRecords @()
    return "RESET"
}