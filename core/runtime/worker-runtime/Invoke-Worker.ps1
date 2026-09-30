param(
    [Parameter(Mandatory=$true)][string]$Worker,
    [Parameter(Mandatory=$true)][string]$Task,
    [string]$TenantId = "",
    [string]$ClientId = "",
    [string]$ProjectId = "",
    [string]$ExecutionId = "",
    [string]$UserId = "",
    [string]$SessionId = "",
    [string]$TokenId = "",
    [string]$Token = "",
    [ValidateSet("SIMULATION","SANDBOX","CERTIFICATION","PILOT","LIVE")]
    [string]$Environment = "SIMULATION",
    [ValidateSet("SIMULATION","SANDBOX","CERTIFICATION","PILOT","LIVE")]
    [string]$Mode = "SIMULATION"
)

$ErrorActionPreference="Stop"

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

$WorkerPath = Join-Path $Root ("workers\"+$Worker)
$WorkerDoc  = Join-Path $WorkerPath "WORKER.md"
$SkillReg   = Join-Path $WorkerPath "skills\SKILLS-REGISTRY.json"

if(-not (Test-Path -LiteralPath $WorkerPath -PathType Container)){
    throw "WORKER_NOT_FOUND:$Worker"
}

if([string]::IsNullOrWhiteSpace($Task)){
    throw "TASK_REQUIRED"
}

$SkillNames=@()

if(Test-Path -LiteralPath $SkillReg -PathType Leaf){
    $Raw=Get-Content -LiteralPath $SkillReg -Raw -Encoding UTF8
    try {
        $Reg=$Raw | ConvertFrom-Json
        foreach($p in $Reg.PSObject.Properties){
            if($null -ne $p.Value){
                $SkillNames += [string]$p.Name
            }
        }
    } catch {
        throw "SKILL_REGISTRY_INVALID:$Worker"
    }
}

$Prompt = @"
You are the BK-AI-WORKERS specialist "$Worker".

Tenant: $TenantId
Client: $ClientId
Project: $ProjectId
Execution: $ExecutionId
User: $UserId

Task:
$Task

Available skills:
$($SkillNames -join ", ")

Rules:
- Stay within the assigned worker role.
- Do not invent external actions.
- Do not expose credentials, tokens or secrets.
- Return a useful structured answer.
"@

$Result=[ordered]@{
    success=$true
    worker=$Worker
    task=$Task
    tenantId=$TenantId
    clientId=$ClientId
    projectId=$ProjectId
    executionId=$ExecutionId
    environment=$Environment
    mode=$Mode
    skillCount=$SkillNames.Count
    prompt=$Prompt
    status="READY_FOR_AI_GATEWAY"
}

[pscustomobject]$Result