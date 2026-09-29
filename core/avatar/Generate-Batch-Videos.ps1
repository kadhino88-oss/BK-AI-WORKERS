# =====================================================================
# BK-AI-WORKERS — Generation en lot des videos talking-avatar (D-ID)
# pour les Workers qui n'en ont pas encore. Reutilise DID-Adapter.ps1
# (cle D-ID + voix ElevenLabs deja stockees en DPAPI). Necessite un
# portrait-3d.jpg reel (pas un badge SVG) pour chaque Worker traite.
# =====================================================================

param(
    [string[]]$WorkerIds = @("rayan","sophie","yanis","nora","dario","ines","clara","amina","thomas","chloe")
)

$ErrorActionPreference = "Stop"
$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

. (Join-Path $Root "core\avatar\DID-Adapter.ps1")

$IntroTexts = @{
    rayan  = "Bonjour, je suis Rayan. Je connecte vos outils entre eux pour automatiser les taches repetitives et vous faire gagner du temps."
    sophie = "Bonjour, je suis Sophie. Je m'occupe du recrutement et des ressources humaines, de la fiche de poste jusqu'au suivi des candidatures."
    yanis  = "Bonjour, je suis Yanis. Je pilote vos projets, du planning aux jalons, pour que chaque mission avance dans les temps."
    nora   = "Bonjour, je suis Nora. Je prends en charge vos tickets clients, du tri jusqu'a la resolution."
    dario  = "Bonjour, je suis Dario. Je suis vos depenses et votre budget pour garder une vision claire de vos finances."
    ines   = "Bonjour, je suis Ines. Je nettoie et j'analyse vos donnees pour en tirer des rapports clairs et fiables."
    clara  = "Bonjour, je suis Clara. Je redige et relis vos contrats, et je signale les points qui meritent votre attention."
    amina  = "Bonjour, je suis Amina. Je fais de la veille marche et de la recherche concurrentielle pour eclairer vos decisions."
    thomas = "Bonjour, je suis Thomas. Je m'occupe de vos fiches produits et du suivi de vos stocks sur vos marketplaces."
    chloe  = "Bonjour, je suis Chloe. Je comprends votre demande, je mobilise les bons Workers, et je verifie leur travail avant de vous le livrer."
}

$Results = @()

foreach ($WorkerId in $WorkerIds) {
    $WorkerLower = $WorkerId.ToLowerInvariant()
    $BaseDir = if ($WorkerLower -eq "chloe") { Join-Path $Root "chloe" } else { Join-Path $Root "workers\$WorkerLower" }

    $IdentityPath = Join-Path $BaseDir "identity\identity.json"
    $PortraitPath = Join-Path $BaseDir "identity\portrait-3d.jpg"
    $OutDir = Join-Path $BaseDir "identity\generated"
    $OutPath = Join-Path $OutDir "intro.mp4"

    Write-Host ""
    Write-Host "=== $WorkerLower ===" -ForegroundColor Cyan

    if (-not (Test-Path -LiteralPath $PortraitPath -PathType Leaf)) {
        Write-Host "SKIP : pas de portrait-3d.jpg reel (badge SVG uniquement) — voir visual_identity dans identity.json" -ForegroundColor Yellow
        $Results += [pscustomobject]@{ Worker = $WorkerLower; Status = "SKIPPED_NO_PORTRAIT" }
        continue
    }

    if (-not (Test-Path -LiteralPath $IdentityPath -PathType Leaf)) {
        Write-Host "SKIP : identity.json introuvable" -ForegroundColor Yellow
        $Results += [pscustomobject]@{ Worker = $WorkerLower; Status = "SKIPPED_NO_IDENTITY" }
        continue
    }

    $Identity = Get-Content -LiteralPath $IdentityPath -Raw | ConvertFrom-Json
    $Voice = $Identity.voice
    if ($null -eq $Voice -or $Voice.status -ne "CONFIGURED") {
        Write-Host "SKIP : voix non configuree" -ForegroundColor Yellow
        $Results += [pscustomobject]@{ Worker = $WorkerLower; Status = "SKIPPED_NO_VOICE" }
        continue
    }

    $Text = $IntroTexts[$WorkerLower]
    if ([string]::IsNullOrWhiteSpace($Text)) {
        Write-Host "SKIP : pas de texte d'intro defini" -ForegroundColor Yellow
        $Results += [pscustomobject]@{ Worker = $WorkerLower; Status = "SKIPPED_NO_TEXT" }
        continue
    }

    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }

    Write-Host "Generation en cours (voix: $($Voice.voice_name))..."

    $Result = Invoke-DIDTalkGeneration `
        -ImagePath $PortraitPath `
        -Text $Text `
        -OutputPath $OutPath `
        -VoiceId $Voice.voice_id `
        -VoiceProvider $Voice.provider `
        -ModelId $Voice.model_id

    if ($Result.Status -eq "SUCCESS") {
        Write-Host "OK -> $OutPath" -ForegroundColor Green
    } else {
        Write-Host "ERREUR : $($Result.Detail)" -ForegroundColor Red
    }

    $Results += [pscustomobject]@{ Worker = $WorkerLower; Status = $Result.Status; Detail = $Result.Detail }
}

Write-Host ""
Write-Host "============================================"
Write-Host " RESUME"
Write-Host "============================================"
$Results | Format-Table -AutoSize
