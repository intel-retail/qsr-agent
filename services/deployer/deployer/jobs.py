"""Background deployment jobs: one at a time, services in inventory order, status kept in memory."""

from __future__ import annotations

import secrets
import threading
from collections import deque
from collections.abc import Callable, Sequence
from datetime import datetime, timezone
from typing import Any

from .inventory import Inventory, InventoryError, Service
from .remote import Executor, build_payload, port_reachable, redact

Verifier = Callable[[str, float], bool]

LOG_LINES_KEPT = 200
LOG_LINES_REPORTED = 25
LOG_LINE_CHARS = 300
JOBS_KEPT = 10


class DeployBusy(RuntimeError):
    """A deployment is already running."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class JobManager:
    def __init__(self, load: Callable[[], Inventory], executor: Callable[[str], Executor],
                 script: str, verifier: Verifier = port_reachable) -> None:
        self._load = load
        self._executor = executor
        self._script = script
        self._verifier = verifier
        self._lock = threading.Lock()
        self._jobs: dict[str, dict[str, Any]] = {}
        self._logs: dict[tuple[str, str], deque[str]] = {}
        self._threads: dict[str, threading.Thread] = {}

    def start(self, names: Sequence[str] | None) -> dict[str, Any]:
        inventory = self._load()
        services = inventory.select(names)
        executor = self._executor(inventory.known_hosts)
        with self._lock:
            running = next((job_id for job_id, job in self._jobs.items() if job["status"] == "running"), None)
            if running:
                raise DeployBusy(f"deployment {running} is still running; check it with get_deployment_status")
            job_id = secrets.token_hex(4)
            self._jobs[job_id] = {
                "job_id": job_id, "status": "running", "started_at": _now(), "finished_at": None,
                "services": [{"service": s.name, "node": s.node, "host": inventory.nodes[s.node].host,
                              "status": "pending", "exit_code": None, "verified": None, "error": None,
                              "started_at": None, "finished_at": None} for s in services],
            }
            for old in list(self._jobs)[:-JOBS_KEPT]:
                self._jobs.pop(old)
                for key in [key for key in self._logs if key[0] == old]:
                    self._logs.pop(key)
            thread = threading.Thread(target=self._run, args=(job_id, inventory, services, executor),
                                      name=f"deploy-{job_id}", daemon=True)
            self._threads[job_id] = thread
        thread.start()
        return self.status(job_id)

    def wait(self, job_id: str, timeout: float | None = None) -> None:
        self._threads[job_id].join(timeout)

    def status(self, job_id: str | None = None) -> dict[str, Any]:
        with self._lock:
            if not self._jobs:
                return {"job_id": None, "status": "none", "services": [],
                        "note": "no deployment has run since the deployer started"}
            chosen = job_id or next(reversed(self._jobs))
            if chosen not in self._jobs:
                raise InventoryError(f"unknown deployment job '{chosen}'")
            job = self._jobs[chosen]
            return {**job, "services": [
                {**entry, "log_tail": list(self._logs.get((chosen, entry["service"]), ()))[-LOG_LINES_REPORTED:]}
                for entry in job["services"]]}

    def _update(self, job_id: str, index: int, **changes: Any) -> None:
        with self._lock:
            self._jobs[job_id]["services"][index].update(changes)

    def _run(self, job_id: str, inventory: Inventory, services: list[Service], executor: Executor) -> None:
        try:
            for index, service in enumerate(services):
                try:
                    self._deploy_one(job_id, index, inventory, service, executor)
                except Exception as error:  # e.g. the verifier; never leave a job reporting success
                    self._update(job_id, index, status="failed", finished_at=_now(),
                                 error=f"{type(error).__name__}: {error}"[:LOG_LINE_CHARS])
        finally:
            with self._lock:
                job = self._jobs.get(job_id)
                if job:
                    failed = any(entry["status"] == "failed" for entry in job["services"])
                    job.update(status="failed" if failed else "succeeded", finished_at=_now())

    def _deploy_one(self, job_id: str, index: int, inventory: Inventory, service: Service,
                    executor: Executor) -> None:
        log: deque[str] = deque(maxlen=LOG_LINES_KEPT)
        with self._lock:
            self._logs[(job_id, service.name)] = log

        def on_line(line: str) -> None:
            with self._lock:
                log.append(redact(line, service.secrets)[:LOG_LINE_CHARS])

        self._update(job_id, index, status="running", started_at=_now())
        try:
            code = executor(inventory.nodes[service.node], build_payload(service, self._script),
                            service.timeout_seconds, on_line)
        except Exception as error:  # SSH, key, host-key and timeout failures all fail only this service
            self._update(job_id, index, status="failed", finished_at=_now(),
                         error=redact(f"{type(error).__name__}: {error}", service.secrets)[:LOG_LINE_CHARS])
            return
        if code != 0:
            self._update(job_id, index, status="failed", exit_code=code, finished_at=_now(),
                         error=f"deploy script exited with status {code}")
            return
        verified = self._verifier(service.mcp_url, float(service.verify_seconds)) if service.mcp_url else None
        self._update(job_id, index, status="succeeded", exit_code=0, verified=verified, finished_at=_now())
