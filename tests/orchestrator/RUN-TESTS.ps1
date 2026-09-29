# ORCHESTRATOR TEST RUNNER

$tests = Get-Content ".\test-cases.json" -Raw | ConvertFrom-Json

$results = @()

foreach ($test in $tests) {

    $result = [PSCustomObject]@{
        ID = $test.id
        Request = $test.request
        ExpectedWorker = if ($test.expected_worker) { $test.expected_worker } else { "-" }
        ExpectedStatus = $test.expected_status
        Result = "READY_FOR_ENGINE"
    }

    $results += $result
}

$results | Format-Table -AutoSize

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " TESTS ORCHESTRATEUR CHARGÉS" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Nombre de scénarios : $($tests.Count)" -ForegroundColor Yellow
Write-Host ""
Write-Host "IMPORTANT :" -ForegroundColor Yellow
Write-Host "Cette phase prépare les tests."
Write-Host "Le moteur d'exécution réel sera branché après validation."
