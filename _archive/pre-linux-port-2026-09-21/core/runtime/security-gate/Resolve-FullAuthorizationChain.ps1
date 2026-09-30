# =====================================================================
# BK-AI-WORKERS — Resolution partagee de la chaine d'autorisation complete
# (Capability, Authority, Policy, WorkerTask, Credential, Connector,
# Provider, Evidence, Retention, PurgeReuse).
#
# Extrait depuis Invoke-Orchestrator.ps1 le 2026-09-14 pour etre reutilise
# aussi par Invoke-Worker-AI.ps1 (et tout futur appelant), plutot que de
# dupliquer ~250 lignes de logique de resolution. AUCUN comportement
# n'est change par rapport a Invoke-Orchestrator.ps1 : meme choix de
# modules, memes commentaires de justification conserves ci-dessous.
# =====================================================================

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$CapabilityEnforcer = Join-Path $Root "core\permissions\capability-matrix\CAPABILITY-ENFORCER.ps1"
$CapabilityMatrixPath = Join-Path $Root "core\permissions\capability-matrix\CAPABILITY-MATRIX.json"
$AuthorityGate = Join-Path $Root "core\runtime\authority-gate\Authority-Gate.ps1"
$ExecutionPolicyEngine = Join-Path $Root "core\runtime\execution-policy\EXECUTION-POLICY-ENGINE.ps1"
$AuthorizationGatewayPath = Join-Path $Root "core\security\authorization-gateway\Authorization-Gateway.ps1"
$AuthorizationGrantPath = Join-Path $Root "core\security\authorization-grant\Authorization-Grant.ps1"
$GrantExecutionPath = Join-Path $Root "core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1"
$FreshnessPath = Join-Path $Root "core\security\authorization-freshness\Authorization-Freshness.ps1"
$ContextIntegrityPath = Join-Path $Root "core\security\authorization-context-integrity\Authorization-Context-Integrity.ps1"
$WorkerTaskAuthorityPath = Join-Path $Root "core\security\worker-task-authority\Worker-Task-Authority.ps1"
$CredentialAccessPath = Join-Path $Root "core\security\credential-access-authorization\Credential-Access-Authorization.ps1"
$ControlledConnectorRuntime = Join-Path $Root "core\runtime\controlled-connectors\CONTROLLED-CONNECTOR-RUNTIME.ps1"
$ControlledConnectorCatalogPath = Join-Path $Root "core\runtime\controlled-connectors\CONTROLLED-CONNECTOR-CATALOG.json"
$AIProvidersConfigPath = Join-Path $Root "core\ai\AI-PROVIDERS.json"
$RetentionTenantGuardPath = Join-Path $Root "core\runtime\execution-retention-tenant-guard\runtime.ps1"
$EvidencePurgeReusePath = Join-Path $Root "core\security\credential-recovery\evidence-purge-reuse\Evidence-Purge-Reuse-Guard.ps1"

foreach ($DepPath in @(
    $CapabilityEnforcer,
    $AuthorityGate,
    $ExecutionPolicyEngine,
    $AuthorizationGatewayPath,
    $AuthorizationGrantPath,
    $GrantExecutionPath,
    $FreshnessPath,
    $ContextIntegrityPath,
    $WorkerTaskAuthorityPath,
    $CredentialAccessPath,
    $ControlledConnectorRuntime,
    $RetentionTenantGuardPath,
    $EvidencePurgeReusePath
)) {
    if (-not (Test-Path -LiteralPath $DepPath -PathType Leaf)) {
        throw "FULL_AUTHORIZATION_CHAIN_DEPENDENCY_MISSING:$DepPath"
    }
}

. $AuthorityGate
. $AuthorizationGatewayPath
. $AuthorizationGrantPath
. $GrantExecutionPath
. $FreshnessPath
. $ContextIntegrityPath
. $WorkerTaskAuthorityPath
. $CredentialAccessPath
. $ControlledConnectorRuntime
. $RetentionTenantGuardPath
. $EvidencePurgeReusePath

