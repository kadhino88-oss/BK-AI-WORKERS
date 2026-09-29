# =====================================================================
# BK-AI-WORKERS — Lecture portable des secrets (Windows + Linux/Docker)
# Ordre de resolution pour un secret nomme (ex: "anthropic", "stripe") :
#   1. variable d'environnement BK_SECRET_<NOM>      (Docker / VPS Linux)
#   2. fichier  $BK_SECRETS_DIR/<nom>.secret         (Docker secrets, chmod 600)
#   3. fichier  .secrets/<nom>.secret.dpapi          (Windows uniquement, DPAPI)
# La valeur en clair n'est jamais ecrite sur disque ni loguee par ce module.
# =====================================================================

function Get-BKRootPath {
    if ($env:BK_ROOT) { return $env:BK_ROOT }
    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Test-BKIsWindows {
    return (($PSVersionTable.PSEdition -ne "Core") -or ($IsWindows -eq $true))
}

function Get-BKSecretSource {
    param([Parameter(Mandatory=$true)][string]$Name)
    $Key = $Name.ToLowerInvariant()
    $EnvName = "BK_SECRET_" + $Key.ToUpperInvariant()
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($EnvName))) {
        return [pscustomobject]@{ Kind = "ENV"; Path = $EnvName }
    }
    if ($env:BK_SECRETS_DIR) {
        $FilePath = Join-Path $env:BK_SECRETS_DIR "$Key.secret"
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
            return [pscustomobject]@{ Kind = "FILE"; Path = $FilePath }
        }
    }
    if (Test-BKIsWindows) {
        $DpapiPath = Join-Path (Join-Path (Get-BKRootPath) ".secrets") "$Key.secret.dpapi"
        if (Test-Path -LiteralPath $DpapiPath -PathType Leaf) {
            return [pscustomobject]@{ Kind = "DPAPI"; Path = $DpapiPath }
        }
    }
    return $null
}

function Test-BKSecret {
    param([Parameter(Mandatory=$true)][string]$Name)
    return ($null -ne (Get-BKSecretSource -Name $Name))
}

# Retourne la valeur en clair (a garder en memoire seulement) ou $null.
function Get-BKSecretValue {
    param([Parameter(Mandatory=$true)][string]$Name)
    $Source = Get-BKSecretSource -Name $Name
    if ($null -eq $Source) { return $null }

    switch ($Source.Kind) {
        "ENV"  { return ([Environment]::GetEnvironmentVariable($Source.Path)).Trim() }
        "FILE" { return ([System.IO.File]::ReadAllText($Source.Path)).Trim() }
        "DPAPI" {
            $Encrypted = (Get-Content -LiteralPath $Source.Path -Raw).Trim()
            $Secure = ConvertTo-SecureString $Encrypted
            $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr) }
        }
    }
}
