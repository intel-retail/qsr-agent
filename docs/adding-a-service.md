# Adding a QSR Service

[Repository overview](../README.md) | [Documentation guide](index.md) |
[Setup](setup.md) | [Architecture](architecture.md) |
**Add a service**

This guide adds a production-oriented `inventory` domain from an authoritative
HTTP API. It does not copy or depend on the simulated services under `tests/`.
Use the same sequence for labor, drive-through, POS, weather, menu, or another
QSR domain.

## 1. Define ownership before code

The domain service owns:

- Source-system access and credentials.
- Current and historical domain data.
- Input validation, authorization, approval, and rate limits.
- Stable MCP tool names and typed parameters.
- Audit records and action results.

Hermes owns conversation and tool orchestration. A skill teaches Hermes when to
call a tool and how to interpret its result. Neither Hermes nor a skill is a
source of restaurant truth or an authorization boundary.

Start with one bounded context read, then add narrow tools only for different
latency, payload, authorization, or history requirements:

| Need | Suggested tool |
|---|---|
| Current domain snapshot | `get_inventory_context(store_id)` |
| Historical range | `get_inventory_history(store_id, start_at, end_at, timezone)` |
| Approved action | `request_restock(store_id, item_id, quantity, approval_id)` |

Every result should identify its source, schema version, store, observation
time, units, and requested time window. A current snapshot cannot answer
“yesterday”; query durable source data instead of agent memory.

## 2. Create a Git branch and service files

Begin from the latest main branch and keep one domain per reviewable change:

```bash
git switch main
git pull --ff-only origin main
git switch -c feature/inventory-mcp

mkdir -p services/inventory/tests
touch services/inventory/__init__.py
touch services/inventory/service.py
touch services/inventory/smoke_client.py
touch services/inventory/tests/test_service.py
mkdir -p qsr-skills/inventory
touch qsr-skills/inventory/SKILL.md
```

Resulting ownership:

```text
services/inventory/
  __init__.py
  Dockerfile                  Production service image
  service.py                 API adapter and MCP tools
  smoke_client.py            Model-independent MCP client
  tests/test_service.py      Contract, API, and policy tests
qsr-skills/inventory/
  SKILL.md                   Hermes routing and interpretation
```

Install the shared service library and official MCP SDK in a local environment:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install -e './mcp-service-base[mcp,test]'
```

The `mcp` extra installs the official MCP runtime used by the server and smoke
client. The `test` extra installs pytest and test dependencies; omit it from
the production image.

## 3. Implement the API adapter and MCP tools

The example upstream API contract is:

```http
GET  /v1/stores/{store_id}/inventory
GET  /v1/approvals/{approval_id}
POST /v1/stores/{store_id}/restock-requests
Authorization: Bearer <INVENTORY_API_TOKEN>
```

The approval response must bind the approval to the exact action and arguments:

```json
{
  "approved": true,
  "action": "request_restock",
  "store_id": "store-001",
  "item_id": "fries",
  "quantity": 4,
  "expires_at": "2026-09-04T20:00:00+00:00"
}
```

Put this complete implementation in `services/inventory/service.py`:

```python
from __future__ import annotations

import json
import os
from datetime import UTC, datetime
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

from mcp_service_base import GateLevel, PolicyGate, ServiceServer


def api_json(method: str, path: str, body: dict[str, Any] | None = None) -> Any:
  api_url = os.environ["INVENTORY_API_URL"].rstrip("/")
  api_token = os.environ["INVENTORY_API_TOKEN"]
  payload = None if body is None else json.dumps(body).encode()
  request = Request(
    f"{api_url}{path}",
    data=payload,
    method=method,
    headers={
      "Accept": "application/json",
      "Authorization": f"Bearer {api_token}",
      "Content-Type": "application/json",
    },
  )
  try:
    with urlopen(request, timeout=10) as response:
      return json.load(response)
  except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as error:
    raise RuntimeError(f"Inventory API request failed: {method} {path}") from error


