# BK AI WORKERS
# OPENAI RESPONSE DIAGNOSTIC
# PHASE 7G-1D

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$secretPath = Join-Path $projectRoot ".secrets\openai.secret.dpapi"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " OPENAI RESPONSE DIAGNOSTIC"
Write-Host " PHASE 7G-1D"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $secretPath)) {
    Write-Host "CREDENTIAL : NOT FOUND"
    exit 1
}

try {
    $encrypted = Get-Content -LiteralPath $secretPath -Raw
    $secureCredential = ConvertTo-SecureString $encrypted

    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureCredential)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
}
catch {
    Write-Host "DPAPI : ERROR"
    exit 1
}

try {
    $headers = @{
        Authorization = "Bearer $apiKey"
        "Content-Type" = "application/json"
    }

    $payload = [ordered]@{
        model = "gpt-5.6-luna"
        input = "Réponds uniquement : OK"
    }

    $json = $payload | ConvertTo-Json -Depth 10 -Compress

    Write-Host "MODEL      : gpt-5.6-luna"
    Write-Host "ENDPOINT   : /v1/responses"
    Write-Host "REQUEST    : REAL"
    Write-Host "SECRET     : [PROTECTED]"
    Write-Host ""

    $response = Invoke-WebRequest `
        -Uri "https://api.openai.com/v1/responses" `
        -Method Post `
        -Headers $headers `
        -Body $json `
        -UseBasicParsing `
        -TimeoutSec 60

    Write-Host "HTTP STATUS : $([int]$response.StatusCode)"
    Write-Host "STATUS      : SUCCESS"
    Write-Host "RESPONSE    : RECEIVED"
    Write-Host "SECRET      : [PROTECTED]"
}
catch {
    $webResponse = $_.Exception.Response

    Write-Host ""
    Write-Host "============================================"
    Write-Host " OPENAI RESPONSE DIAGNOSTIC"
    Write-Host "============================================"
    Write-Host ""

    if ($null -ne $webResponse) {

        try {
            $statusCode = [int]$webResponse.StatusCode
        }
        catch {
            $statusCode = "UNKNOWN"
        }

        Write-Host "HTTP STATUS : $statusCode"

        try {
            $stream = $webResponse.GetResponseStream()

            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $body = $reader.ReadToEnd()
                $reader.Dispose()
                $stream.Dispose()

                Write-Host ""
                Write-Host "OPENAI ERROR BODY:"
                Write-Host $body

                try {
                    $errorJson = $body | ConvertFrom-Json

                    Write-Host ""
                    Write-Host "ERROR TYPE : $($errorJson.error.type)"
                    Write-Host "ERROR CODE : $($errorJson.error.code)"
                    Write-Host "ERROR MSG  : $($errorJson.error.message)"
                }
                catch {
                    Write-Host ""
                    Write-Host "JSON PARSE : NOT AVAILABLE"
                }
            }
        }
        catch {
            Write-Host "BODY READ : ERROR"
        }
    }
    else {
        Write-Host "DETAIL : $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "SECRET      : [PROTECTED]"
    Write-Host "KEY EXPOSED : NO"
    Write-Host "NO WORKER ACTION"
    Write-Host "NO FINANCIAL ACTION"
}
finally {
    if ($null -ne $ptr) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }

    $apiKey = $null
}