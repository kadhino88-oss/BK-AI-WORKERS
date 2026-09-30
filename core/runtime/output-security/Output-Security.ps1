Set-StrictMode -Version 2.0

function Convert-ToPlainHashtable {
    param(
        [Parameter()]
        $InputObject
    )
    # PowerShell 7 convertit les dates ISO en [datetime] (recursion infinie via .Date) ;
    # Windows PowerShell 5.1 les laissait en texte : on renvoie le meme texte ISO.
    if ($InputObject -is [datetime]) { return $InputObject.ToString("o") }
    if ($InputObject -is [datetimeoffset]) { return $InputObject.ToString("o") }


    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string] -or
        $InputObject -is [char] -or
        $InputObject -is [bool] -or
        $InputObject -is [byte] -or
        $InputObject -is [int16] -or
        $InputObject -is [int32] -or
        $InputObject -is [int64] -or
        $InputObject -is [decimal] -or
        $InputObject -is [double] -or
        $InputObject -is [single] -or
        $InputObject -is [datetime]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}

        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = Convert-ToPlainHashtable $InputObject[$key]
        }

        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @()

        foreach ($item in $InputObject) {
            $items += ,(Convert-ToPlainHashtable $item)
        }

        return @($items)
    }

    $properties = @($InputObject.PSObject.Properties)

    if ($properties.Length -gt 0) {
        $result = @{}

        foreach ($property in $properties) {
            $result[[string]$property.Name] = Convert-ToPlainHashtable $property.Value
        }

        return $result
    }

    return $InputObject
}

function Get-OutputSecurityConfig {
    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    $ConfigObject = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json

    return Convert-ToPlainHashtable $ConfigObject
}

function Get-OutputSecurityField {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $Config = Get-OutputSecurityConfig

    if (-not $Config.ContainsKey($Name)) {
        throw "Unknown configuration field: $Name"
    }

    return $Config[$Name]
}

function Convert-ToOutputText {
    param(
        [Parameter()]
        $InputObject
    )

    if ($null -eq $InputObject) {
        return ""
    }

    if ($InputObject -is [string]) {
        return [string]$InputObject
    }

    $PlainObject = Convert-ToPlainHashtable $InputObject

    if ($null -eq $PlainObject) {
        return ""
    }

    return ($PlainObject | ConvertTo-Json -Depth 100 -Compress)
}

function Get-SensitivePatterns {
    return @(
        '(?i)(["'']?(?:password|passwd|pwd)["'']?\s*[:=]\s*)["'']?([^\s"'',;\}\]]+)["'']?',
        '(?i)(["'']?(?:api[_ -]?key|apikey)["'']?\s*[:=]\s*)["'']?([^\s"'',;\}\]]+)["'']?',
        '(?i)(["'']?(?:secret)["'']?\s*[:=]\s*)["'']?([^\s"'',;\}\]]+)["'']?',
        '(?i)(["'']?(?:access[_ -]?token)["'']?\s*[:=]\s*)["'']?([^\s"'',;\}\]]+)["'']?',
        '(?i)(["'']?(?:refresh[_ -]?token)["'']?\s*[:=]\s*)["'']?([^\s"'',;\}\]]+)["'']?',
        '(?i)(["'']?(?:authorization)["'']?\s*[:=]\s*)Bearer\s+([A-Za-z0-9._~+/=-]+)',
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}\b',
        '\bsk-[A-Za-z0-9_-]{10,}\b',
        '\bghp_[A-Za-z0-9]{10,}\b',
        '\bAKIA[A-Z0-9]{12,}\b',
        '\bAIza[A-Za-z0-9_-]{20,}\b'
    )
}

