# QSR Store Agent

This project is a reusable edge-agent pattern for quick-service restaurants.
Hermes handles conversation and orchestration, Qwen3-8B runs locally through
OpenVINO Model Server (OVMS) on an Intel GPU, and independent MCP services own
restaurant data, actions, policy, and audit evidence.

```text
Operator -> Hermes -> OVMS/Qwen -> MCP service -> domain system
         <- answer  <- tool use  <- typed result <- policy/audit
```

The repository includes:

- `mcp-service-base/`: framework-neutral service, policy, log, and MCP binding.
- `tests/mcp-services/`: runnable Kiosk and Order Accuracy simulations.
- `qsr-skills/`: Hermes procedures for domain Q&A and actions.
- `agent-config/hermes/`: reusable local and remote configuration fragments.
- `scripts/setup.sh`: repeatable Linux setup and verification.

The included domain values and actions are simulations. They prove contracts,
routing, action gates, Docker transport, and agent integration; they are not
production restaurant integrations.

## Start Here

1. Follow [setup.md](setup.md) to install and run the exact local stack.
2. Read [architecture.md](architecture.md) for ownership and trust boundaries.
3. Follow [adding-a-service.md](adding-a-service.md) to integrate another QSR
   domain or replace a simulation with an authoritative service.

After prerequisites are installed, the normal path is:

```bash
git clone <repository-url> qsr-agentic-svc
cd qsr-agentic-svc
chmod +x scripts/setup.sh
./scripts/setup.sh
hermes
```

Verify an existing installation at any time without changing it:

```bash
./scripts/setup.sh --check
```
