# Verrou inter-processus + ecriture atomique des fichiers d'etat partages
# (state/users.json, state/sessions.json) - voir core/runtime/State-Lock.ps1.
$BKLockRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $BKLockRoot "core/runtime/State-Lock.ps1")

function Get-IdentityAuthConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-IdentityAuthField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-IdentityAuthConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-IdentityUsers {
    $path = Join-Path $PSScriptRoot "state/users.json"

    if (-not (Test-Path $path)) {
        return @()
    }

    $raw = Get-Content -Raw -Path $path

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json

    if ($null -eq $parsed) {
        return @()
    }

    $result = @()

    foreach ($item in @($parsed)) {
        $result += ,$item
    }

    return $result
}

function Save-IdentityUsers {
    param(
        [Parameter(Mandatory=$false)]
        $Users
    )

    $path = Join-Path $PSScriptRoot "state/users.json"

    $normalized = @()

    foreach ($item in @($Users)) {
        $normalized += ,$item
    }

    $json = ConvertTo-Json `
        -InputObject $normalized `
        -Depth 100

    Write-BKStateFileAtomic -Path $path -Content $json

    return $true
}

function Get-IdentitySessions {
    $path = Join-Path $PSScriptRoot "state/sessions.json"

    if (-not (Test-Path $path)) {
        return @()
    }

    $raw = Get-Content -Raw -Path $path

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json

    if ($null -eq $parsed) {
        return @()
    }

    $result = @()

    foreach ($item in @($parsed)) {
        $result += ,$item
    }

    return $result
}

function Save-IdentitySessions {
    param(
        [Parameter(Mandatory=$false)]
        $Sessions
    )

    $path = Join-Path $PSScriptRoot "state/sessions.json"

    $normalized = @()

    foreach ($item in @($Sessions)) {
        $normalized += ,$item
    }

    $json = ConvertTo-Json `
        -InputObject $normalized `
        -Depth 100

    Write-BKStateFileAtomic -Path $path -Content $json

    return $true
}

function Get-IdentityUser {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$UserId
    )

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        return $null
    }

    $users = @(Get-IdentityUsers)

    foreach ($user in $users) {
        if ([string]$user.UserId -eq $UserId) {
            return $user
        }
    }

    return $null
}

function Get-IdentitySession {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return $null
    }

    $sessions = @(Get-IdentitySessions)

    foreach ($session in $sessions) {
        if ([string]$session.SessionId -eq $SessionId) {
            return $session
        }
    }

    return $null
}

function Test-IdentityContext {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$UserId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Username,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AccountStatus
    )

    $cfg = Get-IdentityAuthConfig

    if (-not $cfg.enabled -or -not $cfg.identityEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "IDENTITY_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "USER_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Username)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "USERNAME_REQUIRED"
        }
    }

    if ($cfg.tenantBindingRequired) {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "TENANT_ID_REQUIRED"
            }
        }
    }

    if ($cfg.clientBindingRequired) {
        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CLIENT_ID_REQUIRED"
            }
        }
    }

    if ($cfg.projectBindingRequired) {
        if ([string]::IsNullOrWhiteSpace($ProjectId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "PROJECT_ID_REQUIRED"
            }
        }
    }

    if ($cfg.accountStatusRequired) {
        if ([string]::IsNullOrWhiteSpace($AccountStatus)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "ACCOUNT_STATUS_REQUIRED"
            }
        }

        $allowedStatuses = @(
            "ACTIVE",
            "DISABLED",
            "LOCKED",
            "PENDING"
        )

        $statusFound = $false

        foreach ($status in $allowedStatuses) {
            if ($status -eq $AccountStatus) {
                $statusFound = $true
                break
            }
        }

        if (-not $statusFound) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "ACCOUNT_STATUS_INVALID"
            }
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "VALID"
        Reason  = "IDENTITY_CONTEXT_VALID"
    }
}

