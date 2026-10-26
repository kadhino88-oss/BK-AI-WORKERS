# =====================================================================
# Redirige, POUR LES TESTS, les appels HTTPS vers une adresse publique fictive (FAKE_REDIRECT_FROM, ex. https://93.184.216.34) vers un faux serveur local
# (FAKE_REDIRECT_BASE, ex. http://127.0.0.1:PORT) : permet de tester l'adaptateur OpenAI-compatible en mode « cle d'un client » (https obligatoire, hote public
# de la liste blanche) sans aucun reseau externe. La verification d'adresse de l'adaptateur a lieu AVANT, sur l'adresse fictive, comme en production.
# A dot-sourcer dans le pilote de test (variable T_PRE).
# =====================================================================
$Global:RealIrm2 = Get-Command -Name Invoke-RestMethod -CommandType Cmdlet

function Invoke-RestMethod {
    param($Uri, $Method = "GET", $Headers, $ContentType, $Body, $TimeoutSec, $MaximumRedirection, $OutFile, $Credential)
    $Splat = @{}
    foreach ($K in $PSBoundParameters.Keys) { $Splat[$K] = $PSBoundParameters[$K] }
    if (([string]$Uri).StartsWith($env:FAKE_REDIRECT_FROM)) { $Splat["Uri"] = $env:FAKE_REDIRECT_BASE + ([string]$Uri).Substring($env:FAKE_REDIRECT_FROM.Length) }
    return & $Global:RealIrm2 @Splat
}
