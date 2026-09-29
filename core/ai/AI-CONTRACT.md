# BK AI WORKERS — AI CONTRACT

## Purpose

Central AI Gateway used by all BK AI Workers.

## Architecture

ORCHESTRATOR
    ↓
CONTEXT BRIDGE
    ↓
AI GATEWAY
    ↓
LLM PROVIDER
    ↓
WORKER

## Mandatory Input

Every AI request must contain:

- client_id
- project_id
- worker_id
- task_id
- objective
- context
- memory
- permissions

## Security

The AI Gateway MUST NOT:

- increase permissions
- bypass client isolation
- bypass project isolation
- bypass worker isolation
- execute financial transactions
- authorize financial transactions
- expose secrets
- expose API keys
- execute irreversible actions without authorization

## Financial Boundary

financial_actions = false by default.

Financial operations require:

STATUS = NEEDS_HUMAN

AUTHORIZATION = KADER_APPROVAL

## Worker Identity

The Gateway must preserve the identity of the Worker.

The model must receive the Worker role and mission.

## Memory

Only validated memory supplied by the Context Bridge may be transmitted.

Raw unauthorized memory must never be transmitted.

## Provider Independence

Workers must never directly depend on a specific LLM provider.

Workers communicate with the AI Gateway.

The Gateway communicates with the selected provider.

## Response

The Gateway returns:

- status
- worker
- task
- answer
- recommendations
- next_action
- security_status
- generated_at

## Modes

SIMULATION
LOCAL
LLM

The system starts in SIMULATION/LOCAL mode.

External LLM access is introduced only after Gateway validation.

## Principle

One Gateway.
Many Workers.
One security model.
One context model.
One memory model.