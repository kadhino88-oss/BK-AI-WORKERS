$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $PSCommandPath
$StateDir = Join-Path $RuntimeRoot "state"
$ConfigPath = Join-Path $RuntimeRoot "TRANSACTION-COMPENSATION-CONFIG.json"
$StatePath = Join-Path $StateDir "transactions.json"

function Get-TransactionConfig {

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Configuration Transaction Compensation introuvable."
    }

    return Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}

function Get-TransactionField {

    param(
        [object]$InputObject,
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {

        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]

    if ($null -ne $property) {
        return $property.Value
    }

    return $null
}

function Convert-ToTransactionHashtable {

    param(
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        throw "Objet transaction requis."
    }

    $result = [ordered]@{}

    $fields = @(
        "TransactionId",
        "ExecutionId",
        "TenantId",
        "ClientId",
        "ProjectId",
        "WorkerId",
        "Status",
        "CreatedAtUtc",
        "CommittedAtUtc",
        "RolledBackAtUtc",
        "CompensatedAtUtc",
        "Steps"
    )

    foreach ($field in $fields) {

        $value = Get-TransactionField `
            -InputObject $InputObject `
            -Name $field

        if ($null -ne $value) {
            $result[$field] = $value
        }
    }

    return $result
}

function Convert-StepCollection {

    param(
        [object]$Steps
    )

    if ($null -eq $Steps) {
        return @()
    }

    return @(
        $Steps |
        ForEach-Object {

            if ($_ -is [System.Collections.IDictionary]) {

                [pscustomobject]@{
                    StepId = $_["StepId"]
                    Operation = $_["Operation"]
                    CompensationAction = $_["CompensationAction"]
                    Status = $_["Status"]
                    AddedAtUtc = $_["AddedAtUtc"]
                    CompletedAtUtc = $_["CompletedAtUtc"]
                    CompensatedAtUtc = $_["CompensatedAtUtc"]
                }
            }
            else {

                [pscustomobject]@{
                    StepId = $_.StepId
                    Operation = $_.Operation
                    CompensationAction = $_.CompensationAction
                    Status = $_.Status
                    AddedAtUtc = $_.AddedAtUtc
                    CompletedAtUtc = $_.CompletedAtUtc
                    CompensatedAtUtc = $_.CompensatedAtUtc
                }
            }
        }
    )
}
function Get-TransactionMap {

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @{}
    }

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{}
    }

    $obj = $raw | ConvertFrom-Json
    $map = @{}

    foreach ($property in $obj.PSObject.Properties) {
        $map[$property.Name] = $property.Value
    }

    return $map
}

