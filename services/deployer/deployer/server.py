"""MCP server: describe, start and monitor inventory-driven deployments."""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from fastmcp import FastMCP
from fastmcp.exceptions import ToolError
from starlette.requests import Request
from starlette.responses import JSONResponse

from .inventory import Inventory, InventoryError, Service
from .jobs import DeployBusy, JobManager

READ_ONLY = {"readOnlyHint": True}
ACTION = {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": True, "openWorldHint": True}


def plan_step(order: int, service: Service, inventory: Inventory) -> dict[str, Any]:
    node = inventory.nodes[service.node]
    return {
        "order": order, "service": service.name, "node": node.name, "host": node.host, "user": node.user,
        "repo": service.repo, "ref": service.ref, "directory": service.directory or ".",
        "install_path": f"{service.base_dir}/{service.name}",
        "build": service.build or None, "start": service.start, "pre": service.pre or None,
        "env_variables": [key for key, _ in service.env],
        "verify": service.mcp_url or None,
    }


def build_server(manager: JobManager, load: Callable[[], Inventory]) -> FastMCP:
    app = FastMCP("deployer")

    @app.tool(
        name="describe_deploy_plan",
        description=(
            "Describe, without changing anything, what a deployment would do: for each service in "
            "order, its node, repository, ref, build and start commands, environment variable names "
            "(never values) and the endpoint checked afterwards. Omit services to plan every "
            "configured service. Call this before asking the operator to approve a deployment."
        ),
        annotations=READ_ONLY,
    )
    def describe_deploy_plan(services: list[str] | None = None) -> dict[str, Any]:
        try:
            inventory = load()
            selected = inventory.select(services)
        except InventoryError as error:
            raise ToolError(str(error)) from error
        return {"steps": [plan_step(i, s, inventory) for i, s in enumerate(selected, 1)],
                "nodes": len({s.node for s in selected}), "inventory": inventory.path}

    @app.tool(
        name="deploy_services",
        description=(
            "STATE-CHANGING. Clone or update each service's repository on its remote node, apply its "
            "environment, then build and start it, using the inventory. Omit services to deploy every "
            "configured service. Runs in the background and returns a job_id immediately; follow it "
            "with get_deployment_status. Only call after the operator approved the plan."
        ),
        annotations=ACTION,
    )
    def deploy_services(services: list[str] | None = None) -> dict[str, Any]:
        try:
            return manager.start(services)
        except (InventoryError, DeployBusy) as error:
            raise ToolError(str(error)) from error

    @app.tool(
        name="get_deployment_status",
        description=(
            "Status of a deployment job (the latest when job_id is omitted): per service its status "
            "(pending, running, succeeded, failed), exit code, whether the MCP endpoint answered "
            "(verified) and the last output lines."
        ),
        annotations=READ_ONLY,
    )
    def get_deployment_status(job_id: str | None = None) -> dict[str, Any]:
        try:
            return manager.status(job_id)
        except InventoryError as error:
            raise ToolError(str(error)) from error

    @app.custom_route("/health", methods=["GET"])
    async def health(_request: Request) -> JSONResponse:
        return JSONResponse({"ok": True})

    return app
