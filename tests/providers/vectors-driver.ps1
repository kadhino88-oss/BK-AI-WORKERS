# Pilote PowerShell des tests de Engine-Common.ps1 : vecteurs d'adresses partages avec Python, appel d'outil texte, fichiers texte, depense / disjoncteur.
# Sortie : un objet JSON { ipMismatches, endpointMismatches, tool, files, health } lu par tests/providers/test_engine_common_ps.py.
param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$OutFile)
$ErrorActionPreference = "Stop"
$env:BK_ROOT = $Repo
. (Join-Path $Repo "core/ai/adapters/Engine-Common.ps1")

$Cases = Get-Content -LiteralPath (Join-Path $Repo "tests/providers/endpoint-cases.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$IpBad = @()
foreach ($C in $Cases.ipClasses) {
    $Got = Get-BKIpClass -Address $C.addr
    if ($Got -ne $C.class) { $IpBad += "$($C.addr): attendu $($C.class), obtenu $Got" }
}
$EpBad = @()
foreach ($C in $Cases.endpoints) {
    $Dns = $C.dns
    $Script:BKResolveHook = { param($H, $P) $Prop = $Dns.PSObject.Properties[$H]; if ($null -eq $Prop) { throw "nx" }; @($Prop.Value) }.GetNewClosure()
    $Allowed = if ($C.PSObject.Properties["allowed"]) { @($C.allowed) } else { @() }
    $R = Test-BKEndpointPolicy -Url $C.url -Kind $C.kind -HasToken ([bool]$C.token) -AllowedHosts $Allowed
    if ($R.Ok -ne [bool]$C.ok) { $EpBad += "$($C.name): ok attendu $($C.ok), obtenu $($R.Ok) ($($R.Code))"; continue }
    if (-not $C.ok -and $R.Code -ne $C.code) { $EpBad += "$($C.name): code attendu $($C.code), obtenu $($R.Code)" }
}
$Script:BKResolveHook = $null

# Appel d'outil ecrit en texte (strict)
$Names = @("use_connector", "memory", "web_fetch", "write_text_file")
$ToolCases = [ordered]@{}
$ToolCases["plain"] = (ConvertFrom-BKToolText -Text "Bonjour, voici la reponse." -ToolNames $Names).Kind
$ToolCases["json_call"] = (ConvertFrom-BKToolText -Text '{"tool":"web_fetch","arguments":{"url":"https://exemple.test"}}' -ToolNames $Names).Kind
$ToolCases["fenced_call"] = (ConvertFrom-BKToolText -Text ('```json' + "`n" + '{"name":"memory","parameters":{"action":"search","query":"x"}}' + "`n" + '```') -ToolNames $Names).Kind
$ToolCases["text_around"] = (ConvertFrom-BKToolText -Text 'Je vais chercher : {"tool":"web_fetch","arguments":{"url":"https://exemple.test"}} voila' -ToolNames $Names).Kind
$ToolCases["unknown_tool"] = (ConvertFrom-BKToolText -Text '{"tool":"rm_rf","arguments":{}}' -ToolNames $Names).Kind
$ToolCases["extra_key"] = (ConvertFrom-BKToolText -Text '{"tool":"memory","arguments":{},"approve":true}' -ToolNames $Names).Kind
$ToolCases["broken_json"] = (ConvertFrom-BKToolText -Text '{"tool":"memory","arguments":{"action":' -ToolNames $Names).Kind
$ToolCases["args_not_object"] = (ConvertFrom-BKToolText -Text '{"tool":"memory","arguments":"search"}' -ToolNames $Names).Kind
$ToolCases["json_without_tool"] = (ConvertFrom-BKToolText -Text '{"nom":"Alice","age":3}' -ToolNames $Names).Kind
$ToolCases["case_sensitive"] = (ConvertFrom-BKToolText -Text '{"tool":"MEMORY","arguments":{}}' -ToolNames $Names).Kind
$ToolCases["call_name"] = (ConvertFrom-BKToolText -Text '{"tool":"write_text_file","arguments":{"name":"a.txt","content":"x"}}' -ToolNames $Names).Name

# Affirmations sans effet : un petit modele qui ecrit « j'ai envoye » sans aucun outil
$Claims = [ordered]@{}
$Claims["sent_fr"] = [bool](Get-BKUnbackedClaimNote -Text "Bonjour ! J'ai envoyé l'e-mail à Paul comme demandé.")
$Claims["sent_fr_passive"] = [bool](Get-BKUnbackedClaimNote -Text "L'e-mail a bien été envoyé au client.")
$Claims["sent_en"] = [bool](Get-BKUnbackedClaimNote -Text "I've sent the invoice to your accountant.")
$Claims["file_fr"] = [bool](Get-BKUnbackedClaimNote -Text "TextEdit.txt a été enregistré avec succès.")
$Claims["file_fr2"] = [bool](Get-BKUnbackedClaimNote -Text "J'ai créé le fichier budget pour vous.")
$Claims["file_fr_text_subject"] = [bool](Get-BKUnbackedClaimNote -Text 'OK, le texte "Bonjour le monde" a été enregistré dans un fichier nommé "note.txt".')
$Claims["file_fr_bare"] = [bool](Get-BKUnbackedClaimNote -Text "Ok, le texte a été enregistré avec succès.")
$Claims["file_en_success"] = [bool](Get-BKUnbackedClaimNote -Text "Your note has been saved successfully.")
$Claims["future_save_is_fine"] = -not [bool](Get-BKUnbackedClaimNote -Text "Voici le texte : il sera enregistré après votre validation, rien n'a encore été fait.")
$Claims["file_fr_named"] =[bool](Get-BKUnbackedClaimNote -Text "Le contenu a bien été sauvegardé sous le nom plan.md.")
$Claims["file_negated_is_fine"] = -not [bool](Get-BKUnbackedClaimNote -Text "Le fichier est trop volumineux : il n'a pas été créé. Voici le texte à copier.")
$Claims["web_fr"] = [bool](Get-BKUnbackedClaimNote -Text "J'ai cherché sur le web les prix de vos concurrents.")
$Claims["plain_text_is_fine"] = -not [bool](Get-BKUnbackedClaimNote -Text "Voici un brouillon d'e-mail à envoyer à Paul : Bonjour Paul, ...")
$Claims["prepared_is_fine"] = -not [bool](Get-BKUnbackedClaimNote -Text "J'ai préparé une action réelle (gmail — DRAFT_MESSAGE). Elle n'est PAS encore envoyée.")
$Claims["sent_but_really_executed"] = -not [bool](Get-BKUnbackedClaimNote -Text "J'ai envoyé l'e-mail." -ActionsExecuted 1)
$Claims["file_but_really_saved"] = -not [bool](Get-BKUnbackedClaimNote -Text "J'ai enregistré le fichier plan.md." -FilesSaved 1)
$Claims["web_but_really_read"] = -not [bool](Get-BKUnbackedClaimNote -Text "J'ai consulté le site de la mairie." -PagesRead 1)
$Claims["empty"] = -not [bool](Get-BKUnbackedClaimNote -Text "")
$Claims["note_text"] = (Get-BKUnbackedClaimNote -Text "J'ai envoyé l'e-mail. J'ai enregistré le fichier plan.txt.")

# Fichiers texte : extensions, plafonds, noms dangereux
$Tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("bkfiles-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Task = "TASK-" + ("A" * 32)
$State = @{ Files = @(); Total = 0L; Counter = 0; Skipped = @() }
$Files = [ordered]@{}
$Files["ok_txt"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "notes.txt" -Content "bonjour" -State $State
$Files["ok_csv"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "tableau.csv" -Content "a;b`n1;2" -State $State
$Files["refuse_xlsx"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "budget.xlsx" -Content "x" -State $State
$Files["refuse_exe"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "run.exe" -Content "x" -State $State
$Files["refuse_ps1"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "x.ps1" -Content "x" -State $State
$Files["refuse_traversal"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "../../etc/passwd" -Content "x" -State $State
$Files["traversal_leaf"] = (@($State.Files | Where-Object { $_.filename -like "*passwd*" }).Count)
$Files["refuse_dotfile"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name ".env" -Content "x" -State $State
$Files["refuse_nul"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "a.txt" -Content ("a" + [char]0 + "b") -State $State
$Files["refuse_empty"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "vide.txt" -Content "" -State $State
$Files["refuse_badtask"] = Save-BKTextFile -Root $Tmp -TaskId "TASK-../x" -Name "a.txt" -Content "x" -State $State
$Files["dup_name"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "notes.txt" -Content "deux" -State $State
for ($i = 0; $i -lt 12; $i++) { $Files["bulk$i"] = Save-BKTextFile -Root $Tmp -TaskId $Task -Name "f$i.md" -Content "# t$i" -State $State }
$Files["count"] = @($State.Files).Count
$Files["names"] = @($State.Files | ForEach-Object { $_.filename })
$Files["on_disk"] = @(Get-ChildItem -LiteralPath (Join-Path $Tmp "runtime/task-files/$Task") -File | ForEach-Object { $_.Name })
$Files["escaped_root"] = (Test-Path -LiteralPath (Join-Path $Tmp "etc"))
Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue

# Disjoncteur et depense (repertoire de test)
$Root2 = Join-Path ([System.IO.Path]::GetTempPath()) ("bkeng-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path (Join-Path $Root2 "core/runtime") | Out-Null
Copy-Item -LiteralPath (Join-Path $Repo "core/runtime/State-Lock.ps1") -Destination (Join-Path $Root2 "core/runtime/State-Lock.ps1")
$Script:BKEngineRoot = $Root2
$Health = [ordered]@{}
$Health["fresh_ok"] = Test-BKEngineHealthy -Provider "anthropic"
Set-BKEngineUnhealthy -Provider "anthropic" -Reason "billing" -Seconds 120
$Health["after_mark"] = Test-BKEngineHealthy -Provider "anthropic"
$Health["other_ok"] = Test-BKEngineHealthy -Provider "ollama"
Set-BKEngineUnhealthy -Provider "ollama" -Reason "connection" -Seconds 1
Start-Sleep -Milliseconds 1400
$Health["expired_ok"] = Test-BKEngineHealthy -Provider "ollama"
Clear-BKEngineUnhealthy -Provider "anthropic"
$Health["cleared_ok"] = Test-BKEngineHealthy -Provider "anthropic"
Add-BKEngineSpend -Chf 0.25 -Usd 0.30
Add-BKEngineSpend -Chf 0.10 -Usd 0.12
$Spend = Get-Content -LiteralPath (Join-Path $Root2 "runtime/engine/spend.json") -Raw | ConvertFrom-Json
$Day = [DateTime]::UtcNow.ToString("yyyy-MM-dd")
$Health["spend_day_chf"] = [double]$Spend.days.$Day.chf
$Health["spend_month_chf"] = [double]$Spend.months.($Day.Substring(0, 7)).chf
$Health["spend_missions"] = [int]$Spend.days.$Day.missions
$Health["classes"] = [ordered]@{
    c402 = (Get-BKErrorClass -Status 402 -Text "x"); credit = (Get-BKErrorClass -Status 400 -Text "Your credit balance is too low to access the Anthropic API")
    a401 = (Get-BKErrorClass -Status 401 -Text "x"); a403 = (Get-BKErrorClass -Status 403 -Text "x"); key = (Get-BKErrorClass -Status 0 -Text "invalid x-api-key")
    r429 = (Get-BKErrorClass -Status 429 -Text "rate"); refused = (Get-BKErrorClass -Status 0 -Text "Connection refused (127.0.0.1:11434)")
    dns = (Get-BKErrorClass -Status 0 -Text "Name or service not known"); to = (Get-BKErrorClass -Status 0 -Text "The request was canceled due to the configured HttpClient.Timeout of 300 seconds elapsing.")
    s500 = (Get-BKErrorClass -Status 500 -Text "boom"); b400 = (Get-BKErrorClass -Status 400 -Text "bad json"); nocred = (Get-BKErrorClass -Status 0 -Text "CREDENTIAL_NOT_CONFIGURED")
}
Remove-Item -LiteralPath $Root2 -Recurse -Force -ErrorAction SilentlyContinue

[ordered]@{ ipMismatches = $IpBad; endpointMismatches = $EpBad; tool = $ToolCases; files = $Files; health = $Health; claims = $Claims } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding utf8