def approval_is_valid(action: str, arguments: dict[str, Any]) -> bool:
  approval_id = arguments.get("approval_id")
  store_id = arguments.get("store_id")
  item_id = arguments.get("item_id")
  quantity = arguments.get("quantity")
  identifiers = (approval_id, store_id, item_id)
  if (
    not all(isinstance(value, str) and value.strip() for value in identifiers)
    or not isinstance(quantity, int)
    or quantity <= 0
  ):
    return False
  approval = api_json("GET", f"/v1/approvals/{quote(str(approval_id), safe='')}")
  try:
    expires_at = datetime.fromisoformat(approval["expires_at"])
  except (KeyError, TypeError, ValueError):
    return False
  return (
    approval.get("approved") is True
    and expires_at.tzinfo is not None
    and expires_at > datetime.now(UTC)
    and approval.get("action") == action
    and approval.get("store_id") == arguments.get("store_id")
    and approval.get("item_id") == arguments.get("item_id")
    and approval.get("quantity") == arguments.get("quantity")
  )


service = ServiceServer(
  service="inventory",
  store_id="multi-store",
  policy=PolicyGate(approver=approval_is_valid),
)


@service.read_tool(
  "get_inventory_context",
  description="Return current item quantities and availability for one store.",
)
def get_inventory_context(store_id: str) -> dict[str, Any]:
  if not store_id.strip():
    raise ValueError("store_id must not be empty")
  upstream = api_json(
    "GET", f"/v1/stores/{quote(store_id, safe='')}/inventory"
  )
  return {
    "schema_version": "1.0",
    "source": "inventory-api",
    "store_id": store_id,
    "observed_at": upstream["observed_at"],
    "items": upstream["items"],
  }


@service.act_tool(
  "request_restock",
  level=GateLevel.NEEDS_APPROVAL,
  description="Create an approved restock request for one inventory item.",
  max_calls=10,
  per_seconds=60,
)
def request_restock(
  store_id: str,
  item_id: str,
  quantity: int,
  approval_id: str,
) -> dict[str, Any]:
  if quantity <= 0:
    raise ValueError("quantity must be greater than zero")
  if not all(value.strip() for value in (store_id, item_id, approval_id)):
    raise ValueError("store_id, item_id, and approval_id must not be empty")
  result = api_json(
    "POST",
    f"/v1/stores/{quote(store_id, safe='')}/restock-requests",
    {
      "item_id": item_id,
      "quantity": quantity,
      "approval_id": approval_id,
    },
  )
  return {
    "status": result["status"],
    "action_id": result["request_id"],
    "executed_at": datetime.now(UTC).isoformat(),
  }


if __name__ == "__main__":
  transport = os.environ.get("MCP_TRANSPORT", "stdio")
  host = os.environ.get("MCP_HOST", "127.0.0.1")
  port = int(os.environ.get("MCP_PORT", "8000"))
  service.run(transport=transport, host=host, port=port)
```

Important implementation rules:

- Read credentials only from environment or a secret manager; never commit or
  log them.
- Encode path parameters and set outbound timeouts.
- Convert upstream failures into bounded errors that do not expose headers or
  response bodies containing secrets.
- Validate output shape instead of passing arbitrary upstream JSON to the LLM.
- Bind approval to action, store, item, quantity, and expiry in production.
- Use a durable database and idempotency key for production actions.

The action function returns domain proof (`status`, `action_id`, and time). The
framework wraps it as `{"executed": true, "level": "needs_approval",
"result": {...}}`. A denial has `executed: false` and a reason, and the action
function is not called. Do not duplicate `executed` or `level` inside the domain
result. Production services should not return `placeholder: true`; that marker
is reserved for simulations.

## 4. Test the MCP server without Hermes

Put this official MCP client in `services/inventory/smoke_client.py`:

```python
from __future__ import annotations

import asyncio
import json
import os
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main() -> None:
  server = StdioServerParameters(
    command=sys.executable,
    args=["services/inventory/service.py"],
    env={
      **os.environ,
      "INVENTORY_API_URL": os.environ["INVENTORY_API_URL"],
      "INVENTORY_API_TOKEN": os.environ["INVENTORY_API_TOKEN"],
    },
  )
  async with stdio_client(server) as (read_stream, write_stream):
    async with ClientSession(read_stream, write_stream) as session:
      await session.initialize()
      tools = await session.list_tools()
      assert "get_inventory_context" in {tool.name for tool in tools.tools}
      result = await session.call_tool(
        "get_inventory_context", {"store_id": "store-001"}
      )
      print(json.dumps(result.model_dump(mode="json"), indent=2))


