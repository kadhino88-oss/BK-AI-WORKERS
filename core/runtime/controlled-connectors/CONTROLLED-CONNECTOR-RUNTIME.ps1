function Get-ControlledConnectorCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "Controlled Connector Catalog introuvable : $CatalogPath"
    }

    $raw = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        throw "Controlled Connector Catalog JSON invalide."
    }
}

function Resolve-ControlledConnector {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath,

        [AllowEmptyString()]
        [string]$Provider,

        [AllowEmptyString()]
        [string]$Category,

        [AllowEmptyString()]
        [string]$Operation
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

    if ([string]::IsNullOrWhiteSpace($Operation)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "OPERATION_REQUIRED"
        }
    }

    $catalog = Get-ControlledConnectorCatalog -CatalogPath $CatalogPath

    $matches = @(
        $catalog.connectors | Where-Object {
            $_.provider -eq $Provider -and
            $_.category -eq $Category
        }
    )

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_NOT_REGISTERED"
            provider = $Provider
            category = $Category
        }
    }

    if ($matches.Count -gt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "MULTIPLE_CONNECTORS"
            provider = $Provider
            category = $Category
        }
    }

    $connector = $matches[0]

    if (-not $connector.enabled) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_DISABLED"
            connectorId = $connector.connectorId
        }
    }

    if ($connector.status -eq "DISABLED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_STATUS_DISABLED"
            connectorId = $connector.connectorId
        }
    }

    $allowedOperation = @(
        $connector.operations | Where-Object {
            $_ -eq $Operation
        }
    )

    if ($allowedOperation.Count -eq 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "OPERATION_NOT_ALLOWED"
            connectorId = $connector.connectorId
            operation = $Operation
        }
    }

    return [pscustomobject]@{
        status = "RESOLVED"
        connectorId = $connector.connectorId
        provider = $connector.provider
        category = $connector.category
        adapterId = $connector.adapterId
        adapterVersion = $connector.adapterVersion
        connectorStatus = $connector.status
        operation = $Operation
    }
}

function Invoke-ControlledConnector {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Connector,

        [AllowEmptyString()]
        [string]$ExecutionId,

        [AllowEmptyString()]
        [string]$CorrelationId,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$CredentialRef,

        [ValidateSet("SIMULATION","CONTROLLED","LIVE")]
        [string]$Mode = "SIMULATION",

        [hashtable]$Parameters = @{}
    )

    # --------------------------------------------------------
    # CONTEXTE OBLIGATOIRE
    # --------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ExecutionId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "CorrelationId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "TenantId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ClientId"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "ProjectId"
        }
    }

    if ($null -eq $Connector) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_REQUIRED"
        }
    }

    if ($Connector.status -ne "RESOLVED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_NOT_RESOLVED"
        }
    }

    # --------------------------------------------------------
    # CREDENTIAL REF OBLIGATOIRE
    # --------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CREDENTIAL_REFERENCE_REQUIRED"
        }
    }

    # --------------------------------------------------------
    # PROTECTION CONTRE SECRET BRUT DANS PARAMETERS
    # --------------------------------------------------------

    if ($null -eq $Parameters) {
        $Parameters = @{}
    }

    $serialized = $Parameters | ConvertTo-Json -Depth 20 -Compress

    $forbidden = @(
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "client_secret",
        "clientsecret",
        "password",
        "passwd",
        "private_key",
        "privatekey",
        "bearer",
        "secret"
    )

    foreach ($token in $forbidden) {
        if ($serialized -match [regex]::Escape($token)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "SECRET_EXPOSURE_ATTEMPT"
                field = $token
            }
        }
    }

    # --------------------------------------------------------
    # CONNECTOR DESACTIVE
    # --------------------------------------------------------

    if ($Connector.connectorStatus -eq "DISABLED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONNECTOR_DISABLED"
        }
    }

    # --------------------------------------------------------
    # MODE SIMULATION
    # --------------------------------------------------------

    if ($Mode -eq "SIMULATION") {
        return [pscustomobject]@{
            status = "SIMULATED"
            connectorId = $Connector.connectorId
            provider = $Connector.provider
            operation = $Connector.operation

            execution = [pscustomobject]@{
                executionId = $ExecutionId
                correlationId = $CorrelationId
                tenantId = $TenantId
                clientId = $ClientId
                projectId = $ProjectId
            }

            credential = [pscustomobject]@{
                credentialRef = $CredentialRef
                secretExposed = $false
            }

            externalCall = [pscustomobject]@{
                performed = $false
                mode = "SIMULATION"
            }

            data = [pscustomobject]@{
                simulated = $true
                message = "Controlled connector simulation."
            }
        }
    }

    # --------------------------------------------------------
    # MODE CONTROLLED
    # --------------------------------------------------------

    if ($Mode -eq "CONTROLLED") {
        return [pscustomobject]@{
            status = "CONTROLLED_READY"
            connectorId = $Connector.connectorId
            provider = $Connector.provider
            operation = $Connector.operation

            execution = [pscustomobject]@{
                executionId = $ExecutionId
                correlationId = $CorrelationId
                tenantId = $TenantId
                clientId = $ClientId
                projectId = $ProjectId
            }

            credential = [pscustomobject]@{
                credentialRef = $CredentialRef
                secretExposed = $false
            }

            externalCall = [pscustomobject]@{
                performed = $false
                mode = "CONTROLLED"
                reason = "LIVE_EXECUTION_NOT_ENABLED"
            }
        }
    }

    # --------------------------------------------------------
    # MODE LIVE
    # --------------------------------------------------------
    # Le Runtime 7H-20 refuse LIVE.
    # L'ouverture sera faite dans une phase ultérieure,
    # après validation des connecteurs réels.

    if ($Mode -eq "LIVE") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "LIVE_EXECUTION_DISABLED"
            connectorId = $Connector.connectorId
            provider = $Connector.provider
            operation = $Connector.operation
        }
    }

    return [pscustomobject]@{
        status = "BLOCKED"
        reason = "UNKNOWN_MODE"
    }
}