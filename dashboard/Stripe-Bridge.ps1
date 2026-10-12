# =====================================================================
# BK-AI-WORKERS — Dashboard : pont CLI vers Stripe-Adapter.ps1
# Appele par dashboard/server.py (POST /api/billing/plan quand Stripe
# est configure, POST /api/billing/stripe-confirm). Ecrit le resultat
# JSON dans -OutFile (meme convention que Submit-Task.ps1 /
# Automation-Bridge.ps1).
# =====================================================================

param(
    [Parameter(Mandatory=$true)][ValidateSet("status", "create-checkout", "confirm", "cancel-subscription")][string]$Action,
    [string]$PlanId = "",
    [string]$SessionId = "",
    [string]$SuccessUrl = "",
    [string]$CancelUrl = "",
    [string]$SubscriptionId = "",
    [ValidateSet("month", "year")][string]$Interval = "month",
    [string]$ClientId = "",
    # Montant du catalogue du serveur (centimes de CHF) et nom du forfait, pour les forfaits sans Price ID Stripe (voir Stripe-Adapter.ps1).
    [long]$AmountCents = 0,
    [string]$PlanName = "",
    [Parameter(Mandatory=$true)][string]$OutFile
)

$ErrorActionPreference = "Stop"
# PowerShell 7+ : ne pas convertir les dates ISO en [datetime] (Windows PowerShell 5.1 les laissait en texte ; le moteur compare/hashe ces textes).
if ($PSVersionTable.PSVersion.Major -ge 7) { $PSDefaultParameterValues["ConvertFrom-Json:DateKind"] = "String" }
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/integrations/Stripe-Adapter.ps1")

$Result = switch ($Action) {
    "status" {
        if (Test-StripeConfigured) {
            $Secret = Get-StripeSecret
            [pscustomobject]@{
                Configured       = $true
                Live             = $Secret.secret_key -notlike "sk_test_*"
                PublishableKey   = $Secret.publishable_key
            }
        } else {
            [pscustomobject]@{ Configured = $false }
        }
    }
    "create-checkout"     { New-StripeCheckoutSession -PlanId $PlanId -SuccessUrl $SuccessUrl -CancelUrl $CancelUrl -Interval $Interval -ClientId $ClientId -AmountCents $AmountCents -PlanName $PlanName }
    "confirm"             { Get-StripeCheckoutSession -SessionId $SessionId }
    "cancel-subscription" { Remove-StripeSubscription -SubscriptionId $SubscriptionId }
}

[System.IO.File]::WriteAllText(
    $OutFile,
    ($Result | ConvertTo-Json -Depth 10),
    [System.Text.UTF8Encoding]::new($false)
)
