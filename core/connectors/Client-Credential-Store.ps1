# =====================================================================
# BK-AI-WORKERS — Identifiants de connecteurs PAR CLIENT (2026-09-24).
# Remplace le modele precedent (un seul identifiant partage par
# fournisseur, celui de Kader, utilise par tous les clients) : chaque
# client (y compris Kader lui-meme, sous son propre ClientId
# "CLI-DASHBOARD") connecte desormais SES PROPRES comptes. Aucun repli
# implicite vers l'identifiant d'un autre client, jamais.
#
# Stockage : core/connectors/client-credentials/data/<ClientId>/<Provider>.json
# { "ciphertext": "...", "updatedAtUtc": "..." } — chiffre au repos via
# Crypto-Helper.ps1 (AES-256-GCM, cle serveur BK_SECRET_CRED_ENCRYPTION_KEY).
# =====================================================================

Set-StrictMode -Off

$Script:CredStoreRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Script:CredStoreRoot "core/runtime/State-Lock.ps1")
. (Join-Path $Script:CredStoreRoot "core/connectors/Crypto-Helper.ps1")

function Get-BKClientCredentialPath {
    param(
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Provider
    )
    # ClientId/Provider viennent de donnees deja validees en amont
    # (session compte / catalogue de connecteurs) mais on filtre quand
    # meme les caracteres non attendus avant de construire un chemin de
    # fichier, par defense en profondeur.
    $SafeClientId = $ClientId -replace '[^a-zA-Z0-9_-]', ''
    $SafeProvider = $Provider -replace '[^a-zA-Z0-9_-]', ''
    $Dir = Join-Path $Script:CredStoreRoot "core/connectors/client-credentials/data/$SafeClientId"
    return (Join-Path $Dir "$SafeProvider.json")
}

function Test-BKClientCredential {
    param(
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Provider
    )
    $Path = Get-BKClientCredentialPath -ClientId $ClientId -Provider $Provider
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

function Get-BKClientCredentialValue {
    <# Renvoie la valeur en clair (JSON ou jeton simple selon le connecteur), ou $null. #>
    param(
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Provider
    )
    $Path = Get-BKClientCredentialPath -ClientId $ClientId -Provider $Provider
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $Record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $Record.ciphertext) { return $null }
    try {
        $Plain = Unprotect-BKClientCredential -CipherTextB64 $Record.ciphertext
        # 2026-09-25 : la migration des identifiants avait stocke la ligne
        # "BK_SECRET_NOM=valeur" ENTIERE au lieu de la seule valeur : 22 des
        # 23 identifiants de Kader etaient donc illisibles (JSON invalide,
        # jeton faux). On retire ce prefixe a la lecture, quel que soit
        # l'etat du fichier stocke.
        return ($Plain -replace '^\s*BK_SECRET_[A-Za-z0-9_]+=', '').Trim()
    } catch {
        return $null
    }
}

function Set-BKClientCredentialValue {
    <# Chiffre et enregistre une valeur pour (ClientId, Provider). Ecrase toute valeur existante. #>
    param(
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Provider,
        [Parameter(Mandatory=$true)][string]$PlainText
    )
    $Path = Get-BKClientCredentialPath -ClientId $ClientId -Provider $Provider
    $Dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $PlainText = ($PlainText -replace '^\s*BK_SECRET_[A-Za-z0-9_]+=', '').Trim()
    $Cipher = Protect-BKClientCredential -PlainText $PlainText
    $Record = @{
        ciphertext   = $Cipher
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Compress
    # 2026-09-28 : ecriture atomique (fichier temporaire + remplacement) sous
    # le verrou commun. Le fichier <ClientId>/<Provider>.json est partage
    # entre les missions d'un meme client (lu par Get-BKClientCredentialValue,
    # reecrit lors d'un renouvellement OAuth) : un lecteur ne doit jamais voir
    # un fichier a moitie ecrit, et deux ecrivains simultanes ne doivent pas
    # se gener (sous Windows, deux File.Replace concurrents echouent).
    Invoke-BKStateLocked { Write-BKStateFileAtomic -Path $Path -Content $Record } | Out-Null
}

function Remove-BKClientCredential {
    param(
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Provider
    )
    $Path = Get-BKClientCredentialPath -ClientId $ClientId -Provider $Provider
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
        return $true
    }
    return $false
}

function Get-BKClientConfiguredProviders {
    <# Liste des connecteurs pour lesquels CE client a deja un identifiant enregistre. #>
    param([Parameter(Mandatory=$true)][string]$ClientId)
    $SafeClientId = $ClientId -replace '[^a-zA-Z0-9_-]', ''
    $Dir = Join-Path $Script:CredStoreRoot "core/connectors/client-credentials/data/$SafeClientId"
    if (-not (Test-Path -LiteralPath $Dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $Dir -Filter "*.json" | ForEach-Object { $_.BaseName })
}
