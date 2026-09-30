function Get-AdapterRegistry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath
    )

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        throw "Registry introuvable : $RegistryPath"
    }

    $raw = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        throw "Registry JSON invalide : $($_.Exception.Message)"
    }
}

function Resolve-IntegrationAdapter {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,

        [Parameter(Mandatory = $true)]
        [string]$Provider,

        [Parameter(Mandatory = $true)]
        [string]$Category,

        [string]$ClientId = $null,

        [string]$ProjectId = $null
    )

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

    if (
        [string]::IsNullOrWhiteSpace($ClientId) -and
        -not [string]::IsNullOrWhiteSpace($ProjectId)
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CLIENT_REQUIRED_FOR_PROJECT_BINDING"
        }
    }

    $registry = Get-AdapterRegistry -RegistryPath $RegistryPath

    # --------------------------------------------------------
    # Priorité 1 : override Client + Project
    # --------------------------------------------------------

    if (
        -not [string]::IsNullOrWhiteSpace($ClientId) -and
        -not [string]::IsNullOrWhiteSpace($ProjectId)
    ) {
        $override = @(
            $registry.clientProjectOverrides | Where-Object {
                $_.clientId -eq $ClientId -and
                $_.projectId -eq $ProjectId -and
                $_.provider -eq $Provider -and
                $_.category -eq $Category
            }
        )

        if ($override.Count -gt 1) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "MULTIPLE_OVERRIDES"
            }
        }

        if ($override.Count -eq 1) {
            $binding = $override[0]

            $adapter = @(
                $registry.adapters | Where-Object {
                    $_.adapterId -eq $binding.adapterId
                }
            )

            if ($adapter.Count -ne 1) {
                return [pscustomobject]@{
                    status = "BLOCKED"
                    reason = "ADAPTER_NOT_REGISTERED"
                    adapterId = $binding.adapterId
                }
            }

            $selectedAdapter = $adapter[0]

            if (-not $selectedAdapter.enabled) {
                return [pscustomobject]@{
                    status = "BLOCKED"
                    reason = "ADAPTER_DISABLED"
                    adapterId = $selectedAdapter.adapterId
                }
            }

            if ($selectedAdapter.status -eq "DISABLED") {
                return [pscustomobject]@{
                    status = "BLOCKED"
                    reason = "ADAPTER_STATUS_DISABLED"
                    adapterId = $selectedAdapter.adapterId
                }
            }

            if (
                -not $registry.defaults.allowVersionMismatch -and
                $selectedAdapter.version -ne $binding.adapterVersion
            ) {
                return [pscustomobject]@{
                    status = "BLOCKED"
                    reason = "VERSION_MISMATCH"
                    adapterId = $selectedAdapter.adapterId
                    registeredVersion = $selectedAdapter.version
                    requestedVersion = $binding.adapterVersion
                }
            }

            return [pscustomobject]@{
                status = "RESOLVED"
                source = "CLIENT_PROJECT_OVERRIDE"
                provider = $Provider
                category = $Category
                adapterId = $selectedAdapter.adapterId
                adapterVersion = $selectedAdapter.version
                adapterStatus = $selectedAdapter.status
                clientId = $ClientId
                projectId = $ProjectId
            }
        }
    }

    # --------------------------------------------------------
    # Priorité 2 : binding provider/category
    # --------------------------------------------------------

    $bindings = @(
        $registry.providerBindings | Where-Object {
            $_.provider -eq $Provider -and
            $_.category -eq $Category
        }
    )

    if ($bindings.Count -eq 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "PROVIDER_NOT_BOUND"
            provider = $Provider
            category = $Category
        }
    }

    if ($bindings.Count -gt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "MULTIPLE_PROVIDER_BINDINGS"
            provider = $Provider
            category = $Category
        }
    }

    $binding = $bindings[0]

    $adapterMatches = @(
        $registry.adapters | Where-Object {
            $_.adapterId -eq $binding.adapterId
        }
    )

    if ($adapterMatches.Count -ne 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_NOT_REGISTERED"
            adapterId = $binding.adapterId
        }
    }

    $adapter = $adapterMatches[0]

    if (-not $adapter.enabled) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_DISABLED"
            adapterId = $adapter.adapterId
        }
    }

    if (
        -not $registry.defaults.allowDisabledAdapters -and
        $adapter.status -eq "DISABLED"
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "ADAPTER_STATUS_DISABLED"
            adapterId = $adapter.adapterId
        }
    }

    if (
        -not $registry.defaults.allowVersionMismatch -and
        $adapter.version -ne $binding.adapterVersion
    ) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "VERSION_MISMATCH"
            adapterId = $adapter.adapterId
            registeredVersion = $adapter.version
            requestedVersion = $binding.adapterVersion
        }
    }

    return [pscustomobject]@{
        status = "RESOLVED"
        source = "PROVIDER_BINDING"
        provider = $Provider
        category = $Category
        adapterId = $adapter.adapterId
        adapterVersion = $adapter.version
        adapterStatus = $adapter.status
        clientId = $ClientId
        projectId = $ProjectId
    }
}