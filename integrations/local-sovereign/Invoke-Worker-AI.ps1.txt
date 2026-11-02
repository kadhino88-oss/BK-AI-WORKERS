[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkerId,
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Objective,
    [string]$ClientPlan = "WORKER_SOLO",
    [int]$TasksDoneToday = 0,
    [int]$TasksDoneWeekly = 0,
    [int]$MessagesInCurrentChat = 0,
    [string]$ComputeMode = "FLASH",
    [string]$Mode = "SOVEREIGN_LOCAL"
)

# 1. GESTION DES MODES D'EFFORT (Faible, Normal, Eleve, Max)
$TaskCost = 1;
if ($ComputeMode -eq "ARGON") { $TaskCost = 10; }
elseif ($ComputeMode -eq "PRO") { $TaskCost = 5; }
elseif ($ComputeMode -eq "FLASH") { $TaskCost = 2; }
else { $TaskCost = 1; } # LITE

# 2. GESTION MULTI-COUCHES DES QUOTAS (Convertis en "Credits")
$DailyQuota = 0; $WeeklyQuota = 0; $ChatLimit = 0;

if ($ClientPlan -eq "FORFAIT_HAUTE_VALEUR") { 
    $DailyQuota = 1500; $WeeklyQuota = 7500; $ChatLimit = 500; 
} 
elseif ($ClientPlan -eq "EQUIPE_STANDARD") { 
    $DailyQuota = 500; $WeeklyQuota = 2500; $ChatLimit = 150; 
} 
elseif ($ClientPlan -eq "WORKER_SOLO") { 
    $DailyQuota = 150; $WeeklyQuota = 750; $ChatLimit = 50; 
} 
else { 
    $DailyQuota = 40; $WeeklyQuota = 200; $ChatLimit = 15; 
}

# 3. VERIFICATION DES LIMITES AVEC LE COUT DE LA TACHE
$ErrorMsg = "";
if ($MessagesInCurrentChat -ge $ChatLimit) {
    $ErrorMsg = "Limite de session atteinte : Le maximum de $ChatLimit messages pour ce co-work est atteint.";
} elseif (($TasksDoneToday + $TaskCost) -gt $DailyQuota) {
    $ErrorMsg = "Quota quotidien insuffisant. Il vous reste $($DailyQuota - $TasksDoneToday) credits, mais le mode $ComputeMode coute $TaskCost credits.";
} elseif (($TasksDoneWeekly + $TaskCost) -gt $WeeklyQuota) {
    $ErrorMsg = "Quota hebdomadaire insuffisant. Il vous reste $($WeeklyQuota - $TasksDoneWeekly) credits, mais le mode $ComputeMode coute $TaskCost credits.";
}

if ($ErrorMsg -ne "") {
    $QuotaError = [ordered]@{
        Worker            = $WorkerId.ToUpperInvariant();
        TaskId            = $TaskId;
        Status            = "QUOTA_EXCEEDED";
        ExecutionMode     = "LOCAL_SOVEREIGN_AI";
        Answer            = "Action refusee : $ErrorMsg";
        ComputeMode       = $ComputeMode;
        TaskCost          = $TaskCost;
        ChatLimitUsed     = "$MessagesInCurrentChat/$ChatLimit";
        DailyQuotaUsed    = "$TasksDoneToday/$DailyQuota";
        WeeklyQuotaUsed   = "$TasksDoneWeekly/$WeeklyQuota";
        financial_actions = $false;
        external_actions  = $false;
        VerifiedBy        = "KADER_ADMIN";
    };
    ConvertTo-Json -InputObject $QuotaError -Depth 5;
    exit;
}

# 4. MOTEUR IA LOCAL SOUVERAIN
$Endpoint = "http://127.0.0.1:11434/api/generate";
$Model = "llama3:latest";

# 5. PROMPT SYSTEME D'ELITE
$SystemPrompt = "Tu es le Worker $WorkerId, un expert d'elite de l'agence suisse BK-AI-WORKERS.
Tu maitrises parfaitement le contexte de la Suisse romande, notamment les fiduciaires, le droit suisse, et la nLPD.
REGLES IMPERATIVES :
1. Agis comme un professionnel de tres haut niveau.
2. Va droit au but, sois precis, technique et percutant.
3. NE DONNE AUCUNE EXPLICATION, justification ou commentaire sur ton travail.
4. Redige UNIQUEMENT le livrable demande.
5. NE PARLE JAMAIS EN ANGLAIS, redige 100% en francais.
6. Adapte ton expertise au domaine demande.
Attention : Le client a configure ta puissance de calcul sur le mode '$ComputeMode'. Fournis une reponse dont le niveau de detail correspond a cet effort.";

$FullPrompt = "$SystemPrompt`n`nObjectif du client : $Objective";

try {
    $BodyObject = @{ model = $Model; prompt = $FullPrompt; stream = $false };
    $Body = ConvertTo-Json -InputObject $BodyObject -Depth 3;
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Body);
    $Response = Invoke-RestMethod -Uri $Endpoint -Method Post -Body $Bytes -ContentType "application/json; charset=utf-8" -ErrorAction Stop;

    $ResultObj = [ordered]@{
        Worker            = $WorkerId.ToUpperInvariant();
        TaskId            = $TaskId;
        Status            = "SUCCESS";
        ExecutionMode     = "LOCAL_SOVEREIGN_AI";
        Answer            = $Response.response.Trim();
        ComputeMode       = $ComputeMode;
        TaskCost          = $TaskCost;
        ChatLimitUsed     = "$($MessagesInCurrentChat + 1)/$ChatLimit";
        DailyQuotaUsed    = "$($TasksDoneToday + $TaskCost)/$DailyQuota";
        WeeklyQuotaUsed   = "$($TasksDoneWeekly + $TaskCost)/$WeeklyQuota";
        ClientPlan        = $ClientPlan;
        financial_actions = $false;
        external_actions  = $false;
        VerifiedBy        = "KADER_ADMIN";
    };
} catch {
    $ResultObj = [ordered]@{
        Worker            = $WorkerId.ToUpperInvariant();
        TaskId            = $TaskId;
        Status            = "ERROR";
        ExecutionMode     = "LOCAL_SOVEREIGN_AI";
        Answer            = "Detail de l'erreur : $($_.Exception.Message)";
        financial_actions = $false;
        external_actions  = $false;
        VerifiedBy        = "KADER_ADMIN";
    };
}

ConvertTo-Json -InputObject $ResultObj -Depth 5;
