from __future__ import annotations

import sys
from collections.abc import Iterable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import yaml

from .event_agent import Capability, CapabilityCatalog, Skill, StaleContextError
from .learning import parse_frontmatter, read_skill_meta

ACCURACY_CONTEXT = "get_order_accuracy_context"
WEATHER_READ = "weather.get_weather_details"
# Skills for the services with built-in clients above: (name, description, required tools, optional tools).
# A skill is registered once all its required tools are. Skills for discovered services are declared in
# their own SKILL.md frontmatter instead (see register_declared_skills); nothing service-specific is added here.
BUILTIN_SKILLS: tuple[tuple[str, str, tuple[str, ...], tuple[str, ...]], ...] = (
    ("event-menu-decisions", "Weather and queue events: decide whether menu availability should change",
     ("kiosk.get_kiosk_context", "kiosk.change_menu_items"), (WEATHER_READ,)),
    ("kiosk-operations", "Restaurant operations, menu, queue, wait, staffing and ordering activity",
     ("kiosk.get_kiosk_context", "kiosk.change_menu_items"), ()),
    ("order-accuracy", "Order mismatches, accuracy alerts, station issues and remake recommendations",
     ("accuracy.get_order_accuracy_context", "accuracy.request_remake"), ()),
)
# Parsed `metadata.qsr` declarations by SKILL.md path, keyed on the file's mtime.
_DECLARED_SKILLS: dict[Path, tuple[float, dict[str, Any] | None]] = {}


class MergedAccuracyClient:
    """Take-away and dine-in Order Accuracy services as one `accuracy` service.

    Contexts are merged (an unreachable service is skipped while another answers) and a
    remake goes to the service that reported the order as flagged.
    """

    def __init__(self, clients: list[Any]) -> None:
        self.clients = clients

    def list_tools(self) -> list[dict[str, Any]]:
        return self.clients[0].list_tools()

    def _contexts(self) -> list[tuple[Any, dict[str, Any]]]:
        answered, error = [], None
        for client in self.clients:
            try:
                answered.append((client, client.call_tool(ACCURACY_CONTEXT)))
            except (RuntimeError, OSError, ValueError) as failure:
                error = failure
        if not answered:
            raise error or RuntimeError("no order-accuracy service answered")
        return answered

    def call_tool(self, name: str, arguments: dict[str, Any] | None = None) -> dict[str, Any]:
        if name == ACCURACY_CONTEXT:
            contexts = [context for _client, context in self._contexts()]
            merged = dict(contexts[0])
            for key in ("stations", "recent_orders", "alerts"):
                merged[key] = [entry for context in contexts for entry in context.get(key) or []]
            totals = {key: sum((context.get("summary") or {}).get(key) or 0 for context in contexts)
                      for key in ("orders_observed", "orders_accurate", "orders_flagged")}
            observed = totals["orders_observed"]
            merged["summary"] = {**(merged.get("summary") or {}), **totals,
                                 "accuracy_rate": round(totals["orders_accurate"] / observed, 3) if observed else None}
            merged["observed_at"] = min(context["observed_at"] for context in contexts)
            return merged
        order_id = (arguments or {}).get("order_id")
        if order_id is not None:
            for client, context in self._contexts():
                if any(order.get("order_id") == order_id and order.get("result") == "flagged"
                       for order in context.get("recent_orders") or []):
                    return client.call_tool(name, arguments)
            raise ValueError(f"no order-accuracy service has flagged order {order_id}")
        return self.clients[0].call_tool(name, arguments)


def validate_menu(arguments: dict[str, Any], observations: dict[str, Any]) -> None:
    context = observations["kiosk.get_kiosk_context"]
    _fresh(context)
    items = {item["id"]: item for item in context.get("menu", {}).get("items", [])}
    seen: set[str] = set()
    for change in arguments["changes"]:
        item_id = change["item_id"]
        if item_id not in items or item_id in seen:
            raise ValueError("menu changes require distinct live item IDs")
        if items[item_id]["available"] == change["available"]:
            raise ValueError(f"{item_id} already has the requested availability")
        if not change["reason"].strip():
            raise ValueError("each menu change needs a reason")
        seen.add(item_id)
    if not arguments["reason"].strip():
        raise ValueError("menu action needs a reason")


