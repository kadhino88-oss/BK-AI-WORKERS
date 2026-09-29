Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\security-audit"
$RuntimeFile = Join-Path $RuntimeRoot "Security-Audit.ps1"

. $RuntimeFile

Reset-AuditEvents | Out-Null

$script:PassCount = 0
$script:FailCount = 0
$script:EventA = $null
$script:EventB = $null

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

Invoke-Test "01 config enabled" {
    (Get-AuditConfig).enabled -eq $true
}

Invoke-Test "02 audit enabled" {
    (Get-AuditConfig).auditEnabled -eq $true
}

Invoke-Test "03 SHA256 enabled" {
    (Get-AuditConfig).hashAlgorithm -eq "SHA256"
}

Invoke-Test "04 create audit event" {

    $script:EventA = New-AuditEvent `
        -EventId "AUD1" `
        -CorrelationId "CORR1" `
        -ExecutionId "EX1" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "MAYA" `
        -ActorType "WORKER" `
        -ActionType "MODEL_CALL" `
        -Severity "INFO" `
        -Decision "ALLOW" `
        -Reason "AUTHORIZED"

    $script:EventA.Status -eq "RECORDED"
}

Invoke-Test "05 add first event" {
    $Result = Add-AuditEvent $script:EventA

    $Result.Sequence -eq 1
}

Invoke-Test "06 first event hash present" {
    $Loaded = Get-AuditEvent "AUD1"

    (
        -not [string]::IsNullOrWhiteSpace(
            [string]$Loaded.EventHash
        )
    ) -and (
        [string]$Loaded.PreviousHash -eq ""
    )
}

Invoke-Test "07 chain valid after first event" {
    (Test-AuditChain).Valid -eq $true
}

Invoke-Test "08 create second event" {

    $script:EventB = New-AuditEvent `
        -EventId "AUD2" `
        -CorrelationId "CORR1" `
        -ExecutionId "EX1" `
        -TenantId "T1" `
        -ClientId "C1" `
        -ProjectId "P1" `
        -WorkerId "MAYA" `
        -ActorType "ORCHESTRATOR" `
        -ActionType "PUBLISH" `
        -Severity "WARNING" `
        -Decision "BLOCK" `
        -Reason "POLICY"

    $script:EventB.CorrelationId -eq "CORR1"
}

Invoke-Test "09 add second event" {
    $Result = Add-AuditEvent $script:EventB

    $Result.Sequence -eq 2
}

Invoke-Test "10 second event links first" {

    $First = Get-AuditEvent "AUD1"
    $Second = Get-AuditEvent "AUD2"

    $Second.PreviousHash -eq $First.EventHash
}

Invoke-Test "11 chain valid after second event" {
    $Result = Test-AuditChain

    (
        $Result.Valid -eq $true
    ) -and (
        $Result.Checked -eq 2
    )
}

Invoke-Test "12 correlation returns both events" {

    $Matches = @(Find-AuditByCorrelationId "CORR1")

    $Matches.Count -eq 2
}

Invoke-Test "13 unknown correlation empty" {

    $Matches = @(Find-AuditByCorrelationId "UNKNOWN")

    $Matches.Count -eq 0
}

Invoke-Test "14 event retrieval" {

    $Loaded = Get-AuditEvent "AUD2"

    $Loaded.Decision -eq "BLOCK"
}

Invoke-Test "15 duplicate blocked" {

    $Result = Add-AuditEvent $script:EventB

    $Result.Status -eq "DUPLICATE"
}

Invoke-Test "16 invalid actor rejected" {

    try {
        New-AuditEvent `
            -EventId "BAD-ACTOR" `
            -CorrelationId "C3" `
            -ExecutionId "EX3" `
            -TenantId "T1" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -ActorType "UNKNOWN" `
            -ActionType "TEST" `
            -Severity "INFO" `
            -Decision "ALLOW" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "17 invalid severity rejected" {

    try {
        New-AuditEvent `
            -EventId "BAD-SEV" `
            -CorrelationId "C4" `
            -ExecutionId "EX4" `
            -TenantId "T1" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -ActorType "SYSTEM" `
            -ActionType "TEST" `
            -Severity "UNKNOWN" `
            -Decision "ALLOW" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "18 invalid decision rejected" {

    try {
        New-AuditEvent `
            -EventId "BAD-DEC" `
            -CorrelationId "C5" `
            -ExecutionId "EX5" `
            -TenantId "T1" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -ActorType "SYSTEM" `
            -ActionType "TEST" `
            -Severity "INFO" `
            -Decision "UNKNOWN" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "19 missing tenant rejected" {

    try {
        New-AuditEvent `
            -EventId "BAD-TENANT" `
            -CorrelationId "C6" `
            -ExecutionId "EX6" `
            -TenantId "" `
            -ClientId "C1" `
            -ProjectId "P1" `
            -WorkerId "SAM" `
            -ActorType "SYSTEM" `
            -ActionType "TEST" `
            -Severity "INFO" `
            -Decision "BLOCK" | Out-Null

        $false
    }
    catch {
        $true
    }
}

Invoke-Test "20 no secrets stored" {

    $StateFile = Join-Path $RuntimeRoot "state\audit-events.json"
    $Text = Get-Content -Raw -Path $StateFile -Encoding UTF8

    $Forbidden = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue)"\s*:'

    $Text -notmatch $Forbidden
}

Invoke-Test "21 no payload stored" {

    $StateFile = Join-Path $RuntimeRoot "state\audit-events.json"
    $Text = Get-Content -Raw -Path $StateFile -Encoding UTF8

    $Text -notmatch '(?i)"payload"\s*:'
}

Invoke-Test "22 tamper detection" {

    $StateFile = Join-Path $RuntimeRoot "state\audit-events.json"

    $Raw = Get-Content -Raw -Path $StateFile -Encoding UTF8
    $State = $Raw | ConvertFrom-Json

    $State[1].Decision = "ALLOW"

    $TamperedJson = ConvertTo-Json `
        -InputObject @($State) `
        -Depth 30

    [System.IO.File]::WriteAllText(
        $StateFile,
        $TamperedJson,
        [System.Text.UTF8Encoding]::new($false)
    )

    $Result = Test-AuditChain

    $Result.Valid -eq $false
}

Invoke-Test "23 reset restores empty trail" {

    Reset-AuditEvents | Out-Null

    $Events = @(Get-AuditEvents)

    $Events.Count -eq 0
}

Invoke-Test "24 empty chain valid" {

    $Result = Test-AuditChain

    (
        $Result.Valid -eq $true
    ) -and (
        $Result.Status -eq "EMPTY"
    ) -and (
        $Result.Checked -eq 0
    )
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-54 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if ($script:PassCount -eq 24 -and $script:FailCount -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"