if __name__ == "__main__":
  asyncio.run(main())
```

Run it against a development or mock API:

```bash
export INVENTORY_API_URL=http://127.0.0.1:8080
export INVENTORY_API_TOKEN=replace-with-local-test-token
python services/inventory/smoke_client.py
```

Unit tests should mock `api_json`, never require a real credential, and cover:

- Valid context shape, units, timestamps, and store identity.
- Upstream timeout, invalid JSON, missing fields, and authorization failure.
- Invalid action inputs.
- Missing, expired, mismatched, and valid approvals.
- Rate limiting and idempotent action behavior.
- No credential content in exceptions or logs.

For example, put this approval-path test in
`services/inventory/tests/test_service.py`:

```python
from datetime import UTC, datetime, timedelta

from services.inventory import service as inventory


def test_approved_restock_executes(monkeypatch):
  def fake_api(method, path, body=None):
    if method == "GET":
      return {
        "approved": True,
        "action": "request_restock",
        "store_id": "store-001",
        "item_id": "fries",
        "quantity": 4,
        "expires_at": (datetime.now(UTC) + timedelta(minutes=5)).isoformat(),
      }
    return {"status": "accepted", "request_id": "restock-123"}

  monkeypatch.setattr(inventory, "api_json", fake_api)
  result = inventory.service.call_action(
    "request_restock",
    store_id="store-001",
    item_id="fries",
    quantity=4,
    approval_id="approval-123",
  )

  assert result["executed"] is True
  assert result["result"]["action_id"] == "restock-123"


def test_mismatched_approval_is_denied(monkeypatch):
  monkeypatch.setattr(
    inventory,
    "api_json",
    lambda method, path, body=None: {
      "approved": True,
      "action": "request_restock",
      "store_id": "another-store",
      "item_id": "fries",
      "quantity": 4,
      "expires_at": (datetime.now(UTC) + timedelta(minutes=5)).isoformat(),
    },
  )

  result = inventory.service.call_action(
    "request_restock",
    store_id="store-001",
    item_id="fries",
    quantity=4,
    approval_id="approval-123",
  )

  assert result["executed"] is False
```

Run them before involving an LLM:

```bash
pytest -q services/inventory/tests
```

## 5. Register the service with Hermes

For local development, add a stdio registration to `~/.hermes/config.yaml`:

```yaml
platform_toolsets:
  cli:
  - inventory

mcp_servers:
  inventory:
  command: /absolute/path/to/qsr-agentic-svc/.venv/bin/python
  args:
    - /absolute/path/to/qsr-agentic-svc/services/inventory/service.py
  env:
    INVENTORY_API_URL: ${INVENTORY_API_URL}
    INVENTORY_API_TOKEN: ${INVENTORY_API_TOKEN}
  enabled: true
```

`platform_toolsets.cli` makes the `inventory` toolset available to ordinary
CLI sessions. Hermes resolves the `${...}` values from its environment and
passes them only to the stdio child. Export the variables before starting
Hermes; do not put literal secrets in `config.yaml`.

For deployment, run the service with Streamable HTTP:

```bash
export MCP_TRANSPORT=streamable-http
export MCP_HOST=0.0.0.0
export MCP_PORT=8000
python services/inventory/service.py
```

Terminate TLS and authenticate requests before exposing `/mcp`. Then register
the remote endpoint instead of the stdio entry:

```yaml
platform_toolsets:
  cli:
  - inventory

mcp_servers:
  inventory:
  url: https://inventory-mcp.example.internal/mcp
  transport: streamable-http
  connect_timeout: 15
  timeout: 120
  headers:
    Authorization: Bearer ${INVENTORY_MCP_TOKEN}
  enabled: true
```

Never configure both `command` and `url` for the same server. Restart Hermes,
then verify discovery before asking a domain question:

```bash
hermes mcp test inventory
```

## 6. Write the Hermes skill

Put this in `qsr-skills/inventory/SKILL.md`:

```markdown
---
name: inventory
description: "Answer inventory, availability, and restock questions using the Inventory MCP service."
version: 1.0.0
platforms: [linux]
metadata:
  hermes:
    tags: [QSR, Inventory, Restock]
