# =====================================================================
# BK-AI-WORKERS — Adaptateur Stripe (Billing reel, mode test ou live
# selon la cle stockee). Portee volontairement etroite : ce fichier ne
# sait faire QUE deux choses —
#   1) creer une Checkout Session Stripe (paiement HEBERGE PAR STRIPE :
#      le client saisit sa carte sur stripe.com, jamais sur ce serveur,
#      jamais vu par Claude ni ecrit sur disque ici) ;
#   2) relire une Checkout Session pour VERIFIER cote serveur qu'elle
#      est bien payee avant d'activer un plan localement.
# Aucune fonction ici ne debite, ne rembourse ni ne cree de charge
# directement — c'est exactement la portee "PREPARE_PAYMENT" deja
# prevue dans core/runtime/controlled-connectors/CONTROLLED-CONNECTOR-
# CATALOG.json. Le secret (cle API + Price IDs) est stocke par Kader
# lui-meme via .secrets\Store-Credential.ps1 -Provider stripe, jamais
# vu par Claude. Ecrit le 2026-09-15 (branchement demande explicitement
# par Kader, mode test, compte Stripe deja existant).
# =====================================================================

. (Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/ai/BK-Secret.ps1")

function Test-StripeConfigured {
    return (Test-BKSecret -Name "stripe")
}

function Get-StripeSecret {
    if (-not (Test-StripeConfigured)) {
        throw "STRIPE_NOT_CONFIGURED"
    }
    $Raw = Get-BKSecretValue -Name "stripe"
    return $Raw | ConvertFrom-Json
}

function ConvertTo-StripeFormBody {
    # Stripe attend du x-www-form-urlencoded avec notation crochets
    # pour les objets/tableaux imbriques (pas du JSON, contrairement a
    # la quasi-totalite des autres connecteurs de ce projet).
    param([Parameter(Mandatory=$true)][System.Collections.Specialized.OrderedDictionary]$Fields)
    $Parts = foreach ($Key in $Fields.Keys) {
        "$([Uri]::EscapeDataString($Key))=$([Uri]::EscapeDataString([string]$Fields[$Key]))"
    }
    return ($Parts -join "&")
}

function Get-StripeCheckoutFields {
    <#
    Champs d'une Checkout Session (fonction PURE : aucun appel reseau, testable sans Stripe — tests/pricing/test_stripe_fields.py).
    Le prix d'un forfait vient de DEUX sources possibles :
      - un Price ID Stripe cree par Kader (secret : prices / pricesAnnual) : s'il existe pour le forfait, il est utilise tel quel, comme
        avant (aucun forfait deja en vente ne change de comportement) ;
      - sinon, le MONTANT DU CATALOGUE du serveur (dashboard/server.py, PLAN_CATALOG, en centimes de franc suisse ; annuel = 10 mois) est
        envoye en price_data : abonnement recurrent en CHF, produit nomme d'apres le forfait. C'est le cas des forfaits Solo, Trio et Equipe.
    Un montant absent ou hors des bornes CHF 1 a CHF 100'000 est refuse (INVALID_AMOUNT) : on n'invente jamais un prix.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$PlanId,
        [Parameter(Mandatory=$true)][string]$SuccessUrl,
        [Parameter(Mandatory=$true)][string]$CancelUrl,
        [ValidateSet("month", "year")][string]$Interval = "month",
        [string]$ClientId = "",
        [string]$PriceId = "",
        [long]$AmountCents = 0,
        [string]$PlanName = "",
        [string]$LaunchCoupon = ""
    )

    $Fields = [ordered]@{
        "mode"                          = "subscription"
        "success_url"                   = $SuccessUrl
        "cancel_url"                    = $CancelUrl
    }
    if (-not [string]::IsNullOrWhiteSpace($PriceId)) {
        $Fields["line_items[0][price]"] = $PriceId
    }
    else {
        if ($AmountCents -lt 100 -or $AmountCents -gt 10000000) {
            throw "INVALID_AMOUNT"
        }
        $Label = if ($Interval -eq "year") { "annuel" } else { "mensuel" }
        # Nom lisible sur la page de paiement Stripe : lettres, chiffres et ponctuation courante seulement, 60 caracteres au plus.
        $SafeName = ($PlanName -replace '[^\p{L}\p{N} .\-]', '').Trim()
        if ($SafeName.Length -gt 60) { $SafeName = $SafeName.Substring(0, 60) }
        if ([string]::IsNullOrWhiteSpace($SafeName)) { $SafeName = $PlanId }
        $Fields["line_items[0][price_data][currency]"]                     = "chf"
        $Fields["line_items[0][price_data][unit_amount]"]                  = [string]$AmountCents
        $Fields["line_items[0][price_data][recurring][interval]"]          = $Interval
        $Fields["line_items[0][price_data][product_data][name]"]           = "BK-AI-WORKERS - $SafeName ($Label)"
    }
    $Fields["line_items[0][quantity]"]       = "1"
    $Fields["metadata[bk_plan_id]"]          = $PlanId
    $Fields["metadata[bk_interval]"]         = $Interval
    if (-not [string]::IsNullOrWhiteSpace($ClientId)) {
        $Fields["metadata[bk_client_id]"] = $ClientId
    }

    # Offre de lancement (-30% sur les 2 premiers mois) : coupon cree
    # par Kader directement dans Stripe (pas un secret, juste un ID
    # d'offre), applique automatiquement si BK_STRIPE_LAUNCH_COUPON
    # est defini. Reservee au mensuel : sur un prix annuel, un coupon
    # "2 mois" s'appliquerait a la totalite de la seule facture de
    # l'annee (effet tres different d'une remise de lancement de 2
    # mois) — a reconsiderer explicitement si Kader veut une offre
    # de lancement dediee a l'annuel.
    if ($Interval -eq "month" -and -not [string]::IsNullOrWhiteSpace($LaunchCoupon)) {
        $Fields["discounts[0][coupon]"] = $LaunchCoupon.Trim()
    }
    return $Fields
}

