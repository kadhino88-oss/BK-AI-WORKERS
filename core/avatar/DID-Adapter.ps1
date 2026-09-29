# =====================================================================
# BK-AI-WORKERS — Adaptateur D-ID (avatar parlant a partir d'un portrait)
# Cle API chargee en DPAPI depuis .secrets\did.secret.dpapi (jamais en
# clair sur disque, jamais journalisee), meme convention que OpenAI.
# Ecrit le 2026-09-14.
# =====================================================================

$Script:DIDRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Script:DIDSecretPath = Join-Path $Script:DIDRoot ".secrets\did.secret.dpapi"
$Script:DIDApiBase = "https://api.d-id.com"

function Get-DIDAuthHeader {
    if (-not (Test-Path -LiteralPath $Script:DIDSecretPath -PathType Leaf)) {
        throw "DID_CREDENTIAL_NOT_CONFIGURED"
    }

    $Encrypted = Get-Content -LiteralPath $Script:DIDSecretPath -Raw
    $SecureCredential = ConvertTo-SecureString $Encrypted
    $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureCredential)
    try {
        $PlainKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Ptr)
        if ([string]::IsNullOrWhiteSpace($PlainKey)) {
            throw "DID_CREDENTIAL_EMPTY"
        }
        # Les cles D-ID generees depuis leur dashboard sont deja au
        # format "username:password" ; on les encode telles quelles.
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainKey)
        return "Basic " + [System.Convert]::ToBase64String($Bytes)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Ptr)
    }
}

function Send-DIDImageUpload {
    param(
        [Parameter(Mandatory=$true)][string]$ImagePath
    )

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "DID_IMAGE_NOT_FOUND:$ImagePath"
    }

    $AuthHeader = Get-DIDAuthHeader

    $Boundary = [guid]::NewGuid().ToString()
    $FileBytes = [System.IO.File]::ReadAllBytes($ImagePath)
    $FileName = [System.IO.Path]::GetFileName($ImagePath)

    $BodyLines = @(
        "--$Boundary",
        "Content-Disposition: form-data; name=`"image`"; filename=`"$FileName`"",
        "Content-Type: image/jpeg",
        "",
        [System.Text.Encoding]::GetEncoding(28591).GetString($FileBytes),
        "--$Boundary--",
        ""
    )
    $Body = $BodyLines -join "`r`n"
    $BodyBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($Body)

    $Response = Invoke-RestMethod `
        -Uri "$Script:DIDApiBase/images" `
        -Method Post `
        -Headers @{ Authorization = $AuthHeader } `
        -ContentType "multipart/form-data; boundary=$Boundary" `
        -Body $BodyBytes `
        -TimeoutSec 60

    if (-not $Response.url) {
        throw "DID_UPLOAD_NO_URL"
    }

    return $Response.url
}

function New-DIDTalk {
    param(
        [Parameter(Mandatory=$true)][string]$SourceUrl,
        [Parameter(Mandatory=$true)][string]$Text,
        [string]$VoiceId = "fr-FR-DeniseNeural",
        [string]$VoiceProvider = "microsoft",
        [string]$ModelId = $null
    )

    $AuthHeader = Get-DIDAuthHeader

    $Provider = @{
        type = $VoiceProvider
        voice_id = $VoiceId
    }
    if ($ModelId) {
        $Provider["model_id"] = $ModelId
    }

    $Body = @{
        source_url = $SourceUrl
        script = @{
            type = "text"
            input = $Text
            provider = $Provider
        }
    } | ConvertTo-Json -Depth 10

    $Response = Invoke-RestMethod `
        -Uri "$Script:DIDApiBase/talks" `
        -Method Post `
        -Headers @{ Authorization = $AuthHeader } `
        -ContentType "application/json" `
        -Body $Body `
        -TimeoutSec 30

    if (-not $Response.id) {
        throw "DID_TALK_CREATION_FAILED"
    }

    return $Response.id
}

function Get-DIDTalkStatus {
    param(
        [Parameter(Mandatory=$true)][string]$TalkId
    )

    $AuthHeader = Get-DIDAuthHeader

    return Invoke-RestMethod `
        -Uri "$Script:DIDApiBase/talks/$TalkId" `
        -Method Get `
        -Headers @{ Authorization = $AuthHeader } `
        -TimeoutSec 30
}

function Invoke-DIDTalkGeneration {
    <#
    Orchestre le flux complet : upload du portrait -> creation du talk
    -> attente (poll) -> telechargement de la video finale.
    Retourne un objet avec Status ("SUCCESS"/"ERROR"), VideoPath, Detail.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ImagePath,
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$OutputPath,
        [string]$VoiceId = "fr-FR-DeniseNeural",
        [string]$VoiceProvider = "microsoft",
        [string]$ModelId = $null,
        [int]$MaxPollSeconds = 90
    )

    try {
        $SourceUrl = Send-DIDImageUpload -ImagePath $ImagePath
        $TalkId = New-DIDTalk -SourceUrl $SourceUrl -Text $Text -VoiceId $VoiceId -VoiceProvider $VoiceProvider -ModelId $ModelId

        $Elapsed = 0
        $PollIntervalSeconds = 3
        $Status = $null

        while ($Elapsed -lt $MaxPollSeconds) {
            Start-Sleep -Seconds $PollIntervalSeconds
            $Elapsed += $PollIntervalSeconds
            $Status = Get-DIDTalkStatus -TalkId $TalkId

            if ($Status.status -eq "done") {
                break
            }
            if ($Status.status -eq "error" -or $Status.status -eq "rejected") {
                return [pscustomobject]@{
                    Status = "ERROR"
                    Detail = "DID_TALK_$($Status.status.ToUpper()):$($Status.error.description)"
                    VideoPath = $null
                    TalkId = $TalkId
                }
            }
        }

        if ($null -eq $Status -or $Status.status -ne "done") {
            return [pscustomobject]@{
                Status = "ERROR"
                Detail = "DID_TALK_TIMEOUT"
                VideoPath = $null
                TalkId = $TalkId
            }
        }

        Invoke-WebRequest -Uri $Status.result_url -OutFile $OutputPath -TimeoutSec 60 | Out-Null

        return [pscustomobject]@{
            Status = "SUCCESS"
            Detail = "OK"
            VideoPath = $OutputPath
            TalkId = $TalkId
        }
    }
    catch {
        return [pscustomobject]@{
            Status = "ERROR"
            Detail = $_.Exception.Message
            VideoPath = $null
            TalkId = $null
        }
    }
}
