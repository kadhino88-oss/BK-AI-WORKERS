# =====================================================================
# Fausse API Anthropic (messages + Files API) pour tester le lanceur d'etape de projet (Project-StepRunner.ps1) sans reseau, sans cout,
# sans vrai secret. Derive de tests/adapter-review/fake_api.ps1 (laisse intact), avec en plus : envoi de fichiers (-Form), erreurs HTTP
# a statut et retry-after, journal du corps utile de chaque requete (conteneur, context_management, tool_choice, marqueurs de cache).
# A dot-sourcer dans le pilote de test : definit Invoke-RestMethod et Invoke-WebRequest, resolus AVANT les vraies commandes.
#
#   FAKE_CASSETTE   JSON { "responses": [ { "body": {...} } | { "throw": "msg" } | { "throw400": "msg" } | { "throwStatus": 529, "message": "..", "retryAfter": 1 } ] }
#   FAKE_FILES      JSON { "<file_id>": { "filename", "mime_type", "size_bytes" } } (Files API : telechargements)
#   FAKE_LOG        fichier JSONL : une ligne par requete (jamais la cle)
#   FAKE_KEY        la fausse cle API que le code teste doit envoyer
# =====================================================================

class FakeHeaders {
    [hashtable]$Map
    FakeHeaders([hashtable]$m) { $this.Map = $m }
    [bool] TryGetValues([string]$Name, [ref]$Values) {
        if ($this.Map.ContainsKey($Name)) { $Values.Value = @([string]$this.Map[$Name]); return $true }
        return $false
    }
}

class FakeHttpException : System.Exception {
    $Response
    FakeHttpException([string]$Message, [int]$Code, [hashtable]$Headers) : base($Message) {
        $this.Response = [pscustomobject]@{ StatusCode = $Code; Headers = [FakeHeaders]::new($Headers) }
    }
}

$Global:FakeCassette = Get-Content -LiteralPath $env:FAKE_CASSETTE -Raw -Encoding UTF8 | ConvertFrom-Json
$Global:FakeFiles = if ($env:FAKE_FILES) { $env:FAKE_FILES | ConvertFrom-Json } else { [pscustomobject]@{} }
$Global:FakePost = 0
$Global:FakeUploads = 0

function Add-FakeLog {
    param($Entry)
    if ($env:FAKE_LOG) {
        [System.IO.File]::AppendAllText($env:FAKE_LOG, (($Entry | ConvertTo-Json -Depth 12 -Compress) + "`n"), [System.Text.UTF8Encoding]::new($false))
    }
}

