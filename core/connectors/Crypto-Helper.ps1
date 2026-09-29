# =====================================================================
# BK-AI-WORKERS — Chiffrement des identifiants de connecteurs PAR CLIENT
# (2026-09-24). Remplace progressivement le modele "une seule cle
# partagee par fournisseur" (BK_SECRET_<NOM>, DPAPI Windows uniquement)
# par un identifiant propre a CHAQUE client, chiffre au repos avec AES-256-GCM
# et une cle maitresse serveur (BK_SECRET_CRED_ENCRYPTION_KEY, generee une
# fois, jamais vue en clair par un humain — purement technique, pas un
# compte personnel).
#
# Format du blob chiffre (une seule ligne, base64) : nonce(12) || tag(16) || ciphertext
# =====================================================================

Set-StrictMode -Off

function Get-BKCredEncryptionKey {
    $KeyB64 = [Environment]::GetEnvironmentVariable("BK_SECRET_CRED_ENCRYPTION_KEY")
    if ([string]::IsNullOrWhiteSpace($KeyB64)) {
        throw "BK_SECRET_CRED_ENCRYPTION_KEY absente : impossible de chiffrer/dechiffrer les identifiants clients."
    }
    $KeyBytes = [Convert]::FromBase64String($KeyB64)
    if ($KeyBytes.Length -ne 32) {
        throw "BK_SECRET_CRED_ENCRYPTION_KEY doit faire 32 octets (AES-256) une fois decodee en base64."
    }
    return $KeyBytes
}

function Protect-BKClientCredential {
    <# .SYNOPSIS Chiffre une valeur en clair -> chaine base64 (nonce+tag+ciphertext). #>
    param([Parameter(Mandatory=$true)][string]$PlainText)

    $Key = Get-BKCredEncryptionKey
    $Nonce = [byte[]]::new(12)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($Nonce)

    $PlainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $CipherBytes = [byte[]]::new($PlainBytes.Length)
    $Tag = [byte[]]::new(16)

    $Aes = [System.Security.Cryptography.AesGcm]::new($Key)
    try {
        $Aes.Encrypt($Nonce, $PlainBytes, $CipherBytes, $Tag)
    } finally {
        $Aes.Dispose()
    }

    $Combined = $Nonce + $Tag + $CipherBytes
    return [Convert]::ToBase64String($Combined)
}

function Unprotect-BKClientCredential {
    <# .SYNOPSIS Dechiffre une chaine produite par Protect-BKClientCredential. #>
    param([Parameter(Mandatory=$true)][string]$CipherTextB64)

    $Key = Get-BKCredEncryptionKey
    $Combined = [Convert]::FromBase64String($CipherTextB64)
    if ($Combined.Length -lt 28) {
        throw "Blob chiffre invalide (trop court)."
    }

    $Nonce = $Combined[0..11]
    $Tag = $Combined[12..27]
    $CipherBytes = $Combined[28..($Combined.Length - 1)]
    $PlainBytes = [byte[]]::new($CipherBytes.Length)

    $Aes = [System.Security.Cryptography.AesGcm]::new($Key)
    try {
        $Aes.Decrypt($Nonce, $CipherBytes, $Tag, $PlainBytes)
    } finally {
        $Aes.Dispose()
    }

    return [System.Text.Encoding]::UTF8.GetString($PlainBytes)
}
