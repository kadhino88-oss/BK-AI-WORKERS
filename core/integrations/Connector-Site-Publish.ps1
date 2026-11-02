# =====================================================================
# Atelier de sites : operations de connecteur pour la PREPARATION de la
# mise en ligne (docs/AUTONOMY-ENGINE.md, section 8.6). Charge par une
# seule ligne a la fin de la table de Connector-Dispatch.ps1.
#
# Ce qui existe vraiment (et rien d'autre n'est promis) :
#   wordpress:CREATE_PAGE_DRAFT  cree une PAGE WordPress en BROUILLON
#     (POST wp/v2/pages, status=draft). Rien n'est publie : le client
#     relit et publie lui-meme dans son WordPress. Chaque appel passe par
#     un article d'approbation (risque medium) valide par le client.
#
# Volontairement ABSENT :
#   - mise a jour d'une page existante : sur WordPress, ecrire une page
#     deja publiee la modifie EN LIGNE (ou la depublie si l'on force
#     status=draft) ; c'est une action sur le site en ligne du client,
#     hors du perimetre « brouillon ». Une nouvelle version = un nouveau
#     brouillon.
#   - televersement de medias (UPLOAD_MEDIA) : l'adaptateur REST generique
#     n'envoie que du JSON ; un envoi binaire demande un autre chemin.
#     Les illustrations du kit sont des SVG integres au contenu ; les
#     images raster se televersent a la main (guide MISE-EN-LIGNE.md).
#   - Webflow : l'API ne cree pas de pages statiques ; Shopify et
#     WooCommerce sont des boutiques, pas des hebergeurs de site vitrine.
#
# La lecture de ce fichier par projects_approvals.connector_ops() repose
# sur la forme exacte  OperationTable["wordpress"].Operations["NOM"] .
# =====================================================================

if ($Script:OperationTable -and $Script:OperationTable["wordpress"]) {
    $Script:OperationTable["wordpress"].Operations["CREATE_PAGE_DRAFT"] = {
        param($P)
        $Body = @{ title = [string]$P.Title; content = [string]$P.Content; status = "draft" }
        if ($P.Slug -and ([string]$P.Slug -match '^[a-z0-9][a-z0-9-]{0,63}$')) { $Body["slug"] = [string]$P.Slug }
        @{ Path = "pages"; Method = "POST"; Body = $Body }
    }
}