function Get-SensitiveFindingCount {
    param(
        [Parameter()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ($null -eq $Text -or $Text.Length -eq 0) {
        return 0
    }

    $Total = 0

    foreach ($Pattern in @(Get-SensitivePatterns)) {
        try {
            $Matches = @(
                [regex]::Matches(
                    $Text,
                    $Pattern,
                    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                )
            )

            $Total = $Total + $Matches.Length
        }
        catch {
            return -1
        }
    }

    return $Total
}

function Invoke-SensitiveRedaction {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Text,

        [Parameter(Mandatory=$true)]
        [string]$Replacement
    )

    if ($null -eq $Text -or $Text.Length -eq 0) {
        return $Text
    }

    $Output = $Text

    foreach ($Pattern in @(Get-SensitivePatterns)) {

        $Output = [regex]::Replace(
            $Output,
            $Pattern,
            {
                param($Match)

                if ($Match.Groups.Count -ge 3 -and
                    $Match.Groups[1].Success) {

                    return $Match.Groups[1].Value + $Replacement
                }

                return $Replacement
            },
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }

    return $Output
}

function Redact-SensitiveOutput {
    param(
        [Parameter()]
        $InputObject
    )

    $Config = Get-OutputSecurityConfig

    $MaxLength = [int]$Config["maxOutputLength"]
    $Replacement = [string]$Config["replacement"]

    $Text = Convert-ToOutputText $InputObject

    if ($Text.Length -gt $MaxLength) {
        return [pscustomobject]@{
            Success  = $false
            Status   = "BLOCKED"
            Output   = ""
            Redacted = $false
            Findings = 0
            Reason   = "OUTPUT_TOO_LARGE"
        }
    }

    if (-not [bool]$Config["redactionEnabled"]) {
        return [pscustomobject]@{
            Success  = $true
            Status   = "CLEAN"
            Output   = $Text
            Redacted = $false
            Findings = 0
            Reason   = "REDACTION_DISABLED"
        }
    }

    $FindingCount = Get-SensitiveFindingCount -Text $Text

    if ($FindingCount -lt 0) {
        return [pscustomobject]@{
            Success  = $false
            Status   = "ERROR"
            Output   = ""
            Redacted = $false
            Findings = 0
            Reason   = "PATTERN_ERROR"
        }
    }

    if ($FindingCount -gt 0) {

        $Output = Invoke-SensitiveRedaction `
            -Text $Text `
            -Replacement $Replacement

        return [pscustomobject]@{
            Success  = $true
            Status   = "REDACTED"
            Output   = $Output
            Redacted = $true
            Findings = $FindingCount
            Reason   = "SENSITIVE_DATA_REDACTED"
        }
    }

    return [pscustomobject]@{
        Success  = $true
        Status   = "CLEAN"
        Output   = $Text
        Redacted = $false
        Findings = 0
        Reason   = "NO_SENSITIVE_DATA"
    }
}

function Test-SensitiveOutput {
    param(
        [Parameter()]
        $InputObject
    )

    $Config = Get-OutputSecurityConfig

    $MaxLength = [int]$Config["maxOutputLength"]

    $Text = Convert-ToOutputText $InputObject

    if ($Text.Length -gt $MaxLength) {
        return [pscustomobject]@{
            Success  = $false
            Status   = "BLOCKED"
            Output   = ""
            Redacted = $false
            Findings = 0
            Reason   = "OUTPUT_TOO_LARGE"
        }
    }

    $FindingCount = Get-SensitiveFindingCount -Text $Text

    if ($FindingCount -lt 0) {
        return [pscustomobject]@{
            Success  = $false
            Status   = "ERROR"
            Output   = ""
            Redacted = $false
            Findings = 0
            Reason   = "PATTERN_ERROR"
        }
    }

    if ($FindingCount -gt 0) {
        return [pscustomobject]@{
            Success  = $true
            Status   = "UNSAFE"
            Output   = ""
            Redacted = $true
            Findings = $FindingCount
            Reason   = "SENSITIVE_DATA_DETECTED"
        }
    }

    return [pscustomobject]@{
        Success  = $true
        Status   = "SAFE"
        Output   = $Text
        Redacted = $false
        Findings = 0
        Reason   = "CLEAN"
    }
}