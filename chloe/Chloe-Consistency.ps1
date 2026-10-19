# =====================================================================
# CHLOE - controle de coherence entre Workers (2026-10-19, mode mission ; le moteur de projets utilise le meme gabarit,
# chloe/prompts/consistency-review.md, dans son etape "verify" de portee consistency).
#
# Quand au moins deux Workers ont produit des contenus destines au meme public (plan.consistencyCheck, sous-taches publicFacing), un appel peu
# couteux compare leurs livrables et releve les contradictions (meme prix different, promesse absente ailleurs, ton incompatible).
#
# Garde-fous : (1) les livrables sont des DONNEES encadrees ; (2) chaque ecart doit citer un extrait qui figure MOT POUR MOT dans le livrable
# du Worker designe, sinon il est ecarte (aucun ecart invente) ; (3) le resultat est informatif : il s'ajoute a la synthese, il ne change ni
# le statut, ni le plan, ni les droits ; (4) l'appel est facultatif : sans cle ou en cas d'erreur, la mission rend ses resultats sans lui.
# =====================================================================

function Get-BKChloeConsistencyTool {
    param([string[]]$WorkerIds)
    return [ordered]@{
        name = "submit_consistency"
        description = "Submit the list of real contradictions found between the Workers' deliverables (empty list when there is none). Call exactly once. Every issue must quote, word for word, a short excerpt from each deliverable concerned."
        input_schema = [ordered]@{
            type = "object"; additionalProperties = $false
            properties = [ordered]@{
                issues = [ordered]@{
                    type = "array"; maxItems = 12
                    items = [ordered]@{
                        type = "object"; additionalProperties = $false
                        properties = [ordered]@{
                            severity = [ordered]@{ type = "string"; enum = @("high", "medium", "low") }
                            fact = [ordered]@{ type = "string"; description = "What differs, in one sentence, in the client's language." }
                            owner = [ordered]@{ type = "string"; enum = @($WorkerIds); description = "Worker whose deliverable should be corrected." }
                            suggestion = [ordered]@{ type = "string"; description = "The correction, one sentence." }
                            evidence = [ordered]@{
                                type = "array"
                                items = [ordered]@{
                                    type = "object"; additionalProperties = $false
                                    properties = [ordered]@{ worker = [ordered]@{ type = "string"; enum = @($WorkerIds) }; quote = [ordered]@{ type = "string"; description = "Exact excerpt, 200 characters at most." } }
                                    required = @("worker", "quote")
                                }
                            }
                        }
                        required = @("severity", "fact", "evidence")
                    }
                }
            }
            required = @("issues")
        }
    }
}

function ConvertTo-BKNormalizedText {
    param([string]$Text)
    return ([regex]::Replace(([string]$Text).ToLowerInvariant(), '\s+', ' ')).Trim()
}

