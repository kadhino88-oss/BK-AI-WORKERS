Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\security-integrity"
$RuntimeFile = Join-Path $RuntimeRoot "Security-Integrity.ps1"

. $RuntimeFile

Reset-IntegrityRecords | Out-Null

$script:PassCount = 0
$script:FailCount = 0

function Invoke-Test {

    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {

        $Result = & $Action

        if ($Result -eq $false) {
            throw "ASSERTION FALSE"
        }

        $script:PassCount++

        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {

        $script:FailCount++

        Write-Host "FAIL $Name :: $($_.Exception.Message)" -ForegroundColor Red
    }
}

$script:ContentA = "BK-AI-WORKERS-INTEGRITY-A"
$script:ContentB = "BK-AI-WORKERS-INTEGRITY-B"

Invoke-Test "01 config enabled" {

    (Get-IntegrityConfig).enabled -eq $true
}

Invoke-Test "02 integrity enabled" {

    (Get-IntegrityConfig).integrityEnabled -eq $true
}

Invoke-Test "03 SHA256 deterministic" {

    $Hash1 = Get-SHA256 "ABC"
    $Hash2 = Get-SHA256 "ABC"

    $Hash1 -eq $Hash2
}

Invoke-Test "04 different content different hash" {

    $Hash1 = Get-SHA256 "ABC"
    $Hash2 = Get-SHA256 "ABD"

    $Hash1 -ne $Hash2
}

Invoke-Test "05 create integrity record" {

    $script:RecordA = New-IntegrityRecord `
        -RecordId "IR1" `
        -ResourceType "TEST" `
        -ResourceId "RES1" `
        -Content $script:ContentA

    $script:RecordA.Status -eq "SEALED"
}

Invoke-Test "06 hash stored" {

    $Expected = Get-SHA256 $script:ContentA

    $script:RecordA.ContentHash -eq $Expected
}

Invoke-Test "07 size stored" {

    $script:RecordA.ContentSize -eq $script:ContentA.Length
}

Invoke-Test "08 save record" {

    Save-IntegrityRecord $script:RecordA | Out-Null

    $Loaded = Get-IntegrityRecord "IR1"

    $null -ne $Loaded
}

Invoke-Test "09 valid integrity" {

    $Result = Verify-Integrity `
        -RecordId "IR1" `
        -Content $script:ContentA

    (
        $Result.Valid -eq $true
    ) -and (
        $Result.Decision -eq "ALLOW"
    )
}

Invoke-Test "10 tampering detected" {

    $Result = Verify-Integrity `
        -RecordId "IR1" `
        -Content $script:ContentB

    (
        $Result.Valid -eq $false
    ) -and (
        $Result.Reason -eq "TAMPERED"
    )
}

Invoke-Test "11 missing content blocked" {

    $Result = Verify-Integrity `
        -RecordId "IR1" `
        -Content ""

    (
        $Result.Valid -eq $false
    ) -and (
        $Result.Reason -eq "CONTENT_MISSING"
    )
}
Invoke-Test "12 missing record blocked" {

    $Result = Verify-Integrity `
        -RecordId "UNKNOWN" `
        -Content "ABC"

    $Result.Reason -eq "RECORD_NOT_FOUND"
}

Invoke-Test "13 duplicate record blocked" {

    $Result = New-IntegrityRecord `
        -RecordId "IR1" `
        -ResourceType "TEST" `
        -ResourceId "RES1" `
        -Content $script:ContentA

    $Result.Status -eq "DUPLICATE"
}

Invoke-Test "14 algorithm fixed to SHA256" {

    $Record = Get-IntegrityRecord "IR1"

    $Record.Algorithm -eq "SHA256"
}

Invoke-Test "15 algorithm mismatch blocked" {

    $StatePath = Join-Path $RuntimeRoot "state\integrity-records.json"

    $Raw = Get-Content `
        -Raw `
        -Path $StatePath `
        -Encoding UTF8

    $State = $Raw | ConvertFrom-Json

    # Etat JSON : tableau de records.
    # On modifie directement le premier record existant.
    $State[0].Algorithm = "MD5"

    $TamperedJson = ConvertTo-Json `
        -InputObject @($State) `
        -Depth 30

    [System.IO.File]::WriteAllText(
        $StatePath,
        $TamperedJson,
        [System.Text.UTF8Encoding]::new($false)
    )

    $Result = Verify-Integrity `
        -RecordId "IR1" `
        -Content $script:ContentA

    $Result.Reason -eq "ALGORITHM_MISMATCH"
}
Invoke-Test "16 reset restores clean state" {

    Reset-IntegrityRecords | Out-Null

    @(Get-IntegrityRecords).Count -eq 0
}

Invoke-Test "17 reseal after reset" {

    $script:RecordB = New-IntegrityRecord `
        -RecordId "IR2" `
        -ResourceType "TEST" `
        -ResourceId "RES2" `
        -Content $script:ContentA

    Save-IntegrityRecord $script:RecordB | Out-Null

    $Result = Verify-Integrity `
        -RecordId "IR2" `
        -Content $script:ContentA

    $Result.Valid -eq $true
}

Invoke-Test "18 file hash available" {

    $Hash = Get-FileSHA256 $RuntimeFile

    (
        -not [string]::IsNullOrWhiteSpace($Hash)
    ) -and (
        $Hash.Length -eq 64
    )
}

Invoke-Test "19 seal file integrity" {

    $Record = New-IntegrityRecord `
        -RecordId "FILE1" `
        -ResourceType "RUNTIME" `
        -ResourceId "7H53" `
        -Content (
            Get-Content -Raw `
                -Path $RuntimeFile `
                -Encoding UTF8
        )

    Save-IntegrityRecord $Record | Out-Null

    $Record.RecordId -eq "FILE1"
}

Invoke-Test "20 verify file integrity" {

    $Result = Verify-FileIntegrity `
        -RecordId "FILE1" `
        -Path $RuntimeFile

    $Result.Valid -eq $true
}

Invoke-Test "21 nonexistent file blocked" {

    $Result = Verify-FileIntegrity `
        -RecordId "FILE1" `
        -Path (
            Join-Path $RuntimeRoot "does-not-exist.txt"
        )

    (
        $Result.Valid -eq $false
    ) -and (
        $Result.Reason -eq "FILE_NOT_FOUND"
    )
}

Invoke-Test "22 no secrets config" {

    $ConfigText = Get-Content `
        -Raw `
        -Path (Join-Path $RuntimeRoot "config.json")

    $Forbidden = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue)"\s*:'

    $ConfigText -notmatch $Forbidden
}

Invoke-Test "23 no payload config" {

    $ConfigText = Get-Content `
        -Raw `
        -Path (Join-Path $RuntimeRoot "config.json")

    $ConfigText -notmatch '(?i)"payload"\s*:'
}

Invoke-Test "24 reset final state" {

    Reset-IntegrityRecords | Out-Null

    @(Get-IntegrityRecords).Count -eq 0
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-53 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if ($script:PassCount -eq 24 -and $script:FailCount -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"