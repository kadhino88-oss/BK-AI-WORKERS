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
    [Parameter(Mandatory=$true)][string]$OutFile
)

$ErrorActionPreference = "Stop"
$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
. (Join-Path $Root "core\integrations\Stripe-Adapter.ps1")

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
    "create-checkout"     { New-StripeCheckoutSession -PlanId $PlanId -SuccessUrl $SuccessUrl -CancelUrl $CancelUrl }
    "confirm"             { Get-StripeCheckoutSession -SessionId $SessionId }
    "cancel-subscription" { Remove-StripeSubscription -SubscriptionId $SubscriptionId }
}

[System.IO.File]::WriteAllText(
    $OutFile,
    ($Result | ConvertTo-Json -Depth 10),
    [System.Text.UTF8Encoding]::new($false)
)
