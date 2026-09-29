function Get-CredentialStoreCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath
    )

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        throw "Credential catalog introuvable : $CatalogPath"
    }

    $raw = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8

    try {
        return ($raw | ConvertFrom-Json)
    }
    catch {
        throw "Credential catalog JSON invalide : $($_.Exception.Message)"
    }
}

function Resolve-CredentialReference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath,

        [AllowEmptyString()]
        [string]$TenantId,

        [AllowEmptyString()]
        [string]$ClientId,

        [AllowEmptyString()]
        [string]$ProjectId,

        [AllowEmptyString()]
        [string]$Provider,

        [AllowEmptyString()]
        [string]$Category,

        [AllowEmptyString()]
        [string]$CredentialRef = $null
    )

    # ========================================================
    # VALIDATION EXPLICITE DU CONTEXTE
    # Ne jamais laisser PowerShell décider du comportement
    # métier concernant les chaînes vides.
    # ========================================================

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

    if ([string]::IsNullOrWhiteSpace($Provider)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "Provider"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Category)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CONTEXT_INCOMPLETE"
            field = "Category"
        }
    }

    # ========================================================
    # CHARGEMENT DU CATALOGUE
    # ========================================================

    if (-not (Test-Path -LiteralPath $CatalogPath)) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CATALOG_NOT_FOUND"
        }
    }

    try {
        $raw = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8
        $catalog = $raw | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CATALOG_INVALID"
        }
    }

    # ========================================================
    # SECURITE DU CATALOGUE
    # ========================================================

    if ($catalog.security.storeRawSecrets -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RAW_SECRET_STORAGE_FORBIDDEN"
        }
    }

    if ($catalog.security.returnRawSecretsToWorkers -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RAW_SECRET_WORKER_EXPOSURE_FORBIDDEN"
        }
    }

    if ($catalog.security.returnRawSecretsToLogs -ne $false) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "RAW_SECRET_LOG_EXPOSURE_FORBIDDEN"
        }
    }

    if ($catalog.security.tenantIsolation -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "TENANT_ISOLATION_INVALID"
        }
    }

    if ($catalog.security.clientIsolation -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CLIENT_ISOLATION_INVALID"
        }
    }

    if ($catalog.security.projectIsolation -ne $true) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "PROJECT_ISOLATION_INVALID"
        }
    }

    # ========================================================
    # RECHERCHE STRICTEMENT ISOLÉE
    # ========================================================

    $matches = @(
        $catalog.credentials | Where-Object {
            $_.tenantId -eq $TenantId -and
            $_.clientId -eq $ClientId -and
            $_.projectId -eq $ProjectId -and
            $_.provider -eq $Provider -and
            $_.category -eq $Category
        }
    )

    # ========================================================
    # CREDENTIAL REF EXPLICITE
    # ========================================================

    if (-not [string]::IsNullOrWhiteSpace($CredentialRef)) {
        $matches = @(
            $matches | Where-Object {
                $_.credentialRef -eq $CredentialRef
            }
        )
    }

    if ($matches.Count -eq 0) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CREDENTIAL_NOT_FOUND"
            tenantId = $TenantId
            clientId = $ClientId
            projectId = $ProjectId
            provider = $Provider
            category = $Category
        }
    }

    if ($matches.Count -gt 1) {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "MULTIPLE_CREDENTIALS"
        }
    }

    $credential = $matches[0]

    if ($credential.status -ne "CONFIGURED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CREDENTIAL_NOT_CONFIGURED"
            credentialRef = $credential.credentialRef
        }
    }

    # ========================================================
    # RESULTAT SANITIZED
    # JAMAIS DE SECRET BRUT
    # ========================================================

    return [pscustomobject]@{
        status = "RESOLVED"
        credentialRef = $credential.credentialRef
        tenantId = $credential.tenantId
        clientId = $credential.clientId
        projectId = $credential.projectId
        provider = $credential.provider
        category = $credential.category
        secretStore = $credential.secretStore

        secret = $null
        accessToken = $null
        apiKey = $null
        password = $null
        refreshToken = $null
        clientSecret = $null
        privateKey = $null

        secretExposure = $false
    }
}
function Get-AdapterCredentialHandle {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$ResolvedCredential
    )

    if ($ResolvedCredential.status -ne "RESOLVED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "CREDENTIAL_NOT_RESOLVED"
        }
    }

    return [pscustomobject]@{
        status = "AUTHORIZED"
        credentialRef = $ResolvedCredential.credentialRef
        tenantId = $ResolvedCredential.tenantId
        clientId = $ResolvedCredential.clientId
        projectId = $ResolvedCredential.projectId
        provider = $ResolvedCredential.provider
        category = $ResolvedCredential.category

        secretExposure = $false

        # Le handle ne contient aucun secret brut.
        secret = $null
        accessToken = $null
        apiKey = $null
        password = $null
    }
}