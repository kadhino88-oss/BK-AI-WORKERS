$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Engine = Join-Path $Root "memory\engine\Memory-Access.ps1"

$Passed = 0
$Failed = 0

function Test-Case {
    param(
        [string]$Name,
        [scriptblock]$Action,
        [bool]$ExpectedSuccess
    )

    Write-Host ""
    Write-Host "TEST : $Name"

    try {
        & $Action
        $ExitCode = $LASTEXITCODE

        if ($ExpectedSuccess -and $ExitCode -eq 0) {
            Write-Host "RESULTAT : PASS"
            $script:Passed++
        }
        elseif (-not $ExpectedSuccess -and $ExitCode -ne 0) {
            Write-Host "RESULTAT : PASS - ACCES REFUSE"
            $script:Passed++
        }
        else {
            Write-Host "RESULTAT : FAIL"
            $script:Failed++
        }
    }
    catch {
        if (-not $ExpectedSuccess) {
            Write-Host "RESULTAT : PASS - ACCES REFUSE"
            $script:Passed++
        }
        else {
            Write-Host "RESULTAT : FAIL"
            $script:Failed++
        }
    }
}

Write-Host ""
Write-Host "============================================"
Write-Host " MEMORY ACCESS SECURITY TEST"
Write-Host " PHASE 5C"
Write-Host "============================================"

Test-Case `
    -Name "MAYA lecture de sa propre memoire" `
    -ExpectedSuccess $true `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "bk-entreprise" `
            -ProjectId "service-ia" `
            -WorkerId "MAYA" `
            -MemoryKey "strategie-lancement"
    }

Test-Case `
    -Name "LUCAS lecture de sa propre memoire" `
    -ExpectedSuccess $true `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "client-demo" `
            -ProjectId "site-web" `
            -WorkerId "LUCAS" `
            -MemoryKey "audit-seo"
    }

Test-Case `
    -Name "LUCAS acces memoire MAYA" `
    -ExpectedSuccess $false `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "bk-entreprise" `
            -ProjectId "service-ia" `
            -WorkerId "LUCAS" `
            -MemoryKey "strategie-lancement"
    }

Test-Case `
    -Name "MAYA acces memoire LUCAS" `
    -ExpectedSuccess $false `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "client-demo" `
            -ProjectId "site-web" `
            -WorkerId "MAYA" `
            -MemoryKey "audit-seo"
    }

Test-Case `
    -Name "Worker inconnu" `
    -ExpectedSuccess $false `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "bk-entreprise" `
            -ProjectId "service-ia" `
            -WorkerId "WORKER-INCONNU" `
            -MemoryKey "strategie-lancement"
    }

Test-Case `
    -Name "Client inconnu" `
    -ExpectedSuccess $false `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "client-inconnu" `
            -ProjectId "site-web" `
            -WorkerId "LUCAS" `
            -MemoryKey "audit-seo"
    }

Test-Case `
    -Name "Projet inconnu" `
    -ExpectedSuccess $false `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "client-demo" `
            -ProjectId "projet-inconnu" `
            -WorkerId "LUCAS" `
            -MemoryKey "audit-seo"
    }

Test-Case `
    -Name "Worker cross-client" `
    -ExpectedSuccess $false `
    -Action {
        & $Engine `
            -Action READ `
            -ClientId "bk-entreprise" `
            -ProjectId "service-ia" `
            -WorkerId "LUCAS" `
            -MemoryKey "strategie-lancement"
    }

Write-Host ""
Write-Host "============================================"
Write-Host " RESULTAT FINAL"
Write-Host "============================================"

Write-Host "TESTS PASSES : $Passed"
Write-Host "TESTS ECHOUES : $Failed"

if ($Failed -eq 0) {
    Write-Host ""
    Write-Host "MEMORY ACCESS : SECURE"
    Write-Host "PHASE 5C : VALIDEE"
    exit 0
}

Write-Host ""
Write-Host "MEMORY ACCESS : ATTENTION"
Write-Host "PHASE 5C : NON VALIDEE"
exit 1