---

# Inventory

Use Inventory MCP results as the only source of inventory facts.

## Tool Routing

| User intent | Tool | Fields | Answer rule |
|---|---|---|---|
| Current stock or availability | `get_inventory_context` | `store_id`, `items`, `observed_at` | Include quantity, unit, and observation time. |
| Restock request | `get_inventory_context`, then `request_restock` | Current item, requested quantity, approval ID, action result | Explain current state, require explicit approved scope, call once, and report execution proof. |

Do not invent quantities or substitute agent memory. Mention an alert once. Do
not propose an action unless the user asks for one or an operating procedure
requires it.
```

Only document tools that the service actually exposes. If history is not yet
implemented, omit that row and explicitly state that historical questions are
unsupported.

Update `AGENTS.md` only for stable cross-domain rules. For example, add a rule
there if Inventory and Kiosk results must always match `store_id` and compatible
observation windows before correlation. Keep inventory field mappings in the
inventory skill.

## 7. Package and deploy the service

Create `services/inventory/Dockerfile`:

```dockerfile
FROM python:3.12-slim

WORKDIR /opt/qsr

COPY mcp-service-base/ ./mcp-service-base/
COPY services/inventory/ ./services/inventory/

RUN pip install --no-cache-dir "./mcp-service-base[mcp]"

ENV PYTHONUNBUFFERED=1 \
    MCP_TRANSPORT=streamable-http \
    MCP_HOST=0.0.0.0 \
    MCP_PORT=8000

EXPOSE 8000
USER 65532:65532

ENTRYPOINT ["python", "/opt/qsr/services/inventory/service.py"]
```

Build from the repository root. Supply API credentials only when starting the
container, preferably through the deployment platform's secret store:

```bash
docker build -f services/inventory/Dockerfile -t inventory-mcp:local .
docker run --rm -p 127.0.0.1:8001:8000 \
  -e INVENTORY_API_URL="$INVENTORY_API_URL" \
  -e INVENTORY_API_TOKEN="$INVENTORY_API_TOKEN" \
  inventory-mcp:local
```

Do not bake `.env`, tokens, certificates, or local databases into the image.
Pin the base image and Python dependencies before release, run as non-root, and
put `/mcp` behind an authenticated HTTPS reverse proxy or service mesh.

## 8. Verify the complete path

Run checks in this order so failures remain attributable:

```bash
pytest -q services/inventory/tests
python services/inventory/smoke_client.py
hermes mcp test inventory
hermes skills list --enabled-only
hermes -z 'Which items are currently low at store-001?' --cli -t inventory
hermes -z 'Which items are currently low at store-001?' --cli
```

For an action, test three separate cases: no approval, mismatched approval, and
valid approval. Confirm the source API and audit log agree with Hermes' answer.
Take one dependency offline and verify Hermes reports the limitation rather
than fabricating data.

Production acceptance requires:

- HTTPS and authenticated MCP ingress.
- Secrets supplied outside Git and container images.
- Health, timeout, retry, audit, and telemetry behavior.
- Durable history for every documented historical question.
- Policy denial and approval tests for every action.
- Read-back or source-system proof after an action.

## 9. Review and publish with Git

Review only intended files and scan for accidental credentials:

```bash
git status --short
git diff --check
git diff -- services/inventory qsr-skills/inventory AGENTS.md
git grep -nEi 'password|api[_-]?key|access[_-]?token|private[_-]?key'
```

The last command will find environment-variable names; inspect each match and
ensure no literal value is committed. Then commit and push the feature branch:

```bash
git add services/inventory qsr-skills/inventory
git add AGENTS.md  # only when cross-domain rules changed
git commit -m "Add inventory MCP service"
git push -u origin feature/inventory-mcp
```

Open a pull request that records the upstream API owner, MCP tools, approval
model, test evidence, deployment endpoint, rollback plan, and known limitations.
Do not merge an action tool whose approval or authorization path is still a
placeholder.

---

[Previous: Architecture](architecture.md) |
[Documentation guide](index.md)
