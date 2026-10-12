# =====================================================================
# Faux API Anthropic (messages + Files API) pour tester ANTHROPIC-ADAPTER.ps1 sans reseau, sans cout, sans vrai secret.
# A dot-sourcer dans le pilote de test : definit Invoke-RestMethod et Invoke-WebRequest, que PowerShell resout AVANT
# les vraies commandes dans tous les scripts enfants.
#
#   FAKE_CASSETTE   JSON { "responses": [ { "body": {...reponse Messages API...} } | { "throw": "msg" } | { "throw400": "msg" } ] }
#                   consommees dans l'ordre pour chaque POST /v1/messages
#   FAKE_FILES      JSON { "<file_id>": { "filename": "...", "mime_type": "...", "size_bytes": 123 } } (Files API)
#   FAKE_LOG        fichier JSONL : une ligne par requete (corps JSON des POST /v1/messages inclus, jamais la cle)
#   FAKE_KEY        la fausse cle API que le code teste doit envoyer
# =====================================================================

class FakeHttpException : System.Exception {
    $Response
    FakeHttpException([string]$Message, [int]$Code) : base($Message) {
        $this.Response = [pscustomobject]@{ StatusCode = $Code }
    }
}

$Global:FakeCassette = Get-Content -LiteralPath $env:FAKE_CASSETTE -Raw -Encoding UTF8 | ConvertFrom-Json
$Global:FakeFiles = if ($env:FAKE_FILES) { $env:FAKE_FILES | ConvertFrom-Json } else { [pscustomobject]@{} }
$Global:FakePost = 0

function Add-FakeLog {
    param($Entry)
    if ($env:FAKE_LOG) {
        [System.IO.File]::AppendAllText($env:FAKE_LOG, (($Entry | ConvertTo-Json -Depth 12 -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
}

function Invoke-RestMethod {
    param($Uri, $Method = "GET", $Headers, $ContentType, $Body, $TimeoutSec, $Credential, $OutFile)
    $UriText = [string]$Uri
    if ($UriText -notlike "https://api.anthropic.com/*") {
        Add-FakeLog ([ordered]@{ kind = "other"; uri = $UriText; method = [string]$Method })
        return [pscustomobject]@{ ok = $true }
    }
    if ($null -eq $Headers -or [string]$Headers["x-api-key"] -ne $env:FAKE_KEY) { throw "401 invalid x-api-key (fake Anthropic)" }

    if ($UriText -match '^https://api\.anthropic\.com/v1/files/([A-Za-z0-9_\-]+)$') {
        $Id = $Matches[1]
        Add-FakeLog ([ordered]@{ kind = "file"; method = [string]$Method; fileId = $Id })
        if ([string]$Method -eq "Delete") { return [pscustomobject]@{ id = $Id; type = "file_deleted" } }
        $Meta = $Global:FakeFiles.PSObject.Properties[$Id]
        if ($null -eq $Meta) { throw [FakeHttpException]::new("404 file not found", 404) }
        return [pscustomobject]@{ id = $Id; filename = $Meta.Value.filename; mime_type = $Meta.Value.mime_type; size_bytes = $Meta.Value.size_bytes }
    }

    # POST /v1/messages
    $BodyText = if ($Body -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
    $Req = $BodyText | ConvertFrom-Json
    $Index = $Global:FakePost
    $Global:FakePost++
    $ToolTypes = @(); foreach ($T in @($Req.tools)) { if ($null -ne $T) { $ToolTypes += [string]$T.type + ":" + [string]$T.name } }
    $SystemIsArray = ($Req.system -is [System.Array])
    $CacheControl = $false
    if ($SystemIsArray) { foreach ($B in $Req.system) { if ($B.cache_control.type -eq "ephemeral") { $CacheControl = $true } } }
    $SystemText = if ($SystemIsArray) { (@($Req.system | ForEach-Object { [string]$_.text }) -join "`n") } else { [string]$Req.system }
    $WebTool = @($Req.tools | Where-Object { $_.name -eq "web_search" }) | Select-Object -First 1
    Add-FakeLog ([ordered]@{
        kind = "messages"; index = $Index; model = [string]$Req.model; systemIsArray = $SystemIsArray; systemCacheControl = $CacheControl
        toolTypes = $ToolTypes; betaHeader = [string]$Headers["anthropic-beta"]; messageCount = @($Req.messages).Count
        effort = [string]$Req.output_config.effort; webMaxUses = $(if ($WebTool) { [int]$WebTool.max_uses } else { 0 })
        systemHasMemory = ($SystemText -like "*<client_memory>*"); systemText = $SystemText
        timeoutSec = [int]$TimeoutSec
    })
    $Responses = @($Global:FakeCassette.responses)
    if ($Index -ge $Responses.Count) { throw "NO_RECORDED_RESPONSE for call #$Index" }
    $Chosen = $Responses[$Index]
    if ($Chosen.PSObject.Properties["throw400"]) { throw [FakeHttpException]::new([string]$Chosen.throw400, 400) }
    if ($Chosen.PSObject.Properties["throw"]) { throw [string]$Chosen.throw }
    return $Chosen.body
}

function Invoke-WebRequest {
    param($Uri, $Method = "GET", $Headers, $TimeoutSec, $OutFile, $UseBasicParsing)
    $UriText = [string]$Uri
    if ($UriText -match '^https://api\.anthropic\.com/v1/files/([A-Za-z0-9_\-]+)/content$') {
        $Id = $Matches[1]
        Add-FakeLog ([ordered]@{ kind = "download"; fileId = $Id })
        $Meta = $Global:FakeFiles.PSObject.Properties[$Id]
        $Size = if ($null -ne $Meta) { [int][Math]::Min([double]$Meta.Value.size_bytes, 2MB) } else { 16 }
        [System.IO.File]::WriteAllBytes([string]$OutFile, (New-Object byte[] $Size))
        return   # comme la vraie commande : rien sur le pipeline avec -OutFile
    }
    Add-FakeLog ([ordered]@{ kind = "other-web"; uri = $UriText })
    return [pscustomobject]@{ StatusCode = 200 }
}
