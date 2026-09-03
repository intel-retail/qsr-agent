# Adding a QSR Service

[Repository overview](../README.md) | [Documentation guide](index.md) |
[Setup](setup.md) | [Architecture](architecture.md) |
**Add a service**

An MCP service is the authority for one restaurant domain. It owns current and
historical data, typed reads/actions, validation, policy gates, and audit logs.
Hermes is already the MCP client; do not duplicate domain data in a skill or
write a second client unless another application also needs the service.

Order Accuracy is the reference implementation:

- Server: `tests/mcp-services/order_accuracy_server.py`
- Model-independent client: `tests/mcp-services/call_tool.py`
- Skill: `qsr-skills/order-accuracy/SKILL.md`
- Cross-domain rules: `AGENTS.md`

Files under `tests/mcp-services/` use simulated data. A production owner should
put the same contract beside its authoritative application and depend on
`mcp-service-base` as a package.

## 1. Design the contract

Choose a stable lowercase domain name such as `order-accuracy`. Provide:

- One bounded `get_<domain>_context` tool for broad and unfamiliar questions.
- Narrow read tools only when history, authorization, size, or latency differs.
- Verb-noun actions such as `request_remake`, each gated in service code.
- Explicit JSON Schemas with stable IDs, units, windows, `source`,
  `schema_version`, `observed_at`, and confidence semantics where relevant.

A current snapshot cannot answer “what was accuracy yesterday?”. Historical
questions require durable source data and a bounded tool such as:

```text
get_order_accuracy_history(
  restaurant_id: string,
  start_at: ISO-8601 timestamp,
  end_at: ISO-8601 timestamp,
  timezone: IANA timezone
)
```

The response must preserve the requested window and timezone. Never reconstruct
history from agent memory or a current snapshot.

## 2. Create the MCP server

For a local simulation, copy the nearest domain module:

```bash
cp tests/mcp-services/order_accuracy_server.py \
  tests/mcp-services/inventory_server.py
```

In the new module:

1. Construct `ServiceServer.from_config(ServiceConfig(...))`.
2. Register event schemas with `register_event_type`.
3. Decorate reads with `@svc.read_tool`.
4. Decorate actions with `@svc.act_tool` and a `GateLevel`.
5. Define exact JSON input schemas in `TOOL_SCHEMAS`.
6. Call `run_service(svc, <service-name>, TOOL_SCHEMAS)` from `__main__`.

Reads return evidence; actions return `executed`, gate/status, a stable action
ID, and proof fields. Authorization, approval, rate limits, and validation must
remain in service code because skill instructions are not a security boundary.

Add the service to `SERVICES` in
`tests/mcp-services/service_launcher.py` so the shared Docker image can launch
it with `QSR_SERVICE=<domain>`.

## 3. Add a model-independent client path

For stdio simulation tests, extend the `choices` and script map in
`tests/mcp-services/call_tool.py`. Then call the service without Hermes or a
model:

```bash
python3 tests/mcp-services/call_tool.py \
  order-accuracy get_order_accuracy_context
```

For production Streamable HTTP, Hermes is the client. Another application that
needs direct access should use an official MCP SDK and the same `/mcp` endpoint;
do not invent a parallel REST contract for the same tools.

## 4. Register the service with Hermes

Local stdio registration:

```yaml
platform_toolsets:
  cli:
    - inventory
mcp_servers:
  inventory:
    command: python3
    args:
      - /absolute/path/to/qsr-agentic-svc/tests/mcp-services/inventory_server.py
    enabled: true
```

Remote production registration:

```yaml
platform_toolsets:
  cli:
    - inventory
mcp_servers:
  inventory:
    url: https://inventory.example.internal/mcp
    transport: streamable-http
    connect_timeout: 15
    timeout: 120
    headers:
      Authorization: Bearer ${INVENTORY_MCP_TOKEN}
    enabled: true
```

Use `command`/`args` or `url`, never both for one server. Put tokens in the
environment, terminate TLS before the service, restrict ingress, and never log
credentials. Restart Hermes after changing registration.

## 5. Write the domain skill

Create `qsr-skills/<domain>/SKILL.md`:

```markdown
---
name: inventory
description: "Answer inventory, stock, availability, and replenishment questions."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [QSR, Inventory]
---

# Inventory

Use the Inventory MCP service as the only source of inventory facts.

## Tool Routing

| User intent | Tool | Fields | Answer rule |
|---|---|---|---|
| Current stock | `get_inventory_context` | `items`, `observed_at` | Include quantity, unit, and observation time. |
| Other inventory analysis | `get_inventory_context` | Relevant returned fields | Call once and state missing evidence instead of guessing. |
```

For every specialized Q&A rule, identify the exact tool, field paths,
calculation, units, time window, and missing-data behavior. For every action,
document the evidence read, explicit approval requirement, call parameters,
execution-proof fields, and read-back verification.

Update `AGENTS.md` only for rules that span domains, such as correlating
Inventory and Kiosk data by restaurant identity and compatible observation
windows. Domain-specific field mappings belong in the skill.

## 6. Test the full path

Add model-independent tests for response shape, historical bounds, invalid
input, denied actions, approved actions, and transport startup. Then run:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s tests/mcp-services -p 'test_services.py' -v
hermes mcp test <domain>
hermes skills list --enabled-only
hermes -z '<simple domain question>' --cli -t <domain>
hermes -z '<broad domain question>' --cli
```

Confirm the service received `tools/call` and the final answer matches its
result. Test denied and approved actions separately. For cross-domain tests,
make one service unavailable and verify Hermes reports partial coverage instead
of inventing the missing portion.

---

[Previous: Architecture](architecture.md) |
[Documentation guide](index.md)
