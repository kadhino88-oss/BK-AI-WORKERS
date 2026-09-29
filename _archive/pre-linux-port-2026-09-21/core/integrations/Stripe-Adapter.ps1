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
        [Parameter(Mandatory=$true)][string]$CancelUrl
    )

    if (-not (Test-StripeConfigured)) {
        return [pscustomobject]@{ Status = "NOT_CONFIGURED" }
    }

    try {
        $Secret = Get-StripeSecret
        $PriceId = $Secret.prices.$PlanId
        if (-not $PriceId) {
            return [pscustomobject]@{ Status = "UNKNOWN_PLAN"; Detail = "Aucun Price ID Stripe pour '$PlanId'." }
        }

        $Fields = [ordered]@{
            "mode"                          = "subscription"
            "success_url"                   = $SuccessUrl
            "cancel_url"                    = $CancelUrl
            "line_items[0][price]"          = $PriceId
            "line_items[0][quantity]"       = "1"
            "metadata[bk_plan_id]"          = $PlanId
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
