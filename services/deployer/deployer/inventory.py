"""Deployment inventory: nodes (SSH targets) and services (what to run where).

The inventory is the only source of hosts, repositories and commands. The model can
only choose service names from it, so nothing it says reaches a shell.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.parse import urlparse

import yaml

NAME = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
HOST = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9.:-]{0,251}[A-Za-z0-9])?$")
USER = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
REF = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9._/-]{0,127}$")
REPO = re.compile(r"^https://[A-Za-z0-9._~/@:%+-]{1,255}$")
RELATIVE_PATH = re.compile(r"^[A-Za-z0-9_.][A-Za-z0-9_./-]{0,127}$")
REMOTE_BASE = re.compile(r"^(~(/[A-Za-z0-9_./-]{0,127})?|/[A-Za-z0-9_./-]{0,127}|[A-Za-z0-9_][A-Za-z0-9_./-]{0,127})$")
ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")

DEFAULT_KNOWN_HOSTS = "/run/deployer/known_hosts"
DEFAULT_BASE_DIR = "~/qsr-services"
DEFAULT_TIMEOUT_SECONDS = 3600
DEFAULT_VERIFY_SECONDS = 120


class InventoryError(ValueError):
    """The inventory is missing, malformed, or does not contain a requested service."""


@dataclass(frozen=True)
class Node:
    name: str
    host: str
    port: int
    user: str
    ssh_key: str


@dataclass(frozen=True)
class Service:
    name: str
    node: str
    repo: str
    ref: str
    directory: str
    build: str
    start: str
    env_file: str
    env: tuple[tuple[str, str], ...]
    shell_env: tuple[tuple[str, str], ...]
    base_dir: str
    timeout_seconds: int
    mcp_url: str
    verify_seconds: int
    agent_env: tuple[tuple[str, str], ...] = ()
    pre: str = ""

    @property
    def secrets(self) -> tuple[str, ...]:
        """Values to keep out of logs returned to the model."""
        return tuple(value for _, value in self.env + self.shell_env if len(value) >= 4)


@dataclass(frozen=True)
class Inventory:
    nodes: Mapping[str, Node]
    services: Mapping[str, Service]
    known_hosts: str = DEFAULT_KNOWN_HOSTS
    path: str = field(default="", compare=False)

    def select(self, names: Sequence[str] | None) -> list[Service]:
        """Services to deploy in inventory order; every service when `names` is empty."""
        if not names:
            return list(self.services.values())
        unknown = sorted(set(names) - set(self.services))
        if unknown:
            known = ", ".join(self.services) or "none"
            raise InventoryError(f"unknown service(s): {', '.join(unknown)}; configured services: {known}")
        wanted = set(names)
        return [service for service in self.services.values() if service.name in wanted]


def _text(table: Mapping[str, Any], key: str, default: str | None = None, *, where: str) -> str:
    value = table.get(key, default)
    if value is None:
        raise InventoryError(f"{where}: '{key}' is required")
    if not isinstance(value, (str, int)) or isinstance(value, bool):
        raise InventoryError(f"{where}: '{key}' must be text")
    return str(value).strip()


def _number(table: Mapping[str, Any], key: str, default: int, low: int, high: int, *, where: str) -> int:
    value = table.get(key, default)
    if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
        raise InventoryError(f"{where}: '{key}' must be an integer between {low} and {high}")
    return value


def _table(value: Any, *, where: str) -> Mapping[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise InventoryError(f"{where} must be a mapping")
    return value


def _env(value: Any, *, where: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, item in _table(value, where=where).items():
        if not ENV_KEY.match(key):
            raise InventoryError(f"{where}: invalid variable name '{key}'")
        if isinstance(item, bool):
            item = str(item).lower()
        if not isinstance(item, (str, int, float)):
            raise InventoryError(f"{where}.{key}: value must be a string or number")
        text = str(item)
        if any(char in text for char in "\r\n\0"):
            raise InventoryError(f"{where}.{key}: value must be a single line")
        result[key] = text
    return result


def _match(pattern: re.Pattern[str], value: str, label: str, *, where: str) -> str:
    if not pattern.match(value) or ".." in value.split("/"):
        raise InventoryError(f"{where}: invalid {label} '{value}'")
    return value


def parse_inventory(document: Any, path: str = "") -> Inventory:
    root = _table(document, where="inventory")
    defaults = _table(root.get("defaults"), where="defaults")
    node_defaults = _table(defaults.get("node"), where="defaults.node")
    service_defaults = _table(defaults.get("service"), where="defaults.service")

    nodes: dict[str, Node] = {}
    for name, entry in _table(root.get("nodes"), where="nodes").items():
        where = f"nodes.{name}"
        table = {**node_defaults, **_table(entry, where=where)}
        _match(NAME, name, "node name", where=where)
        nodes[name] = Node(
            name=name,
            host=_match(HOST, _text(table, "host", where=where), "host", where=where),
            port=_number(table, "port", 22, 1, 65535, where=where),
            user=_match(USER, _text(table, "user", where=where), "user", where=where),
            ssh_key=_text(table, "ssh_key", where=where),
        )
    if not nodes:
        raise InventoryError("inventory defines no nodes")

    services: dict[str, Service] = {}
    for name, entry in _table(root.get("services"), where="services").items():
        where = f"services.{name}"
        table = {**service_defaults, **_table(entry, where=where)}
        _match(NAME, name, "service name", where=where)
        node = _text(table, "node", where=where)
        if node not in nodes:
            raise InventoryError(f"{where}: node '{node}' is not defined under nodes")
        directory = _text(table, "dir", "", where=where)
        if directory:
            _match(RELATIVE_PATH, directory, "dir", where=where)
        env_file = _text(table, "env_file", ".env", where=where)
        _match(RELATIVE_PATH, env_file, "env_file", where=where)
        base_dir = _text(table, "base_dir", DEFAULT_BASE_DIR, where=where)
        _match(REMOTE_BASE, base_dir, "base_dir", where=where)
        mcp_url = _text(table, "mcp_url", "", where=where)
        if mcp_url:
            parsed = urlparse(mcp_url)
            if parsed.scheme not in {"http", "https"} or not parsed.hostname:
                raise InventoryError(f"{where}: mcp_url must be an http(s) URL")
        agent_env = _env(_table(entry, where=where).get("agent_env"), where=f"{where}.agent_env")
        for key, url in agent_env.items():
            parsed_url = urlparse(url)
            if parsed_url.scheme not in {"http", "https"} or not parsed_url.hostname:
                raise InventoryError(f"{where}.agent_env.{key}: must be an http(s) URL")
        merged_shell = {**_env(service_defaults.get("shell_env"), where="defaults.service.shell_env"),
                        **_env(_table(entry, where=where).get("shell_env"), where=f"{where}.shell_env")}
        services[name] = Service(
            name=name,
            node=node,
            repo=_match(REPO, _text(table, "repo", where=where), "repo (https:// only)", where=where),
            ref=_match(REF, _text(table, "ref", "main", where=where), "ref", where=where),
            directory=directory,
            build=_text(table, "build", "", where=where),
            start=_text(table, "start", where=where),
            env_file=env_file,
            env=tuple(_env(_table(entry, where=where).get("env"), where=f"{where}.env").items()),
            shell_env=tuple(merged_shell.items()),
            base_dir=base_dir,
            timeout_seconds=_number(table, "timeout_seconds", DEFAULT_TIMEOUT_SECONDS, 60, 21600, where=where),
            mcp_url=mcp_url,
            verify_seconds=_number(table, "verify_seconds", DEFAULT_VERIFY_SECONDS, 0, 1800, where=where),
            agent_env=tuple(agent_env.items()),
            pre=_text(table, "pre", "", where=where),
        )
    if not services:
        raise InventoryError("inventory defines no services")

    known_hosts = _text(root, "known_hosts", DEFAULT_KNOWN_HOSTS, where="inventory")
    return Inventory(nodes=nodes, services=services, known_hosts=known_hosts, path=path)


def load_inventory(path: Path) -> Inventory:
    try:
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise InventoryError(f"inventory not found at {path}; copy deployer-config/inventory.example.yaml "
                             "to deployer-config/inventory.yaml and edit it") from error
    except (OSError, yaml.YAMLError) as error:
        raise InventoryError(f"cannot read inventory {path}: {error}") from error
    return parse_inventory(document, str(path))
