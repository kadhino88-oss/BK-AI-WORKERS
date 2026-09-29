# BK AI WORKERS
# OPENAI MODEL ACCESS CHECK
# PHASE 7G-1C

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$secretPath = Join-Path $projectRoot ".secrets\openai.secret.dpapi"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " OPENAI MODEL ACCESS CHECK"
Write-Host " PHASE 7G-1C"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $secretPath)) {
    Write-Host "CREDENTIAL FILE : NOT FOUND"
    exit 1
}

try {
    $encrypted = Get-Content -LiteralPath $secretPath -Raw
    $secureCredential = ConvertTo-SecureString $encrypted
}
catch {
    Write-Host "DPAPI : ERROR"
    exit 1
}

$ptr = $null
$apiKey = $null

try {
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureCredential)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)

    $headers = @{
        "Authorization" = "Bearer $apiKey"
    }

    $models = Invoke-RestMethod `
        -Uri "https://api.openai.com/v1/models" `
        -Method Get `
        -Headers $headers `
        -TimeoutSec 30

    $targets = @(
        "gpt-5.6-luna",
        "gpt-5.6-terra",
        "gpt-5.6-sol",
        "gpt-5"
    )

    Write-Host "MODELS API : SUCCESS"
    Write-Host ""

    foreach ($target in $targets) {
        $match = @($models.data | Where-Object { $_.id -eq $target })

        if ($match.Count -gt 0) {
            Write-Host "$target : AVAILABLE"
        }
        else {
            Write-Host "$target : NOT RETURNED"
        }
    }

    Write-Host ""
    Write-Host "AVAILABLE GPT MODELS :"
    $models.data |
        Where-Object { $_.id -like "gpt-5*" } |
        Select-Object -ExpandProperty id |
        Sort-Object |
        Select-Object -First 30
}
catch {
    Write-Host ""
    Write-Host "STATUS : ERROR"
    Write-Host "DETAIL : $($_.Exception.Message)"
    exit 1
}
finally {
    if ($null -ne $ptr) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }

    $apiKey = $null
}