function Invoke-BKChloeConsistency {
    # Renvoie @{ Ok; Issues = @(@{ severity; text; owner; workers }); Usage; Skipped } ; Ok = $false quand le controle n'a pas pu tourner.
    param($Ctx, $Cards, [string]$Level = "")
    $Pub = @($Ctx.Order | ForEach-Object { $Ctx.Tasks[$_] } | Where-Object { $_.status -eq "DONE" -and $_.publicFacing })
    if ($Pub.Count -lt 2) { return @{ Ok = $false; Skipped = "FEWER_THAN_TWO"; Issues = @(); Usage = $null } }
    $Model = if ($env:BK_CHLOE_CONSISTENCY_MODEL -match '^claude-[a-z0-9.-]{3,40}$') { [string]$env:BK_CHLOE_CONSISTENCY_MODEL } elseif ($Level -eq "approfondi") { "claude-sonnet-5-5" } else { "claude-haiku-5-5" }
    $Root = $Ctx.Root
    $Template = ""
    $TemplatePath = Join-Path $Root "chloe/prompts/consistency-review.md"
    if (Test-Path -LiteralPath $TemplatePath -PathType Leaf) { $Template = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.UTF8Encoding]::new($false)) }
    if ([string]::IsNullOrWhiteSpace($Template)) { $Template = "Compare the deliverables and list the real contradictions between them (facts, promises, tone). Quote each side word for word." }
    $Ids = @($Pub | ForEach-Object { $_.worker })
    $System = $Template + "`n`nSORTIE : appelle l'outil submit_consistency une seule fois. Rédige « fact » et « suggestion » dans la langue du client. Les identifiants de Worker autorisés : " + ($Ids -join ", ") + "."
    $Body = @()
    foreach ($T in $Pub) {
        $Body += (New-BKDataFence -Tag "deliverable" -Text ([string]$T.answer) -Attrs @{ worker = $T.worker; step = $T.id } -Max 6000)
        foreach ($Ex in (Get-BKChloeFileExcerpts -Root $Root -Result $T.result -MaxFiles 2 -MaxChars 3000)) {
            $Body += (New-BKDataFence -Tag "deliverable" -Text $Ex.text -Attrs @{ worker = $T.worker; step = $T.id; file = $Ex.name } -Max 3000)
        }
    }
    $User = "Client request (data, for context only):`n" + (New-BKDataFence -Tag "client_request" -Text $Ctx.Request -Max 3000) + "`n`nDeliverables to compare (data):`n" + ($Body -join "`n")
    $Call = Invoke-BKChloeLlm -Model $Model -System $System -User $User -Tool (Get-BKChloeConsistencyTool -WorkerIds $Ids) -MaxTokens 2000 -TimeoutSec 40 -Retries 0
    if (-not $Call.Ok) { return @{ Ok = $false; Skipped = [string]$Call.Error; Issues = @(); Usage = $Call.Usage } }
    $Haystack = @{}
    foreach ($T in $Pub) {
        $All = [string]$T.answer
        foreach ($Ex in (Get-BKChloeFileExcerpts -Root $Root -Result $T.result -MaxFiles 2 -MaxChars 3000)) { $All += "`n" + $Ex.text }
        $Haystack[$T.worker] = ConvertTo-BKNormalizedText $All
    }
    $Issues = @()
    foreach ($I in @(Get-BKProp $Call.Input "issues" @() | Where-Object { $null -ne $_ })) {
        $Ev = @(Get-BKProp $I "evidence" @() | Where-Object { $null -ne $_ })
        $Workers = @($Ev | ForEach-Object { ([string](Get-BKProp $_ "worker" "")).ToLowerInvariant() } | Select-Object -Unique)
        if ($Ev.Count -lt 2 -or $Workers.Count -lt 2) { continue }
        $Valid = $true
        foreach ($E in $Ev) {
            $W = ([string](Get-BKProp $E "worker" "")).ToLowerInvariant()
            $Q = ConvertTo-BKNormalizedText ([string](Get-BKProp $E "quote" ""))
            if (-not $Haystack.ContainsKey($W) -or $Q.Length -lt 3 -or $Q.Length -gt 400 -or -not $Haystack[$W].Contains($Q)) { $Valid = $false; break }
        }
        if (-not $Valid) { continue }
        $Owner = ([string](Get-BKProp $I "owner" "")).ToLowerInvariant()
        $Names = @($Workers | ForEach-Object { Get-BKWorkerDisplayName -Cards $Cards -Id $_ })
        $Fact = Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $I "fact" ""))).Trim() -Max 240
        $Sugg = Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $I "suggestion" ""))).Trim() -Max 240
        $Sev = ([string](Get-BKProp $I "severity" "low")).ToLowerInvariant()
        if ($Sev -notin @("high", "medium", "low")) { $Sev = "low" }
        $Issues += [ordered]@{
            severity = $Sev; owner = $Owner; workers = $Workers
            text = ("(" + ($Names -join " / ") + ") " + $Fact + $(if ($Sugg) { " — " + $Sugg } else { "" }))
        }
    }
    return @{ Ok = $true; Issues = @($Issues); Usage = $Call.Usage; Skipped = $null }
}