def validate_remake(arguments: dict[str, Any], observations: dict[str, Any]) -> None:
    context = observations["accuracy.get_order_accuracy_context"]
    _fresh(context)
    order = next((order for order in context.get("recent_orders", [])
                  if order.get("order_id") == arguments["order_id"]), None)
    if not order or order.get("result") != "flagged" or not order.get("issues"):
        raise ValueError("remake requires an exact currently flagged order with issue evidence")
    if not arguments["reason"].strip():
        raise ValueError("remake action needs a reason")


def validate_kiosk_settings(arguments: dict[str, Any], observations: dict[str, Any]) -> None:
    context = observations["kiosk.get_kiosk_context"]
    _fresh(context)
    operations = context.get("operations", {})
    current = {"mode": operations.get("kiosk_mode"), "active_kiosks": operations.get("active_kiosks"),
               "upsell_enabled": operations.get("upsell_enabled")}
    requested = {key: arguments[key] for key in current if key in arguments}
    if not requested:
        raise ValueError("kiosk settings action needs mode, active_kiosks or upsell_enabled")
    unchanged = [key for key, value in requested.items() if current[key] == value]
    if unchanged:
        raise ValueError(f"already in the requested state: {', '.join(unchanged)}")
    if "active_kiosks" in requested and requested["active_kiosks"] > operations.get("max_kiosks", 0):
        raise ValueError("active_kiosks exceeds max_kiosks")
    if not arguments["reason"].strip():
        raise ValueError("kiosk settings action needs a reason")


def register_learned_skills(catalog: CapabilityCatalog, directory: Path) -> dict[str, str]:
    """(Re)register learned-*/SKILL.md skills; return skipped skill names with reasons."""
    for name, skill in list(catalog.skills.items()):
        if skill.events:
            catalog.remove_skill(name)
    skipped: dict[str, str] = {}
    for path in sorted(directory.glob("learned-*/SKILL.md")):
        try:
            meta = read_skill_meta(path)
            tools = tuple(meta["tools"])
            missing = [tool for tool in tools if tool not in catalog.tools]
            if missing:
                raise ValueError(f"unregistered tools: {', '.join(missing)}")
            for tool in tools:
                if not set(catalog.tools[tool].required_reads) <= set(tools):
                    raise ValueError(f"{tool} needs its required reads listed")
            catalog.register_skill(Skill(meta["name"], meta["description"], path, tools, tuple(meta["events"])))
        except (OSError, ValueError, yaml.YAMLError) as error:
            skipped[path.parent.name] = str(error)
            print(f"[autonomy] skipped learned skill {path.parent.name}: {error}", file=sys.stderr)
    return skipped


def _fresh(context: dict[str, Any]) -> None:
    observed = datetime.fromisoformat(context.get("observed_at", "").replace("Z", "+00:00"))
    if observed.tzinfo is None:
        raise ValueError("context has an invalid observation time")
    age = (datetime.now(UTC) - observed).total_seconds()
    if age < -30:
        raise ValueError("context has a future observation time")
    if age > 120:
        raise StaleContextError("context is stale")


def register_defaults(
    catalog: CapabilityCatalog, root: Path, kiosk: Any | None, accuracy: Any | None, weather: Any | None = None
) -> None:
    """Built-in capabilities of the configured services; a skill is registered only when all its tools are."""
    if kiosk is not None:
        catalog.register_tool(Capability(
            "kiosk.get_kiosk_context", "Read current menu, queue, wait, staffing and demand",
            kiosk, "get_kiosk_context", True,
        ))
        catalog.register_tool(Capability(
            "kiosk.change_menu_items", "Propose up to three menu availability changes; no prices",
            kiosk, "change_menu_items", False, ("kiosk.get_kiosk_context",), validate_menu,
        ))
        catalog.register_tool(Capability(
            "kiosk.update_kiosk_settings",
            "Propose kiosk operating settings: express/standard mode, active kiosks, upsell prompts",
            kiosk, "update_kiosk_settings", False, ("kiosk.get_kiosk_context",), validate_kiosk_settings,
        ))
    if accuracy is not None:
        catalog.register_tool(Capability(
            "accuracy.get_order_accuracy_context", "Read accuracy, flagged orders, mismatches and stations",
            accuracy, "get_order_accuracy_context", True,
        ))
        catalog.register_tool(Capability(
            "accuracy.request_remake", "Propose remaking an exact flagged order",
            accuracy, "request_remake", False, ("accuracy.get_order_accuracy_context",), validate_remake,
        ))
    if weather is not None:
        catalog.register_tool(Capability(
            WEATHER_READ,
            "Read current store-location weather: condition, is_raining, temperature_c, precipitation",
            weather, "get_weather_details", True, store_scoped=False,
        ))
    register_skills(catalog, root)


