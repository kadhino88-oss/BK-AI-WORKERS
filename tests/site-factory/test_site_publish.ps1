# Atelier de sites : operation WordPress CREATE_PAGE_DRAFT (core/integrations/Connector-Site-Publish.ps1), chargee par Connector-Dispatch.ps1.
# Aucun reseau : le constructeur de requete est appele directement, et Invoke-ConnectorAction sans identifiant enregistre s'arrete a NOT_CONFIGURED.
#     pwsh -NoProfile -File tests/site-factory/test_site_publish.ps1
$ErrorActionPreference = "Stop"
$Repo = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$env:BK_ROOT = $Repo
. (Join-Path $Repo "core/integrations/Connector-Dispatch.ps1")

$Fails = 0
function Check([string]$Name, [bool]$Cond, [string]$Detail = "") {
    if ($Cond) { Write-Host "  PASS  $Name" } else { Write-Host "  FAIL  $Name  $Detail"; $script:Fails++ }
}

$Ops = $Script:OperationTable["wordpress"].Operations
Check "wordpress:CREATE_PAGE_DRAFT existe" ($Ops.ContainsKey("CREATE_PAGE_DRAFT"))
Check "les operations WordPress d'origine sont intactes" ($Ops.ContainsKey("CREATE_DRAFT") -and $Ops.ContainsKey("UPDATE_DRAFT") -and $Ops.ContainsKey("READ_POST"))
Check "aucune mise a jour de page ni televersement de media n'est promis" (-not $Ops.ContainsKey("UPDATE_PAGE_DRAFT") -and -not $Ops.ContainsKey("UPLOAD_MEDIA"))

$B = & $Ops["CREATE_PAGE_DRAFT"] @{ Title = "Accueil"; Content = "<!-- wp:html -->`n<p>Bonjour</p>`n<!-- /wp:html -->"; Slug = "accueil" }
Check "chemin wp/v2 pages (et non posts)" ($B.Path -eq "pages") $B.Path
Check "methode POST" ($B.Method -eq "POST")
Check "statut TOUJOURS brouillon" ($B.Body.status -eq "draft")
Check "titre et contenu exacts" ($B.Body.title -eq "Accueil" -and $B.Body.content -like "*<p>Bonjour</p>*")
Check "slug valide transmis" ($B.Body.slug -eq "accueil")

$B2 = & $Ops["CREATE_PAGE_DRAFT"] @{ Title = "X"; Content = "Y"; Slug = "../../wp-admin" }
Check "slug invalide ignore" (-not $B2.Body.ContainsKey("slug"))
$B3 = & $Ops["CREATE_PAGE_DRAFT"] @{ Title = "X"; Content = "Y"; Status = "publish" }
Check "un parametre status ne peut pas publier" ($B3.Body.status -eq "draft")

$R = Invoke-ConnectorAction -ConnectorId "wordpress" -Operation "CREATE_PAGE_DRAFT" -ClientId "CLI-CUST-ZZZZZZZZ" -Params @{ Title = "T"; Content = "C" }
Check "sans identifiant enregistre : NOT_CONFIGURED, aucun appel" ($R.Status -eq "NOT_CONFIGURED") ([string]$R.Status)

if ($Fails -gt 0) { Write-Host "$Fails echec(s)"; exit 1 }
Write-Host "OK"
exit 0