function Save-TransactionMap {

    param(
        [hashtable]$Map
    )

    if ($null -eq $Map) {
        throw "Map transaction requise."
    }

    $config = Get-TransactionConfig

    if ($Map.Count -gt [int]$config.maxTransactions) {
        throw "Nombre maximal de transactions atteint."
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $Map |
        ConvertTo-Json -Depth 15 |
        Set-Content `
            -LiteralPath $StatePath `
            -Encoding UTF8

    return $true
}

function New-Transaction {

    param(
        [string]$TransactionId,
        [string]$ExecutionId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId
    )

    foreach ($value in @(
        $TransactionId,
        $ExecutionId,
        $TenantId,
        $ClientId,
        $ProjectId,
        $WorkerId
    )) {

        if ($value -and $value -match '[\r\n]') {
            throw "Valeur invalide."
        }
    }

    if ([string]::IsNullOrWhiteSpace($TransactionId)) {
        throw "TransactionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId requis."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId requis."
    }

    $map = Get-TransactionMap

    if ($map.ContainsKey($TransactionId)) {
        throw "Transaction deja existante."
    }

    return [ordered]@{
        TransactionId = $TransactionId
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        Status = "OPEN"
        CreatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        CommittedAtUtc = $null
        RolledBackAtUtc = $null
        CompensatedAtUtc = $null
        Steps = @()
    }
}
function Add-TransactionStep {

    param(
        [object]$Transaction,
        [string]$StepId,
        [string]$Operation,
        [string]$CompensationAction
    )

    $config = Get-TransactionConfig

    if ($null -eq $Transaction) {
        throw "Transaction requise."
    }

    $transactionId = [string](
        Get-TransactionField `
            -InputObject $Transaction `
            -Name "TransactionId"
    )

    $status = [string](
        Get-TransactionField `
            -InputObject $Transaction `
            -Name "Status"
    )

    if ([string]::IsNullOrWhiteSpace($transactionId)) {
        throw "TransactionId requis."
    }

    if ($status -ne "OPEN") {
        throw "Transaction non ouverte."
    }

    if ([string]::IsNullOrWhiteSpace($StepId)) {
        throw "StepId requis."
    }

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        throw "Operation requise."
    }

    if ([string]::IsNullOrWhiteSpace($CompensationAction)) {
        throw "CompensationAction requise."
    }

    $steps = @(
        Convert-StepCollection `
            -Steps (
                Get-TransactionField `
                    -InputObject $Transaction `
                    -Name "Steps"
            )
    )

    if ($steps.Count -ge [int]$config.maxSteps) {
        throw "Nombre maximal d'etapes atteint."
    }

    if (
        @(
            $steps |
            Where-Object {
                $_.StepId -eq $StepId
            }
        ).Count -gt 0
    ) {
        throw "StepId deja existant."
    }

    $steps += [pscustomobject]@{
        StepId = $StepId
        Operation = $Operation
        CompensationAction = $CompensationAction
        Status = "PENDING"
        AddedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        CompletedAtUtc = $null
        CompensatedAtUtc = $null
    }

    $transactionHash = [ordered]@{
        TransactionId = $transactionId
        ExecutionId = [string](
            Get-TransactionField $Transaction "ExecutionId"
        )
        TenantId = [string](
            Get-TransactionField $Transaction "TenantId"
        )
        ClientId = [string](
            Get-TransactionField $Transaction "ClientId"
        )
        ProjectId = [string](
            Get-TransactionField $Transaction "ProjectId"
        )
        WorkerId = [string](
            Get-TransactionField $Transaction "WorkerId"
        )
        Status = $status
        CreatedAtUtc = [string](
            Get-TransactionField $Transaction "CreatedAtUtc"
        )
        CommittedAtUtc = Get-TransactionField $Transaction "CommittedAtUtc"
        RolledBackAtUtc = Get-TransactionField $Transaction "RolledBackAtUtc"
        CompensatedAtUtc = Get-TransactionField $Transaction "CompensatedAtUtc"
        Steps = @($steps)
    }

    return $transactionHash
}
function Save-Transaction {

    param(
        [object]$Transaction
    )

    if ($null -eq $Transaction) {
        throw "Transaction requise."
    }

    $normalized = Convert-ToTransactionHashtable `
        -InputObject $Transaction

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$normalized["TransactionId"]
        )
    ) {
        throw "TransactionId requis."
    }

    if (-not $normalized.Contains("Steps")) {
        $normalized["Steps"] = @()
    }
    else {
        $normalized["Steps"] = @(
            Convert-StepCollection `
                -Steps $normalized["Steps"]
        )
    }

    $map = Get-TransactionMap

    $map[$normalized["TransactionId"]] = $normalized

    Save-TransactionMap -Map $map | Out-Null

    return $true
}
function Get-Transaction {

    param(
        [string]$TransactionId,
        [AllowEmptyString()]
        [string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($TransactionId)) {
        throw "TransactionId requis."
    }

    $map = Get-TransactionMap

    if (-not $map.ContainsKey($TransactionId)) {
        return $null
    }

    $raw = $map[$TransactionId]

    $storedTenant = [string](
        Get-TransactionField `
            -InputObject $raw `
            -Name "TenantId"
    )

    if ($TenantId -and $storedTenant -ne $TenantId) {
        return $null
    }

    $normalized = Convert-ToTransactionHashtable `
        -InputObject $raw

    $normalized["Steps"] = @(
        Convert-StepCollection `
            -Steps $normalized["Steps"]
    )

    return [pscustomobject]$normalized
}
function Complete-TransactionStep {

    param(
        [string]$TransactionId,
        [string]$TenantId,
        [string]$StepId
    )

    $transaction = Get-Transaction `
        -TransactionId $TransactionId `
        -TenantId $TenantId

    if ($null -eq $transaction) {
        return $false
    }

    if ([string]$transaction.Status -ne "OPEN") {
        return $false
    }

    $steps = @(
        Convert-StepCollection `
            -Steps $transaction.Steps
    )

    $found = $false

    foreach ($step in $steps) {

        if ($step.StepId -eq $StepId) {

            if ($step.Status -ne "COMPLETED") {

                $step.Status = "COMPLETED"

                $step.CompletedAtUtc = (
                    Get-Date
                ).ToUniversalTime().ToString("o")
            }

            $found = $true
        }
    }

    if (-not $found) {
        return $false
    }

    $normalized = Convert-ToTransactionHashtable `
        -InputObject $transaction

    $normalized["Steps"] = @($steps)

    Save-Transaction `
        -Transaction $normalized | Out-Null

    return $true
}
function Test-TransactionReadyForCommit {

    param(
        [object]$Transaction
    )

    if ($null -eq $Transaction) {
        return $false
    }

    if ([string]$Transaction.Status -ne "OPEN") {
        return $false
    }

    $steps = @(
        Convert-StepCollection -Steps $Transaction.Steps
    )

    if ($steps.Count -eq 0) {
        return $false
    }

    foreach ($step in $steps) {

        if ([string]$step.Status -ne "COMPLETED") {
            return $false
        }
    }

    return $true
}
function Commit-Transaction {

    param(
        [string]$TransactionId,
        [string]$TenantId
    )

    $transaction = Get-Transaction `
        -TransactionId $TransactionId `
        -TenantId $TenantId

    if ($null -eq $transaction) {
        return $false
    }

    if (-not (Test-TransactionReadyForCommit -Transaction $transaction)) {
        return $false
    }

    $normalized = Convert-ToTransactionHashtable `
        -InputObject $transaction

    $normalized["Status"] = "COMMITTED"

    $normalized["CommittedAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $normalized["Steps"] = @(
        Convert-StepCollection `
            -Steps $transaction.Steps
    )

    Save-Transaction `
        -Transaction $normalized | Out-Null

    return $true
}
function Rollback-Transaction {

    param(
        [string]$TransactionId,
        [string]$TenantId
    )

    $transaction = Get-Transaction `
        -TransactionId $TransactionId `
        -TenantId $TenantId

    if ($null -eq $transaction) {
        return $false
    }

    if ([string]$transaction.Status -notin @("OPEN","FAILED")) {
        return $false
    }

    $normalized = Convert-ToTransactionHashtable `
        -InputObject $transaction

    $normalized["Status"] = "ROLLED_BACK"
    $normalized["RolledBackAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    $normalized["Steps"] = @(
        Convert-StepCollection -Steps $transaction.Steps
    )

    Save-Transaction `
        -Transaction $normalized | Out-Null

    return $true
}
function Invoke-TransactionCompensation {

    param(
        [string]$TransactionId,
        [string]$TenantId
    )

    $config = Get-TransactionConfig

    if (-not $config.compensationEnabled) {
        throw "Compensation desactivee."
    }

    $transaction = Get-Transaction `
        -TransactionId $TransactionId `
        -TenantId $TenantId

    if ($null -eq $transaction) {
        return $false
    }

    if ($transaction.Status -notin @(
        "OPEN",
        "FAILED",
        "ROLLED_BACK"
    )) {
        return $false
    }

    $normalized = Convert-ToTransactionHashtable `
        -InputObject $transaction

    $steps = @(
        Convert-StepCollection `
            -Steps $transaction.Steps
    )

    [array]::Reverse($steps)

    foreach ($step in $steps) {

        if ($step.Status -eq "COMPLETED") {

            $step.Status = "COMPENSATED"

            $step.CompensatedAtUtc = (
                Get-Date
            ).ToUniversalTime().ToString("o")
        }
    }

    $normalized["Steps"] = @($steps)

    $normalized["Status"] = "COMPENSATED"

    $normalized["CompensatedAtUtc"] = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-Transaction `
        -Transaction $normalized | Out-Null

    return $true
}
function Test-TransactionTenantIsolation {

    param(
        [string]$TransactionId,
        [string]$TenantId
    )

    $transaction = Get-Transaction `
        -TransactionId $TransactionId `
        -TenantId $TenantId

    return ($null -ne $transaction)
}

function Reset-TransactionState {

    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    return $true
}