function New-StripeCheckoutSession {
    <#
    Cree une vraie Checkout Session Stripe (mode test ou live selon la
    cle stockee) et renvoie l'URL hebergee par Stripe vers laquelle
    rediriger le navigateur. Aucun mouvement d'argent ici : le paiement
    a lieu sur la page Stripe elle-meme, quand le client le complete.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$PlanId,
        [Parameter(Mandatory=$true)][string]$SuccessUrl,
        [Parameter(Mandatory=$true)][string]$CancelUrl,
        # "month" (defaut, comportement inchange) ou "year" — voir
        # $Secret.pricesAnnual, cree par Kader dans Stripe (nouveau Price
        # annuel sur le meme Product que le mensuel), champ optionnel :
        # un plan sans prix annuel configure renvoie UNKNOWN_PLAN plutot
        # que de retomber silencieusement sur le prix mensuel.
        [ValidateSet("month", "year")][string]$Interval = "month",
        # ClientId du compte qui paie (voir server.py, comptes clients du
        # 2026-09-22) : enregistre dans les metadata Stripe pour que la
        # confirmation apres paiement sache QUEL client activer, sans
        # dependre uniquement du cookie de session encore present au
        # retour (filet de securite : la metadata Stripe fait foi).
        [string]$ClientId = "",
        # Montant du catalogue du serveur (centimes de CHF) et nom du forfait : utilises quand AUCUN Price ID n'est enregistre pour ce
        # forfait (voir Get-StripeCheckoutFields). 0 = pas de montant fourni.
        [long]$AmountCents = 0,
        [string]$PlanName = ""
    )

    if (-not (Test-StripeConfigured)) {
        return [pscustomobject]@{ Status = "NOT_CONFIGURED" }
    }

    try {
        $Secret = Get-StripeSecret
        $PriceId = if ($Interval -eq "year") { $Secret.pricesAnnual.$PlanId } else { $Secret.prices.$PlanId }
        if (-not $PriceId -and $AmountCents -le 0) {
            $Label = if ($Interval -eq "year") { "annuel" } else { "mensuel" }
            return [pscustomobject]@{ Status = "UNKNOWN_PLAN"; Detail = "Aucun Price ID Stripe $Label ni montant de catalogue pour '$PlanId'." }
        }

        $Fields = Get-StripeCheckoutFields -PlanId $PlanId -SuccessUrl $SuccessUrl -CancelUrl $CancelUrl -Interval $Interval -ClientId $ClientId `
            -PriceId ([string]$PriceId) -AmountCents $AmountCents -PlanName $PlanName -LaunchCoupon ([string]$env:BK_STRIPE_LAUNCH_COUPON)

        $Body = ConvertTo-StripeFormBody -Fields $Fields

        $Response = Invoke-RestMethod -Uri "https://api.stripe.com/v1/checkout/sessions" `
            -Method POST `
            -Headers @{ Authorization = "Bearer $($Secret.secret_key)" } `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $Body `
            -TimeoutSec 20

        return [pscustomobject]@{
            Status      = "SUCCESS"
            SessionId   = $Response.id
            CheckoutUrl = $Response.url
            Live        = $Secret.secret_key -notlike "sk_test_*"
        }
    }
    catch {
        return [pscustomobject]@{ Status = "ERROR"; Detail = $_.Exception.Message }
    }
}

function ConvertTo-StripeSubscriptionSummary {
    <#
    Fonction PURE (aucun appel reseau, testable sans Stripe : tests/pricing/test_stripe_fields.py) : resume l'objet "subscription" de l'API Stripe
    (ou son simple identifiant texte quand il n'est pas deplie, ou $null). CurrentPeriodEnd = fin de la periode DEJA payee, en texte ISO 8601 UTC :
    selon la version de l'API Stripe elle est sur l'abonnement (current_period_end) ou sur ses lignes (items.data[0].current_period_end).
    #>
    param($Subscription)

    $Summary = [ordered]@{ Id = $null; Status = $null; CancelAtPeriodEnd = $false; CurrentPeriodEnd = $null }
    if ($null -eq $Subscription) { return [pscustomobject]$Summary }
    if ($Subscription -is [string]) {
        $Summary.Id = $Subscription
        return [pscustomobject]$Summary
    }
    $Props = $Subscription.PSObject.Properties
    if ($Props["id"]) { $Summary.Id = [string]$Props["id"].Value }
    if ($Props["status"]) { $Summary.Status = [string]$Props["status"].Value }
    if ($Props["cancel_at_period_end"]) { $Summary.CancelAtPeriodEnd = [bool]$Props["cancel_at_period_end"].Value }
    $Raw = $null
    if ($Props["current_period_end"] -and $Props["current_period_end"].Value) { $Raw = $Props["current_period_end"].Value }
    if (-not $Raw -and $Props["items"] -and $Props["items"].Value -and $Props["items"].Value.PSObject.Properties["data"]) {
        $First = @($Props["items"].Value.data) | Select-Object -First 1
        if ($First -and $First.PSObject.Properties["current_period_end"]) { $Raw = $First.current_period_end }
    }
    if ($Raw) {
        try { $Summary.CurrentPeriodEnd = [DateTimeOffset]::FromUnixTimeSeconds([long]$Raw).UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ssZ") } catch { }
    }
    return [pscustomobject]$Summary
}

function Get-StripeCheckoutSession {
    <#
    Relit une Checkout Session existante DIRECTEMENT DEPUIS STRIPE (pas
    depuis un parametre d'URL client, jamais fiable seul) pour verifier
    cote serveur si elle est reellement payee avant d'activer un plan.
    L'abonnement est relu avec elle (expand) : SubscriptionStatus dit s'il
    est TOUJOURS actif (payment_status reste "paid" a vie, meme apres une
    resiliation, il ne suffit donc jamais a lui seul) ; le serveur
    (dashboard/server.py, activate_checkout_plan) refuse tout abonnement
    qui n'est plus actif et n'active une session qu'une seule fois.
    #>
    param([Parameter(Mandatory=$true)][string]$SessionId)

    if (-not (Test-StripeConfigured)) {
        return [pscustomobject]@{ Status = "NOT_CONFIGURED" }
    }
    # L'identifiant vient du navigateur du client : il ne doit jamais pouvoir changer le chemin de l'appel (cs_test_..., cs_live_...).
    if ($SessionId -notmatch '^cs_[A-Za-z0-9_]{6,250}$') {
        return [pscustomobject]@{ Status = "ERROR"; Detail = "INVALID_SESSION_ID" }
    }

    try {
        $Secret = Get-StripeSecret
        $Response = Invoke-RestMethod -Uri "https://api.stripe.com/v1/checkout/sessions/${SessionId}?expand%5B%5D=subscription" `
            -Method GET `
            -Headers @{ Authorization = "Bearer $($Secret.secret_key)" } `
            -TimeoutSec 20

        $Sub = ConvertTo-StripeSubscriptionSummary -Subscription $Response.subscription
        return [pscustomobject]@{
            Status             = "SUCCESS"
            SessionId          = $Response.id
            PaymentStatus      = $Response.payment_status
            SessionStatus      = $Response.status
            PlanId             = $Response.metadata.bk_plan_id
            ClientId           = $Response.metadata.bk_client_id
            Interval           = $Response.metadata.bk_interval
            CustomerEmail      = $Response.customer_details.email
            Paid               = ($Response.payment_status -eq "paid")
            SubscriptionId     = $Sub.Id
            SubscriptionStatus = $Sub.Status
            CurrentPeriodEnd   = $Sub.CurrentPeriodEnd
        }
    }
    catch {
        return [pscustomobject]@{ Status = "ERROR"; Detail = $_.Exception.Message }
    }
}

