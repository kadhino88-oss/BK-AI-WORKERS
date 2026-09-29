# BK AI WORKERS
# OPENAI 429 DIAGNOSTIC
# PHASE 7G-1B

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$secretPath = Join-Path $projectRoot ".secrets\openai.secret.dpapi"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " OPENAI 429 DIAGNOSTIC"
Write-Host " PHASE 7G-1B"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $secretPath)) {
    Write-Host "CREDENTIAL FILE : NOT FOUND"
    exit 1
}

Write-Host "CREDENTIAL FILE : PRESENT"
Write-Host "STORAGE         : DPAPI"

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

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host "CREDENTIAL : EMPTY"
        exit 1
    }

    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    $body = @{
        model = "gpt-5"
        input = "OK"
        max_output_tokens = 8
    } | ConvertTo-Json -Depth 5

    try {
        $response = Invoke-RestMethod `
            -Uri "https://api.openai.com/v1/responses" `
            -Method Post `
            -Headers $headers `
            -Body $body `
            -TimeoutSec 30

        Write-Host ""
        Write-Host "============================================"
        Write-Host " OPENAI DIAGNOSTIC RESULT"
        Write-Host "============================================"
        Write-Host ""
        Write-Host "STATUS : SUCCESS"
        Write-Host "REQUEST : ACCEPTED"
        Write-Host "SECRET : [PROTECTED]"
        Write-Host ""
    }
    catch {
        $webResponse = $_.Exception.Response

        Write-Host ""
        Write-Host "============================================"
        Write-Host " OPENAI DIAGNOSTIC RESULT"
        Write-Host "============================================"
        Write-Host ""

        if ($null -ne $webResponse) {
            Write-Host "HTTP STATUS : $([int]$webResponse.StatusCode)"
            Write-Host "STATUS NAME : $($webResponse.StatusDescription)"

            $stream = $webResponse.GetResponseStream()

            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $errorBody = $reader.ReadToEnd()
                $reader.Dispose()
                $stream.Dispose()

                try {
                    $errorJson = $errorBody | ConvertFrom-Json

                    Write-Host ""
                    Write-Host "ERROR TYPE : $($errorJson.error.type)"
                    Write-Host "ERROR CODE : $($errorJson.error.code)"
                    Write-Host "ERROR MSG  : $($errorJson.error.message)"
                }
                catch {
                    Write-Host ""
                    Write-Host "ERROR BODY : $errorBody"
                }
            }
        }
        else {
            Write-Host "HTTP STATUS : UNKNOWN"
            Write-Host "DETAIL : $($_.Exception.Message)"
        }

        Write-Host ""
        Write-Host "SECRET      : [PROTECTED]"
        Write-Host "KEY EXPOSED : NO"
    }
}
finally {
    if ($null -ne $ptr) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }

    $apiKey = $null
}

Write-Host ""
Write-Host "============================================"
Write-Host " DIAGNOSTIC FINISHED"
Write-Host "============================================"
Write-Host ""