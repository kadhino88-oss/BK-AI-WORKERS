function New-IntegrationAdapterRequest {
    param(
        [string]$AdapterId,
        [string]$Provider,
        [string]$Category,
        [string]$AdapterVersion,
        [string]$ExecutionId,
        [string]$CorrelationId,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ProjectId,
        [string]$WorkerId,
        [string]$SkillId,
        [string]$TaskId,
        [string]$ToolId,
        [string]$Action,
        [ValidateSet("SIMULATION","CONTROLLED","LIVE")]
        [string]$Mode,
        [ValidateSet("SIMULATION","LIVE","NEEDS_HUMAN","BLOCKED")]
        [string]$PolicyDecision,
        [string]$Operation,
        [hashtable]$Parameters = @{},
        [string]$IdempotencyKey = $null
    )

    $required = @{
        AdapterId = $AdapterId
        Provider = $Provider
        ExecutionId = $ExecutionId
        CorrelationId = $CorrelationId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        WorkerId = $WorkerId
        SkillId = $SkillId
        TaskId = $TaskId
        ToolId = $ToolId
        Action = $Action
        Mode = $Mode
        Operation = $Operation
    }

    foreach ($key in $required.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$required[$key])) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "CONTEXT_INCOMPLETE"
                field = $key
            }
        }
    }

    if (-not $Parameters) {
        $Parameters = @{}
    }

    $serializedParameters = ($Parameters | ConvertTo-Json -Depth 20 -Compress)

    $forbidden = @(
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "client_secret",
        "clientsecret",
        "password",
        "passwd",
        "secret",
        "private_key",
        "privatekey",
        "authorization",
        "bearer"
    )

    foreach ($token in $forbidden) {
        if ($serializedParameters -match [regex]::Escape($token)) {
            return [pscustomobject]@{
                status = "BLOCKED"
                reason = "SECRET_EXPOSURE_ATTEMPT"
                field = $token
            }
        }
    }

    if ($PolicyDecision -eq "BLOCKED") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "POLICY_BLOCKED"
        }
    }

    if ($PolicyDecision -eq "NEEDS_HUMAN") {
        return [pscustomobject]@{
            status = "NEEDS_HUMAN"
            reason = "HUMAN_APPROVAL_REQUIRED"
        }
    }

    if ($Mode -eq "SIMULATION") {
        return [pscustomobject]@{
            contractVersion = "1.0"
            adapter = [pscustomobject]@{
                adapterId = $AdapterId
                provider = $Provider
                category = $Category
                version = $AdapterVersion
                status = "SIMULATION"
            }
            execution = [pscustomobject]@{
                executionId = $ExecutionId
                correlationId = $CorrelationId
                tenantId = $TenantId
                clientId = $ClientId
                projectId = $ProjectId
                workerId = $WorkerId
                skillId = $SkillId
                taskId = $TaskId
                toolId = $ToolId
                action = $Action
                mode = $Mode
                authorization = [pscustomobject]@{
                    capabilityChecked = $true
                    policyDecision = $PolicyDecision
                }
            }
            request = [pscustomobject]@{
                operation = $Operation
                parameters = $Parameters
                idempotencyKey = $IdempotencyKey
            }
            security = [pscustomobject]@{
                secretsProvidedToAdapter = $false
                secretReferencesAllowed = $true
                tenantIsolation = $true
                clientIsolation = $true
                projectIsolation = $true
            }
            response = [pscustomobject]@{
                status = "SIMULATED"
                provider = $Provider
                operation = $Operation
                externalRequestId = $null
                data = $null
                error = $null
            }
        }
    }

    if ($PolicyDecision -ne "LIVE") {
        return [pscustomobject]@{
            status = "BLOCKED"
            reason = "POLICY_NOT_LIVE"
        }
    }

    return [pscustomobject]@{
        contractVersion = "1.0"
        adapter = [pscustomobject]@{
            adapterId = $AdapterId
            provider = $Provider
            category = $Category
            version = $AdapterVersion
            status = "CONTROLLED"
        }
        execution = [pscustomobject]@{
            executionId = $ExecutionId
            correlationId = $CorrelationId
            tenantId = $TenantId
            clientId = $ClientId
            projectId = $ProjectId
            workerId = $WorkerId
            skillId = $SkillId
            taskId = $TaskId
            toolId = $ToolId
            action = $Action
            mode = $Mode
            authorization = [pscustomobject]@{
                capabilityChecked = $true
                policyDecision = $PolicyDecision
            }
        }
        request = [pscustomobject]@{
            operation = $Operation
            parameters = $Parameters
            idempotencyKey = $IdempotencyKey
        }
        security = [pscustomobject]@{
            secretsProvidedToAdapter = $false
            secretReferencesAllowed = $true
            tenantIsolation = $true
            clientIsolation = $true
            projectIsolation = $true
        }
        response = [pscustomobject]@{
            status = "SUCCESS"
            provider = $Provider
            operation = $Operation
            externalRequestId = $null
            data = $null
            error = $null
        }
        executionReady = $true
    }
}