function New-IdentityUser {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$UserId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Username,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId = "",

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AccountStatus = "ACTIVE"
    )

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        $UserId = [guid]::NewGuid().ToString()
    }

    $check = Test-IdentityContext `
        -UserId $UserId `
        -Username $Username `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -AccountStatus $AccountStatus

    if (-not $check.Success) {
        return $check
    }

    # Lecture -> verification doublons/limite -> ajout -> ecriture de
    # state/users.json dans un seul bloc verrouille.
    return (Invoke-BKStateLocked {
        $users = @(Get-IdentityUsers)
        $cfg = Get-IdentityAuthConfig

        foreach ($existing in $users) {

            if ([string]$existing.UserId -eq $UserId) {
                return [pscustomobject]@{
                    Success = $false
                    Status  = "DUPLICATE"
                    Reason  = "USER_ID_ALREADY_EXISTS"
                    UserId  = $UserId
                }
            }

            if ([string]$existing.Username -eq $Username -and
                [string]$existing.TenantId -eq $TenantId) {

                return [pscustomobject]@{
                    Success = $false
                    Status  = "DUPLICATE"
                    Reason  = "USERNAME_ALREADY_EXISTS_IN_TENANT"
                }
            }
        }

        if (@($users).Length -ge [int]$cfg.maxUsers) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "USER_LIMIT_REACHED"
            }
        }

        $user = [pscustomobject]@{
            UserId       = $UserId
            Username     = $Username
            TenantId     = $TenantId
            ClientId     = $ClientId
            ProjectId    = $ProjectId
            AccountStatus = $AccountStatus
            CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
        }

        $users += ,$user

        $null = Save-IdentityUsers $users

        return [pscustomobject]@{
            Success       = $true
            Status        = "CREATED"
            Reason        = "IDENTITY_CREATED"
            UserId        = $UserId
            Username      = $Username
            TenantId      = $TenantId
            ClientId      = $ClientId
            ProjectId     = $ProjectId
            AccountStatus = $AccountStatus
        }
    })
}

function Test-IdentityAuthentication {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$UserId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId
    )

    $cfg = Get-IdentityAuthConfig

    if (-not $cfg.authenticationEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "AUTHENTICATION_DISABLED"
        }
    }

    $user = Get-IdentityUser -UserId $UserId

    if ($null -eq $user) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "USER_NOT_FOUND"
        }
    }

    if ($user.AccountStatus -ne "ACTIVE") {

        if (-not $cfg.allowDisabledAccount) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "ACCOUNT_NOT_ACTIVE"
            }
        }
    }

    if ([string]$user.TenantId -ne [string]$TenantId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "TENANT_MISMATCH"
        }
    }

    if ([string]$user.ClientId -ne [string]$ClientId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLIENT_MISMATCH"
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "AUTHENTICATED"
        Reason  = "IDENTITY_AUTHENTICATED"
        UserId = $user.UserId
        TenantId = $user.TenantId
        ClientId = $user.ClientId
        ProjectId = $user.ProjectId
    }
}

function New-IdentitySession {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$UserId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId = ""
    )

    $cfg = Get-IdentityAuthConfig

    if (-not $cfg.sessionEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SESSION_DISABLED"
        }
    }

    $auth = Test-IdentityAuthentication `
        -UserId $UserId `
        -TenantId $TenantId `
        -ClientId $ClientId

    if (-not $auth.Success) {
        return $auth
    }

    # Lecture -> verification limite -> ajout -> ecriture de
    # state/sessions.json dans un seul bloc verrouille.
    return (Invoke-BKStateLocked {
        $sessions = @(Get-IdentitySessions)

        if (@($sessions).Length -ge [int]$cfg.maxSessions) {
            return [pscustomobject]@{
                Success = $false
                Status = "BLOCKED"
                Reason = "SESSION_LIMIT_REACHED"
            }
        }

        $now = [DateTime]::UtcNow
        $expires = $now.AddSeconds(
            [double]$cfg.sessionDurationSeconds
        )

        $session = [pscustomobject]@{
            SessionId    = [guid]::NewGuid().ToString()
            UserId       = $UserId
            TenantId     = $TenantId
            ClientId     = $ClientId
            ProjectId    = $ProjectId
            Status       = "ACTIVE"
            CreatedAtUtc = $now.ToString("o")
            ExpiresAtUtc = $expires.ToString("o")
        }

        $sessions += ,$session

        $null = Save-IdentitySessions $sessions

        return [pscustomobject]@{
            Success     = $true
            Status      = "SESSION_CREATED"
            Reason      = "SESSION_CREATED"
            SessionId   = $session.SessionId
            UserId      = $UserId
            TenantId    = $TenantId
            ClientId    = $ClientId
            ProjectId   = $ProjectId
            ExpiresAtUtc = $expires.ToString("o")
        }
    })
}