function Resolve-BKFullAuthorizationChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Worker,
        [Parameter(Mandatory=$true)][string]$Action,
        [Parameter(Mandatory=$true)][string]$Description,
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$true)][string]$TenantId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$ProjectId,
        [Parameter(Mandatory=$true)][string]$ExecutionId,
        [Parameter(Mandatory=$true)][string]$UserId,
        [Parameter(Mandatory=$true)][string]$SessionId,
        [Parameter(Mandatory=$true)][string]$TokenId,
        [Parameter(Mandatory=$true)][string]$Token,
        [Parameter(Mandatory=$true)][string]$Mode
    )

    # =================================================
    # RESOLUTION + APPLICATION REELLE DE LA CAPABILITY
    # (Worker + Skill + Tool + Action), avant le Gate.
    # Aucun contournement : si aucune capability reelle
    # n'est resolue et autorisee par le Capability
    # Enforcer, CapabilityAuthorized reste $false et le
    # Global Security Gate bloque legitimement dessus.
    # =================================================

    $CapabilityAuthorized = $false
    $ResolvedSkillId = $null
    $ResolvedToolId = $null
    $CapabilityDecision = $null

    try {
        $Matrix = Get-Content -LiteralPath $CapabilityMatrixPath -Raw -Encoding UTF8 | ConvertFrom-Json

        $WorkerEntry = $Matrix.workers |
            Where-Object { $_.workerId -eq $Worker } |
            Select-Object -First 1

        if ($null -ne $WorkerEntry) {
            $SkillRegistryRelative = [string]$WorkerEntry.skillsSource
            $SkillRegistryPath = Join-Path $Root ($SkillRegistryRelative -replace "/", "\")

            $SkillRegistry = $null
            if (Test-Path -LiteralPath $SkillRegistryPath) {
                $SkillRegistry = Get-Content -LiteralPath $SkillRegistryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            }

            # On essaie chaque capability declaree (pas seulement la
            # premiere) jusqu'a trouver une skillDomain qui correspond
            # reellement a une categorie presente dans le registre de
            # skills du Worker. Aucune tentative de rapprochement
            # approximatif entre noms differents : correspondance exacte
            # uniquement, sur des donnees deja declarees par le projet.
            foreach ($Capability in $WorkerEntry.capabilities) {
                if ($null -ne $SkillRegistry) {
                    foreach ($SkillProperty in $SkillRegistry.skills.PSObject.Properties) {
                        if ($Capability.skillDomains -contains $SkillProperty.Value.category) {
                            $ResolvedToolId = [string]$Capability.tool
                            $ResolvedSkillId = $SkillProperty.Name
                            break
                        }
                    }
                }
                if ($null -ne $ResolvedSkillId) { break }
            }

            if ($null -ne $ResolvedSkillId) {
                $CapabilityDecision = & $CapabilityEnforcer `
                    -WorkerId $Worker `
                    -SkillId $ResolvedSkillId `
                    -ToolId $ResolvedToolId `
                    -Action $Action `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId `
                    -Mode $Mode

                $CapabilityAuthorized = [bool]$CapabilityDecision.authorized
            }
        }
    }
    catch {
        $CapabilityAuthorized = $false
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DE L'AUTHORITY GATE.
    # =================================================

    $AuthorityAuthorized = $false

    try {
        $AuthorityRequest = New-AuthorityRequest `
            -RequestId $TaskId `
            -ExecutionId $ExecutionId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -WorkerId $Worker `
            -ActionType $Action `
            -Description $Description

        if ($null -ne $AuthorityRequest -and $AuthorityRequest.RequestId -eq $TaskId) {
            $AuthorityDecision = Test-AuthorityExecution -RequestId $TaskId
            $AuthorityAuthorized = [bool]$AuthorityDecision.Allowed
        }
    }
    catch {
        $AuthorityAuthorized = $false
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DE LA POLICY.
    # =================================================

    $PolicyAuthorized = $false

    if (($null -ne $ResolvedSkillId) -and ($null -ne $ResolvedToolId)) {
        try {
            $PolicyAuthorizationDecision = if ($null -ne $CapabilityDecision) { [string]$CapabilityDecision.decision } else { "BLOCKED" }

            $PolicyDecision = & $ExecutionPolicyEngine `
                -AuthorizationDecision $PolicyAuthorizationDecision `
                -WorkerId $Worker `
                -SkillId $ResolvedSkillId `
                -ToolId $ResolvedToolId `
                -Action $Action `
                -Mode $Mode `
                -HumanApproved $false

            $PolicyAuthorized = [bool]$PolicyDecision.allowed
        }
        catch {
            $PolicyAuthorized = $false
        }
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DU WORKER_TASK.
    # Chaine anti-confused-deputy : Authorization Decision
    # -> Grant -> Execution Binding -> Freshness -> Context
    # Integrity -> Worker/Task Authority.
    # =================================================

    $WorkerTaskAuthorized = $false
    $Grant = $null
    $GrantBinding = $null
    $Freshness = $null
    $Integrity = $null
    $WorkerTaskAuthority = $null

    if (($null -ne $ResolvedSkillId) -and ($null -ne $ResolvedToolId)) {
        try {
            $OrchestratorAuth = Authorize-Request `
                -UserId $UserId `
                -SessionId $SessionId `
                -Action $Action `
                -TenantId $TenantId `
                -ClientId $ClientId `
                -ProjectId $ProjectId `
                -TokenId $TokenId `
                -Token $Token

            if ($null -ne $OrchestratorAuth -and $OrchestratorAuth.Decision -eq "ALLOW") {

                $Grant = New-AuthorizationGrant `
                    -AuthorizationId $OrchestratorAuth.DecisionId `
                    -UserId $UserId `
                    -SessionId $SessionId `
                    -Action $Action `
                    -TenantId $TenantId `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId

                if ($null -ne $Grant -and -not [string]::IsNullOrWhiteSpace([string]$Grant.GrantId)) {

                    $GrantBinding = New-ExecutionGrantBinding `
                        -GrantId $Grant.GrantId `
                        -Grant $Grant.Grant `
                        -ExecutionId $ExecutionId `
                        -UserId $UserId `
                        -SessionId $SessionId `
                        -Action $Action `
                        -TenantId $TenantId `
                        -ClientId $ClientId `
                        -ProjectId $ProjectId

                    if ($null -ne $GrantBinding -and -not [string]::IsNullOrWhiteSpace([string]$GrantBinding.BindingId)) {

                        $Freshness = New-AuthorizationFreshness `
                            -UserId $UserId `
                            -SessionId $SessionId `
                            -GrantId $Grant.GrantId `
                            -Grant $Grant.Grant `
                            -BindingId $GrantBinding.BindingId `
                            -ExecutionId $ExecutionId `
                            -Action $Action `
                            -TenantId $TenantId `
                            -ClientId $ClientId `
                            -ProjectId $ProjectId

                        if ($null -ne $Freshness -and -not [string]::IsNullOrWhiteSpace([string]$Freshness.FreshnessId)) {

                            $Integrity = New-AuthorizationContextIntegrity `
                                -UserId $UserId `
                                -SessionId $SessionId `
                                -GrantId $Grant.GrantId `
                                -BindingId $GrantBinding.BindingId `
                                -ExecutionId $ExecutionId `
                                -Action $Action `
                                -TenantId $TenantId `
                                -ClientId $ClientId `
                                -ProjectId $ProjectId `
                                -Grant $Grant.Grant `
                                -FreshnessId $Freshness.FreshnessId `
                                -Nonce $Freshness.Nonce

                            if ($null -ne $Integrity -and -not [string]::IsNullOrWhiteSpace([string]$Integrity.IntegrityId)) {

                                $WorkerTaskAuthority = New-WorkerTaskAuthority `
                                    -UserId $UserId `
                                    -SessionId $SessionId `
                                    -GrantId $Grant.GrantId `
                                    -BindingId $GrantBinding.BindingId `
                                    -ExecutionId $ExecutionId `
                                    -Action $Action `
                                    -TenantId $TenantId `
                                    -ClientId $ClientId `
                                    -ProjectId $ProjectId `
                                    -WorkerId $Worker `
                                    -TaskId $TaskId `
                                    -Grant $Grant.Grant `
                                    -FreshnessId $Freshness.FreshnessId `
                                    -Nonce $Freshness.Nonce `
                                    -IntegrityId $Integrity.IntegrityId

                                if ($null -ne $WorkerTaskAuthority -and $WorkerTaskAuthority.Success -eq $true) {

                                    $WorkerTaskCheck = Test-WorkerTaskAuthority `
                                        -AuthorityId $WorkerTaskAuthority.AuthorityId `
                                        -UserId $UserId `
                                        -SessionId $SessionId `
                                        -GrantId $Grant.GrantId `
                                        -BindingId $GrantBinding.BindingId `
                                        -ExecutionId $ExecutionId `
                                        -Action $Action `
                                        -TenantId $TenantId `
                                        -ClientId $ClientId `
                                        -ProjectId $ProjectId `
                                        -WorkerId $Worker `
                                        -TaskId $TaskId

                                    $WorkerTaskAuthorized = (
                                        $WorkerTaskCheck.Success -eq $true -and
                                        $WorkerTaskCheck.Decision -eq "ALLOW"
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            $WorkerTaskAuthorized = $false
        }
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DU CREDENTIAL.
    # =================================================

    $CredentialAuthorized = $false
    $CredentialAuthorization = $null

    if (
        ($null -ne $ResolvedToolId) -and
        ($null -ne $Grant) -and
        ($null -ne $GrantBinding) -and
        ($null -ne $Freshness) -and
        ($null -ne $Integrity)
    ) {
        try {
            $CredentialRef = "CRED-REF-$Worker-$ResolvedToolId"

            $CredentialAuthorization = New-CredentialAccessAuthorization `
                -UserId $UserId `
                -SessionId $SessionId `
                -TenantId $TenantId `
                -ClientId $ClientId `
                -ProjectId $ProjectId `
                -WorkerId $Worker `
                -Action $Action `
                -ConnectorId $ResolvedToolId `
                -CredentialRef $CredentialRef `
                -Grant $Grant.Grant `
                -FreshnessId $Freshness.FreshnessId `
                -Nonce $Freshness.Nonce `
                -IntegrityId $Integrity.IntegrityId

            if ($null -ne $CredentialAuthorization -and $CredentialAuthorization.Success -eq $true) {

                $CredentialCheck = Test-CredentialAccessAuthorization `
                    -AuthorizationId $CredentialAuthorization.AuthorizationId `
                    -CredentialRef $CredentialRef `
                    -UserId $UserId `
                    -SessionId $SessionId `
                    -TenantId $TenantId `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId `
                    -WorkerId $Worker `
                    -Action $Action `
                    -ConnectorId $ResolvedToolId

                $CredentialAuthorized = (
                    $CredentialCheck.Success -eq $true -and
                    $CredentialCheck.Decision -eq "ALLOW"
                )
            }
        }
        catch {
            $CredentialAuthorized = $false
        }
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DU CONNECTOR.
    # =================================================

    $ConnectorAuthorized = $false

    if ($null -ne $ResolvedToolId) {
        try {
            $ReadLikeOperation = $null
            $Catalog = Get-ControlledConnectorCatalog -CatalogPath $ControlledConnectorCatalogPath

            $CatalogEntry = $Catalog.connectors |
                Where-Object { $_.provider -eq $ResolvedToolId -and $_.enabled -eq $true } |
                Select-Object -First 1

            if ($null -ne $CatalogEntry) {
                $ReadLikeOperation = $CatalogEntry.operations |
                    Where-Object { $_ -match "READ|SEARCH" } |
                    Select-Object -First 1
            }

            if ($null -ne $ReadLikeOperation) {
                $ConnectorResolution = Resolve-ControlledConnector `
                    -CatalogPath $ControlledConnectorCatalogPath `
                    -Provider $ResolvedToolId `
                    -Category $CatalogEntry.category `
                    -Operation $ReadLikeOperation

                $ConnectorAuthorized = ($ConnectorResolution.status -eq "RESOLVED")
            }
        }
        catch {
            $ConnectorAuthorized = $false
        }
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DU PROVIDER.
    # =================================================

    $ProviderAuthorized = $false

    try {
        $ProvidersConfig = Get-Content -LiteralPath $AIProvidersConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

        if ($Mode -eq "SIMULATION") {
            $ProviderAuthorized = [bool]$ProvidersConfig.development.simulation
        }
        else {
            $EnabledProviders = @(
                $ProvidersConfig.providers.PSObject.Properties |
                Where-Object { $_.Value.enabled -eq $true }
            )
            $ProviderAuthorized = ($EnabledProviders.Count -gt 0)
        }
    }
    catch {
        $ProviderAuthorized = $false
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DE RETENTION ET
    # PURGE_REUSE.
    #
    # CHOIX DOCUMENTE (aucun module dedie evident n'existe
    # pour ces deux stages dans le contexte "execution de
    # tache") :
    #   - RETENTION -> core/runtime/execution-retention-tenant-guard
    #   - PURGE_REUSE -> Evidence-Purge-Reuse-Guard.ps1
    # A CONFIRMER/CORRIGER par Kader/ChatGPT si un autre
    # module etait prevu.
    # =================================================

    $RetentionValid = $false
    $PurgeReuseValid = $false
    $RetentionId = $TaskId

    if ($null -ne $ResolvedToolId) {
        try {
            $RetentionRegistration = Register-RetentionTenantRecord `
                -RetentionId $RetentionId `
                -TenantId $TenantId `
                -ClientId $ClientId `
                -ProjectId $ProjectId

            if ($null -ne $RetentionRegistration -and $RetentionRegistration.Success -eq $true) {

                $RetentionCheck = Test-RetentionTenantAuthorization `
                    -RetentionId $RetentionId `
                    -TenantId $TenantId `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId `
                    -Operation $Action

                $RetentionValid = ($RetentionCheck.Success -eq $true)
            }
        }
        catch {
            $RetentionValid = $false
        }

        if ($RetentionValid) {
            try {
                $EvidenceHashSource = "$TaskId|$ExecutionId|$Worker|$ClientId|$ProjectId"
                $Sha256 = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $HashBytes = $Sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($EvidenceHashSource))
                    $EvidenceHash = -join ($HashBytes | ForEach-Object { $_.ToString("x2") })
                }
                finally {
                    $Sha256.Dispose()
                }

                $PurgeReuseRegistration = Register-EvidencePurgeReuseGuard `
                    -EvidenceId $TaskId `
                    -RetentionId $RetentionId `
                    -TenantId $TenantId `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId `
                    -ExecutionId $ExecutionId `
                    -EvidenceHash $EvidenceHash `
                    -ImmutableEvidence $true `
                    -IntegrityValid $true `
                    -RetentionState "RETAINED"

                if ($null -ne $PurgeReuseRegistration -and -not [string]::IsNullOrWhiteSpace([string]$PurgeReuseRegistration.GuardId)) {

                    $PurgeReuseCheck = Test-EvidencePurgeReuse -GuardId $PurgeReuseRegistration.GuardId
                    $PurgeReuseValid = ($PurgeReuseCheck.Allowed -eq $true)
                }
            }
            catch {
                $PurgeReuseValid = $false
            }
        }
    }

    # =================================================
    # RESOLUTION + APPLICATION REELLE DE L'EVIDENCE.
    # =================================================

    $EvidenceAuthorized = (
        ($null -ne $Grant) -and
        ($null -ne $GrantBinding) -and
        ($null -ne $Freshness) -and
        ($null -ne $Integrity) -and
        ($null -ne $WorkerTaskAuthority) -and ($WorkerTaskAuthority.Success -eq $true) -and
        ($null -ne $CredentialAuthorization) -and ($CredentialAuthorization.Success -eq $true) -and
        $RetentionValid -and
        $PurgeReuseValid
    )

    return [pscustomobject]@{
        ResolvedSkillId       = $ResolvedSkillId
        ResolvedToolId        = $ResolvedToolId
        CapabilityAuthorized  = $CapabilityAuthorized
        AuthorityAuthorized   = $AuthorityAuthorized
        PolicyAuthorized      = $PolicyAuthorized
        WorkerTaskAuthorized  = $WorkerTaskAuthorized
        CredentialAuthorized  = $CredentialAuthorized
        ConnectorAuthorized   = $ConnectorAuthorized
        ProviderAuthorized    = $ProviderAuthorized
        EvidenceAuthorized    = $EvidenceAuthorized
        RetentionValid        = $RetentionValid
        PurgeReuseValid       = $PurgeReuseValid
    }
}
