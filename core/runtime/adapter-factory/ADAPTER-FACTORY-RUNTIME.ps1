function Get-AdapterFactoryCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "Adapter Factory Catalog introuvable : $CatalogPath"
    }

    try {
        return (
            Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        )
    }
    catch {
        throw "Adapter Factory Catalog invalide."
    }
}

function New-AdapterInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath,

        [AllowEmptyString()]
        [string]$AdapterId,

        [AllowEmptyString()]
        [string]$Provider,

        [AllowEmptyString()]
        [string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($AdapterId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Provider)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "PROVIDER_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Category)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CATEGORY_REQUIRED"
        }
    }

    $catalog = Get-AdapterFactoryCatalog -CatalogPath $CatalogPath

    if ($catalog.liveCreationEnabled -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LIVE_CREATION_CONFIGURATION_INVALID"
        }
    }

    $matches = @(
        $catalog.adapters | Where-Object {
            $_.adapterId -eq $AdapterId -and
            $_.provider -eq $Provider -and
            $_.category -eq $Category
        }
    )

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_NOT_REGISTERED"
        }
    }

    if ($matches.Count -gt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "MULTIPLE_ADAPTER_DEFINITIONS"
        }
    }

    $definition = $matches[0]

    if (-not $definition.enabled) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_DISABLED"
            adapterId = $definition.adapterId
        }
    }

    if ($definition.lifecycle -eq "DEPRECATED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_DEPRECATED"
            adapterId = $definition.adapterId
        }
    }

    if ($definition.lifecycle -eq "DISABLED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_LIFECYCLE_DISABLED"
            adapterId = $definition.adapterId
        }
    }

    if ($definition.health -ne "HEALTHY") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_UNHEALTHY"
            adapterId = $definition.adapterId
            health = $definition.health
        }
    }

    return [pscustomobject]@{
        status = "CREATED"
        instanceId = "ADAPTER-INSTANCE-$([guid]::NewGuid().ToString())"

        adapterId = $definition.adapterId
        provider = $definition.provider
        category = $definition.category
        version = $definition.version

        lifecycle = $definition.lifecycle
        health = $definition.health

        supportsSimulation = $definition.supportsSimulation
        supportsControlled = $definition.supportsControlled
        supportsLive = $definition.supportsLive

        externalCallAllowed = $false
        secretExposure = $false
    }
}

function Get-AdapterHealth {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$AdapterInstance
    )

    if ($AdapterInstance.status -ne "CREATED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "INVALID_ADAPTER_INSTANCE"
        }
    }

    return [pscustomobject]@{
        status = "HEALTHY"
        adapterId = $AdapterInstance.adapterId
        version = $AdapterInstance.version
        externalCallAllowed = $false
    }
}

function Set-AdapterLifecycle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath,

        [AllowEmptyString()]
        [string]$AdapterId,

        [ValidateSet(
            "REGISTERED",
            "READY",
            "ENABLED",
            "DISABLED",
            "DEPRECATED"
        )]
        [string]$Lifecycle
    )

    if ([string]::IsNullOrWhiteSpace($AdapterId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_ID_REQUIRED"
        }
    }

    $catalog = Get-AdapterFactoryCatalog -CatalogPath $CatalogPath

    $matches = @(
        $catalog.adapters | Where-Object {
            $_.adapterId -eq $AdapterId
        }
    )

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_NOT_REGISTERED"
        }
    }

    if ($matches.Count -gt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "MULTIPLE_ADAPTER_DEFINITIONS"
        }
    }

    $adapter = $matches[0]

    # Cette fonction prépare uniquement l'état.
    # Elle ne contacte aucun provider externe.

    return [pscustomobject]@{
        status = "LIFECYCLE_UPDATED"
        adapterId = $adapter.adapterId
        previousLifecycle = $adapter.lifecycle
        requestedLifecycle = $Lifecycle
        externalCallPerformed = $false
        secretExposure = $false
    }
}