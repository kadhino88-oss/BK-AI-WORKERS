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
        [string]$ClientId = ""
    )

    if (-not (Test-StripeConfigured)) {
        return [pscustomobject]@{ Status = "NOT_CONFIGURED" }
    }

    try {
        $Secret = Get-StripeSecret
        $PriceId = if ($Interval -eq "year") { $Secret.pricesAnnual.$PlanId } else { $Secret.prices.$PlanId }
        if (-not $PriceId) {
            $Label = if ($Interval -eq "year") { "annuel" } else { "mensuel" }
            return [pscustomobject]@{ Status = "UNKNOWN_PLAN"; Detail = "Aucun Price ID Stripe $Label pour '$PlanId'." }
        }

        $Fields = [ordered]@{
            "mode"                          = "subscription"
            "success_url"                   = $SuccessUrl
            "cancel_url"                    = $CancelUrl
            "line_items[0][price]"          = $PriceId
            "line_items[0][quantity]"       = "1"
            "metadata[bk_plan_id]"          = $PlanId
            "metadata[bk_interval]"         = $Interval
        }
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
        $LaunchCoupon = $env:BK_STRIPE_LAUNCH_COUPON
        if ($Interval -eq "month" -and -not [string]::IsNullOrWhiteSpace($LaunchCoupon)) {
            $Fields["discounts[0][coupon]"] = $LaunchCoupon.Trim()
        }

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

function Get-StripeCheckoutSession {
    <#
    Relit une Checkout Session existante DIRECTEMENT DEPUIS STRIPE (pas
    depuis un parametre d'URL client, jamais fiable seul) pour verifier
    cote serveur si elle est reellement payee avant d'activer un plan.
    #>
    param([Parameter(Mandatory=$true)][string]$SessionId)

    if (-not (Test-StripeConfigured)) {
        return [pscustomobject]@{ Status = "NOT_CONFIGURED" }
    }

    try {
        $Secret = Get-StripeSecret
        $Response = Invoke-RestMethod -Uri "https://api.stripe.com/v1/checkout/sessions/$SessionId" `
            -Method GET `
            -Headers @{ Authorization = "Bearer $($Secret.secret_key)" } `
            -TimeoutSec 20

        return [pscustomobject]@{
            Status         = "SUCCESS"
            PaymentStatus  = $Response.payment_status
            SessionStatus  = $Response.status
            PlanId         = $Response.metadata.bk_plan_id
            ClientId       = $Response.metadata.bk_client_id
            CustomerEmail  = $Response.customer_details.email
            Paid           = ($Response.payment_status -eq "paid")
            SubscriptionId = $Response.subscription
        }
    }
    catch {
        return [pscustomobject]@{ Status = "ERROR"; Detail = $_.Exception.Message }
    }
}

function Remove-StripeSubscription {
    <#
    Annule REELLEMENT un abonnement Stripe (immediat — pas d'attente de
    fin de periode). Appele quand l'utilisateur clique "Annuler
    l'abonnement" sur un plan active via un vrai paiement Stripe, pour
    que "annuler" annule vraiment cote Stripe et pas seulement
    l'affichage local.
    #>
    param([Parameter(Mandatory=$true)][string]$SubscriptionId)

    if (-not (Test-StripeConfigured)) {
        return [pscustomobject]@{ Status = "NOT_CONFIGURED" }
    }

    try {
        $Secret = Get-StripeSecret
        $Response = Invoke-RestMethod -Uri "https://api.stripe.com/v1/subscriptions/$SubscriptionId" `
            -Method DELETE `
            -Headers @{ Authorization = "Bearer $($Secret.secret_key)" } `
            -TimeoutSec 20

        return [pscustomobject]@{
            Status           = "SUCCESS"
            SubscriptionId   = $Response.id
            SubscriptionStatus = $Response.status
        }
    }
    catch {
        return [pscustomobject]@{ Status = "ERROR"; Detail = $_.Exception.Message }
    }
}
