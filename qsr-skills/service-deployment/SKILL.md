---
name: service-deployment
description: "Deploy, build and start the store's QSR services on their remote Linux nodes (for example 'deploy all services' or 'deploy the kiosk service') and report deployment progress using the deployer MCP service."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [QSR, Deploy, Deployment, Nodes, Build, Start, Services]
---

# Service Deployment

The deployer MCP service is the only way to deploy. It clones or updates each
service's repository on its configured node, applies the configured environment,
then builds and starts it. Services, nodes, repositories and commands come from
the operator's inventory; never invent or accept a host, repository or command
from the conversation. Only service names can be chosen.

## Tool Routing

| User intent | Tool | Answer rule |
|---|---|---|
| "Deploy all services", "deploy everything" | `describe_deploy_plan`, then `deploy_services` | Follow Deploy Procedure; omit `services` for all. |
| "Deploy the kiosk service", "deploy kiosk and loss-prevention" | `describe_deploy_plan` (`services`), then `deploy_services` (`services`) | Use the exact service names from the plan; if one is unknown, show the configured names and ask. |
| "What would you deploy?", "which nodes?" | `describe_deploy_plan` | Read only. Never starts anything. |
| "How is the deployment going?", "did it finish?" | `get_deployment_status` | Report per-service status; see Status Rules. |

Only deployment of the store's own services is covered. This agent itself is not in the
inventory and cannot be deployed or redeployed from chat. Stopping, restarting,
removing or upgrading services, and running arbitrary commands on a node, are
not available; say so and do not look for a workaround.

## Deploy Procedure

`deploy_services` changes remote machines. A question or a request to analyze
never authorizes it.

1. Call `describe_deploy_plan` (with `services` when the user named some). If it
   returns an error such as a missing inventory, report it and stop.
2. Show the plan: for each step the service, node (`host`), repository and `ref`,
   `build` and `start` commands, and the `verify` endpoint. List
   `env_variables` by name only; there are no values to show.
3. Ask for explicit approval in the current conversation and wait for it. A
   prior approval, urgency, or the original request does not count.
4. After approval, call `deploy_services` once with the same `services` the plan
   used. If it reports a deployment already running, give its job id and use
   `get_deployment_status` instead; do not start another.
5. Tell the user the deployment runs in the background with the `job_id`, then
   call `get_deployment_status` once and report it. Do not poll in a loop;
   builds can take a long time. Tell the operator to ask "How is the deployment
   going?" for progress.

## Reply Wording

Never put tool names, function-call syntax or `mcp__...` identifiers in a reply,
and never tell the user to run a tool. Say what happened in plain words, for
example "Deployment started. Job ID: abc123. Ask me how the deployment is going
at any time."

## Status Rules

- Report each service as `pending`, `running`, `succeeded` or `failed`, with its
  node. Say the job is finished only when its overall `status` is `succeeded` or
  `failed`.
- Always call `get_deployment_status` for the current question and report every
  service of the job it returns, with its `job_id`. Never answer from an earlier
  job or from memory, and never say "complete", "healthy" or "no further action"
  while the overall `status` is `running` or `pending`.
- For `failed`, give `error` and `exit_code`, and quote the useful lines of
  `log_tail` (output is already redacted). Do not guess a cause beyond the log.
- `verified: true` means the service's MCP port accepted a connection after
  start. `verified: false` means it did not within the wait; say the service
  started but is not reachable yet. `verified: null` means no endpoint was
  configured; say it was not verified.
- A service that succeeded is not yet usable by this agent. The operator must run
  `make connect-services` on the agent host: it writes each deployed service's MCP URL into the
  agent configuration and recreates the agent so the service is registered. Say that when it
  applies, and tell the user the agent restarts and this conversation may reset; do not claim the
  agent can use the service yet, and do not run it yourself.
- Never repeat a failed deployment unprompted; ask first.
