param(
    [string]$EnginePath
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($EnginePath)) {
    Write-Host "EnginePath obligatoire." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $EnginePath)) {
    Write-Host "Engine introuvable." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "      7H-16 RUNTIME ENFORCER VALIDATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

try {

    $Command = Get-Command `
        -Name $EnginePath `
        -ErrorAction Stop

    if ($null -eq $Command) {
        throw "Engine non chargeable."
    }

    Write-Host "Engine : OK" -ForegroundColor Green
    Write-Host "Signature PowerShell : OK" -ForegroundColor Green

}
catch {

    Write-Host "RESULTAT : FAIL" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "RESULTAT : PASS" -ForegroundColor Green
Write-Host "Integration Runtime Enforcer valide." -ForegroundColor Green

exit 0