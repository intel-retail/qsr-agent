"""Command line: serve the deployer MCP server, validate an inventory, or print agent settings."""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from pathlib import Path

from starlette.middleware import Middleware

from .auth import MIN_TOKEN_CHARS, BearerAuth
from .inventory import InventoryError, load_inventory
from .jobs import JobManager
from .remote import SshExecutor, load_script
from .server import build_server, plan_step

DEFAULT_INVENTORY = "/run/deployer/inventory.yaml"


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(prog="qsr-deployer", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    serve = sub.add_parser("serve", help="run the MCP server")
    serve.add_argument("--transport", choices=("stdio", "http", "streamable-http"), default="stdio")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8095)
    sub.add_parser("check", help="validate the inventory and print the deployment plan")
    sub.add_parser("agent-env", help="print KEY=URL lines that connect the agent to the deployed services")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, stream=sys.stderr, format="%(levelname)s %(message)s")
    inventory_path = Path(os.environ.get("QSR_DEPLOYER_INVENTORY", DEFAULT_INVENTORY))

    def load():
        return load_inventory(inventory_path)

    if args.command in {"check", "agent-env"}:
        try:
            inventory = load()
        except InventoryError as error:
            raise SystemExit(f"inventory invalid: {error}") from error
        if args.command == "check":
            print(json.dumps([plan_step(i, s, inventory) for i, s in enumerate(inventory.services.values(), 1)], indent=2))
        else:
            for service in inventory.services.values():
                for key, url in service.agent_env:
                    print(f"{key}={url}")
        return

    manager = JobManager(load, lambda known_hosts: SshExecutor(known_hosts), load_script())
    app = build_server(manager, load)
    if args.transport == "stdio":
        app.run("stdio", show_banner=False)
        return
    token = os.environ.get("QSR_DEPLOYER_TOKEN", "").strip()
    if len(token) < MIN_TOKEN_CHARS:
        raise SystemExit(f"QSR_DEPLOYER_TOKEN must be at least {MIN_TOKEN_CHARS} characters to serve over HTTP "
                         "(`make deployer` creates it)")
    app.run("http", show_banner=False, host=args.host, port=args.port,
            middleware=[Middleware(BearerAuth, token=token)])


if __name__ == "__main__":
    main()