function Invoke-RestMethod {
    param($Uri, $Method = "GET", $Headers, $ContentType, $Body, $TimeoutSec, $Credential, $OutFile, $Form)
    $UriText = [string]$Uri
    if ($UriText -notlike "https://api.anthropic.com/*") {
        Add-FakeLog ([ordered]@{ kind = "other"; uri = $UriText; method = [string]$Method })
        return [pscustomobject]@{ ok = $true }
    }
    if ($null -eq $Headers -or [string]$Headers["x-api-key"] -ne $env:FAKE_KEY) { throw "401 invalid x-api-key (fake Anthropic)" }

    if ($UriText -eq "https://api.anthropic.com/v1/files" -and [string]$Method -eq "Post") {
        $Global:FakeUploads++
        $Id = "file_up_" + $Global:FakeUploads
        Add-FakeLog ([ordered]@{ kind = "upload"; fileId = $Id; formKeys = @($Form.Keys); name = [string]$Form["file"].Name })
        return [pscustomobject]@{ id = $Id; type = "file"; filename = [string]$Form["file"].Name }
    }

    if ($UriText -match '^https://api\.anthropic\.com/v1/files/([A-Za-z0-9_\-]+)$') {
        $Id = $Matches[1]
        Add-FakeLog ([ordered]@{ kind = "file"; method = [string]$Method; fileId = $Id })
        if ([string]$Method -eq "Delete") { return [pscustomobject]@{ id = $Id; type = "file_deleted" } }
        $Meta = $Global:FakeFiles.PSObject.Properties[$Id]
        if ($null -eq $Meta) { throw [FakeHttpException]::new("404 file not found", 404, @{}) }
        return [pscustomobject]@{ id = $Id; filename = $Meta.Value.filename; mime_type = $Meta.Value.mime_type; size_bytes = $Meta.Value.size_bytes }
    }

    # POST /v1/messages
    $BodyText = if ($Body -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
    $Req = $BodyText | ConvertFrom-Json
    $Index = $Global:FakePost
    $Global:FakePost++
    $ToolTypes = @(); foreach ($T in @($Req.tools)) { if ($null -ne $T) { $ToolTypes += [string]$T.type + ":" + [string]$T.name } }
    $ToolNames = @(); foreach ($T in @($Req.tools)) { if ($null -ne $T) { $ToolNames += [string]$T.name } }
    $SystemIsArray = ($Req.system -is [System.Array])
    $CacheControl = $false
    if ($SystemIsArray) { foreach ($B in $Req.system) { if ($B.cache_control.type -eq "ephemeral") { $CacheControl = $true } } }
    $SystemText = if ($SystemIsArray) { (@($Req.system | ForEach-Object { [string]$_.text }) -join "`n") } else { [string]$Req.system }
    $WebTool = @($Req.tools | Where-Object { $_.name -eq "web_search" }) | Select-Object -First 1
    $Markers = 0; $LastBlockHasMarker = $false
    foreach ($M in @($Req.messages)) { if ($M.content -is [System.Array]) { foreach ($B in $M.content) { if ($B.cache_control) { $Markers++ } } } }
    $LastMsg = @($Req.messages)[-1]
    if ($LastMsg.content -is [System.Array] -and @($LastMsg.content).Count -gt 0) { $LastBlockHasMarker = [bool](@($LastMsg.content)[-1].cache_control) }
    $LastJson = ($LastMsg | ConvertTo-Json -Depth 12 -Compress)
    if ($LastJson.Length -gt 6000) { $LastJson = $LastJson.Substring(0, 6000) }
    $FirstUser = @($Req.messages)[0]
    $FirstBlockTypes = @(); if ($FirstUser.content -is [System.Array]) { foreach ($B in $FirstUser.content) { $FirstBlockTypes += [string]$B.type } }
    $FirstText = ""; if ($FirstUser.content -is [System.Array]) { $FirstText = [string](@($FirstUser.content | Where-Object { $_.type -eq "text" })[-1].text) }
    $HasExamples = $false; foreach ($T in @($Req.tools)) { if ($T -and $T.input_examples) { $HasExamples = $true } }
    Add-FakeLog ([ordered]@{
        kind = "messages"; index = $Index; model = [string]$Req.model; systemIsArray = $SystemIsArray; systemCacheControl = $CacheControl
        toolTypes = $ToolTypes; toolNames = $ToolNames; betaHeader = [string]$Headers["anthropic-beta"]; messageCount = @($Req.messages).Count
        effort = [string]$Req.output_config.effort; webMaxUses = $(if ($WebTool) { [int]$WebTool.max_uses } else { 0 })
        systemText = $SystemText; timeoutSec = [int]$TimeoutSec; maxTokens = [int]$Req.max_tokens
        container = [string]$Req.container; hasContextManagement = [bool]$Req.context_management; toolChoice = [string]$Req.tool_choice.type
        cacheMarkersInMessages = $Markers; lastBlockHasMarker = $LastBlockHasMarker; lastMessage = $LastJson; hasInputExamples = $HasExamples
        firstBlockTypes = $FirstBlockTypes; firstText = $FirstText
    })
    $Responses = @($Global:FakeCassette.responses)
    if ($Index -ge $Responses.Count) { throw "NO_RECORDED_RESPONSE for call #$Index" }
    $Chosen = $Responses[$Index]
    if ($Chosen.PSObject.Properties["throw400"]) { throw [FakeHttpException]::new([string]$Chosen.throw400, 400, @{}) }
    if ($Chosen.PSObject.Properties["throwStatus"]) {
        $H = @{}; if ($Chosen.PSObject.Properties["retryAfter"]) { $H["retry-after"] = [string]$Chosen.retryAfter }
        throw [FakeHttpException]::new([string]$Chosen.message, [int]$Chosen.throwStatus, $H)
    }
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
        return
    }
    Add-FakeLog ([ordered]@{ kind = "other-web"; uri = $UriText })
    return [pscustomobject]@{ StatusCode = 200 }
}