def register_skills(catalog: CapabilityCatalog, root: Path, disabled: Iterable[str] = ()) -> None:
    """Register the built-in and declared skills whose tools are all in the catalog (idempotent)."""
    skip = set(disabled)
    for name, description, required, optional in BUILTIN_SKILLS:
        if name in catalog.skills or name in skip or not all(tool in catalog.tools for tool in required):
            continue
        tools = (*required, *(tool for tool in optional if tool in catalog.tools))
        _register(catalog, name, description, root / "qsr-skills" / name / "SKILL.md", tools)
    register_declared_skills(catalog, root / "qsr-skills", skip)


def register_declared_skills(catalog: CapabilityCatalog, skills_dir: Path, disabled: Iterable[str] = ()) -> None:
    """Register skills that declare themselves for the event agent in `metadata.qsr` of their SKILL.md.

    A service's skill may only grant that service's own tools (`service` + unprefixed `tools`), and is
    offered for its `event_types` only (empty = any event). Registered once the service is discovered.
    """
    skip = set(disabled)
    for path in sorted(skills_dir.glob("*/SKILL.md")):
        meta = _declared_meta(path)
        if meta is None or meta["name"] in catalog.skills or meta["name"] in skip:
            continue
        tools = tuple(f"{meta['service']}.{tool}" for tool in meta["tools"])
        if all(tool in catalog.tools for tool in tools):
            _register(catalog, meta["name"], meta["description"], path, tools, tuple(meta["event_types"]))


def _declared_meta(path: Path) -> dict[str, Any] | None:
    """Validated `metadata.qsr` of a service skill, or None when the skill is chat-only or invalid."""
    try:
        mtime = path.stat().st_mtime
    except OSError:
        return None
    cached = _DECLARED_SKILLS.get(path)
    if cached and cached[0] == mtime:
        return cached[1]
    meta = None
    try:
        front = parse_frontmatter(path.read_text(encoding="utf-8"))
        qsr = (front.get("metadata") or {}).get("qsr")
        if isinstance(qsr, dict):
            meta = _validate_declaration(front, qsr, path.parent.name)
    except (OSError, ValueError, yaml.YAMLError) as error:
        print(f"[autonomy] skipped skill declaration {path.parent.name}: {error}", file=sys.stderr)
    _DECLARED_SKILLS[path] = (mtime, meta)
    return meta


def _validate_declaration(front: dict[str, Any], qsr: dict[str, Any], directory: str) -> dict[str, Any]:
    name, description = front.get("name"), front.get("description")
    if name != directory:
        raise ValueError("skill name must match its directory")
    if not isinstance(description, str) or not description.strip():
        raise ValueError("description is required")
    service, tools, event_types = qsr.get("service"), qsr.get("tools"), qsr.get("event_types", [])
    if not isinstance(service, str) or not service or "." in service:
        raise ValueError("metadata.qsr.service must be the skill's own service name")
    if not isinstance(tools, list) or not tools or not all(isinstance(tool, str) and tool for tool in tools):
        raise ValueError("metadata.qsr.tools must be a non-empty list of tool names")
    if any("." in tool for tool in tools):
        raise ValueError("metadata.qsr.tools may only name the skill's own service tools (no '<service>.' prefix)")
    if not isinstance(event_types, list) or not all(isinstance(kind, str) and kind for kind in event_types):
        raise ValueError("metadata.qsr.event_types must be a list of event type names")
    return {"name": name, "description": description.strip(), "service": service, "tools": tools,
            "event_types": event_types}


def _register(catalog: CapabilityCatalog, name: str, description: str, path: Path, tools: tuple[str, ...],
              event_types: tuple[str, ...] = ()) -> None:
    # The catalog requires an action's context reads to be part of the skill.
    tools += tuple(dict.fromkeys(read for tool in tools for read in catalog.tools[tool].required_reads
                                 if read not in tools))
    catalog.register_skill(Skill(name, description, path, tools, event_types=event_types))