function Get-StripeCancelFields {
    <#
    Champs d'une resiliation (fonction PURE, testable sans Stripe) :
      - -AtPeriodEnd : cancel_at_period_end=true, l'abonnement reste actif jusqu'a la fin de la periode DEJA payee puis s'arrete, sans nouveau
        prelevement (CGV article 6 : la resiliation prend effet a la fin de la periode en cours) ;
      - -Prorate     : resiliation immediate qui credite le temps deja paye mais non utilise (prorate + invoice_now), pour remplacer un abonnement par
        un forfait superieur sans perdre les mois payes d'avance ;
      - sinon        : aucun champ, resiliation immediate simple.
    #>
    param([switch]$AtPeriodEnd, [switch]$Prorate)

    $Fields = [ordered]@{}
    if ($AtPeriodEnd) {
        $Fields["cancel_at_period_end"] = "true"
    }
    elseif ($Prorate) {
        $Fields["prorate"]     = "true"
        $Fields["invoice_now"] = "true"
    }
    return $Fields
}

function Remove-StripeSubscription {
    <#
    Resilie REELLEMENT un abonnement Stripe, pour que "annuler" annule vraiment cote Stripe et pas seulement l'affichage local.
    - -AtPeriodEnd (clic client sur "Annuler l'abonnement") : l'abonnement va jusqu'au bout de la periode payee puis s'arrete ; renvoie
      CurrentPeriodEnd, la date de fin, que le serveur garde pour laisser le forfait actif jusque-la.
    - -Prorate (remplacement par un forfait superieur apres un nouveau paiement) : resiliation immediate, temps non utilise credite.
    - sans option : resiliation immediate simple.
    #>
    param([Parameter(Mandatory=$true)][string]$SubscriptionId, [switch]$AtPeriodEnd, [switch]$Prorate)

    if (-not (Test-StripeConfigured)) {
        return [pscustomobject]@{ Status = "NOT_CONFIGURED" }
    }
    if ($SubscriptionId -notmatch '^sub_[A-Za-z0-9_]{1,200}$') {
        return [pscustomobject]@{ Status = "ERROR"; Detail = "INVALID_SUBSCRIPTION_ID" }
    }

    try {
        $Secret = Get-StripeSecret
        $Fields = Get-StripeCancelFields -AtPeriodEnd:$AtPeriodEnd -Prorate:$Prorate
        $Params = @{
            Uri        = "https://api.stripe.com/v1/subscriptions/$SubscriptionId"
            Method     = if ($AtPeriodEnd) { "POST" } else { "DELETE" }
            Headers    = @{ Authorization = "Bearer $($Secret.secret_key)" }
            TimeoutSec = 20
        }
        if ($Fields.Count -gt 0) {
            $Params["ContentType"] = "application/x-www-form-urlencoded"
            $Params["Body"] = ConvertTo-StripeFormBody -Fields $Fields
        }
        $Response = Invoke-RestMethod @Params

        $Sub = ConvertTo-StripeSubscriptionSummary -Subscription $Response
        return [pscustomobject]@{
            Status             = "SUCCESS"
            SubscriptionId     = $Sub.Id
            SubscriptionStatus = $Sub.Status
            CancelAtPeriodEnd  = $Sub.CancelAtPeriodEnd
            CurrentPeriodEnd   = $Sub.CurrentPeriodEnd
        }
    }
    catch {
        return [pscustomobject]@{ Status = "ERROR"; Detail = $_.Exception.Message }
    }
}