function Test-IdentitySession {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$SessionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [datetime]$ReferenceTime = [DateTime]::UtcNow
    )

    $session = Get-IdentitySession `
        -SessionId $SessionId

    if ($null -eq $session) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SESSION_NOT_FOUND"
        }
    }

    if ([string]$session.TenantId -ne [string]$TenantId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SESSION_TENANT_MISMATCH"
        }
    }

    if ([string]$session.ClientId -ne [string]$ClientId) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SESSION_CLIENT_MISMATCH"
        }
    }

    if ([string]$session.Status -ne "ACTIVE") {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SESSION_NOT_ACTIVE"
        }
    }

    try {
        $expires = [DateTime]::Parse(
            [string]$session.ExpiresAtUtc
        )
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SESSION_EXPIRATION_INVALID"
        }
    }

    if ($ReferenceTime -ge $expires) {

        if (-not (Get-IdentityAuthConfig).allowExpiredSession) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "SESSION_EXPIRED"
            }
        }
    }

    return [pscustomobject]@{
        Success   = $true
        Status    = "VALID"
        Reason    = "SESSION_VALID"
        SessionId = $session.SessionId
        UserId    = $session.UserId
        TenantId  = $session.TenantId
        ClientId  = $session.ClientId
        ProjectId = $session.ProjectId
        ExpiresAtUtc = $expires.ToString("o")
    }
}

function Revoke-IdentitySession {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$SessionId
    )

    if ([string]::IsNullOrWhiteSpace($SessionId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "SESSION_ID_REQUIRED"
        }
    }

    # Lecture -> revocation -> ecriture de state/sessions.json dans un seul
    # bloc verrouille.
    return (Invoke-BKStateLocked {
        $sessions = @(Get-IdentitySessions)
        $found = $false

        foreach ($session in $sessions) {

            if ([string]$session.SessionId -eq $SessionId) {

                if ([string]$session.Status -eq "REVOKED") {
                    return [pscustomobject]@{
                        Success = $false
                        Status  = "DUPLICATE"
                        Reason  = "SESSION_ALREADY_REVOKED"
                    }
                }

                $session.Status = "REVOKED"

                $revokedAt = [DateTime]::UtcNow.ToString("o")

                $existingProperty = $session.PSObject.Properties["RevokedAtUtc"]

                if ($null -eq $existingProperty) {
                    $session | Add-Member `
                        -MemberType NoteProperty `
                        -Name "RevokedAtUtc" `
                        -Value $revokedAt `
                        -Force
                }
                else {
                    $session.RevokedAtUtc = $revokedAt
                }

                $found = $true
                break
            }
        }

        if (-not $found) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "SESSION_NOT_FOUND"
            }
        }

        $null = Save-IdentitySessions $sessions

        return [pscustomobject]@{
            Success    = $true
            Status     = "REVOKED"
            Reason     = "SESSION_REVOKED"
            SessionId  = $SessionId
            RevokedAtUtc = $revokedAt
        }
    })
}
function Reset-IdentityAuth {
    # Les deux remises a zero sous le verrou : aucune mission ne peut
    # intercaler une lecture/ecriture entre elles ni reecrire un etat perime.
    $null = Invoke-BKStateLocked {
        $null = Save-IdentityUsers @()
        $null = Save-IdentitySessions @()
    }
    return $true
}